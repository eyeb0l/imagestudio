import Foundation
import ImageIO
import PencilKit
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import ImageStudio

// MARK: - Helpers

/// A straight stroke in canvas coordinates.
private func stroke(from start: CGPoint, to end: CGPoint, width: CGFloat = 4) -> PKStroke {
    let points = (0...24).map { step -> PKStrokePoint in
        let t = CGFloat(step) / 24
        return PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                             timeOffset: Double(step) * 0.01, size: CGSize(width: width, height: width),
                             opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.monoline, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
}

private func drawing(_ strokes: PKStroke...) -> PKDrawing { PKDrawing(strokes: strokes) }

/// A decoded PNG's alpha values, top row first.
private struct AlphaMap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(png: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        try buffer.withUnsafeMutableBytes { pointer in
            let context = try #require(CGContext(data: pointer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                                 bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = buffer
    }

    func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
}

/// The colour type from a PNG's IHDR: 6 is RGBA.
private func pngColorType(_ data: Data) -> UInt8? {
    data.count > 25 && data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) ? data[data.startIndex + 25] : nil
}

nonisolated private func pngData(width: Int, height: Int, scale: CGFloat = 1) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }.pngData()!
}

/// A reference file and a markup that fits it, cleaned up with `remove()`.
private struct MarkedFiles {
    let reference: String
    let overlay: String

    var all: [String] { [reference] + MarkupStore.fileNames(forOverlay: overlay) }
    func remove() { ReferenceStore.delete(all) }

    static func make(width: Int = 300, height: Int = 200) async throws -> MarkedFiles {
        let reference = try await ReferenceStore.importImage(pngData(width: width, height: height))
        let geometry = try #require(MarkupGeometry(pixelWidth: width, pixelHeight: height))
        let strokes = drawing(stroke(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 50)))
        let overlay = try #require(try MarkupExporter.renderOverlay(from: strokes, geometry: geometry))
        return MarkedFiles(reference: reference,
                           overlay: try MarkupStore.save(overlay: overlay, drawing: strokes.dataRepresentation()))
    }
}

private func filesExist(_ names: [String]) -> [Bool] { names.map(ReferenceStore.fileExists) }

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: GeneratedImage.self, PendingGeneration.self,
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

/// A `Studio` with no API key, so generations fail straight away without a request, and a
/// sweep that only records what it's told to keep rather than touching the real directory.
private func makeStudio(container: ModelContainer, sweep: @escaping (Set<String>) -> Void = { _ in }) -> Studio {
    Studio(container: container, apiKeys: APIKeyStore(service: "MarkupTests-\(UUID().uuidString)"),
           removeOrphanedReferences: sweep)
}

private func record(references: [String], markup: String?, settings: GenerationSettings = GenerationSettings()) -> GeneratedImage {
    GeneratedImage(prompt: "p", settings: settings, width: 1, height: 1, fileName: "\(UUID().uuidString).png",
                   fileSize: 1, batchID: UUID(), duration: 1, referenceFileNames: references, markupFileName: markup)
}

// MARK: - Requests

@Suite("Markup requests")
struct MarkupRequestTests {
    private let references = [
        OpenAIImageClient.ReferenceUpload(fileName: "reference-1.jpg", mimeType: "image/jpeg", data: Data("FIRST".utf8)),
        OpenAIImageClient.ReferenceUpload(fileName: "reference-2.png", mimeType: "image/png", data: Data("SECOND".utf8)),
    ]
    private let markup = OpenAIImageClient.ReferenceUpload(fileName: "markup.png", mimeType: "image/png", data: Data("OVERLAY".utf8))

    @Test func sendsMarkupAsAFilePartAfterTheImagesInOrder() throws {
        let body = OpenAIImageClient.editRequestBody(prompt: "Recolour the circled vase", settings: GenerationSettings(),
                                                     references: references, markup: markup, boundary: "B")
        let text = String(decoding: body, as: UTF8.self)

        let first = try #require(text.range(of: "name=\"image[]\"; filename=\"reference-1.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nFIRST\r\n"))
        let second = try #require(text.range(of: "name=\"image[]\"; filename=\"reference-2.png\"\r\nContent-Type: image/png\r\n\r\nSECOND\r\n"))
        let overlay = try #require(text.range(of: "Content-Disposition: form-data; name=\"markup\"; filename=\"markup.png\"\r\nContent-Type: image/png\r\n\r\nOVERLAY\r\n"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < overlay.lowerBound)
        #expect(text.contains("name=\"prompt\"\r\n\r\nRecolour the circled vase\r\n"))
        #expect(!text.contains("name=\"mask\""))
        #expect(!text.contains("prompt_rewriter"))
        #expect(text.hasSuffix("--B--\r\n"))
    }

    @Test func editsWithoutMarkupHaveNoMarkupPart() {
        let body = OpenAIImageClient.editRequestBody(prompt: "x", settings: GenerationSettings(), references: references, boundary: "B")
        #expect(!String(decoding: body, as: UTF8.self).contains("markup"))
    }

    @Test func generationsNeverSendMarkup() throws {
        let text = String(decoding: try OpenAIImageClient.requestBody(prompt: "x", settings: GenerationSettings()), as: UTF8.self)
        #expect(!text.contains("markup"))
    }

    @Test func aRequestWithMarkupUsesAModelThatSupportsIt() {
        var settings = GenerationSettings()
        settings.model = .gptImage15
        let body = OpenAIImageClient.editRequestBody(prompt: "x", settings: settings, references: references, markup: markup, boundary: "B")
        #expect(String(decoding: body, as: UTF8.self).contains("name=\"model\"\r\n\r\ngpt-image-2.6-flare\r\n"))
    }

    @Test func ticketBodySendsTheStoredFilesWithTheMarkup() async throws {
        let files = try await MarkedFiles.make()
        let extra = try await ReferenceStore.importImage(pngData(width: 50, height: 50))
        defer { files.remove(); ReferenceStore.delete([extra]) }
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: GenerationSettings(), startedAt: .now,
                                      referenceFileNames: [files.reference, extra], markupFileName: files.overlay)

