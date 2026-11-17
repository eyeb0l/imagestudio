import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import ImageStudio

/// Real GIF files for the tests below.
enum TestGIF {
    /// One full-size solid-colour frame per entry, encoded by ImageIO.
    static func make(frames: [(color: UIColor, delay: Double)], side: Int = 16) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        for frame in frames {
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
                frame.color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
            CGImageDestinationAddImage(destination, image.cgImage!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// An 8×8 red frame, then a frame that only paints the top-left 2×2 pixels green and keeps
    /// the rest, as an optimised GIF does. Written by hand, as ImageIO's encoder won't produce one.
    static func partialUpdates() -> Data {
        var data = Data("GIF89a".utf8)
        data += [8, 0, 8, 0, 0xF0, 0, 0] // logical screen, 2-colour global palette
        data += [0xFF, 0, 0, 0, 0xFF, 0] // palette: 0 is red, 1 is green
        func frame(x: UInt8, y: UInt8, side: UInt8, palette index: UInt8) -> [UInt8] {
            var bytes: [UInt8] = [0x21, 0xF9, 0x04, 0x04, 10, 0, 0, 0] // keep the previous frame; 100 ms
            bytes += [0x2C, x, 0, y, 0, side, 0, side, 0, 0, 2] // image descriptor; LZW minimum code size
            let block = lzwLiterals(Array(repeating: index, count: Int(side) * Int(side)))
            bytes += [UInt8(block.count)] + block + [0]
            return bytes
        }
        data += frame(x: 0, y: 0, side: 8, palette: 0)
        data += frame(x: 0, y: 0, side: 2, palette: 1)
        data += [0x3B]
        return data
    }

    /// Valid LZW that never uses the dictionary. Starts with a clear code and restarts before the
    /// code size would grow, so every code is 3 bits.
    private static func lzwLiterals(_ pixels: [UInt8]) -> [UInt8] {
        var codes: [UInt8] = [4]
        for (index, pixel) in pixels.enumerated() {
            if index > 0, index.isMultiple(of: 2) { codes.append(4) }
            codes.append(pixel)
        }
        codes.append(5)
        var output: [UInt8] = []
        var buffer = 0
        var bits = 0
        for code in codes {
            buffer |= Int(code) << bits
            bits += 3
            while bits >= 8 {
                output.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                bits -= 8
            }
        }
        if bits > 0 { output.append(UInt8(buffer & 0xFF)) }
        return output
    }

    /// The RGB value of a pixel, drawn into a known format.
    static func pixel(of image: UIImage, x: Int = 0, y: Int = 0) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try #require(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                      bytesPerRow: cgImage.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        bytes.withUnsafeMutableBytes { _ in
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        let offset = (y * cgImage.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    static func temporaryFile(_ data: Data, extension pathExtension: String = "gif") throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(pathExtension)")
        try data.write(to: url)
        return url
    }
}

@Suite("GIF settings")
struct GIFSettingsTests {
    private var gif: GenerationSettings {
        var settings = GenerationSettings()
        settings.outputFormat = .gif
        return settings
    }

    @Test func describesTheFormat() {
        #expect(OutputFormat.gif.fileExtension == "gif")
        #expect(OutputFormat.gif.contentType == .gif)
        #expect(!OutputFormat.gif.supportsCompression)
        #expect(!OutputFormat.gif.supportsTransparency)
        #expect(OutputFormat.gif.isGenerationOnly)
        #expect(OutputFormat.gif.isAnimated)
        for format in [OutputFormat.png, .jpeg, .webp] {
            #expect(!format.isGenerationOnly)
            #expect(!format.isAnimated)
            #expect(format.libraryBadge == nil)
        }
    }

    @Test func isOfferedOnlyByGPTImage26() {
        for model in ImageModel.allCases {
            let expected = model == .flare26 || model == .sunburst26
            #expect(model.supportedFormats.contains(.gif) == expected, "\(model)")
            #expect(!model.formats(hasReferences: true).contains(.gif), "\(model)")
        }
    }

    @Test func defaultsMatchTheAPI() {
        #expect(GenerationSettings().frameCount == 9)
        #expect(GenerationSettings().frameDurationMs == 200)
    }

    @Test(arguments: [
        (1, 2), (2, 2), (9, 9), (16, 16), (17, 16), (64, 16), (-3, 2),
    ])
    func clampsFrameCount(input: Int, expected: Int) {
        var settings = gif
        settings.frameCount = input
        #expect(settings.normalized().frameCount == expected)
    }

    @Test(arguments: [
        (0, 20), (19, 20), (20, 20), (24, 20), (25, 30), (205, 210), (2000, 2000), (2004, 2000), (9000, 2000), (-5, 20),
    ])
    func clampsAndRoundsFrameDuration(input: Int, expected: Int) {
        var settings = gif
        settings.frameDurationMs = input
        #expect(settings.normalized().frameDurationMs == expected)
    }

    @Test func hiddenFrameSettingsResetSoEqualityStaysMeaningful() {
        var settings = gif
        settings.frameCount = 4
        settings.frameDurationMs = 500
        settings.outputFormat = .webp
        let normalized = settings.normalized()
        #expect(normalized.frameCount == 9)
        #expect(normalized.frameDurationMs == 200)
        var defaults = GenerationSettings()
        defaults.outputFormat = .webp
        #expect(normalized == defaults)
    }

    @Test func switchingToAModelWithoutGIFFallsBackToPNG() {
        var settings = gif
        settings.frameCount = 4
        settings.model = .flare25
        let normalized = settings.normalized()
        #expect(normalized.outputFormat == .png)
        #expect(normalized.frameCount == 9)
    }

    @Test func transparentBackgroundLeavesNoGIFOrFrameSettings() {
        var settings = gif
        settings.frameCount = 4
        settings.background = .transparent
        let normalized = settings.normalized()
        #expect(normalized.outputFormat == .png)
        #expect(normalized.frameCount == 9)
    }

    @Test func referencesRuleOutGIF() {
        var settings = gif
        settings.frameCount = 4
        settings.frameDurationMs = 500

        let kept = settings.normalized(hasReferences: false)
        #expect(kept.outputFormat == .gif)
        #expect(kept.frameCount == 4)
        #expect(kept.frameDurationMs == 500)

        let coerced = settings.normalized(hasReferences: true)
        #expect(coerced.outputFormat == .png)
        #expect(coerced.frameCount == 9)
        #expect(coerced.frameDurationMs == 200)
    }

    @Test func referencesLeaveOtherFormatsAlone() {
        var settings = GenerationSettings()
        settings.outputFormat = .webp
        settings.compression = 60
        let normalized = settings.normalized(hasReferences: true)
        #expect(normalized.outputFormat == .webp)
        #expect(normalized.compression == 60)
    }

    @Test func decodesLeniently() throws {
        let invalid = #"{"outputFormat":"gif","frameCount":"lots","frameDurationMs":null}"#
        let settings = try JSONDecoder().decode(GenerationSettings.self, from: Data(invalid.utf8))
        #expect(settings.outputFormat == .gif)
        #expect(settings.frameCount == 9)
        #expect(settings.frameDurationMs == 200)

        let older = #"{"model":"gpt-image-2.6-flare","outputFormat":"png"}"#
        let saved = try JSONDecoder().decode(GenerationSettings.self, from: Data(older.utf8))
        #expect(saved.frameCount == 9)
        #expect(saved.frameDurationMs == 200)

        let outOfRange = #"{"outputFormat":"gif","frameCount":500,"frameDurationMs":5}"#
        let clamped = try JSONDecoder().decode(GenerationSettings.self, from: Data(outOfRange.utf8)).normalized()
        #expect(clamped.frameCount == 16)
        #expect(clamped.frameDurationMs == 20)
    }

    @Test func roundTrips() throws {
        var settings = gif
        settings.frameCount = 12
        settings.frameDurationMs = 80
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GenerationSettings.self, from: data) == settings)
    }
}

