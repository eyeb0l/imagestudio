import Foundation

/// What's known about one failed request attempt, kept with the job so it can be read later,
/// including after a relaunch. Never holds the API key: it's built from the response alone, and
/// anything in the response that looks like a key is masked.
nonisolated struct GenerationAttemptLog: Codable, Sendable, Equatable, Identifiable {
    /// Response text kept per attempt. An error page's start says what produced it.
    static let maxExcerptLength = 500
    private static let titleSearchLength = 4096

    var id = UUID()
    let attempt: Int
    let startedAt: Date
    /// From sending the request (or when it was due to send) until the response finished.
    let duration: TimeInterval
    /// `nil` if no response arrived, e.g. the connection was lost.
    let status: Int?
    /// OpenAI's `x-request-id`, which its support can look up.
    let requestID: String?
    /// How long OpenAI says it spent, from `openai-processing-ms`.
    let processingMilliseconds: Int?
    /// Says which layer answered: a gateway's response has no OpenAI request ID or JSON error.
    let server: String?
    let rayID: String?
    let contentType: String?
    /// The `Retry-After` header as sent, including values longer than the app will wait.
    let retryAfter: String?
    let responseExcerpt: String?
    /// The message the app showed for this attempt.
    var message = ""

    init(ticket: GenerationTicket, response: URLResponse?, data: Data, finishedAt: Date = .now) {
        let http = response as? HTTPURLResponse
        attempt = ticket.attempt
        startedAt = ticket.attemptStartedAt ?? ticket.startedAt
        duration = max(finishedAt.timeIntervalSince(startedAt), 0)
        status = http?.statusCode
        requestID = http?.value(forHTTPHeaderField: "x-request-id")
        processingMilliseconds = http?.value(forHTTPHeaderField: "openai-processing-ms").flatMap(Int.init)
        server = http?.value(forHTTPHeaderField: "server")
        rayID = http?.value(forHTTPHeaderField: "cf-ray")
        contentType = http?.value(forHTTPHeaderField: "content-type")
        retryAfter = http?.value(forHTTPHeaderField: "retry-after")
        responseExcerpt = Self.excerpt(of: data)
    }

    /// The start of a response or, for an error page, just its title: what comes first in one
    /// is mostly boilerplate.
    static func excerpt(of data: Data) -> String? {
        let start = String(decoding: data.prefix(titleSearchLength), as: UTF8.self)
        let title = start.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/).map { String($0.1) }
        let text = (title ?? String(decoding: data.prefix(maxExcerptLength), as: UTF8.self))
            .replacing(/sk-[A-Za-z0-9_\-*•]+/, with: "sk-…")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    var resultLabel: String {
        status.map { "HTTP \($0)" } ?? "No response"
    }
}

/// The attempts behind a failed job as text, to read or to send to OpenAI's support.
/// Includes the prompt, as it may be what's failing, and is only ever copied by the user.
nonisolated enum GenerationFailureReport {
    /// A job's log keeps this many attempts, the most recent ones.
    static let maxAttempts = 12

    static func appending(_ attempt: GenerationAttemptLog, to log: [GenerationAttemptLog]) -> [GenerationAttemptLog] {
        Array((log + [attempt]).suffix(maxAttempts))
    }

    static func durationLabel(_ duration: TimeInterval) -> String {
        Duration.seconds(duration.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    static func text(prompt: String, settings: GenerationSettings, referenceCount: Int, hasMarkup: Bool,
                     message: String?, attempts: [GenerationAttemptLog]) -> String {
        var lines = ["Image Studio generation failure"]
        if let message { lines.append("Message: \(message)") }
        lines += requestRows(settings: settings, referenceCount: referenceCount, hasMarkup: hasMarkup).map { "\($0.0): \($0.1)" }
        lines.append("Prompt: \(prompt)")
        for attempt in attempts {
            lines.append("")
            lines.append("Attempt \(attempt.attempt)")
            lines += attemptRows(attempt).map { "\($0.0): \($0.1)" }
        }
        return lines.joined(separator: "\n")
    }

    static func requestRows(settings: GenerationSettings, referenceCount: Int, hasMarkup: Bool) -> [(String, String)] {
        var rows = [
            ("Model", settings.model.rawValue),
            ("Format", settings.outputFormat.rawValue),
            ("Size", settings.size.apiValue),
            ("Quality", settings.quality.rawValue),
        ]
        if let complexity = settings.apiComplexity { rows.append(("Complexity", complexity)) }
        if let author = settings.apiSVGAuthor { rows.append(("SVG author", author)) }
        if referenceCount > 0 { rows.append(("References", referenceCount.formatted())) }
        if hasMarkup { rows.append(("Markup", "Yes")) }
        return rows
    }

    static func attemptRows(_ attempt: GenerationAttemptLog) -> [(String, String)] {
        var rows = [
            ("Result", attempt.resultLabel),
            ("Started", attempt.startedAt.formatted(.iso8601)),
            ("Took", durationLabel(attempt.duration)),
        ]
        if !attempt.message.isEmpty { rows.append(("Message", attempt.message)) }
        if let id = attempt.requestID { rows.append(("Request ID", id)) }
        if let ms = attempt.processingMilliseconds { rows.append(("OpenAI processing", "\(ms) ms")) }
        if let server = attempt.server { rows.append(("Server", server)) }
        if let ray = attempt.rayID { rows.append(("CF-Ray", ray)) }
        if let type = attempt.contentType { rows.append(("Content type", type)) }
        if let retryAfter = attempt.retryAfter { rows.append(("Retry-After", retryAfter)) }
        if let excerpt = attempt.responseExcerpt { rows.append(("Response", excerpt)) }
        return rows
    }
}
