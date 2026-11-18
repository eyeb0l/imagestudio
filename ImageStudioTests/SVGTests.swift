import Foundation
import ImageIO
import Network
import SwiftData
import Synchronization
import Testing
import UIKit
import UniformTypeIdentifiers
import WebKit
@testable import ImageStudio

/// Documents for the tests below.
enum TestSVG {
    /// A 200×100 canvas: a red square on the left, a blue circle on the right, unpainted between.
    static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="200" height="100">
    <rect x="0" y="0" width="100" height="100" fill="#ff0000"/><circle cx="150" cy="50" r="30" fill="#0000ff"/>
    </svg>
    """
    static var sampleData: Data { Data(sample.utf8) }

    static func document(_ text: String) throws -> SVGDocument {
        try #require(SVGDocument(data: Data(text.utf8)))
    }

    /// Everything a document might try to reach, all pointing at `host`.
    static func reachingOut(to host: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100">
        <style>@import url(\(host)/style.css); rect { background: url(\(host)/background.png); }</style>
        <image href="\(host)/image.png" width="10" height="10"/>
        <image xlink:href="\(host)/image-xlink.png" width="10" height="10"/>
        <use href="\(host)/external.svg#shape"/>
        <rect id="target" width="100" height="100" fill="#ff0000"/>
        <script href="\(host)/script.js"></script>
        <script>
        new Image().src = "\(host)/from-script.png";
        fetch("\(host)/from-fetch");
        document.getElementById("target").setAttribute("fill", "#00ff00");
        </script>
        <foreignObject width="10" height="10"><iframe xmlns="http://www.w3.org/1999/xhtml" src="\(host)/frame.html"></iframe></foreignObject>
        </svg>
        """
    }

    /// Pixels in RGBA, drawn into a known format (premultiplied).
    static func pixels(of image: UIImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
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
        return (cgImage.width, cgImage.height, bytes)
    }

    /// The RGBA value at a position, as fractions of the width and height.
    static func colour(of image: UIImage, atX x: Double, y: Double) throws -> [UInt8] {
        let (width, height, bytes) = try pixels(of: image)
        let offset = (Int(Double(height) * y) * width + Int(Double(width) * x)) * 4
        return Array(bytes[offset..<offset + 4])
    }

    static func temporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "SVGTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("SVG settings")
struct SVGSettingsTests {
    private var svg: GenerationSettings {
        var settings = GenerationSettings()
        settings.outputFormat = .svg
        return settings
    }

    @Test func describesTheFormat() {
        #expect(OutputFormat.svg.fileExtension == "svg")
        #expect(OutputFormat.svg.contentType == .svg)
        #expect(OutputFormat.svg.contentType.identifier == "public.svg-image")
        #expect(OutputFormat.svg.libraryBadge == "SVG")
        #expect(OutputFormat.svg.isVector)
        #expect(OutputFormat.svg.isGenerationOnly)
        #expect(!OutputFormat.svg.supportsCompression)
        // The API documents transparent backgrounds for PNG and WebP only.
        #expect(!OutputFormat.svg.supportsTransparency)
        #expect(!OutputFormat.svg.isAnimated)
        #expect(!OutputFormat.svg.mayRequirePreviewAccess)
        #expect(!OutputFormat.svg.allowsMultipleImages)
        #expect(!OutputFormat.svg.canBeReference)
        for format in [OutputFormat.png, .jpeg, .webp, .gif] {
            #expect(!format.isVector)
            #expect(format.allowsMultipleImages)
            #expect(format.canBeReference)
        }
    }

    @Test func isOfferedOnlyByGPTImage26() {
        for model in ImageModel.allCases {
            let expected = model == .flare26 || model == .sunburst26
            #expect(model.supportedFormats.contains(.svg) == expected, "\(model)")
            #expect(!model.formats(hasReferences: true).contains(.svg), "\(model)")
        }
    }

    @Test(arguments: [-2, 0, 1, 2, 10, 99])
    func normalisesCountToOne(count: Int) {
        var settings = svg
        settings.count = count
        #expect(settings.normalized().count == 1)
        #expect(settings.normalized().outputFormat == .svg)
        #expect(settings.allowedCountRange == 1...1)
    }

    @Test func otherFormatsKeepTheirCount() {
        for format in [OutputFormat.png, .jpeg, .webp, .gif] {
            var settings = GenerationSettings()
            settings.outputFormat = format
            settings.count = 7
            #expect(settings.normalized().count == 7)
            #expect(settings.allowedCountRange == GenerationSettings.countRange)
        }
    }

    @Test func referencesFallBackToPNGAndItsLimitsNotSVGs() {
        var settings = svg
        settings.count = 4
        let normalized = settings.normalized(hasReferences: true)
        #expect(normalized.outputFormat == .png)
        #expect(normalized.count == 4)
    }

    @Test func aModelWithoutSVGFallsBackToPNG() {
        var settings = svg
        settings.count = 3
        settings.model = .flare25
        let normalized = settings.normalized()
        #expect(normalized.outputFormat == .png)
        #expect(normalized.count == 3)
    }

    @Test func transparentBackgroundLeavesNoSVG() {
        var settings = svg
        settings.background = .transparent
        #expect(settings.normalized().outputFormat == .png)
    }

    @Test func roundTrips() throws {
        let data = try JSONEncoder().encode(svg)
        #expect(try JSONDecoder().decode(GenerationSettings.self, from: data) == svg)
    }
}

@Suite("SVG requests")
struct SVGRequestTests {
    private var svg: GenerationSettings {
        var settings = GenerationSettings()
        settings.model = .sunburst26
        settings.outputFormat = .svg
        settings.count = 6
        settings.compression = 40
        settings.frameCount = 5
        settings.quality = .xhigh
        settings.complexity = .low
        return settings
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sendsOnlyWhatTheAPIAccepts() throws {
        let body = try json(OpenAIImageClient.requestBody(prompt: "A logo", settings: svg))
        #expect(body["output_format"] as? String == "svg")
        #expect(body["n"] as? Int == 1)
        #expect(body["model"] as? String == "gpt-image-2.6-sunburst")
        #expect(body["quality"] as? String == "xhigh")
        #expect(body["complexity"] as? String == "low")
        for field in ["output_compression", "frame_count", "frame_duration_ms", "prompt_rewriter", "stream", "partial_images"] {
            #expect(body[field] == nil, "\(field)")
        }
    }

    @Test func modelWithoutSVGNeverRequestsIt() throws {
        var settings = svg
        settings.model = .gptImage2
        let body = try json(OpenAIImageClient.requestBody(prompt: "x", settings: settings))
        #expect(body["output_format"] as? String == "png")
        #expect(body["n"] as? Int == 6)
    }

    @Test func editRequestsNeverAskForSVG() {
        let body = OpenAIImageClient.editRequestBody(
            prompt: "x", settings: svg,
            references: [.init(fileName: "reference-1.png", mimeType: "image/png", data: Data([1]))],
            boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"output_format\"\r\n\r\npng"))
        #expect(!text.contains("svg"))
        #expect(text.contains("name=\"n\"\r\n\r\n6"))
    }

    @Test func ticketsKeepTheirFileExtensionInStepWithTheRequest() throws {
        let plain = GenerationTicket(jobID: UUID(), prompt: "p", settings: svg, startedAt: .now)
        #expect(plain.settings.outputFormat == .svg)
        #expect(plain.settings.count == 1)
        let withReferences = GenerationTicket(jobID: UUID(), prompt: "p", settings: svg, startedAt: .now,
                                              referenceFileNames: ["a.jpg"])
        #expect(withReferences.settings.outputFormat == .png)
        let decoded = try JSONDecoder().decode(GenerationTicket.self, from: JSONEncoder().encode(plain))
        #expect(decoded.settings.outputFormat == .svg)
    }