@Suite("GIF requests")
struct GIFRequestTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sendsFrameFieldsAndNoCompressionForGIF() throws {
        var settings = GenerationSettings()
        settings.outputFormat = .gif
        settings.frameCount = 12
        settings.frameDurationMs = 80
        settings.compression = 50
        let body = try json(OpenAIImageClient.requestBody(prompt: "x", settings: settings))
        #expect(body["output_format"] as? String == "gif")
        #expect(body["frame_count"] as? Int == 12)
        #expect(body["frame_duration_ms"] as? Int == 80)
        #expect(body["output_compression"] == nil)
    }

    @Test func clampsFrameFieldsInTheBody() throws {
        var settings = GenerationSettings()
        settings.outputFormat = .gif
        settings.frameCount = 64
        settings.frameDurationMs = 3
        let body = try json(OpenAIImageClient.requestBody(prompt: "x", settings: settings))
        #expect(body["frame_count"] as? Int == 16)
        #expect(body["frame_duration_ms"] as? Int == 20)
    }

    @Test(arguments: [OutputFormat.png, .jpeg, .webp])
    func omitsFrameFieldsForOtherFormats(format: OutputFormat) throws {
        var settings = GenerationSettings()
        settings.outputFormat = format
        settings.frameCount = 12
        settings.frameDurationMs = 80
        let body = try json(OpenAIImageClient.requestBody(prompt: "x", settings: settings))
        #expect(body["frame_count"] == nil)
        #expect(body["frame_duration_ms"] == nil)
    }

    @Test func modelWithoutGIFNeverRequestsIt() throws {
        var settings = GenerationSettings()
        settings.model = .sunburst25
        settings.outputFormat = .gif
        let body = try json(OpenAIImageClient.requestBody(prompt: "x", settings: settings))
        #expect(body["output_format"] as? String == "png")
        #expect(body["frame_count"] == nil)
    }

    @Test func editRequestsNeverAskForGIF() {
        var settings = GenerationSettings()
        settings.outputFormat = .gif
        settings.frameCount = 12
        settings.frameDurationMs = 80
        let body = OpenAIImageClient.editRequestBody(prompt: "x", settings: settings, references: [], boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"output_format\"\r\n\r\npng\r\n"))
        #expect(!text.contains("gif"))
        #expect(!text.contains("frame_count"))
        #expect(!text.contains("frame_duration_ms"))
    }

    @Test func ticketsWithReferencesNeverCarryGIF() throws {
        var settings = GenerationSettings()
        settings.outputFormat = .gif
        settings.frameCount = 12

        let plain = GenerationTicket(jobID: UUID(), prompt: "x", settings: settings, startedAt: .now)
        #expect(plain.settings.outputFormat == .gif)
        #expect(plain.settings.frameCount == 12)

        let withReferences = GenerationTicket(jobID: UUID(), prompt: "x", settings: settings, startedAt: .now,
                                              referenceFileNames: ["a.jpg"])
        #expect(withReferences.settings.outputFormat == .png)
        #expect(withReferences.settings.frameCount == 9)
        #expect(withReferences.nextAttempt().settings.outputFormat == .png)

        // Also when an in-flight task's ticket is read back after a relaunch.
        let forged = """
        {"jobID":"\(UUID().uuidString)","prompt":"x","settings":{"outputFormat":"gif"},"startedAt":0,"referenceFileNames":["a.jpg"]}
        """
        let decoded = try JSONDecoder().decode(GenerationTicket.self, from: Data(forged.utf8))
        #expect(decoded.settings.outputFormat == .png)
    }

    @Test func previewAccessErrorsAreReadable() {
        var gif = GenerationSettings()
        gif.outputFormat = .gif
        let forbidden = OpenAIError.api(status: 403, message: "Your organization lacks access.", code: nil)

        #expect(Studio.message(for: forbidden, settings: gif)
            == "Your organization lacks access. GIF output may need preview access for this model.")
        #expect(Studio.message(for: OpenAIError.api(status: 403, message: nil, code: nil), settings: gif)
            == "OpenAI returned an error (HTTP 403). GIF output may need preview access for this model.")
        // Other formats and other errors are left as they are.
        #expect(Studio.message(for: forbidden, settings: GenerationSettings()) == "Your organization lacks access.")
        let tooLarge = OpenAIError.api(status: 400, message: "Reduce frame_count, the frame size or n.", code: nil)
        #expect(Studio.message(for: tooLarge, settings: gif) == "Reduce frame_count, the frame size or n.")
        #expect(!RetryPolicy.isTransient(forbidden))
    }
}