        let body = try GenerationSession.editRequestBody(for: ticket, boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        let first = try #require(text.range(of: "filename=\"reference-1.jpg\""))
        let overlay = try #require(text.range(of: "name=\"markup\"; filename=\"markup.png\"\r\nContent-Type: image/png"))
        #expect(first.lowerBound < overlay.lowerBound)
        #expect(body.range(of: try Data(contentsOf: ReferenceStore.url(for: files.overlay))) != nil)
        // The next attempt reads the same files.
        #expect(ticket.nextAttempt().markupFileName == files.overlay)
    }

    @Test func aMissingMarkupFileFailsTheSend() async throws {
        let files = try await MarkedFiles.make()
        defer { files.remove() }
        ReferenceStore.delete([files.overlay])
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: GenerationSettings(), startedAt: .now,
                                      referenceFileNames: [files.reference], markupFileName: files.overlay)
        #expect(throws: MarkupStore.MarkupError.missing) {
            try GenerationSession.editRequestBody(for: ticket, boundary: "B")
        }
    }

    @Test func markupThatDoesNotFitTheFirstImageFailsTheSend() async throws {
        let files = try await MarkedFiles.make(width: 300, height: 200)
        let other = try await ReferenceStore.importImage(pngData(width: 200, height: 300))
        defer { files.remove(); ReferenceStore.delete([other]) }
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: GenerationSettings(), startedAt: .now,
                                      referenceFileNames: [other], markupFileName: files.overlay)
        #expect(throws: MarkupStore.MarkupError.mismatchedSize) {
            try GenerationSession.editRequestBody(for: ticket, boundary: "B")
        }
    }

    @Test func anOpaqueFileIsNotSentAsMarkup() async throws {
        let reference = try await ReferenceStore.importImage(pngData(width: 100, height: 100))
        let overlay = try MarkupStore.save(overlay: try ReferenceStore.normalize(pngData(width: 100, height: 100)).0, drawing: Data())
        defer { ReferenceStore.delete([reference] + MarkupStore.fileNames(forOverlay: overlay)) }
        #expect(throws: MarkupStore.MarkupError.noAlpha) {
            try MarkupStore.upload(overlay: overlay, firstReference: reference)
        }
    }
}

// MARK: - Tickets and migration

/// The library's schema from before markup, to migrate from.
private enum PreMarkupSchema {
    @Model
    final class GeneratedImage {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var prompt: String
        var revisedPrompt: String?
        var modelID: String
        var requestedSize: String
        var quality: String
        var complexity: String?
        var background: String
        var outputFormat: String
        var outputCompression: Int?
        var moderation: String
        var frameCount: Int?
        var frameDurationMs: Int?
        var width: Int
        var height: Int
        var resolvedQuality: String?
        var resolvedBackground: String?
        var fileName: String
        var fileSize: Int
        var batchID: UUID
        var duration: TimeInterval
        var inputTokens: Int?
        var outputTokens: Int?
        var referenceFileNames: [String] = []

        init(id: UUID, referenceFileNames: [String]) {
            self.id = id
            createdAt = .now
            prompt = "old"
            modelID = ImageModel.gptImage2.rawValue
            requestedSize = "auto"
            quality = "auto"
            background = "auto"
            outputFormat = "png"
            moderation = "auto"
            width = 1
            height = 1
            fileName = "old.png"
            fileSize = 1
            batchID = UUID()
            duration = 1
            self.referenceFileNames = referenceFileNames
        }
    }

    @Model
    final class PendingGeneration {
        @Attribute(.unique) var id: UUID
        var prompt: String
        var settingsData: Data
        var startedAt: Date
        var failureMessage: String?
        var attempt: Int = 1
        var referenceFileNames: [String] = []

        init(id: UUID) {
            self.id = id
            prompt = "old"
            settingsData = Data()
            startedAt = .now
        }
    }
}

@Suite("Markup persistence")
struct MarkupPersistenceTests {
    @Test func ticketsFromBeforeMarkupStillDecode() throws {
        let json = """
        {"jobID":"\(UUID().uuidString)","prompt":"x","settings":{"model":"gpt-image-2"},"startedAt":0,"attempt":2,"referenceFileNames":["a.jpg"]}
        """
        let ticket = try JSONDecoder().decode(GenerationTicket.self, from: Data(json.utf8))
        #expect(ticket.markupFileName == nil)
        #expect(ticket.referenceFileNames == ["a.jpg"])
        // Nothing about it changes: it wasn't sent with markup, so its model stands.
        #expect(ticket.settings.model == .gptImage2)
    }

