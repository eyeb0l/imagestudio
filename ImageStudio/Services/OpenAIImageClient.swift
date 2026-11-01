import Foundation

/// Errors surfaced to the user from OpenAI requests.
nonisolated enum OpenAIError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case blockedBySafetySystem(String?)
    case api(status: Int, message: String?, code: String?)
    case invalidResponse
    case noImages

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your OpenAI API key in Settings to generate images."
        case .invalidAPIKey:
            "OpenAI rejected this API key. Check it in Settings."
        case .blockedBySafetySystem(let message):
            message ?? "This request was blocked by OpenAI's safety system. Try rephrasing the prompt."
        case .api(let status, let message, _):
            message ?? "OpenAI returned an error (HTTP \(status))."
        case .invalidResponse:
            "OpenAI returned a response Image Studio couldn't read."
        case .noImages:
            "OpenAI didn't return any images. Try again."
        }
    }
}

/// Builds, verifies and parses OpenAI Image API requests. Generation requests themselves run
/// on a background URLSession (`GenerationSession`); this client's session is only used to verify keys.
nonisolated struct OpenAIImageClient: Sendable {
    static let shared = OpenAIImageClient()

    let session: URLSession
    let baseURL: URL

    init(session: URLSession? = nil, baseURL: URL = OpenAIImageClient.defaultBaseURL) {
        self.session = session ?? Self.makeSession()
        self.baseURL = baseURL
    }

    static var defaultBaseURL: URL {
        #if DEBUG
        // Lets a debug build target a local mock server: launch with `-OpenAIBaseURL http://127.0.0.1:8765/v1`.
        if let override = UserDefaults.standard.string(forKey: "OpenAIBaseURL"), let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://api.openai.com/v1")!
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    struct Output: Sendable {
        var images: [Data]
        var revisedPrompts: [String?]
        var size: String?
        var quality: String?
        var background: String?
        var outputFormat: String?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    // MARK: Requests

    /// The request for `/images/generations`. The body is supplied separately because
    /// generations run as background uploads (see `GenerationSession`).
    static func generationRequest(apiKey: String, baseURL: URL = defaultBaseURL) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "images/generations"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Checks a key against a lightweight, free endpoint.
    @concurrent
    func verify(apiKey: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Self.validate(data: data, response: response)
    }

    // MARK: Encoding and decoding (static for testability)

    struct RequestBody: Encodable {
        let model: String
        let prompt: String
        let n: Int
        let size: String
        let quality: String
        let background: String
        let moderation: String
        let outputFormat: String
        let outputCompression: Int?

        enum CodingKeys: String, CodingKey {
            case model, prompt, n, size, quality, background, moderation
            case outputFormat = "output_format"
            case outputCompression = "output_compression"
        }
    }

    static func requestBody(prompt: String, settings: GenerationSettings) throws -> Data {
        let settings = settings.normalized()
        let body = RequestBody(
            model: settings.model.rawValue,
            prompt: prompt,
            n: settings.count,
            size: settings.size.apiValue,
            quality: settings.quality.rawValue,
            background: settings.background.rawValue,
            moderation: settings.moderation.rawValue,
            outputFormat: settings.outputFormat.rawValue,
            outputCompression: settings.outputFormat.supportsCompression ? settings.compression : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(body)
    }

    private struct GenerationResponse: Decodable {
        struct Item: Decodable {
            let b64Json: String?
            let revisedPrompt: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
        }

        let data: [Item]?
        let size: String?
        let quality: String?
        let background: String?
        let outputFormat: String?
        let usage: Usage?
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let message: String?
            let type: String?
            let code: String?
        }

        let error: Body
    }

    static func parseGeneration(data: Data, response: URLResponse) throws -> Output {
        try validate(data: data, response: response)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(GenerationResponse.self, from: data) else {
            throw OpenAIError.invalidResponse
        }

        let items = decoded.data ?? []
        var images: [Data] = []
        var revisedPrompts: [String?] = []
        for item in items {
            guard let base64 = item.b64Json, let imageData = Data(base64Encoded: base64) else { continue }
            images.append(imageData)
            revisedPrompts.append(item.revisedPrompt)
        }
        guard !images.isEmpty else { throw OpenAIError.noImages }

        return Output(
            images: images,
            revisedPrompts: revisedPrompts,
            size: decoded.size,
            quality: decoded.quality,
            background: decoded.background,
            outputFormat: decoded.outputFormat,
            inputTokens: decoded.usage?.inputTokens,
            outputTokens: decoded.usage?.outputTokens
        )
    }

    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }

        let body = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
        let message = body?.message.flatMap { $0.isEmpty ? nil : $0 }

        if http.statusCode == 401 { throw OpenAIError.invalidAPIKey }
        if body?.code == "moderation_blocked" {
            throw OpenAIError.blockedBySafetySystem(message)
        }
        throw OpenAIError.api(status: http.statusCode, message: message, code: body?.code)
    }
}