@Suite("GIF and the composer")
@MainActor
struct GIFComposerTests {
    private var gifDefaults: GenerationSettings {
        var settings = GenerationSettings()
        settings.outputFormat = .gif
        settings.frameCount = 12
        settings.frameDurationMs = 80
        return settings
    }

    private func attachReference(to composer: Composer) async {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        await composer.addReferences([{ png }])
    }

    @Test func attachingAReferenceChangesTheFormatAndRemovingItRestoresIt() async throws {
        let composer = Composer()
        let defaults = gifDefaults
        #expect(composer.settings(defaults: defaults).outputFormat == .gif)

        await attachReference(to: composer)
        let name = try #require(composer.references.first)
        defer { ReferenceStore.delete([name]) }

        let attached = composer.settings(defaults: defaults)
        #expect(attached.outputFormat == .png)
        #expect(attached.frameCount == 9)
        #expect(composer.overrides == nil) // the saved defaults aren't touched
        #expect(composer.draftSettings(defaults: defaults) == defaults)

        composer.removeReference(name)
        let restored = composer.settings(defaults: defaults)
        #expect(restored.outputFormat == .gif)
        #expect(restored.frameCount == 12)
    }

    @Test func onlyWhatChangedIsAppliedToTheDraft() async throws {
        let composer = Composer()
        let defaults = gifDefaults
        await attachReference(to: composer)
        let name = try #require(composer.references.first)
        defer { ReferenceStore.delete([name]) }

        // Several changes at once, none of them to the format held back.
        var edited = composer.settings(defaults: defaults)
        edited.quality = .low
        edited.count = 3
        edited.complexity = .medium
        composer.applyEdit(edited, defaults: defaults)

        let draft = composer.draftSettings(defaults: defaults)
        #expect(draft.outputFormat == .gif)
        #expect(draft.frameCount == defaults.frameCount)
        #expect(draft.quality == .low && draft.count == 3 && draft.complexity == .medium)

        // Choosing another format is a new choice.
        edited = composer.settings(defaults: defaults)
        edited.outputFormat = .jpeg
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.draftSettings(defaults: defaults).outputFormat == .jpeg)
    }

    @Test func aTransparentBackgroundChosenWhileHeldBackWinsOverGIF() async throws {
        let composer = Composer()
        let defaults = gifDefaults
        await attachReference(to: composer)
        let name = try #require(composer.references.first)

        var edited = composer.settings(defaults: defaults)
        edited.background = .transparent
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.settings(defaults: defaults).background == .transparent)

        // GIFs can't be transparent, so the later choice stands, visibly.
        composer.removeReference(name)
        let released = composer.settings(defaults: defaults)
        #expect(released.background == .transparent)
        #expect(released.outputFormat == .png)
    }

    @Test func editsWithAReferenceAttachedKeepTheHeldBackFormat() async throws {
        let composer = Composer()
        let defaults = gifDefaults
        await attachReference(to: composer)
        let name = try #require(composer.references.first)
        defer { ReferenceStore.delete([name]) }

        var edited = composer.settings(defaults: defaults)
        edited.quality = .high
        composer.applyEdit(edited, defaults: defaults)

        #expect(composer.settings(defaults: defaults).outputFormat == .png)
        #expect(composer.settings(defaults: defaults).quality == .high)
        // "Save as Defaults" uses the draft, so it can't replace GIF with the stand-in PNG.
        let draft = composer.draftSettings(defaults: defaults)
        #expect(draft.outputFormat == .gif)
        #expect(draft.frameCount == 12)
        #expect(draft.frameDurationMs == 80)
        #expect(draft.quality == .high)
    }

    @Test func choosingAnotherFormatWithAReferenceAttachedSticks() async throws {
        let composer = Composer()
        let defaults = gifDefaults
        await attachReference(to: composer)
        let name = try #require(composer.references.first)
        defer { ReferenceStore.delete([name]) }

        var edited = composer.settings(defaults: defaults)
        edited.outputFormat = .webp
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.draftSettings(defaults: defaults).outputFormat == .webp)
        #expect(composer.settings(defaults: defaults).outputFormat == .webp)
    }

    @Test func switchingModelWithAReferenceAttachedDropsGIF() async throws {
        let composer = Composer()
        let defaults = gifDefaults
        await attachReference(to: composer)
        let name = try #require(composer.references.first)
        defer { ReferenceStore.delete([name]) }

        var edited = composer.settings(defaults: defaults)
        edited.model = .flare25
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.draftSettings(defaults: defaults).outputFormat == .png)
    }

    @Test func overrideEqualityIgnoresHiddenFrameSettings() {
        let composer = Composer()
        let defaults = GenerationSettings()
        var edited = defaults
        edited.outputFormat = .gif
        edited.frameCount = 4
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.overrides?.frameCount == 4)

        var back = composer.settings(defaults: defaults)
        back.outputFormat = .png
        composer.applyEdit(back, defaults: defaults)
        #expect(composer.overrides == nil)
    }

    @Test func reusingAGIFKeepsItsFrameSettings() {
        let composer = Composer()
        let image = GeneratedImage(prompt: "p", settings: gifDefaults, width: 1, height: 1, fileName: "f.gif",
                                   fileSize: 1, batchID: UUID(), duration: 1)
        composer.reuse(image, defaults: GenerationSettings())
        let settings = composer.settings(defaults: GenerationSettings())
        #expect(settings.outputFormat == .gif)
        #expect(settings.frameCount == 12)
        #expect(settings.frameDurationMs == 80)
    }

    @Test func reusingAPNGOverReferencesDoesNotBringGIFBack() async throws {
        let composer = Composer()
        let defaults = gifDefaults
        await attachReference(to: composer)
        let name = try #require(composer.references.first)
        defer { ReferenceStore.delete([name]) }

        let png = GeneratedImage(prompt: "p", settings: GenerationSettings(), width: 1, height: 1, fileName: "f.png",
                                 fileSize: 1, batchID: UUID(), duration: 1)
        composer.reuse(png, defaults: defaults)
        #expect(composer.references.isEmpty)
        #expect(composer.settings(defaults: defaults).outputFormat == .png)
    }
}