    @Test func ticketsRoundTripMarkup() throws {
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: GenerationSettings(), startedAt: .now,
                                      referenceFileNames: ["a.jpg"], markupFileName: "a.markup.png")
        let decoded = try JSONDecoder().decode(GenerationTicket.self, from: JSONEncoder().encode(ticket))
        #expect(decoded.markupFileName == "a.markup.png")
        #expect(decoded.nextAttempt().markupFileName == "a.markup.png")
    }

    @Test func aStoreFromBeforeMarkupMigrates() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarkupMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "library.store")
        let imageID = UUID()
        let jobID = UUID()

        do {
            let schema = Schema([PreMarkupSchema.GeneratedImage.self, PreMarkupSchema.PendingGeneration.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            container.mainContext.insert(PreMarkupSchema.GeneratedImage(id: imageID, referenceFileNames: ["a.jpg"]))
            container.mainContext.insert(PreMarkupSchema.PendingGeneration(id: jobID))
            try container.mainContext.save()
        }

        let schema = Schema([GeneratedImage.self, PendingGeneration.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let image = try #require(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()).first)
        #expect(image.id == imageID)
        #expect(image.referenceFileNames == ["a.jpg"])
        #expect(image.markupFileName == nil)
        let job = try #require(try container.mainContext.fetch(FetchDescriptor<PendingGeneration>()).first)
        #expect(job.id == jobID)
        #expect(job.markupFileName == nil)
    }

    @Test func modelsDefaultToNoMarkup() {
        #expect(PendingGeneration(id: UUID(), prompt: "x", settings: GenerationSettings(), startedAt: .now).markupFileName == nil)
        #expect(record(references: [], markup: nil).markupFileName == nil)
        #expect(Studio.Job(prompt: "x", settings: GenerationSettings()).markupFileName == nil)
    }

    @Test func aDrawingIsStoredAndFoundFromItsOverlay() async throws {
        let files = try await MarkedFiles.make()
        defer { files.remove() }
        #expect(MarkupStore.fileNames(forOverlay: files.overlay).count == 2)
        #expect(filesExist(files.all) == [true, true, true])
        #expect(MarkupStore.loadDrawing(forOverlay: files.overlay)?.strokes.count == 1)

        let copy = try MarkupStore.duplicate(files.overlay)
        defer { MarkupStore.delete(overlay: copy) }
        #expect(copy != files.overlay)
        #expect(MarkupStore.loadDrawing(forOverlay: copy)?.strokes.count == 1)
        MarkupStore.delete(overlay: copy)
        #expect(filesExist(MarkupStore.fileNames(forOverlay: copy)) == [false, false])
        #expect(filesExist(files.all) == [true, true, true])
    }
}

// MARK: - Ownership

@Suite("Markup ownership")
@MainActor
struct MarkupOwnershipTests {
    @Test func theSweepKeepsMarkupInUseAndRemovesTheRest() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarkupSweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageFiles = ["image.jpg", "image.markup.png", "image.markup.pkdrawing"]
        let jobFiles = ["job.jpg", "job.markup.png", "job.markup.pkdrawing"]
        let orphans = ["orphan.jpg", "orphan.markup.png", "orphan.markup.pkdrawing"]
        for name in imageFiles + jobFiles + orphans {
            try Data([1]).write(to: folder.appending(path: name))
        }

        let container = try makeContainer()
        container.mainContext.insert(record(references: ["image.jpg"], markup: "image.markup.png"))
        container.mainContext.insert(PendingGeneration(id: UUID(), prompt: "p", settings: GenerationSettings(), startedAt: .now,
                                                       failureMessage: "failed", referenceFileNames: ["job.jpg"],
                                                       markupFileName: "job.markup.png"))
        try container.mainContext.save()

        // As at launch.
        _ = makeStudio(container: container) { ReferenceStore.removeOrphans(keeping: $0, in: folder) }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(Set(remaining) == Set(imageFiles + jobFiles))
    }

    @Test func deletingAnImageReleasesItsFilesOnlyOnceNothingUsesThem() async throws {
        let files = try await MarkedFiles.make()
        defer { files.remove() }
        let container = try makeContainer()
        let first = record(references: [files.reference], markup: files.overlay)
        let second = record(references: [files.reference], markup: files.overlay)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let studio = makeStudio(container: container)

        studio.delete([first])
        #expect(filesExist(files.all) == [true, true, true])
        studio.delete([second])
        #expect(filesExist(files.all) == [false, false, false])
    }

    @Test func aJobOwnsMarkupUntilItIsDismissed() async throws {
        let files = try await MarkedFiles.make()
        defer { files.remove() }
        let container = try makeContainer()
        let studio = makeStudio(container: container)

        studio.generate(prompt: "x", settings: GenerationSettings(), references: [files.reference], markup: files.overlay)
        let job = try #require(studio.jobs.first)
        #expect(job.markupFileName == files.overlay)
        #expect(job.isFailed) // No API key in this test.
        let stored = try #require(try container.mainContext.fetch(FetchDescriptor<PendingGeneration>()).first)
        #expect(stored.markupFileName == files.overlay)

        // Relaunch: a new Studio restores it from the record.
        let relaunched = makeStudio(container: container)
        #expect(relaunched.jobs.first?.markupFileName == files.overlay)

        relaunched.retry(try #require(relaunched.jobs.first))
        #expect(relaunched.jobs.first?.markupFileName == files.overlay)
        #expect(filesExist(files.all) == [true, true, true])

        relaunched.cancel(try #require(relaunched.jobs.first))
        #expect(filesExist(files.all) == [false, false, false])
    }

    @Test func regeneratingCarriesMarkupAndSharesItsFiles() async throws {
        let files = try await MarkedFiles.make()
        defer { files.remove() }
        let container = try makeContainer()
        let image = record(references: [files.reference], markup: files.overlay)
        container.mainContext.insert(image)
        try container.mainContext.save()
        let studio = makeStudio(container: container)

        studio.regenerate([image])
        let job = try #require(studio.jobs.first)
        #expect(job.markupFileName == files.overlay)
        #expect(job.references == [files.reference])

        // The job still needs them after the image goes.
        studio.delete([image])
        #expect(filesExist(files.all) == [true, true, true])
        studio.cancel(job)
        #expect(filesExist(files.all) == [false, false, false])
    }

    @Test func aFinishedRequestRecordsTheMarkupOnItsImages() async throws {
        let context = ModelContext(try makeContainer())
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: GenerationSettings(), startedAt: .now,
                                      referenceFileNames: ["a.jpg"], markupFileName: "a.markup.png")
        let output = OpenAIImageClient.Output(images: [Data([1])], revisedPrompts: [nil])
        let images = try await Studio.commit(output, for: ticket, in: context, writeFile: { _, _ in }, removeFile: { _ in })
        #expect(images.first?.markupFileName == "a.markup.png")
        #expect(images.first?.referenceStoreFileNames == ["a.jpg", "a.markup.png", "a.markup.pkdrawing"])
    }

    @Test func deleteAllKeepsTheComposersFiles() async throws {
        let container = try makeContainer()
        var kept: Set<String> = []
        let studio = makeStudio(container: container) { kept = $0 }

        let files = try await MarkedFiles.make()
        defer { files.remove() }
        let composer = Composer()
        composer.replaceReferences(withCopiesOf: [files.reference], markup: files.overlay)
        defer { composer.replaceReferences(withCopiesOf: []) }
        #expect(composer.heldFileNames.count == 3)

        studio.deleteAll(keeping: composer.heldFileNames, removeAllImageFiles: {})
        #expect(kept == Set(composer.heldFileNames))
    }
}

// MARK: - Composer

@Suite("Markup in the composer")
@MainActor
struct MarkupComposerTests {
    /// A composer with two references, the first with markup.
    private func makeComposer() async throws -> (Composer, MarkedFiles, String) {
        let files = try await MarkedFiles.make()
        let second = try await ReferenceStore.importImage(pngData(width: 60, height: 60))
        defer { files.remove(); ReferenceStore.delete([second]) }
        let composer = Composer()
        composer.replaceReferences(withCopiesOf: [files.reference, second], markup: files.overlay)
        return (composer, MarkedFiles(reference: composer.references[0], overlay: try #require(composer.markup?.overlayFileName)), composer.references[1])
    }

    private func cleanUp(_ composer: Composer) {
        composer.replaceReferences(withCopiesOf: [])
    }

    @Test func copiesMarkupAndItsDrawingForTheDraft() async throws {
        let original = try await MarkedFiles.make()
        defer { original.remove() }
        let composer = Composer()
        defer { cleanUp(composer) }
        composer.replaceReferences(withCopiesOf: [original.reference], markup: original.overlay)

        let markup = try #require(composer.markup)
        #expect(markup.overlayFileName != original.overlay)
        #expect(markup.referenceFileName == composer.references.first)
        #expect(MarkupStore.loadDrawing(forOverlay: markup.overlayFileName)?.strokes.count == 1)
        // The draft has its own files, whatever happens to the original.
        original.remove()
        #expect(!filesExist(composer.heldFileNames).contains(false))
    }

    @Test func removingTheFirstReferenceDropsTheMarkupAndSaysSo() async throws {
        let (composer, files, second) = try await makeComposer()
        defer { cleanUp(composer) }

        composer.removeReference(files.reference)

        #expect(composer.references == [second])
        #expect(composer.markup == nil)
        #expect(composer.markupNotice != nil)
        #expect(filesExist(files.all) == [false, false, false])
    }

    @Test func removingAnotherReferenceKeepsTheMarkup() async throws {
        let (composer, files, second) = try await makeComposer()
        defer { cleanUp(composer) }

        composer.removeReference(second)

        #expect(composer.markup?.overlayFileName == files.overlay)
        #expect(composer.markupNotice == nil)
        #expect(filesExist(files.all) == [true, true, true])
    }

    @Test func addingReferencesKeepsTheMarkup() async throws {
        let (composer, files, _) = try await makeComposer()
        defer { cleanUp(composer) }
        await composer.addReferences([{ pngData(width: 40, height: 40) }])
        #expect(composer.references.first == files.reference)
        #expect(composer.references.count == 3)
        #expect(composer.markup?.overlayFileName == files.overlay)
    }

    @Test func aNewFirstImageDropsTheOldMarkup() async throws {
        let (composer, files, second) = try await makeComposer()
        defer { cleanUp(composer) }
        let incoming = try await ReferenceStore.importImage(pngData(width: 80, height: 80))
        let request = Composer.MarkupRequest(referenceFileName: incoming, isNewAttachment: true, existingOverlayFileName: nil)

        composer.finishMarkup(request, overlay: nil)

        #expect(composer.references == [incoming, files.reference, second])
        #expect(composer.markup == nil)
        #expect(composer.markupNotice != nil)
        #expect(filesExist(MarkupStore.fileNames(forOverlay: files.overlay)) == [false, false])
    }

    @Test func aFinishedDrawingOnANewImageGoesOnTheFirstReference() async throws {
        let (composer, files, second) = try await makeComposer()
        defer { cleanUp(composer) }
        let incoming = try await MarkedFiles.make(width: 80, height: 90)
        let request = Composer.MarkupRequest(referenceFileName: incoming.reference, isNewAttachment: true, existingOverlayFileName: nil)

        composer.finishMarkup(request, overlay: incoming.overlay)

        #expect(composer.references == [incoming.reference, files.reference, second])
        #expect(composer.markup == Composer.AttachedMarkup(overlayFileName: incoming.overlay, referenceFileName: incoming.reference))
        #expect(composer.markupRequest == nil)
    }

    @Test func cancellingANewImageLeavesTheComposerAsItWas() async throws {
        let (composer, files, second) = try await makeComposer()
        defer { cleanUp(composer) }
        let incoming = try await ReferenceStore.importImage(pngData(width: 80, height: 80))

        composer.cancelMarkup(Composer.MarkupRequest(referenceFileName: incoming, isNewAttachment: true, existingOverlayFileName: nil))

        #expect(composer.references == [files.reference, second])
        #expect(composer.markup?.overlayFileName == files.overlay)
        #expect(!ReferenceStore.fileExists(incoming))
    }

    @Test func replacingMarkupDeletesTheOldFiles() async throws {
        let (composer, files, _) = try await makeComposer()
        defer { cleanUp(composer) }
        composer.beginMarkup()
        let request = try #require(composer.markupRequest)
        #expect(request.existingOverlayFileName == files.overlay)
        #expect(!request.isNewAttachment)
        let new = try MarkupStore.save(overlay: Data([1]), drawing: Data([2]))

        composer.finishMarkup(request, overlay: new)

        #expect(composer.markup?.overlayFileName == new)
        #expect(filesExist(MarkupStore.fileNames(forOverlay: files.overlay)) == [false, false])
        #expect(filesExist(MarkupStore.fileNames(forOverlay: new)) == [true, true])
    }

    @Test func finishingUnchangedKeepsTheFiles() async throws {
        let (composer, files, _) = try await makeComposer()
        defer { cleanUp(composer) }
        composer.beginMarkup()
        composer.finishMarkup(try #require(composer.markupRequest), overlay: files.overlay)
        #expect(composer.markup?.overlayFileName == files.overlay)
        #expect(filesExist(files.all) == [true, true, true])
    }

    @Test func finishingWithoutADrawingRemovesTheMarkup() async throws {
        let (composer, files, _) = try await makeComposer()
        defer { cleanUp(composer) }
        composer.beginMarkup()
        composer.finishMarkup(try #require(composer.markupRequest), overlay: nil)
        #expect(composer.markup == nil)
        #expect(composer.references.first == files.reference)
        #expect(composer.markupNotice == nil)
        #expect(filesExist(MarkupStore.fileNames(forOverlay: files.overlay)) == [false, false])
    }

    @Test func aDrawingIsNeverAttachedToADifferentImage() async throws {
        let (composer, files, second) = try await makeComposer()
        defer { cleanUp(composer) }
        composer.beginMarkup()
        let request = try #require(composer.markupRequest)
        composer.removeReference(files.reference)
        let drawn = try MarkupStore.save(overlay: Data([1]), drawing: Data([2]))

        composer.finishMarkup(request, overlay: drawn)

        #expect(composer.references == [second])
        #expect(composer.markup == nil)
        #expect(filesExist(MarkupStore.fileNames(forOverlay: drawn)) == [false, false])
    }

    @Test func takingTheAttachmentsHandsOverTheFiles() async throws {
        let (composer, files, second) = try await makeComposer()
        let taken = composer.takeReferences()
        defer { ReferenceStore.delete(taken.references + MarkupStore.fileNames(forOverlay: taken.markup)) }

        #expect(taken.references == [files.reference, second])
        #expect(taken.markup == files.overlay)
        #expect(composer.references.isEmpty)
        #expect(composer.markup == nil)
        #expect(composer.markupNotice == nil)
        #expect(filesExist(files.all) == [true, true, true])
    }

    @Test func reusingAnImageCarriesItsMarkupAndReplacesTheDraftsOwn() async throws {
        let (composer, old, _) = try await makeComposer()
        defer { cleanUp(composer) }
        let source = try await MarkedFiles.make()
        defer { source.remove() }

        composer.reuse(record(references: [source.reference], markup: source.overlay), defaults: GenerationSettings())

        #expect(composer.references.count == 1)
        #expect(composer.markup?.referenceFileName == composer.references.first)
        #expect(composer.markup?.overlayFileName != source.overlay)
        #expect(composer.markupNotice == nil)
        #expect(filesExist(old.all) == [false, false, false])
    }

    @Test func reusingAnImageWithoutMarkupClearsTheDraftsOwn() async throws {
        let (composer, old, _) = try await makeComposer()
        defer { cleanUp(composer) }
        let source = try await ReferenceStore.importImage(pngData(width: 50, height: 50))
        defer { ReferenceStore.delete([source]) }

        composer.reuse(record(references: [source], markup: nil), defaults: GenerationSettings())

        #expect(composer.markup == nil)
        #expect(filesExist(old.all) == [false, false, false])
    }

    @Test func markupDoesNotMoveToAnotherImageIfItsOwnIsMissing() async throws {
        let original = try await MarkedFiles.make()
        let second = try await ReferenceStore.importImage(pngData(width: 60, height: 60))
        defer { original.remove(); ReferenceStore.delete([second]) }
        ReferenceStore.delete([original.reference])
        let composer = Composer()
        defer { cleanUp(composer) }

        composer.replaceReferences(withCopiesOf: [original.reference, second], markup: original.overlay)

        #expect(composer.references.count == 1)
        #expect(composer.markup == nil)
        #expect(composer.markupNotice != nil)
    }

    @Test func missingMarkupIsReportedWhenCopying() async throws {
        let original = try await MarkedFiles.make()
        defer { original.remove() }
        ReferenceStore.delete([original.overlay])
        let composer = Composer()
        defer { cleanUp(composer) }

        composer.replaceReferences(withCopiesOf: [original.reference], markup: original.overlay)

        #expect(composer.references.count == 1)
        #expect(composer.markup == nil)
        #expect(composer.markupNotice != nil)
    }

    @Test func aLibraryImageCanOnlyBeMarkedUpIfThereIsRoom() async throws {
        let composer = Composer()
        defer { cleanUp(composer) }
        let names = try await (0..<ReferenceStore.maxReferences).asyncMap { _ in
            try await ReferenceStore.importImage(pngData(width: 10, height: 10))
        }
        defer { ReferenceStore.delete(names) }
        composer.replaceReferences(withCopiesOf: names)

        await composer.beginMarkup(from: record(references: [], markup: nil))

        #expect(composer.markupRequest == nil)
        #expect(composer.importFailure != nil)
        #expect(composer.references.count == ReferenceStore.maxReferences)
    }

    /// A library image with a real file, as `beginMarkup(from:)` imports it.
    private func storedRecord() throws -> GeneratedImage {
        let image = record(references: [], markup: nil)
        try pngData(width: 64, height: 64).write(to: image.fileURL)
        return image
    }

    @Test func preparingTheCanvasDoesNotCountAsAReference() async throws {
        let image = try storedRecord()
        defer { try? ImageStore.delete(fileName: image.fileName) }
        let composer = Composer()

        await composer.beginMarkup(from: image)

        let request = try #require(composer.markupRequest)
        defer { composer.cancelMarkup(request) }
        #expect(!composer.hasReferences)
        #expect(composer.importingCount == 0)
        // Its slot is taken, though, as Done will attach it.
        #expect(composer.remainingReferenceSlots == ReferenceStore.maxReferences - 1)
    }

    @Test func overlappingMarkUpActionsOnlyImportOnce() async throws {
        let image = try storedRecord()
        defer { try? ImageStore.delete(fileName: image.fileName) }
        let composer = Composer()
        func stored() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: ReferenceStore.directory.path(percentEncoded: false)))
        }
        let before = try stored()

        let first = Task { @MainActor in await composer.beginMarkup(from: image) }
        let second = Task { @MainActor in await composer.beginMarkup(from: image) }
        await first.value
        await second.value

        let request = try #require(composer.markupRequest)
        #expect(try stored().subtracting(before) == [request.referenceFileName])
        composer.cancelMarkup(request)
        #expect(try stored() == before)
    }

    @Test func theEditorModelIsOnlyMadeOnce() throws {
        let name = "\(UUID().uuidString).png"
        let url = ReferenceStore.url(for: name)
        try pngData(width: 64, height: 32).write(to: url)
        let request = Composer.MarkupRequest(referenceFileName: name, isNewAttachment: false, existingOverlayFileName: nil)
        let loader = MarkupEditorLoader()

        let model = try #require(loader.model(for: request))
        // With the file gone, reading it again would fail.
        ReferenceStore.delete([name])
        #expect(loader.model(for: request) === model)
    }

    @Test func theEditorHasNoModelForAnUnreadableImage() {
        let request = Composer.MarkupRequest(referenceFileName: "missing.png", isNewAttachment: false, existingOverlayFileName: nil)
        let loader = MarkupEditorLoader()
        #expect(loader.model(for: request) == nil)
        #expect(loader.model(for: request) == nil)
    }

    @Test func aVectorCanNotBeMarkedUp() async throws {
        var settings = GenerationSettings()
        settings.outputFormat = .svg
        let composer = Composer()
        await composer.beginMarkup(from: record(references: [], markup: nil, settings: settings))
        #expect(composer.markupRequest == nil)
        #expect(composer.importingCount == 0)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}

// MARK: - Model constraint

@Suite("Markup model constraint")
@MainActor
struct MarkupModelTests {
    @Test func theRightModelsSupportMarkup() {
        #expect(ImageModel.allCases.filter { $0.supportsMarkup } == [ImageModel.flare26, .sunburst26, .flare25, .sunburst25])
        #expect(ImageModel.available(hasMarkup: true) == [ImageModel.flare26, .sunburst26, .flare25, .sunburst25])
        #expect(ImageModel.available(hasMarkup: false) == ImageModel.allCases)
        #expect(ImageModel.markupFallback.supportsMarkup)
    }

    @Test func normalisingWithMarkupCoercesTheModelFirst() {
        var settings = GenerationSettings()
        settings.model = .gptImage15
        settings.quality = .xhigh
        settings.size = ImageSize(width: 2048, height: 2048)
        // Without markup, these aren't valid for GPT Image 1.5.
        #expect(settings.normalized(hasReferences: true).quality == .high)
        let marked = settings.normalized(hasReferences: true, hasMarkup: true)
        #expect(marked.model == .flare26)
        #expect(marked.quality == .xhigh)
        #expect(marked.size == settings.size)
    }

    @Test func markupKeepsSupportedModelsAndRulesOutGenerationOnlyFormats() {
        var settings = GenerationSettings()
        settings.model = .sunburst25
        #expect(settings.normalized(hasMarkup: true).model == .sunburst25)
        settings.model = .sunburst26
        settings.outputFormat = .svg
        #expect(settings.normalized(hasMarkup: true).outputFormat == .fallback)
    }

    private func composerWithMarkup() async throws -> Composer {
        let files = try await MarkedFiles.make()
        defer { files.remove() }
        let composer = Composer()
        composer.replaceReferences(withCopiesOf: [files.reference], markup: files.overlay)
        return composer
    }

    @Test func theEffectiveModelIsCoercedAndTheDraftAndDefaultsAreNot() async throws {
        let composer = try await composerWithMarkup()
        defer { composer.replaceReferences(withCopiesOf: []) }
        var defaults = GenerationSettings()
        defaults.model = .gptImage2

        #expect(composer.settings(defaults: defaults).model == .flare26)
        #expect(composer.draftSettings(defaults: defaults).model == .gptImage2)
        #expect(defaults.model == .gptImage2)
        #expect(composer.overrides == nil)

        composer.removeMarkup()
        #expect(composer.settings(defaults: defaults).model == .gptImage2)
    }

    @Test func editingAnotherOptionKeepsTheModelHeldBack() async throws {
        let composer = try await composerWithMarkup()
        defer { composer.replaceReferences(withCopiesOf: []) }
        var defaults = GenerationSettings()
        defaults.model = .gptImage15

        var edited = composer.settings(defaults: defaults)
        edited.quality = .xhigh
        composer.applyEdit(edited, defaults: defaults)

        // What's sent keeps the edit, which GPT Image 1.5 itself couldn't have.
        #expect(composer.settings(defaults: defaults).model == .flare26)
        #expect(composer.settings(defaults: defaults).quality == .xhigh)
        #expect(composer.draftSettings(defaults: defaults).model == .gptImage15)

        composer.removeMarkup()
        #expect(composer.settings(defaults: defaults).model == .gptImage15)
        #expect(composer.settings(defaults: defaults).quality == .high)
    }

    @Test func undoingAnEditWhileTheModelIsHeldBackClearsTheOverride() async throws {
        let composer = try await composerWithMarkup()
        defer { composer.replaceReferences(withCopiesOf: []) }
        var defaults = GenerationSettings()
        defaults.model = .gptImage2

        var edited = composer.settings(defaults: defaults)
        let quality = edited.quality
        edited.quality = .low
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.overrides != nil)
        edited.quality = quality
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.overrides == nil)
    }

    @Test func choosingASupportedModelIsANewChoice() async throws {
        let composer = try await composerWithMarkup()
        defer { composer.replaceReferences(withCopiesOf: []) }
        var defaults = GenerationSettings()
        defaults.model = .gptImage2

        var edited = composer.settings(defaults: defaults)
        edited.model = .sunburst25
        composer.applyEdit(edited, defaults: defaults)

        #expect(composer.settings(defaults: defaults).model == .sunburst25)
        #expect(composer.draftSettings(defaults: defaults).model == .sunburst25)
    }

    @Test func aRequestIsCoercedEvenIfItsSettingsWereNot() throws {
        var settings = GenerationSettings()
        settings.model = .gptImage2
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: settings, startedAt: .now,
                                      referenceFileNames: ["a.jpg"], markupFileName: "a.markup.png")
        #expect(ticket.settings.model == .flare26)
        #expect(record(references: ["a.jpg"], markup: "a.markup.png", settings: settings).settings.model == .flare26)
    }
}

// MARK: - Overlay

@Suite("Markup overlay")
struct MarkupOverlayTests {
    @Test func anEmptyDrawingIsNoMarkup() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 100, pixelHeight: 100))
        #expect(try MarkupExporter.renderOverlay(from: PKDrawing(), geometry: geometry) == nil)
    }

    @Test func strokesOutsideTheImageAreNoMarkup() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 1000, pixelHeight: 1000))
        let offImage = drawing(stroke(from: CGPoint(x: 5000, y: 5000), to: CGPoint(x: 6000, y: 5000)))
        #expect(try MarkupExporter.renderOverlay(from: offImage, geometry: geometry) == nil)
    }

    @Test("Exact size and real alpha", arguments: [
        (1024, 1536), (1536, 1024), (2048, 2048), (1024, 1024), (864, 1536), (1537, 1001), (333, 2048), (7, 5),
    ])
    func overlayMatchesThePixelSize(width: Int, height: Int) throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: width, pixelHeight: height))
        let canvas = geometry.canvasSize
        let line = drawing(stroke(from: CGPoint(x: canvas.width * 0.25, y: canvas.height / 2),
                                  to: CGPoint(x: canvas.width * 0.75, y: canvas.height / 2),
                                  width: min(canvas.width, canvas.height) * 0.3))
        let png = try #require(try MarkupExporter.renderOverlay(from: line, geometry: geometry))

        #expect(pngColorType(png) == 6)
        let size = try #require(ImageStore.pixelSize(of: png))
        #expect(size.width == width)
        #expect(size.height == height)

        let map = try AlphaMap(png: png)
        #expect(map.width == width)
        #expect(map.height == height)
        #expect(map.alpha(x: width / 2, y: height / 2) > 200)
        // Never flattened: everywhere else stays clear.
        #expect(map.alpha(x: 0, y: 0) == 0)
        #expect(map.alpha(x: width - 1, y: height - 1) == 0)
    }

    @Test("A @3x source's file decides the size, not its points")
    func usesFilePixelsNotPoints() async throws {
        // 900 x 600 pixels, or 300 x 200 points.
        let name = try await ReferenceStore.importImage(pngData(width: 900, height: 600, scale: 3))
        defer { ReferenceStore.delete([name]) }
        let size = try #require(MarkupStore.pixelSize(at: ReferenceStore.url(for: name)))
        #expect(size.width == 900)
        #expect(size.height == 600)

        let geometry = try #require(MarkupGeometry(pixelWidth: size.width, pixelHeight: size.height))
        let png = try #require(try MarkupExporter.renderOverlay(
            from: drawing(stroke(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 200, y: 100))), geometry: geometry))
        let overlay = try #require(ImageStore.pixelSize(of: png))
        #expect(overlay.width == 900)
        #expect(overlay.height == 600)
    }

    @Test("A sideways photo's stored file has orientation baked in")
    func storedFilesHaveOrientationBakedIn() async throws {
        // 300 x 200 stored, but tagged to show rotated: 200 x 300 on screen.
        let source = try #require(CGImageSourceCreateWithData(pngData(width: 300, height: 200) as CFData, nil))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let name = try await ReferenceStore.importImage(output as Data)
        defer { ReferenceStore.delete([name]) }
        let raw = try #require(CGImageSourceCreateWithURL(ReferenceStore.url(for: name) as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(raw, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 200)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 300)
        #expect(properties[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        let size = try #require(MarkupStore.pixelSize(at: ReferenceStore.url(for: name)))
        #expect(size.width == 200 && size.height == 300)
    }

    @Test func aDrawingThatCoversEverythingIsRefused() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 64, pixelHeight: 64))
        let strokes = stride(from: CGFloat(0), through: 256, by: 16).map {
            stroke(from: CGPoint(x: -50, y: $0), to: CGPoint(x: 306, y: $0), width: 50)
        }
        #expect(throws: MarkupStore.MarkupError.noTransparency) {
            try MarkupExporter.renderOverlay(from: PKDrawing(strokes: strokes), geometry: geometry)
        }
    }

    @Test func imagesOverThePixelLimitAreRefused() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 4097, pixelHeight: 4096))
        #expect(geometry.pixelCount > MarkupStore.maxPixels)
        #expect(throws: MarkupStore.MarkupError.tooManyPixels) {
            try MarkupExporter.renderOverlay(from: drawing(stroke(from: .zero, to: CGPoint(x: 9, y: 9))), geometry: geometry)
        }
        #expect(MarkupGeometry(pixelWidth: 4096, pixelHeight: 4096)?.pixelCount == MarkupStore.maxPixels)
    }

    @Test func invalidSizesHaveNoGeometry() {
        #expect(MarkupGeometry(pixelWidth: 0, pixelHeight: 10) == nil)
        #expect(MarkupGeometry(pixelWidth: 10, pixelHeight: 0) == nil)
    }
}