    @Test func parsesASVGResponse() throws {
        let body = """
        {"data":[{"b64_json":"\(TestSVG.sampleData.base64EncodedString())"}],"output_format":"svg","size":"1024x1024",
         "usage":{"input_tokens":9,"output_tokens":4160},"svg_usage":{"input_tokens":1,"model":"m","output_tokens":2,"reasoning_tokens":0,"total_tokens":3}}
        """
        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let output = try OpenAIImageClient.parseGeneration(data: Data(body.utf8), response: response)
        #expect(output.images == [TestSVG.sampleData])
        #expect(output.outputFormat == "svg")
    }
}

@Suite("SVG and the composer")
@MainActor
struct SVGComposerTests {
    private var svgDefaults: GenerationSettings {
        var settings = GenerationSettings()
        settings.outputFormat = .svg
        return settings
    }

    private func attachReference(to composer: Composer) async {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        await composer.addReferences([{ png }])
    }

    @Test func choosingSVGShowsAndSendsOneImage() {
        let composer = Composer()
        var defaults = GenerationSettings()
        defaults.count = 4
        var edited = composer.settings(defaults: defaults)
        #expect(edited.count == 4)
        edited.outputFormat = .svg
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.settings(defaults: defaults).outputFormat == .svg)
        #expect(composer.settings(defaults: defaults).count == 1)
    }

    @Test func attachingAReferenceChangesTheFormatAndRemovingItRestoresIt() async throws {
        let composer = Composer()
        let defaults = svgDefaults
        #expect(composer.settings(defaults: defaults).outputFormat == .svg)

        await attachReference(to: composer)
        #expect(composer.hasReferences)
        #expect(composer.settings(defaults: defaults).outputFormat == .png)
        #expect(composer.draftSettings(defaults: defaults).outputFormat == .svg)

        composer.removeReference(try #require(composer.references.first))
        #expect(composer.settings(defaults: defaults).outputFormat == .svg)
        #expect(composer.settings(defaults: defaults).count == 1)
    }

    @Test func aCountChosenWhileAReferenceHoldsBackSVGApplies() async throws {
        let composer = Composer()
        let defaults = svgDefaults
        await attachReference(to: composer)
        defer { ReferenceStore.delete(composer.references) }

        var edited = composer.settings(defaults: defaults)
        edited.count = 3
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.settings(defaults: defaults).count == 3, "the stepper mustn't snap back to 1")
        #expect(composer.settings(defaults: defaults).outputFormat == .png)
        #expect(composer.draftSettings(defaults: defaults).outputFormat == .svg)

        // Another change keeps both.
        edited = composer.settings(defaults: defaults)
        edited.quality = .low
        composer.applyEdit(edited, defaults: defaults)
        #expect(composer.settings(defaults: defaults).count == 3)
        #expect(composer.settings(defaults: defaults).quality == .low)

        // Without references it's an SVG again, and one image.
        let name = try #require(composer.references.first)
        composer.removeReference(name)
        #expect(composer.settings(defaults: defaults).outputFormat == .svg)
        #expect(composer.settings(defaults: defaults).count == 1)
    }

    @Test func theToastNamesTheFormat() {
        #expect(Toast.referencesReplaced(.svg).message == "SVG can't use references. Using PNG.")
        #expect(Toast.referencesReplaced(.gif).message == "GIF can't use references. Using PNG.")
    }

    @Test func reusingAnSVGKeepsTheFormatWithOneImage() {
        let composer = Composer()
        var defaults = GenerationSettings()
        defaults.count = 5
        let image = GeneratedImage(prompt: "A logo", settings: svgDefaults, width: 1, height: 1, fileName: "f.svg",
                                   fileSize: 1, batchID: UUID(), duration: 1)
        composer.reuse(image, defaults: defaults)
        #expect(composer.prompt == "A logo")
        #expect(composer.settings(defaults: defaults).outputFormat == .svg)
        #expect(composer.settings(defaults: defaults).count == 1)
    }

    @Test func regeneratingAnSVGRequestsAnSVG() throws {
        var settings = svgDefaults
        settings.complexity = .medium
        let image = GeneratedImage(prompt: "p", settings: settings, width: 1, height: 1, fileName: "f.svg",
                                   fileSize: 1, batchID: UUID(), duration: 1)
        #expect(image.settings.outputFormat == .svg)
        #expect(image.settings.count == 1)
        #expect(image.settings.complexity == .medium)
        #expect(image.outputCompression == nil)
        #expect(image.frameCount == nil)
    }
}

@Suite("SVG documents")
struct SVGDocumentTests {
    @Test(arguments: [
        ("100", 100.0), ("100px", 100), (" 100 ", 100), ("1e2", 100), ("12.5", 12.5), (".5", 0.5), ("+5", 5),
        ("1in", 96), ("72pt", 96), ("6pc", 96), ("2.54cm", 96), ("25.4mm", 96), ("101.6q", 96), ("100PX", 100),
    ])
    func readsAbsoluteLengths(value: String, expected: Double) throws {
        let length = try #require(SVGDocument.length(from: value))
        #expect(abs(length - expected) < 0.000_1)
    }

    @Test(arguments: [
        "", " ", "100%", "2em", "2ex", "2rem", "10vw", "0", "0px", "-5", "-5px", "abc", "px", "10 px", "1e", "1e400",
        "nan", "inf", "Infinity", "0x10", "1,5", "--1", "1.2.3",
    ])
    func refusesLengthsThatGiveNoSize(value: String) {
        #expect(SVGDocument.length(from: value) == nil)
    }

    @Test(arguments: [
        ("0 0 24 24", 24.0, 24.0), ("0,0,24,12", 24, 12), ("0, 0, 24, 12", 24, 12), (" -5 -5 10 20 ", 10, 20),
        ("0 0 1.5e2 1e2", 150, 100), ("0\n0\t16\n9", 16, 9),
    ])
    func readsViewBoxes(value: String, width: Double, height: Double) throws {
        let size = try #require(SVGDocument.viewBoxSize(from: value))
        #expect(size == CGSize(width: width, height: height))
    }

    @Test(arguments: ["", "0 0 24", "0 0 24 24 24", "0 0 0 24", "0 0 24 0", "0 0 -24 24", "a b c d", "0 0 nan 24", "0 0 inf 24", "0 0 1e400 1"])
    func refusesViewBoxesThatGiveNoSize(value: String) {
        #expect(SVGDocument.viewBoxSize(from: value) == nil)
    }

    @Test(arguments: [
        // Both absolute: they win, even over a viewBox of another shape.
        ("200", "100", "0 0 10 10", CGSize(width: 200, height: 100)),
        ("200", "100", nil, CGSize(width: 200, height: 100)),
        // No width or height, or only relative ones: the viewBox.
        (nil, nil, "0 0 300 150", CGSize(width: 300, height: 150)),
        ("100%", "100%", "0 0 300 150", CGSize(width: 300, height: 150)),
        ("auto", "auto", "0 0 300 150", CGSize(width: 300, height: 150)),
        // One absolute: it sets the scale, and the viewBox the shape.
        ("600", nil, "0 0 300 150", CGSize(width: 600, height: 300)),
        (nil, "600", "0 0 300 150", CGSize(width: 1200, height: 600)),
        ("600", "100%", "0 0 300 150", CGSize(width: 600, height: 300)),
    ] as [(String?, String?, String?, CGSize)])
    func combinesAttributes(width: String?, height: String?, viewBox: String?, expected: CGSize) {
        #expect(SVGDocument.intrinsicSize(width: width, height: height, viewBox: viewBox) == expected)
    }

    @Test(arguments: [
        (nil, nil, nil),
        ("100", nil, nil), (nil, "100", nil), ("100%", "100%", nil), ("0", "0", nil),
        // Attributes and a viewBox that multiply out to something out of range.
        ("1e308", nil, "0 0 1e-308 1e308"),
    ] as [(String?, String?, String?)])
    func givesNoSizeWhenThereIsNone(width: String?, height: String?, viewBox: String?) {
        #expect(SVGDocument.intrinsicSize(width: width, height: height, viewBox: viewBox) == nil)
    }