@Suite("GIF library records")
@MainActor
struct GIFLibraryTests {
    private var gif: GenerationSettings {
        var settings = GenerationSettings()
        settings.model = .sunburst26
        settings.outputFormat = .gif
        settings.frameCount = 5
        settings.frameDurationMs = 70
        settings.compression = 40
        return settings
    }

    private func record(_ settings: GenerationSettings, references: [String] = []) -> GeneratedImage {
        GeneratedImage(prompt: "p", settings: settings, width: 1, height: 1, fileName: "f",
                       fileSize: 1, batchID: UUID(), duration: 1, referenceFileNames: references)
    }

    @Test func storesFrameSettingsForRegeneration() {
        let image = record(gif)
        #expect(image.frameCount == 5)
        #expect(image.frameDurationMs == 70)
        #expect(image.outputCompression == nil)

        let settings = image.settings
        #expect(settings.outputFormat == .gif)
        #expect(settings.model == .sunburst26)
        #expect(settings.frameCount == 5)
        #expect(settings.frameDurationMs == 70)
        #expect(settings.count == 1)
    }

    @Test func otherFormatsStoreNoFrameSettings() {
        let image = record(GenerationSettings())
        #expect(image.frameCount == nil)
        #expect(image.frameDurationMs == nil)
        #expect(image.settings.frameCount == 9)
        #expect(image.settings.frameDurationMs == 200)
    }