// MARK: - Geometry

@Suite("Markup coordinates")
@MainActor
struct MarkupCoordinateTests {
    @Test func fitsAPortraitImageInALandscapeViewWithBarsAtTheSides() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 1000, pixelHeight: 2000))
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let fitted = geometry.fittedRect(in: bounds)
        #expect(fitted == CGRect(x: 300, y: 0, width: 200, height: 400))

        // The image's corners map to the canvas's and the pixels', whatever the bars around them.
        let canvas = geometry.canvasSize
        #expect(canvas == CGSize(width: 128, height: 256))
        #expect(geometry.canvasPoint(forViewPoint: CGPoint(x: 300, y: 0), in: bounds) == .zero)
        let far = geometry.canvasPoint(forViewPoint: CGPoint(x: 500, y: 400), in: bounds)
        #expect(far == CGPoint(x: canvas.width, y: canvas.height))
        #expect(geometry.pixelPoint(forCanvasPoint: far) == CGPoint(x: 1000, y: 2000))
    }

    @Test func fitsALandscapeImageInAPortraitViewWithBarsAboveAndBelow() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 1536, pixelHeight: 1024))
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 600)
        let fitted = geometry.fittedRect(in: bounds)
        #expect(fitted == CGRect(x: 0, y: 200, width: 300, height: 200))

        let centre = geometry.canvasPoint(forViewPoint: CGPoint(x: 150, y: 300), in: bounds)
        let pixel = geometry.pixelPoint(forCanvasPoint: centre)
        #expect(pixel == CGPoint(x: 768, y: 512))
    }

    /// A line drawn at a place on screen comes out at that place in the image, through both
    /// letterbox layouts, as the same drawing survives rotation.
    @Test("View point to overlay pixel", arguments: [
        (1024, 1536, 390.0, 700.0), (1024, 1536, 800.0, 360.0),
        (1536, 1024, 390.0, 700.0), (1536, 1024, 800.0, 360.0),
    ])
    func viewPointsLandOnTheRightPixels(width: Int, height: Int, viewWidth: CGFloat, viewHeight: CGFloat) throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: width, pixelHeight: height))
        let bounds = CGRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
        let fitted = geometry.fittedRect(in: bounds)

        // From a quarter of the way along the image to three quarters, a quarter of the way down.
        let start = CGPoint(x: fitted.minX + fitted.width * 0.25, y: fitted.minY + fitted.height * 0.25)
        let end = CGPoint(x: fitted.minX + fitted.width * 0.75, y: fitted.minY + fitted.height * 0.25)
        let line = drawing(stroke(from: geometry.canvasPoint(forViewPoint: start, in: bounds),
                                  to: geometry.canvasPoint(forViewPoint: end, in: bounds)))
        let map = try AlphaMap(png: try #require(try MarkupExporter.renderOverlay(from: line, geometry: geometry)))

        #expect(map.alpha(x: width / 2, y: height / 4) > 200)
        #expect(map.alpha(x: width / 2, y: height * 3 / 4) == 0)
        #expect(map.alpha(x: width / 8, y: height / 4) == 0)
        #expect(map.alpha(x: width * 7 / 8, y: height / 4) == 0)
    }

    @Test("The canvas covers the image and rotates with it")
    func containerKeepsTheCanvasOnTheImage() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 1024, pixelHeight: 1536))
        let restored = drawing(stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 90)))
        let container = MarkupCanvasContainerView(geometry: geometry, drawing: restored)

        for bounds in [CGRect(x: 0, y: 0, width: 390, height: 700), CGRect(x: 0, y: 0, width: 800, height: 360)] {
            container.frame = bounds
            container.layoutIfNeeded()
            let fitted = geometry.fittedRect(in: bounds)
            #expect(container.canvas.frame == fitted)
            #expect(container.imageView.frame == fitted)
            #expect(abs(container.canvas.zoomScale - fitted.width / geometry.canvasSize.width) < 0.0001)
            #expect(container.canvas.contentOffset == .zero)
        }
        #expect(container.canvas.drawingPolicy == .anyInput)
        #expect(container.canvas.drawing.strokes.count == 1)
    }

    @Test func theLineWidthsAreOnesPencilKitAccepts() {
        let range = PKInkingTool.InkType.monoline.validWidthRange
        for width in MarkupLineWidth.allCases {
            #expect(range.contains(width.canvasWidth), "\(width.canvasWidth) not in \(range)")
        }
    }
}