    @Test func aBadViewBoxDoesNotMatterWithAnAbsoluteSize() {
        #expect(SVGDocument.intrinsicSize(width: "100", height: "50", viewBox: "0 0 0 0") == CGSize(width: 100, height: 50))
    }

    @Test func readsTheRootElement() throws {
        #expect(try TestSVG.document(TestSVG.sample).intrinsicSize == CGSize(width: 200, height: 100))
        #expect(try TestSVG.document(TestSVG.sample).aspectRatio == 2)
        let prefixed = #"<s:svg xmlns:s="http://www.w3.org/2000/svg" viewBox="0 0 4 3"/>"#
        #expect(try TestSVG.document(prefixed).intrinsicSize == CGSize(width: 4, height: 3))
        // Only the root counts.
        let nested = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 3"><svg width="99" height="1"/></svg>"#
        #expect(try TestSVG.document(nested).intrinsicSize == CGSize(width: 4, height: 3))
        // A doctype without entities is common and harmless.
        let doctype = #"<?xml version="1.0"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg xmlns="http://www.w3.org/2000/svg" width="4" height="3"/>"#
        #expect(try TestSVG.document(doctype).intrinsicSize == CGSize(width: 4, height: 3))
    }

    @Test func aDocumentWithNoSizeHasAUsableShape() throws {
        let document = try TestSVG.document(#"<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>"#)
        #expect(document.intrinsicSize == nil)
        #expect(document.aspectRatio == 1)
    }

    nonisolated static let notDocuments = [
        "",
        "not xml",
        #"{"json": true}"#,
        "<html><body>hi</body></html>",
        "<rect/>",
        // Right name, wrong or no namespace: WebKit shows these as nothing.
        #"<svg viewBox="0 0 1 1"/>"#,
        #"<svg xmlns="http://example.com/" viewBox="0 0 1 1"/>"#,
        // Not well formed.
        #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10""#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><g></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" width="1" width="2"/>"#,
        // Entity declarations: expansion bombs and external entities.
        #"<!DOCTYPE svg [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><svg xmlns="http://www.w3.org/2000/svg"><text>&c;</text></svg>"#,
        #"<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg"><text>&xxe;</text></svg>"#,
    ]

    @Test(arguments: notDocuments)
    func refusesWhatIsNotASafeDocument(text: String) {
        #expect(SVGDocument(data: Data(text.utf8)) == nil)
    }

    @Test func refusesBinaryAndOversizedData() throws {
        #expect(SVGDocument(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE])) == nil)
        // An entity declaration in another encoding must not slip past the search for them.
        let utf16 = #"<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE svg [<!ENTITY a "b">]><svg xmlns="http://www.w3.org/2000/svg">&a;</svg>"#
        #expect(SVGDocument(data: try #require(utf16.data(using: .utf16))) == nil)
        let padding = String(repeating: " ", count: SVGDocument.maxByteCount)
        #expect(SVGDocument(data: Data((TestSVG.sample + padding).utf8)) == nil)
    }

    @Test func recognisesSVGBytesButNotPhotosThatMentionThem() {
        #expect(SVGDocument.looksLikeSVG(TestSVG.sampleData))
        #expect(SVGDocument.looksLikeSVG(Data("\u{FEFF}\n  <!-- a logo --><SVG/>".utf8)))
        #expect(!SVGDocument.looksLikeSVG(Data([0xFF, 0xD8, 0xFF, 0xE1]) + Data("<x:xmpmeta><svg/>".utf8)))
        #expect(!SVGDocument.looksLikeSVG(Data("<html></html>".utf8)))
        #expect(!SVGDocument.looksLikeSVG(Data()))
    }

    @Test func recognisesFilesByExtension() {
        #expect(SVGDocument.isSVG(URL(filePath: "/a/b.svg")))
        #expect(SVGDocument.isSVG(URL(filePath: "/a/b.SVG")))
        #expect(!SVGDocument.isSVG(URL(filePath: "/a/b.png")))
        #expect(!SVGDocument.isSVG(URL(filePath: "/a/svg")))
    }

    @Test func recordsDimensionsThatKeepTheShapeAndAreNeverZero() {
        func check(_ size: CGSize, _ expected: (Int, Int)) {
            let dimensions = SVGDocument.dimensions(for: size)
            #expect(dimensions.width == expected.0, "\(size)")
            #expect(dimensions.height == expected.1, "\(size)")
        }
        check(CGSize(width: 24, height: 24), (24, 24))
        check(CGSize(width: 1536, height: 1024), (1536, 1024))
        // Fractions don't fit, so the shape is recorded at a larger scale.
        check(CGSize(width: 0.5, height: 0.25), (4096, 2048))
        check(CGSize(width: 1.5, height: 1), (4096, 2731))
        // Enormous values must not overflow.
        check(CGSize(width: 1e300, height: 5e299), (16_384, 8192))
        // Extremely thin shapes still can't reach zero.
        check(CGSize(width: 100_000, height: 1), (16_384, 1))
    }

    @Test func dimensionsFallBackToTheReportedSizeThenADefault() {
        let reported = ImageSize(width: 1536, height: 1024)
        let malformed = Data("<svg".utf8)
        let fromAPI = SVGDocument.dimensions(of: malformed, reported: reported)
        #expect(fromAPI.width == 1536 && fromAPI.height == 1024)
        for reported in [nil, ImageSize.auto] {
            let fallback = SVGDocument.dimensions(of: malformed, reported: reported)
            #expect(fallback.width == 1024 && fallback.height == 1024)
        }
        // A readable document with no size is drawn on the fallback canvas, so its record says so.
        let unsized = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>"#.utf8)
        let drawnSize = SVGDocument.dimensions(of: unsized, reported: reported)
        #expect(drawnSize.width == 1024 && drawnSize.height == 1024)
        let own = SVGDocument.dimensions(of: TestSVG.sampleData, reported: reported)
        #expect(own.width == 200 && own.height == 100)
    }

    @Test func otherFormatsStillUseTheirPixels() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4)).pngData { _ in }
        let dimensions = ImageStore.dimensions(of: png, format: .png, reported: ImageSize(width: 1, height: 1))
        let pixels = try #require(ImageStore.pixelSize(of: png))
        #expect(dimensions.width == pixels.width && dimensions.height == pixels.height)
        let unreadable = ImageStore.dimensions(of: Data([1]), format: .png, reported: ImageSize(width: 5, height: 6))
        #expect(unreadable.width == 5 && unreadable.height == 6)
        let unknown = ImageStore.dimensions(of: Data([1]), format: .png, reported: nil)
        #expect(unknown.width == 0 && unknown.height == 0)
    }
}