    @Test func existingRecordsWithoutFrameSettingsStillRegenerate() {
        let image = record(gif)
        image.frameCount = nil
        image.frameDurationMs = nil
        #expect(image.settings.outputFormat == .gif)
        #expect(image.settings.frameCount == 9)
        #expect(image.settings.frameDurationMs == 200)
    }

    @Test func regeneratingWithReferencesNeverRequestsGIF() {
        #expect(record(gif, references: ["a.jpg"]).settings.outputFormat == .png)
    }

    @Test func committingAGIFKeepsItsBytesExtensionAndSize() async throws {
        let data = TestGIF.make(frames: [(.red, 0.1), (.blue, 0.1)], side: 32)
        let container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let ticket = GenerationTicket(jobID: UUID(), prompt: "A fox", settings: gif, startedAt: .now)
        let output = OpenAIImageClient.Output(images: [data], revisedPrompts: [nil], size: "1024x1024", quality: "high",
                                              background: "opaque", outputFormat: "gif", inputTokens: 1, outputTokens: 1)
        var written: [String: Data] = [:]
        let saved = try await Studio.commit(output, for: ticket, in: container.mainContext,
                                            writeFile: { written[$1] = $0 }, removeFile: { _ in })
        let image = try #require(saved.first)
        #expect(image.fileName.hasSuffix(".gif"))
        #expect(written[image.fileName] == data)
        #expect(image.format == .gif)
        #expect(image.width == 32)
        #expect(image.height == 32)
        #expect(image.frameCount == 5)
    }

