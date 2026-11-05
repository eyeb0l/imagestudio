import Foundation
import ImageIO
import Testing
import UIKit
@testable import ImageStudio

@Suite("Reference images")
struct ReferenceImageTests {
    private func render(width: Int, height: Int, opaque: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.withAlphaComponent(opaque ? 1 : 0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        return image.pngData()!
    }

    private func pixelSize(_ data: Data) -> (Int, Int)? {
        ImageStore.pixelSize(of: data).map { ($0.width, $0.height) }
    }

    @Test func downscalesLargeImagesAndKeepsAspectRatio() throws {
        let (data, type) = try ReferenceStore.normalize(render(width: 4000, height: 3000, opaque: true))
        #expect(type == .jpeg)
        let size = try #require(pixelSize(data))
        #expect(size.0 == 2048)
        #expect(size.1 == 1536)
    }

    @Test func keepsSmallImagesAndTransparency() throws {
        let (data, type) = try ReferenceStore.normalize(render(width: 600, height: 400, opaque: false))
        #expect(type == .png)
        let size = try #require(pixelSize(data))
        #expect(size.0 == 600)
        #expect(size.1 == 400)
    }

    @Test func rejectsNonImageData() {
        #expect(throws: ReferenceStore.ImportError.self) {
            try ReferenceStore.normalize(Data("not an image".utf8))
        }
    }

    @Test func importsAndDuplicatesFiles() async throws {
        let name = try await ReferenceStore.importImage(render(width: 300, height: 300, opaque: true))
        let copy = try ReferenceStore.duplicate(name)
        defer { ReferenceStore.delete([name, copy]) }

        #expect(name != copy)
        #expect(ReferenceStore.fileExists(name))
        #expect(ReferenceStore.fileExists(copy))
        #expect(ReferenceStore.mimeType(for: name) == "image/jpeg")
    }

    @Test func findsOrphans() {
        let orphans = ReferenceStore.orphans(in: ["a.jpg", "b.png", ".DS_Store", "c.jpg"], referenced: ["b.png"])
        #expect(Set(orphans) == ["a.jpg", "c.jpg"])
    }

    @Test func ticketsWithoutReferencesStillDecode() throws {
        let json = """
        {"jobID":"\(UUID().uuidString)","prompt":"x","settings":{},"startedAt":0,"attempt":2}
        """
        let ticket = try JSONDecoder().decode(GenerationTicket.self, from: Data(json.utf8))
        #expect(ticket.referenceFileNames.isEmpty)
        #expect(ticket.attempt == 2)
    }

    @Test func ticketsRoundTripReferences() throws {
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: GenerationSettings(),
                                      startedAt: .now, referenceFileNames: ["a.jpg", "b.png"])
        let decoded = try JSONDecoder().decode(GenerationTicket.self, from: JSONEncoder().encode(ticket))
        #expect(decoded.referenceFileNames == ["a.jpg", "b.png"])
        #expect(decoded.nextAttempt().referenceFileNames == ["a.jpg", "b.png"])
    }
}

@Suite("Edit requests")
struct EditRequestTests {
    @Test func sendsComplexityToModelsThatSupportIt() {
        var settings = GenerationSettings()
        settings.model = .sunburst26
        settings.complexity = .medium
        let body = OpenAIImageClient.editRequestBody(prompt: "x", settings: settings, references: [], boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"complexity\"\r\n\r\nmedium\r\n"))
        #expect(text.contains("name=\"model\"\r\n\r\ngpt-image-2.6-sunburst\r\n"))
    }

    @Test func buildsMultipartBody() throws {
        var settings = GenerationSettings()
        settings.model = .gptImage2
        settings.quality = .xhigh // not supported by GPT Image 2; should be normalised to high
        settings.outputFormat = .jpeg
        settings.compression = 80
        settings.count = 2
        let references = [
            OpenAIImageClient.ReferenceUpload(fileName: "reference-1.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0x01])),
            OpenAIImageClient.ReferenceUpload(fileName: "reference-2.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x02])),
        ]
        let body = OpenAIImageClient.editRequestBody(prompt: "Put the cat in a hat ✨", settings: settings,
                                                     references: references, boundary: "B")
        let text = String(decoding: body, as: UTF8.self)

        func field(_ name: String) -> String? {
            let marker = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            guard let start = text.range(of: marker)?.upperBound,
                  let end = text[start...].range(of: "\r\n--B")?.lowerBound else { return nil }
            return String(text[start..<end])
        }

        #expect(field("model") == "gpt-image-2")
        #expect(field("prompt") == "Put the cat in a hat ✨")
        #expect(field("n") == "2")
        #expect(field("quality") == "high")
        #expect(field("output_format") == "jpeg")
        #expect(field("output_compression") == "80")
        #expect(field("complexity") == nil) // not supported by GPT Image 2
        #expect(text.components(separatedBy: "name=\"image[]\"").count - 1 == 2)
        #expect(text.contains("filename=\"reference-2.png\"\r\nContent-Type: image/png\r\n\r\n"))
        #expect(text.hasPrefix("--B\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
    }

    @Test func omitsCompressionForPNG() {
        let body = OpenAIImageClient.editRequestBody(prompt: "x", settings: GenerationSettings(), references: [], boundary: "B")
        #expect(!String(decoding: body, as: UTF8.self).contains("output_compression"))
    }

    @Test func targetsEditsEndpoint() {
        let request = OpenAIImageClient.editRequest(apiKey: "sk-test", boundary: "B",
                                                    baseURL: URL(string: "https://api.openai.com/v1")!)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/edits")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }
}