@Suite("SVG author")
struct SVGAuthorTests {
    private func body(_ settings: GenerationSettings) throws -> [String: Any] {
        let data = try OpenAIImageClient.requestBody(prompt: "x", settings: settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sendsTheAuthorModelForSVG() throws {
        var settings = GenerationSettings()
        settings.outputFormat = .svg
        #expect((try body(settings)["svg"] as? [String: String]) == ["model": "gpt-6.1-terra"])
        settings.svgAuthor = .astra
        #expect((try body(settings)["svg"] as? [String: String]) == ["model": "gpt-6-astra"])
    }

    @Test func sendsNoAuthorForOtherFormats() throws {
        for format in [OutputFormat.png, .jpeg, .webp, .gif] {
            var settings = GenerationSettings()
            settings.outputFormat = format
            settings.svgAuthor = .astra
            #expect(try body(settings)["svg"] == nil, "\(format)")
            #expect(settings.normalized().svgAuthor == .terra)
        }
    }

    @Test func decodingIsLenient() throws {
        let saved = #"{"outputFormat":"svg","svgAuthor":"gpt-99"}"#
        #expect(try JSONDecoder().decode(GenerationSettings.self, from: Data(saved.utf8)).svgAuthor == .terra)
        let chosen = #"{"outputFormat":"svg","svgAuthor":"gpt-6.1-sol"}"#
        #expect(try JSONDecoder().decode(GenerationSettings.self, from: Data(chosen.utf8)).svgAuthor == .sol)
    }

    @Test func readsTheAuthorsUsage() throws {
        let payload = """
        {"data":[{"b64_json":"\(TestSVG.sampleData.base64EncodedString())"}],"output_format":"svg",
         "usage":{"input_tokens":9,"output_tokens":4160},
         "svg_usage":{"input_tokens":120,"model":"m","output_tokens":900,"reasoning_tokens":0,"total_tokens":1020}}
        """
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/images/generations")!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let output = try OpenAIImageClient.parseGeneration(data: Data(payload.utf8), response: response)
        #expect(output.outputTokens == 4160)
        #expect(output.svgInputTokens == 120)
        #expect(output.svgOutputTokens == 900)
    }

    @Test func regenerationKeepsTheAuthor() {
        var settings = GenerationSettings()
        settings.outputFormat = .svg
        settings.svgAuthor = .sol
        let image = GeneratedImage(prompt: "p", settings: settings, width: 1, height: 1, fileName: "f.svg", fileSize: 1,
                                   batchID: UUID(), duration: 1, svgInputTokens: 120, svgOutputTokens: 900)
        #expect(image.svgAuthorModel == "gpt-6.1-sol")
        #expect(image.settings.svgAuthor == .sol)
        #expect(image.svgOutputTokens == 900)

        let png = GeneratedImage(prompt: "p", settings: GenerationSettings(), width: 1, height: 1, fileName: "f.png",
                                 fileSize: 1, batchID: UUID(), duration: 1)
        #expect(png.svgAuthorModel == nil)
    }
}

@Suite("SVG encoding declarations and sizes")
struct SVGDeclarationTests {
    private let body = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>"#

    @Test func refusesADeclaredEncodingThatCanHideMarkup() {
        // ASCII only, so valid UTF-8, but an XML parser reads the entity declaration in UTF-7.
        let hidden = #"<?xml version="1.0" encoding="UTF-7"?><!DOCTYPE svg [+ADw-!ENTITY a "boom"+AD4-]>"# + body
        #expect(SVGDocument(data: Data(hidden.utf8)) == nil)
        for declaration in [#"<?xml version="1.0" encoding="UTF-16"?>"#, "<?xml version='1.0' encoding='iso-8859-1'?>",
                            #"<?xml version="1.0" encoding = "utf-7"?>"#] {
            #expect(SVGDocument(data: Data((declaration + body).utf8)) == nil, "\(declaration)")
        }
    }

    @Test func acceptsUTF8Declarations() {
        for declaration in ["", #"<?xml version="1.0"?>"#, #"<?xml version="1.0" encoding="UTF-8"?>"#,
                            "<?xml version='1.0' encoding='utf-8' standalone='no'?>"] {
            #expect(SVGDocument(data: Data((declaration + body).utf8)) != nil, "\(declaration)")
        }
    }

    @Test func addsTheReportedSizeToADocumentWithoutOne() throws {
        let unsized = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="1400" width="10" height="10"/></svg>"#.utf8)
        let sized = SVGDocument.addingSize(ImageSize(width: 1536, height: 1024), to: unsized)
        let document = try #require(SVGDocument(data: sized))
        #expect(document.intrinsicSize == CGSize(width: 1536, height: 1024))
        let plan = SVGRenderPlan(document: document, maxPixelSize: 480)
        #expect(plan.outputPixels == CGSize(width: 480, height: 320))
        #expect(String(decoding: sized, as: UTF8.self).contains(#"<rect x="1400""#))
    }

    @Test func leavesOtherDocumentsAlone() {
        let reported = ImageSize(width: 1536, height: 1024)
        let unsized = Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
        #expect(SVGDocument.addingSize(reported, to: TestSVG.sampleData) == TestSVG.sampleData)
        #expect(SVGDocument.addingSize(reported, to: Data("<svg".utf8)) == Data("<svg".utf8))
        #expect(SVGDocument.addingSize(nil, to: unsized) == unsized)
        #expect(SVGDocument.addingSize(.auto, to: unsized) == unsized)
        // Adding to this would repeat an attribute, so it isn't changed, and stays readable.
        let relative = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="100%"/>"#.utf8)
        #expect(SVGDocument.addingSize(reported, to: relative) == relative)
    }
}

@Suite("SVG render plans")
struct SVGRenderPlanTests {
    private func document(_ width: Int, _ height: Int) throws -> SVGDocument {
        try TestSVG.document(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \#(width) \#(height)"/>"#)
    }

    @Test func fitsTheLongestEdgeAndKeepsTheShape() throws {
        #expect(SVGRenderPlan(document: try document(200, 100), maxPixelSize: 480).outputPixels == CGSize(width: 480, height: 240))
        #expect(SVGRenderPlan(document: try document(100, 200), maxPixelSize: 480).outputPixels == CGSize(width: 240, height: 480))
        #expect(SVGRenderPlan(document: try document(1, 1), maxPixelSize: 480).outputPixels == CGSize(width: 480, height: 480))
    }

    @Test func staysWithinTheMaximumAndAboveZero() throws {
        #expect(SVGRenderPlan(document: try document(1, 1), maxPixelSize: 100_000).outputPixels == CGSize(width: 4096, height: 4096))
        #expect(SVGRenderPlan(document: try document(1, 1), maxPixelSize: 0).outputPixels == CGSize(width: 1, height: 1))
        #expect(SVGRenderPlan(document: try document(100_000, 1), maxPixelSize: 480).outputPixels == CGSize(width: 480, height: 1))
    }

    @Test func aCropIsThePartAskedForAtTheDocumentScale() throws {
        let plan = SVGRenderPlan(document: try document(2, 1), documentPixels: CGSize(width: 8000, height: 4000),
                                 region: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5))
        #expect(plan.outputPixels == CGSize(width: 2000, height: 2000))
        #expect(plan.offset == CGPoint(x: 4000, y: 1000))
        #expect(!plan.isEmpty)
    }

    @Test func aCropOutsideTheDocumentIsEmpty() throws {
        let plan = SVGRenderPlan(document: try document(1, 1), documentPixels: CGSize(width: 100, height: 100),
                                 region: CGRect(x: 2, y: 2, width: 1, height: 1))
        #expect(plan.isEmpty)
    }

    @Test func thePageCarriesTheDocumentOnlyAsBase64() throws {
        let hostile = #"<svg xmlns="http://www.w3.org/2000/svg"></img><script>alert(1)</script></svg>"#
        let html = SVGRenderPlan(document: try document(1, 1), maxPixelSize: 300).html(for: Data(hostile.utf8), displayScale: 3)
        #expect(!html.contains("alert"))
        #expect(html.contains("data:image/svg+xml;base64,\(Data(hostile.utf8).base64EncodedString())"))
        #expect(html.contains("default-src 'none'"))
    }
}

/// Fetches made by a document would land here, so tests can tell whether any were.
private final class ConnectionCounter: Sendable {
    private final class Count: Sendable {
        let value = Mutex(0)
    }

    private let listener: NWListener
    private let count = Count()

    var connections: Int { count.value.withLock { $0 } }
    var host: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "ConnectionCounter")
        listener.newConnectionHandler = { [count] connection in
            count.value.withLock { $0 += 1 }
            connection.cancel()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Mutex(Optional(continuation))
            listener.stateUpdateHandler = { state in
                if case .ready = state { once.withLock { $0.take() }?.resume() }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(_ start: () -> Void) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }
}

/// These use real web views, which take seconds to start, so they share one where they can.
@Suite("SVG rasteriser", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SVGRasterizerTests {
    /// Long enough for a cold start with every other suite running at once.
    private static let shared = SVGRasterizer(timeout: .seconds(60))

    private func rasterize(_ text: String, maxPixelSize: Int = 400, with rasterizer: SVGRasterizer? = nil) async throws -> UIImage {
        let data = Data(text.utf8)
        return try await (rasterizer ?? Self.shared).rasterize(data, document: try TestSVG.document(text), maxPixelSize: maxPixelSize)
    }

    private func expectRed(_ colour: [UInt8]) {
        #expect(colour[0] > 240 && colour[1] < 15 && colour[2] < 15 && colour[3] == 255, "\(colour)")
    }

    private func expectClear(_ colour: [UInt8]) {
        #expect(colour[3] == 0, "\(colour)")
    }

    @Test func rendersARealDocumentWithItsShapeAndTransparency() async throws {
        let image = try await rasterize(TestSVG.sample, maxPixelSize: 400)
        #expect(image.scale == 1)
        #expect(image.cgImage?.width == 400)
        #expect(image.cgImage?.height == 200)
        expectRed(try TestSVG.colour(of: image, atX: 0.1, y: 0.5))
        let blue = try TestSVG.colour(of: image, atX: 0.75, y: 0.5)
        #expect(blue[2] > 240 && blue[0] < 15 && blue[3] == 255, "\(blue)")
        expectClear(try TestSVG.colour(of: image, atX: 0.55, y: 0.1))
    }

    @Test func rendersDocumentsThatOnlyGiveAViewBox() async throws {
        let text = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20"><rect width="10" height="10" fill="#f00"/></svg>"##
        let image = try await rasterize(text, maxPixelSize: 200)
        #expect(image.cgImage?.width == 100)
        #expect(image.cgImage?.height == 200)
        expectRed(try TestSVG.colour(of: image, atX: 0.5, y: 0.25))
        expectClear(try TestSVG.colour(of: image, atX: 0.5, y: 0.75))
    }

    @Test func scalesDocumentsThatOnlyGiveWidthAndHeight() async throws {
        let text = ##"<svg xmlns="http://www.w3.org/2000/svg" width="10px" height="10px"><rect width="5" height="10" fill="#f00"/></svg>"##
        let image = try await rasterize(text, maxPixelSize: 300)
        expectRed(try TestSVG.colour(of: image, atX: 0.25, y: 0.5))
        expectClear(try TestSVG.colour(of: image, atX: 0.75, y: 0.5))
    }

    @Test func framesDocumentsWithNoSizeTheSameAtEverySize() async throws {
        let text = ##"<svg xmlns="http://www.w3.org/2000/svg"><rect width="512" height="1024" fill="#f00"/></svg>"##
        for size in [200, 500] {
            let image = try await rasterize(text, maxPixelSize: size)
            #expect(image.cgImage?.width == size)
            expectRed(try TestSVG.colour(of: image, atX: 0.25, y: 0.5))
            expectClear(try TestSVG.colour(of: image, atX: 0.75, y: 0.5))
        }
    }

    @Test func aValidDocumentThatDrawsNothingIsAClearImageNotAFailure() async throws {
        let image = try await rasterize(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>"#, maxPixelSize: 50)
        expectClear(try TestSVG.colour(of: image, atX: 0.5, y: 0.5))
    }

    @Test func staysSharpWhenAskedForMorePixels() async throws {
        // A tiny document: an upscaled bitmap would have a wide blurred edge.
        let text = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><circle cx="4" cy="4" r="3" fill="#000"/></svg>"##
        let (width, height, bytes) = try TestSVG.pixels(of: try await rasterize(text, maxPixelSize: 2048))
        #expect(width == 2048 && height == 2048)
        let row = height / 2
        let soft = (0..<width).filter { x in
            let alpha = bytes[(row * width + x) * 4 + 3]
            return alpha != 0 && alpha != 255
        }
        #expect(soft.count <= 8, "\(soft.count) partly covered pixels across two edges")
        #expect(bytes[(row * width + width / 2) * 4 + 3] == 255)
        #expect(bytes[(row * width + 10) * 4 + 3] == 0)
    }

    @Test func rendersACropAtTheHigherScale() async throws {
        let document = try TestSVG.document(TestSVG.sample)
        // The middle of the document: the red square's right edge in the left half of the crop.
        let plan = SVGRenderPlan(document: document, documentPixels: CGSize(width: 8000, height: 4000),
                                 region: CGRect(x: 0.45, y: 0, width: 0.1, height: 0.1))
        let image = try await Self.shared.render(TestSVG.sampleData, plan: plan)
        #expect(image.cgImage?.width == 800)
        #expect(image.cgImage?.height == 400)
        expectRed(try TestSVG.colour(of: image, atX: 0.25, y: 0.5))
        expectClear(try TestSVG.colour(of: image, atX: 0.75, y: 0.5))
    }

    @Test func aDifferentSizeOnTheSameWebViewIsNotAffectedByTheLastOne() async throws {
        for size in [64, 1000, 200] {
            let image = try await rasterize(TestSVG.sample, maxPixelSize: size)
            #expect(image.cgImage?.width == size)
            expectRed(try TestSVG.colour(of: image, atX: 0.25, y: 0.5))
            expectClear(try TestSVG.colour(of: image, atX: 0.55, y: 0.1))
        }
    }

    @Test func webKitRefusingADocumentIsAnErrorAndHarmless() async throws {
        // Passes `SVGDocument` as a well-formed document, but it isn't a usable image by the time
        // WebKit sees these bytes, so this exercises the page's own check.
        let document = try TestSVG.document(TestSVG.sample)
        let rasterizer = Self.shared
        await #expect(throws: SVGRasterError.invalidDocument) {
            try await rasterizer.rasterize(Data("<svg".utf8), document: document, maxPixelSize: 100)
        }
        await #expect(throws: SVGRasterError.invalidDocument) {
            try await rasterizer.rasterize(Data(#"<svg viewBox="0 0 1 1"/>"#.utf8), document: document, maxPixelSize: 100)
        }
        // The web view is still good.
        expectRed(try TestSVG.colour(of: try await rasterize(TestSVG.sample), atX: 0.1, y: 0.5))
    }

    @Test func timesOutAndStaysUsable() async throws {
        let rasterizer = Self.shared
        let document = try TestSVG.document(TestSVG.sample)
        _ = try await rasterize(TestSVG.sample) // warm
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SVGRasterError.timedOut) {
            try await rasterizer.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 100, timeout: .zero)
        }
        #expect(clock.now - start < .seconds(5))
        // The stuck web view was thrown away. A new one takes over.
        let created = rasterizer.webViewsCreated
        expectRed(try TestSVG.colour(of: try await rasterize(TestSVG.sample), atX: 0.1, y: 0.5))
        #expect(rasterizer.webViewsCreated == created + 1)
    }

    @Test func aTimeoutSpanningABackgroundPeriodDoesNotBlameTheDocument() async throws {
        let document = try TestSVG.document(TestSVG.sample)
        var rasterizer: SVGRasterizer?
        var suspended = false
        // Goes to the background during the first attempt, and is back by the time it times out.
        let subject = SVGRasterizer(canRender: {
            if !suspended {
                suspended = true
                rasterizer?.noteAppWentToBackground()
            }
            return true
        })
        rasterizer = subject
        await #expect(throws: SVGRasterError.timedOut) {
            try await subject.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 100, timeout: .zero)
        }
        // It tried again, on a new web view. Only a timeout with nothing to explain it is reported.
        #expect(subject.webViewsCreated == 2)
    }