    @Test func copyPutsTheOriginalBytesOnThePasteboard() throws {
        let data = TestGIF.make(frames: [(.red, 0.1), (.blue, 0.1)])
        let fileName = ImageStore.makeFileName(format: .gif)
        try data.write(to: ImageStore.url(for: fileName))
        defer { try? ImageStore.delete(fileName: fileName) }

        let image = GeneratedImage(prompt: "p", settings: gif, width: 16, height: 16, fileName: fileName,
                                   fileSize: data.count, batchID: UUID(), duration: 1)
        #expect(image.copyToPasteboard())
        #expect(UIPasteboard.general.data(forPasteboardType: UTType.gif.identifier) == data)
    }
}

@Suite("GIF decoding")
struct GIFDecodingTests {
    private let sample: [(color: UIColor, delay: Double)] = [(.red, 0.1), (.green, 0.25), (.blue, 0.05)]

    @Test func readsTheTimingOfEveryFrame() throws {
        let decoder = try #require(AnimatedImageDecoder(data: TestGIF.make(frames: sample)))
        #expect(decoder.frameDelays.count == 3)
        for (delay, expected) in zip(decoder.frameDelays, sample.map(\.delay)) {
            #expect(abs(delay - expected) < 0.001)
        }
    }

    @Test func keepsShortDelaysAndReplacesMissingOnes() throws {
        let short = try #require(AnimatedImageDecoder(data: TestGIF.make(frames: [(.red, 0.02), (.blue, 0.02)])))
        #expect(abs(short.frameDelays[0] - 0.02) < 0.001) // the API's minimum isn't slowed down
        let none = try #require(AnimatedImageDecoder(data: TestGIF.make(frames: [(.red, 0), (.blue, 0)])))
        #expect(none.frameDelays == [AnimatedImageDecoder.fallbackDelay, AnimatedImageDecoder.fallbackDelay])
    }

    @Test func decodesEachFrame() async throws {
        let decoder = try #require(AnimatedImageDecoder(data: TestGIF.make(frames: sample)))
        let first = try await #require(decoder.frame(at: 0))
        let second = try await #require(decoder.frame(at: 1))
        #expect(try TestGIF.pixel(of: first).r > 200)
        #expect(try TestGIF.pixel(of: first).g < 60)
        #expect(try TestGIF.pixel(of: second).g > 150)
        #expect(try TestGIF.pixel(of: second).r < 60)
        #expect(await decoder.frame(at: 3) == nil)
    }

    @Test func compositesFramesThatOnlyUpdatePartOfTheImage() async throws {
        let data = TestGIF.partialUpdates()
        let decoder = try #require(AnimatedImageDecoder(data: data))
        #expect(decoder.frameDelays.count == 2)
        // Out of order on purpose: looping goes back to the first frame.
        for index in [1, 0, 1] {
            let frame = try await #require(decoder.frame(at: index))
            #expect(frame.cgImage?.width == 8)
            let corner = try TestGIF.pixel(of: frame, x: 0, y: 0)
            let far = try TestGIF.pixel(of: frame, x: 7, y: 7)
            #expect(far.r > 200 && far.g < 60, "frame \(index) lost what the first frame painted")
            if index == 1 {
                #expect(corner.g > 150 && corner.r < 60)
            } else {
                #expect(corner.r > 200 && corner.g < 60)
            }
        }
    }

