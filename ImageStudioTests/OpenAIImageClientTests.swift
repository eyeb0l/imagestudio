import Foundation
import Testing
@testable import ImageStudio

@Suite("OpenAI client")
struct OpenAIImageClientTests {
    private let url = URL(string: "https://api.openai.com/v1/images/generations")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func encodesRequestBody() throws {
        var settings = GenerationSettings()
        settings.model = .sunburst
        settings.size = ImageSize(width: 1536, height: 864)
        settings.quality = .xhigh
        settings.count = 2
        let body = try json(OpenAIImageClient.requestBody(prompt: "A cat", settings: settings))

        #expect(body["model"] as? String == "gpt-image-2.5-sunburst")
        #expect(body["prompt"] as? String == "A cat")
        #expect(body["n"] as? Int == 2)
        #expect(body["size"] as? String == "1536x864")
        #expect(body["quality"] as? String == "xhigh")
        #expect(body["output_format"] as? String == "png")
        #expect(body["output_compression"] == nil) // PNG has no compression
    }

    @Test func includesCompressionForLossyFormats() throws {
        var settings = GenerationSettings()
        settings.outputFormat = .webp
        settings.compression = 75
        let body = try json(OpenAIImageClient.requestBody(prompt: "x", settings: settings))
        #expect(body["output_format"] as? String == "webp")
        #expect(body["output_compression"] as? Int == 75)
    }

    @Test func parsesSuccessfulResponse() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let payload = """
        {"created": 1, "size": "1024x1024", "quality": "high", "background": "opaque", "output_format": "png",
         "data": [{"b64_json": "\(png)"}, {"b64_json": "\(png)"}],
         "usage": {"input_tokens": 12, "output_tokens": 4160, "total_tokens": 4172}}
        """
        let output = try OpenAIImageClient.parseGeneration(data: Data(payload.utf8), response: response(200))
        #expect(output.images.count == 2)
        #expect(output.quality == "high")
        #expect(output.background == "opaque")
        #expect(output.inputTokens == 12)
        #expect(output.outputTokens == 4160)
    }

    @Test func emptyDataIsAnError() {
        #expect(throws: OpenAIError.noImages) {
            try OpenAIImageClient.parseGeneration(data: Data(#"{"created":1,"data":[]}"#.utf8), response: response(200))
        }
    }

    @Test func mapsUnauthorized() {
        let body = #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#
        #expect(throws: OpenAIError.invalidAPIKey) {
            try OpenAIImageClient.validate(data: Data(body.utf8), response: response(401))
        }
    }

    @Test func mapsModerationBlocks() {
        let body = #"{"error":{"message":"Your request was rejected by the safety system.","type":"image_generation_user_error","code":"moderation_blocked"}}"#
        #expect(throws: OpenAIError.blockedBySafetySystem("Your request was rejected by the safety system.")) {
            try OpenAIImageClient.validate(data: Data(body.utf8), response: response(400))
        }
    }

    @Test func surfacesAPIMessages() {
        let body = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#
        do {
            try OpenAIImageClient.validate(data: Data(body.utf8), response: response(429))
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription == "You exceeded your current quota.")
        }
    }

    @Test func handlesNonJSONErrors() {
        #expect(throws: OpenAIError.api(status: 502, message: nil, code: nil)) {
            try OpenAIImageClient.validate(data: Data("Bad Gateway".utf8), response: response(502))
        }
    }

    @Test func masksKeys() {
        #expect(APIKeyStore.mask("sk-proj-abcdefghijklmnop1234") == "sk-proj-••••1234")
        #expect(APIKeyStore.mask("sk-abcdefWXYZ") == "sk-••••WXYZ")
    }
}

@Suite("Keychain", .serialized)
@MainActor
struct KeychainTests {
    @Test func storesUpdatesAndRemovesKey() throws {
        let store = APIKeyStore(service: "com.eyeb0l.ImageStudio.tests.\(UUID().uuidString)")
        #expect(!store.isConfigured)

        try store.save("  sk-test-1111  ")
        #expect(store.isConfigured)
        #expect(store.key() == "sk-test-1111")

        try store.save("sk-test-2222")
        #expect(store.key() == "sk-test-2222")
        #expect(store.maskedKey == "sk-••••2222")

        try store.remove()
        #expect(!store.isConfigured)
        #expect(store.key() == nil)
    }
}