    @Test func aTimeoutInTheForegroundIsNotRetried() async throws {
        let document = try TestSVG.document(TestSVG.sample)
        let subject = SVGRasterizer()
        await #expect(throws: SVGRasterError.timedOut) {
            try await subject.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 100, timeout: .zero)
        }
        #expect(subject.webViewsCreated == 1)
    }

    @Test func aDocumentBuiltToHangCannotHangTheCaller() async throws {
        // Each level draws the one before twice, so the last would draw 2^40 shapes.
        var levels = ##"<g id="l0"><circle r="5" filter="url(#b)"/></g>"##
        for level in 1...40 {
            levels += ##"<g id="l\##(level)"><use href="#l\##(level - 1)"/><use href="#l\##(level - 1)" x="1"/></g>"##
        }
        let text = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><defs><filter id="b"><feGaussianBlur stdDeviation="9"/></filter>\##(levels)</defs><use href="#l40"/></svg>"##
        _ = try await rasterize(TestSVG.sample) // warm, so the timeout isn't spent starting up
        let document = try TestSVG.document(text)
        let clock = ContinuousClock()
        let start = clock.now
        // Whether WebKit gives up, draws it or never finishes, the caller gets an answer on time.
        _ = try? await Self.shared.rasterize(Data(text.utf8), document: document, maxPixelSize: 400, timeout: .seconds(3))
        #expect(clock.now - start < .seconds(10))
        expectRed(try TestSVG.colour(of: try await rasterize(TestSVG.sample), atX: 0.1, y: 0.5))
    }

    @Test func limitsWebViewsAndKeepsWhatItStarts() async throws {
        let rasterizer = SVGRasterizer(timeout: .seconds(60))
        let document = try TestSVG.document(TestSVG.sample)
        let tasks = (0..<12).map { index in
            Task { try await rasterizer.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 40 + index) }
        }
        for (index, task) in tasks.enumerated() {
            #expect(try await task.value.cgImage?.width == 40 + index)
        }
        #expect(rasterizer.peakConcurrentRenders == 2)
        #expect(rasterizer.webViewsCreated == 2)
    }

    @Test func aCallerThatGivesUpLeavesTheQueue() async throws {
        let rasterizer = SVGRasterizer(timeout: .seconds(60), maxConcurrentRenders: 1)
        let document = try TestSVG.document(TestSVG.sample)
        let first = Task { try await rasterizer.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 50) }
        await Task.yield()
        let second = Task { try await rasterizer.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 60) }
        await Task.yield()
        second.cancel()
        await #expect(throws: SVGRasterError.cancelled) { try await second.value }
        #expect(try await first.value.cgImage?.width == 50)
        #expect(rasterizer.webViewsCreated == 1)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await rasterizer.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 60)
        }
        await #expect(throws: SVGRasterError.cancelled) { try await cancelled.value }
    }

    @Test func doesNotStartAWebViewInTheBackground() async throws {
        let rasterizer = SVGRasterizer(canRender: { false })
        let document = try TestSVG.document(TestSVG.sample)
        await #expect(throws: SVGRasterError.unavailableInBackground) {
            try await rasterizer.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 100)
        }
        #expect(rasterizer.webViewsCreated == 0)
    }

    @Test func aTimeoutCausedByGoingToTheBackgroundIsNotBlamedOnTheDocument() async throws {
        var active = true
        let stalled = SVGRasterizer(timeout: .seconds(60), canRender: { active })
        let document = try TestSVG.document(TestSVG.sample)
        let task = Task { try await stalled.rasterize(TestSVG.sampleData, document: document, maxPixelSize: 100, timeout: .milliseconds(1)) }
        // In the window after it passes its checks, as if the user had just left the app.
        await Task.yield()
        await Task.yield()
        active = false
        await #expect(throws: SVGRasterError.unavailableInBackground) { try await task.value }
    }

    @Test func oversizedInputIsRefusedWithoutAWebView() async throws {
        let rasterizer = SVGRasterizer(timeout: .seconds(1))
        let document = try TestSVG.document(TestSVG.sample)
        let huge = Data(count: SVGDocument.maxByteCount + 1)
        await #expect(throws: SVGRasterError.invalidDocument) {
            try await rasterizer.rasterize(huge, document: document, maxPixelSize: 100)
        }
        #expect(rasterizer.webViewsCreated == 0)
    }

    @Test func documentsCannotReachTheNetworkOrRunScripts() async throws {
        let counter = try await ConnectionCounter()
        defer { counter.stop() }
        let text = TestSVG.reachingOut(to: counter.host)

        // Control: the same text in an ordinary web view really does phone home,
        // so the listener works and a count of zero below means something.
        let navigation = NavigationWaiter()
        let unprotected = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        unprotected.navigationDelegate = navigation
        await navigation.wait { unprotected.loadHTMLString(text, baseURL: nil) }
        try await Task.sleep(for: .seconds(1))
        #expect(counter.connections > 0, "the control should reach the listener")
        unprotected.navigationDelegate = nil
        unprotected.stopLoading()
        try await Task.sleep(for: .milliseconds(200))
        let baseline = counter.connections

        let image = try await rasterize(text, maxPixelSize: 200)
        try await Task.sleep(for: .seconds(1))
        #expect(counter.connections == baseline, "the document reached the network")
        // The script would have turned this green.
        expectRed(try TestSVG.colour(of: image, atX: 0.8, y: 0.8))
    }
}