    @Test func downsamplesFrames() async throws {
        let decoder = try #require(AnimatedImageDecoder(data: TestGIF.make(frames: sample, side: 64)))
        let frame = try await #require(decoder.frame(at: 0, maxPixelSize: 20))
        #expect(frame.cgImage?.width == 20)
    }

    @Test func rejectsFilesThatAreNotGIFs() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        #expect(AnimatedImageDecoder(data: png) == nil)
        #expect(AnimatedImageDecoder(data: Data("nope".utf8)) == nil)
    }

    @Test func thumbnailsAndSizeComeFromTheFirstFrame() async throws {
        let data = TestGIF.make(frames: sample, side: 40)
        let size = try #require(ImageStore.pixelSize(of: data))
        #expect(size.width == 40)
        #expect(size.height == 40)

        let url = try TestGIF.temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let thumbnail = try #require(await ImageLoader.shared.image(at: url, maxPixelSize: 20))
        #expect(thumbnail.cgImage?.width == 20)
        #expect(try TestGIF.pixel(of: thumbnail).r > 200)
        #expect(try TestGIF.pixel(of: thumbnail).g < 60)
    }

    @Test @MainActor func playbackLoopsAtTheFilesTiming() async throws {
        let frames: [(color: UIColor, delay: Double)] = [(.red, 0.1), (.green, 0.05), (.blue, 0.05)]
        let url = try TestGIF.temporaryFile(TestGIF.make(frames: frames))
        defer { try? FileManager.default.removeItem(at: url) }

        var colours: [String] = []
        var finished: CheckedContinuation<Void, Never>?
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            await AnimatedImageDecoder.play(url: url) { frame in
                guard let pixel = try? TestGIF.pixel(of: frame) else { return }
                colours.append(pixel.r > 200 ? "r" : pixel.g > 150 ? "g" : "b")
                if colours.count == 7 {
                    finished?.resume()
                    finished = nil
                }
            }
        }
        await withCheckedContinuation { finished = $0 }
        let elapsed = clock.now - start
        task.cancel()
        await task.value

        // Two full loops: 0.2 s each, so the seventh frame (the start of the third) is due at 0.4 s.
        #expect(colours == ["r", "g", "b", "r", "g", "b", "r"])
        #expect(elapsed >= .milliseconds(390))
    }

    @Test @MainActor func cancellingStopsPlayback() async throws {
        let url = try TestGIF.temporaryFile(TestGIF.make(frames: [(.red, 0.02), (.blue, 0.02)]))
        defer { try? FileManager.default.removeItem(at: url) }
        var shown = 0
        let task = Task { await AnimatedImageDecoder.play(url: url) { _ in shown += 1 } }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        let atCancel = shown
        #expect(atCancel > 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown == atCancel)
    }

    @Test @MainActor func stillsDoNotPlay() async throws {
        let png = try TestGIF.temporaryFile(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in },
                                            extension: "png")
        let oneFrame = try TestGIF.temporaryFile(TestGIF.make(frames: [(.red, 0.1)]))
        defer {
            try? FileManager.default.removeItem(at: png)
            try? FileManager.default.removeItem(at: oneFrame)
        }
        var shown = 0
        await AnimatedImageDecoder.play(url: png) { _ in shown += 1 }
        await AnimatedImageDecoder.play(url: oneFrame) { _ in shown += 1 }
        await AnimatedImageDecoder.play(url: URL.temporaryDirectory.appending(path: "missing.gif")) { _ in shown += 1 }
        #expect(shown == 0)
    }

    @Test func usingAGIFAsAReferenceReencodesItsFirstFrame() async throws {
        let data = TestGIF.make(frames: sample, side: 40)
        let (encoded, type) = try ReferenceStore.normalize(data)
        #expect(type == .png || type == .jpeg)

        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(CGImageSourceGetType(source) as String? == type.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 40)
        #expect(try TestGIF.pixel(of: UIImage(cgImage: image)).r > 200)

        let url = try TestGIF.temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let name = try await ReferenceStore.importFile(at: url)
        defer { ReferenceStore.delete([name]) }
        #expect(!name.hasSuffix(".gif"))
        let mime = ReferenceStore.mimeType(for: name)
        #expect(mime == "image/png" || mime == "image/jpeg")
    }
}