// MARK: - History

@Suite("Markup history")
struct MarkupHistoryTests {
    @Test func undoesAndRedoes() {
        var history = MarkupHistory(0)
        #expect(!history.canUndo)
        #expect(!history.canRedo)
        history.record(1)
        history.record(2)
        #expect(history.undo() == 1)
        #expect(history.undo() == 0)
        #expect(history.undo() == nil)
        #expect(history.current == 0)
        #expect(history.redo() == 1)
        #expect(history.canRedo)
        history.record(5)
        #expect(!history.canRedo)
        #expect(history.current == 5)
        #expect(history.undo() == 1)
    }

    @Test func aDrawingIsTheSameAfterASaveAndLoad() throws {
        let original = drawing(stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 90)))
        let loaded = try PKDrawing(data: original.dataRepresentation())
        #expect(MarkupSnapshot(loaded) == MarkupSnapshot(original))
        #expect(MarkupSnapshot(PKDrawing()) == MarkupSnapshot(PKDrawing()))
        #expect(MarkupSnapshot(original) != MarkupSnapshot(PKDrawing()))
    }

    @Test func reportingTheCurrentValueIsNotAChange() {
        var history = MarkupHistory(0)
        history.record(0)
        #expect(!history.canUndo)
        history.record(1)
        _ = history.undo()
        // A canvas told to show the undone value reports it back.
        history.record(0)
        #expect(history.canRedo)
    }

    @Test @MainActor func theEditorRestoresAndClears() throws {
        let geometry = try #require(MarkupGeometry(pixelWidth: 100, pixelHeight: 100))
        let restored = drawing(stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 90)))
        let model = MarkupEditorModel(geometry: geometry, drawing: restored, couldNotRestore: false)
        model.container.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        model.container.layoutIfNeeded()
        #expect(MarkupSnapshot(model.container.canvas.drawing) == MarkupSnapshot(restored))
        #expect(!model.hasChanges)

        model.clear()
        #expect(model.hasChanges)
        #expect(model.isEmpty)
        #expect(model.container.canvas.drawing.strokes.isEmpty)

        model.undo()
        #expect(!model.hasChanges)
        #expect(MarkupSnapshot(model.container.canvas.drawing) == MarkupSnapshot(restored))
        model.redo()
        #expect(model.isEmpty)
    }
}