@Suite("SVG image loading and caching", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SVGImageLoadingTests {
    private static let rasterizer = SVGRasterizer(timeout: .seconds(60))
    private static let notRendering = SVGRasterizer(canRender: { false })

    /// A loader with its own memory and disk caches.
    private func makeLoader(rasterizer: @escaping @MainActor @Sendable () -> SVGRasterizer = { SVGImageLoadingTests.rasterizer }) throws -> (ImageLoader, SVGRasterCache) {
        let cache = SVGRasterCache(directory: try TestSVG.temporaryDirectory())
        return (ImageLoader(rasterCache: cache, rasterizer: rasterizer), cache)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func rendersFilesWithTheExtensionAndCachesThemOnDisk() async throws {
        let (loader, cache) = try makeLoader()
        let url = try TestGIF.temporaryFile(TestSVG.sampleData, extension: "svg")
        defer {
            try? FileManager.default.removeItem(at: url)
            cache.removeAll()
        }
        let image = try #require(await loader.image(at: url, maxPixelSize: 300))
        #expect(image.cgImage?.width == 300)
        #expect(loader.cachedImage(at: url, maxPixelSize: 300) === image)

        let cached = cache.url(forSource: url, maxPixelSize: 300)
        #expect(exists(cached))

        // A new launch: nothing in memory, no way to render, but the disk cache has it.
        let relaunched = ImageLoader(rasterCache: cache, rasterizer: { SVGImageLoadingTests.notRendering })
        let fromDisk = try #require(await relaunched.image(at: url, maxPixelSize: 300))
        #expect(fromDisk.cgImage?.width == 300)
        #expect(try TestSVG.colour(of: fromDisk, atX: 0.1, y: 0.5)[0] > 240)
        #expect(try TestSVG.colour(of: fromDisk, atX: 0.55, y: 0.1)[3] == 0, "the cache must keep transparency")
    }

    @Test func doesNotCacheTheFullScreenSizeOnDisk() async throws {
        let (loader, cache) = try makeLoader()
        let url = try TestGIF.temporaryFile(TestSVG.sampleData, extension: "svg")
        defer {
            try? FileManager.default.removeItem(at: url)
            cache.removeAll()
        }
        #expect(await loader.image(at: url, maxPixelSize: 4096)?.cgImage?.width == 4096)
        #expect(!exists(cache.url(forSource: url, maxPixelSize: 4096)))
    }

    @Test(arguments: SVGDocumentTests.notDocuments)
    func aBadFileIsNilAndCachesNothing(text: String) async throws {
        let (loader, cache) = try makeLoader()
        let url = try TestGIF.temporaryFile(Data(text.utf8), extension: "svg")
        defer {
            try? FileManager.default.removeItem(at: url)
            cache.removeAll()
        }
        #expect(await loader.image(at: url, maxPixelSize: 100) == nil)
        #expect(!exists(cache.url(forSource: url, maxPixelSize: 100)))
    }

    @Test func aMissingFileIsNil() async throws {
        let (loader, _) = try makeLoader()
        #expect(await loader.image(at: URL.temporaryDirectory.appending(path: "missing-\(UUID()).svg"), maxPixelSize: 100) == nil)
    }

    @Test func aDocumentThatHungTheRendererIsNotTriedAgain() async throws {
        let impatient = SVGRasterizer(timeout: .zero)
        let (loader, cache) = try makeLoader(rasterizer: { impatient })
        let url = try TestGIF.temporaryFile(TestSVG.sampleData, extension: "svg")
        defer {
            try? FileManager.default.removeItem(at: url)
            cache.removeAll()
        }
        #expect(await loader.image(at: url, maxPixelSize: 100) == nil)
        let created = impatient.webViewsCreated
        #expect(created > 0)
        #expect(await loader.image(at: url, maxPixelSize: 200) == nil)
        #expect(impatient.webViewsCreated == created)
    }

    @Test func theBackgroundIsNotRememberedAsAFailure() async throws {
        let (background, cache) = try makeLoader(rasterizer: { SVGImageLoadingTests.notRendering })
        let url = try TestGIF.temporaryFile(TestSVG.sampleData, extension: "svg")
        defer {
            try? FileManager.default.removeItem(at: url)
            cache.removeAll()
        }
        #expect(await background.image(at: url, maxPixelSize: 100) == nil)
        #expect(!exists(cache.url(forSource: url, maxPixelSize: 100)))
    }

    @Test func deletingAnImageDeletesItsCacheEntries() async throws {
        let fileName = ImageStore.makeFileName(format: .svg)
        try TestSVG.sampleData.write(to: ImageStore.url(for: fileName))
        let loader = ImageLoader(rasterizer: { SVGImageLoadingTests.rasterizer })
        #expect(await loader.image(fileName: fileName, maxPixelSize: 111) != nil)
        #expect(await loader.image(fileName: fileName, maxPixelSize: 222) != nil)
        let source = ImageStore.url(for: fileName)
        let small = SVGRasterCache.shared.url(forSource: source, maxPixelSize: 111)
        let large = SVGRasterCache.shared.url(forSource: source, maxPixelSize: 222)
        #expect(exists(small) && exists(large))

        try ImageStore.delete(fileName: fileName)
        #expect(!exists(source))
        #expect(!exists(small) && !exists(large))
        #expect(!exists(small.deletingLastPathComponent()))
    }

    @Test func studioDeletionDeletesCacheEntries() async throws {
        let fileName = ImageStore.makeFileName(format: .svg)
        try TestSVG.sampleData.write(to: ImageStore.url(for: fileName))
        let source = ImageStore.url(for: fileName)
        let loader = ImageLoader(rasterizer: { SVGImageLoadingTests.rasterizer })
        #expect(await loader.image(fileName: fileName, maxPixelSize: 111) != nil)
        #expect(exists(SVGRasterCache.shared.url(forSource: source, maxPixelSize: 111)))

        let container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, LibraryDeletion.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var settings = GenerationSettings()
        settings.outputFormat = .svg
        let image = GeneratedImage(prompt: "p", settings: settings, width: 2, height: 1, fileName: fileName,
                                   fileSize: 1, batchID: UUID(), duration: 1)
        container.mainContext.insert(image)
        #expect(Studio.deleteImages([image], in: container.mainContext) == nil)
        #expect(!exists(source))
        #expect(!exists(SVGRasterCache.shared.url(forSource: source, maxPixelSize: 111)))
    }

    @Test func deleteAllClearsTheCache() throws {
        let images = try TestSVG.temporaryDirectory()
        let cache = SVGRasterCache(directory: try TestSVG.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: images) }
        let source = images.appending(path: "a.svg")
        try TestSVG.sampleData.write(to: source)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        cache.store(png, forSource: source, maxPixelSize: 100)
        #expect(exists(cache.url(forSource: source, maxPixelSize: 100)))

        try ImageStore.deleteAll(in: images, rasterCache: cache)
        #expect(!exists(source))
        #expect(!exists(cache.directory))
    }

    @Test func resettingTheLibraryClearsTheCache() throws {
        let store = try TestSVG.temporaryDirectory()
        let cache = SVGRasterCache(directory: try TestSVG.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store) }
        let storeURL = store.appending(path: "default.store")
        try Data("db".utf8).write(to: storeURL)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        let source = store.appending(path: "a.svg")
        cache.store(png, forSource: source, maxPixelSize: 100)
        #expect(exists(cache.directory))

        let model = AppModel(simulatesFailure: true, storeURL: storeURL,
                             backupsDirectory: store.appending(path: "Backups"), rasterCache: cache,
                             opener: { try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, LibraryDeletion.self,
                                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)) })
        model.resetLibrary()
        #expect(!exists(cache.directory))
    }

    @Test func removingEntriesForOneFileLeavesOthers() throws {
        let cache = SVGRasterCache(directory: try TestSVG.temporaryDirectory())
        defer { cache.removeAll() }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        let a = URL(filePath: "/x/a.svg")
        let b = URL(filePath: "/x/b.svg")
        cache.store(png, forSource: a, maxPixelSize: 100)
        cache.store(png, forSource: b, maxPixelSize: 100)
        cache.remove(fileName: "a.svg")
        #expect(!exists(cache.url(forSource: a, maxPixelSize: 100)))
        #expect(exists(cache.url(forSource: b, maxPixelSize: 100)))
        cache.remove(fileName: "never-existed.svg") // harmless
    }

    @Test func aBitmapTooLargeToCacheIsNotWritten() throws {
        let cache = SVGRasterCache(directory: try TestSVG.temporaryDirectory())
        defer { cache.removeAll() }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        let tooLarge = SVGRasterCache.maxCachedPixelSize + 1
        let source = URL(filePath: "/x/a.svg")
        cache.store(png, forSource: source, maxPixelSize: tooLarge)
        #expect(!exists(cache.url(forSource: source, maxPixelSize: tooLarge)))
    }

    // MARK: Notification thumbnails

    @Test func aNotificationThumbnailIsAValidPNGWhenItCanBeRendered() async throws {
        let (loader, cache) = try makeLoader()
        let fileName = ImageStore.makeFileName(format: .svg)
        try TestSVG.sampleData.write(to: ImageStore.url(for: fileName))
        defer {
            try? ImageStore.delete(fileName: fileName)
            cache.removeAll()
        }
        let attachment = try #require(await GenerationNotifier.thumbnailAttachment(fileName: fileName, loader: loader))
        #expect(attachment.type == UTType.png.identifier)
    }

    @Test func aNotificationGoesWithoutAThumbnailInABackgroundRelaunch() async throws {
        let (loader, cache) = try makeLoader(rasterizer: { SVGImageLoadingTests.notRendering })
        let fileName = ImageStore.makeFileName(format: .svg)
        try TestSVG.sampleData.write(to: ImageStore.url(for: fileName))
        defer {
            try? ImageStore.delete(fileName: fileName)
            cache.removeAll()
        }
        #expect(await GenerationNotifier.thumbnailAttachment(fileName: fileName, loader: loader) == nil)
    }

    @Test func aNotificationUsesTheThumbnailTheLibraryAlreadyCached() async throws {
        let (loader, cache) = try makeLoader(rasterizer: { SVGImageLoadingTests.notRendering })
        let fileName = ImageStore.makeFileName(format: .svg)
        let url = ImageStore.url(for: fileName)
        try TestSVG.sampleData.write(to: url)
        defer {
            try? ImageStore.delete(fileName: fileName)
            cache.removeAll()
        }
        let tile = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        cache.store(tile, forSource: url, maxPixelSize: StoredImageView.thumbnailPixelSize)
        #expect(await GenerationNotifier.thumbnailAttachment(fileName: fileName, loader: loader) != nil)
    }

    @Test func aNotificationGoesWithoutAThumbnailForABadDocument() async throws {
        let (loader, cache) = try makeLoader()
        let fileName = ImageStore.makeFileName(format: .svg)
        try Data("<svg".utf8).write(to: ImageStore.url(for: fileName))
        defer {
            try? ImageStore.delete(fileName: fileName)
            cache.removeAll()
        }
        #expect(await GenerationNotifier.thumbnailAttachment(fileName: fileName, loader: loader) == nil)
    }

    // MARK: The GIF player

    @Test func theGIFPlayerLeavesSVGsAlone() async throws {
        #expect(AnimatedImageDecoder(data: TestSVG.sampleData) == nil)
        let url = try TestGIF.temporaryFile(TestSVG.sampleData, extension: "svg")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AnimatedImageDecoder(url: url) == nil)
        var shown = 0
        await AnimatedImageDecoder.play(url: url) { _ in shown += 1 }
        #expect(shown == 0)
    }
}

@Suite("SVG library records")
@MainActor
struct SVGLibraryTests {
    private var svg: GenerationSettings {
        var settings = GenerationSettings()
        settings.model = .sunburst26
        settings.outputFormat = .svg
        settings.count = 5
        settings.complexity = .low
        return settings
    }

    /// Held for the length of each test, as records don't outlive their container.
    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, LibraryDeletion.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func commit(_ data: Data, size: String? = "1024x1024") async throws -> (GeneratedImage, [String: Data]) {
        let ticket = GenerationTicket(jobID: UUID(), prompt: "A fox", settings: svg, startedAt: .now)
        let output = OpenAIImageClient.Output(images: [data], revisedPrompts: [nil], size: size, quality: "high",
                                              background: "opaque", outputFormat: "svg", inputTokens: 1, outputTokens: 1)
        var written: [String: Data] = [:]
        let saved = try await Studio.commit(output, for: ticket, in: container.mainContext,
                                            writeFile: { written[$1] = $0 }, removeFile: { _ in })
        return (try #require(saved.first), written)
    }

    @Test func committingKeepsTheBytesAndUsesTheDocumentsSize() async throws {
        let (image, written) = try await commit(TestSVG.sampleData)
        #expect(image.fileName.hasSuffix(".svg"))
        #expect(written[image.fileName] == TestSVG.sampleData)
        #expect(image.format == .svg)
        #expect(image.width == 200)
        #expect(image.height == 100)
        #expect(image.aspectRatio == 2)
        #expect(image.fileSize == TestSVG.sampleData.count)
        #expect(image.complexity == "low")
    }

    @Test func committingFallsBackToTheReportedSize() async throws {
        let (image, _) = try await commit(Data("<svg".utf8), size: "1536x1024")
        #expect(image.width == 1536)
        #expect(image.height == 1024)
    }

    @Test(arguments: [nil, "auto", "nonsense"] as [String?])
    func committingWithNoSizeAnywhereStillHasAShape(size: String?) async throws {
        let (image, _) = try await commit(Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8), size: size)
        #expect(image.width == 1024)
        #expect(image.height == 1024)
        #expect(image.aspectRatio == 1)
    }

    private func stored(_ data: Data) throws -> GeneratedImage {
        let fileName = ImageStore.makeFileName(format: .svg)
        try data.write(to: ImageStore.url(for: fileName))
        return GeneratedImage(prompt: "p", settings: svg, width: 200, height: 100, fileName: fileName,
                              fileSize: data.count, batchID: UUID(), duration: 1)
    }

    @Test func exportSharesTheOriginalFile() throws {
        // `ShareLink` is given this URL. Its type comes from the extension.
        let image = try stored(TestSVG.sampleData)
        defer { try? ImageStore.delete(fileName: image.fileName) }
        #expect(image.fileURL.pathExtension == "svg")
        #expect(UTType(filenameExtension: image.fileURL.pathExtension) == .svg)
        #expect(try Data(contentsOf: image.fileURL) == TestSVG.sampleData)
    }

    @Test func copyKeepsTheOriginalBytesAndAddsTheText() throws {
        let image = try stored(TestSVG.sampleData)
        defer { try? ImageStore.delete(fileName: image.fileName) }
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        #expect(image.copyToPasteboard(pasteboard))
        #expect(pasteboard.data(forPasteboardType: "public.svg-image") == TestSVG.sampleData)
        #expect(pasteboard.string == TestSVG.sample)
        #expect(pasteboard.numberOfItems == 1)
    }

    @Test func copyOfAFileThatIsNotTextStillKeepsItsBytes() throws {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01])
        let image = try stored(bytes)
        defer { try? ImageStore.delete(fileName: image.fileName) }
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        #expect(image.copyToPasteboard(pasteboard))
        #expect(pasteboard.data(forPasteboardType: "public.svg-image") == bytes)
        #expect(pasteboard.string == nil)
    }

    @Test func rasterFormatsCopyOnlyTheirOwnType() throws {
        var settings = GenerationSettings()
        settings.outputFormat = .gif
        let data = TestGIF.make(frames: [(.red, 0.1), (.blue, 0.1)])
        let fileName = ImageStore.makeFileName(format: .gif)
        try data.write(to: ImageStore.url(for: fileName))
        defer { try? ImageStore.delete(fileName: fileName) }
        let image = GeneratedImage(prompt: "p", settings: settings, width: 16, height: 16, fileName: fileName,
                                   fileSize: data.count, batchID: UUID(), duration: 1)
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        #expect(image.copyToPasteboard(pasteboard))
        #expect(pasteboard.data(forPasteboardType: UTType.gif.identifier) == data)
        #expect(pasteboard.string == nil)
    }

    // MARK: References

    @Test func anSVGCannotBecomeAReferenceByAnyRoute() async throws {
        let image = try stored(TestSVG.sampleData)
        defer { try? ImageStore.delete(fileName: image.fileName) }

        // The composer, as the menus and multi-select use it.
        let composer = Composer()
        await composer.addReferences(from: [image])
        #expect(composer.references.isEmpty)
        #expect(composer.importFailure == nil)

        // The store, directly.
        await #expect(throws: ReferenceStore.ImportError.self) {
            _ = try await ReferenceStore.importFile(at: image.fileURL)
        }
        await #expect(throws: ReferenceStore.ImportError.self) {
            _ = try await ReferenceStore.importImage(TestSVG.sampleData)
        }
        #expect(throws: ReferenceStore.ImportError.self) { try ReferenceStore.normalize(TestSVG.sampleData) }

        // As bytes under another name, e.g. from Photos.
        let renamed = try TestGIF.temporaryFile(TestSVG.sampleData, extension: "png")
        defer { try? FileManager.default.removeItem(at: renamed) }
        await #expect(throws: ReferenceStore.ImportError.self) {
            _ = try await ReferenceStore.importFile(at: renamed)
        }
    }

    @Test func aMixedSelectionAttachesOnlyTheRasterImages() async throws {
        let vector = try stored(TestSVG.sampleData)
        defer { try? ImageStore.delete(fileName: vector.fileName) }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let fileName = ImageStore.makeFileName(format: .png)
        try png.write(to: ImageStore.url(for: fileName))
        defer { try? ImageStore.delete(fileName: fileName) }
        let raster = GeneratedImage(prompt: "p", settings: GenerationSettings(), width: 4, height: 4, fileName: fileName,
                                    fileSize: png.count, batchID: UUID(), duration: 1)

        let composer = Composer()
        await composer.addReferences(from: [vector, raster])
        #expect(composer.references.count == 1)
        #expect(composer.references.allSatisfy { !$0.hasSuffix(".svg") })
        ReferenceStore.delete(composer.references)
    }
}
