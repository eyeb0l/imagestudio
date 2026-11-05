import Foundation
import Synchronization

/// Everything needed to turn a finished request into library images. It travels with the
/// URLSession task (as its `taskDescription`), so results can be saved even if the app was
/// terminated and relaunched while the request was in flight.
nonisolated struct GenerationTicket: Codable, Sendable, Equatable {
    let jobID: UUID
    let prompt: String
    let settings: GenerationSettings
    let startedAt: Date
    /// Which request attempt this is (1-based). Tickets from before retries existed decode as 1.
    var attempt: Int = 1
    /// Reference images (in `ReferenceStore`). Non-empty requests go to `/images/edits`.
    var referenceFileNames: [String] = []
    /// The annotation layer (see `MarkupStore`) for the first reference. Tickets from before
    /// markup existed decode as `nil`.
    var markupFileName: String?
    /// When this attempt was sent, or due to be, for the failure log.
    var attemptStartedAt: Date?

    init(jobID: UUID, prompt: String, settings: GenerationSettings, startedAt: Date, attempt: Int = 1,
         referenceFileNames: [String] = [], markupFileName: String? = nil) {
        self.jobID = jobID
        self.prompt = prompt
        // Reference images send the request to /images/edits, so its settings must suit that endpoint.
        // This also keeps the saved file's extension in step with what the request asks for.
        self.settings = settings.normalized(hasReferences: !referenceFileNames.isEmpty, hasMarkup: markupFileName != nil)
        self.startedAt = startedAt
        self.attempt = attempt
        self.referenceFileNames = referenceFileNames
        self.markupFileName = markupFileName
    }

    private enum CodingKeys: String, CodingKey {
        case jobID, prompt, settings, startedAt, attempt, referenceFileNames, markupFileName, attemptStartedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            jobID: try container.decode(UUID.self, forKey: .jobID),
            prompt: try container.decode(String.self, forKey: .prompt),
            settings: try container.decode(GenerationSettings.self, forKey: .settings),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            attempt: try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 1,
            referenceFileNames: try container.decodeIfPresent([String].self, forKey: .referenceFileNames) ?? [],
            markupFileName: try container.decodeIfPresent(String.self, forKey: .markupFileName)
        )
        attemptStartedAt = try container.decodeIfPresent(Date.self, forKey: .attemptStartedAt)
    }

    /// The same job, for the next request attempt.
    func nextAttempt() -> GenerationTicket {
        var copy = self
        copy.attempt += 1
        return copy
    }
}

/// Runs generation requests on a background URLSession. The system keeps these requests
/// going while the app is suspended or after it's terminated by the system, then relaunches
/// the app in the background to deliver the result.
nonisolated final class GenerationSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.eyeb0l.ImageStudio.generation"
    static let shared = GenerationSession()

    typealias Outcome = Result<OpenAIImageClient.Output, any Error>
    typealias ResultHandler = @MainActor @Sendable (GenerationTicket, Outcome, _ retryAfter: TimeInterval?,
                                                    _ attemptLog: GenerationAttemptLog?) async -> Void

    private struct Delivery {
        let ticket: GenerationTicket
        let outcome: Outcome
        /// The server's `Retry-After` header, in seconds, if the response had one.
        let retryAfter: TimeInterval?
        /// Details of the attempt, if it failed.
        let attemptLog: GenerationAttemptLog?
    }

    private struct State {
        var handler: ResultHandler?
        /// Results that arrived before a handler was registered.
        var undelivered: [Delivery] = []
        var responseFiles: [UUID: FileHandle] = [:]
        var processing: [UUID: Task<Void, Never>] = [:]
        var backgroundCompletion: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    // Assigned once in init; URLSession is thread-safe.
    nonisolated(unsafe) private var session: URLSession!

    private static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Generations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: Public API

    /// Registers the handler for finished requests and flushes any that arrived earlier.
    func setResultHandler(_ handler: @escaping ResultHandler) {
        let pending = state.withLock { state in
            state.handler = handler
            defer { state.undelivered = [] }
            return state.undelivered
        }
        for delivery in pending { deliver(delivery) }
    }

    /// Stores the system's completion handler from a background relaunch; it's called once
    /// all delivered results have been processed.
    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.backgroundCompletion = handler }
    }

    /// Starts the request. With `notBefore`, the system holds it until then (used for retries),
    /// including while the app is suspended.
    func start(_ ticket: GenerationTicket, apiKey: String, notBefore: Date? = nil) throws {
        var ticket = ticket
        ticket.attemptStartedAt = notBefore ?? .now
        let bodyURL = Self.requestURL(for: ticket.jobID)
        try? FileManager.default.removeItem(at: Self.responseURL(for: ticket.jobID))

        let request: URLRequest
        if ticket.referenceFileNames.isEmpty {
            // Text-only requests have nothing for markup to apply to.
            guard ticket.markupFileName == nil else { throw MarkupStore.MarkupError.noReference }
            try OpenAIImageClient.requestBody(prompt: ticket.prompt, settings: ticket.settings)
                .write(to: bodyURL, options: .atomic)
            request = OpenAIImageClient.generationRequest(apiKey: apiKey)
        } else {
            // With reference images the request goes to /images/edits as multipart form data.
            let boundary = "ImageStudio-\(UUID().uuidString)"
            try Self.editRequestBody(for: ticket, boundary: boundary).write(to: bodyURL, options: .atomic)
            request = OpenAIImageClient.editRequest(apiKey: apiKey, boundary: boundary)
        }

        // Background sessions only support uploads from a file, not in-memory bodies.
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        task.earliestBeginDate = notBefore
        task.resume()
    }

    /// The multipart body for a request with reference images. Throws if a file it needs is
    /// missing or unusable, so a request is never sent without its markup.
    static func editRequestBody(for ticket: GenerationTicket, boundary: String) throws -> Data {
        let uploads = try ticket.referenceFileNames.enumerated().map { index, name in
            guard ReferenceStore.fileExists(name) else { throw ReferenceStore.ImportError.missing }
            let url = ReferenceStore.url(for: name)
            return OpenAIImageClient.ReferenceUpload(
                fileName: "reference-\(index + 1).\(url.pathExtension)",
                mimeType: ReferenceStore.mimeType(for: name),
                data: try Data(contentsOf: url)
            )
        }
        let markup = try ticket.markupFileName.map { overlay in
            guard let first = ticket.referenceFileNames.first else { throw MarkupStore.MarkupError.noReference }
            return try MarkupStore.upload(overlay: overlay, firstReference: first)
        }
        return OpenAIImageClient.editRequestBody(prompt: ticket.prompt, settings: ticket.settings,
                                                 references: uploads, markup: markup, boundary: boundary)
    }

    func cancel(jobID: UUID) async {
        for task in await session.allTasks where Self.ticket(for: task)?.jobID == jobID {
            task.cancel()
        }
    }

    /// Jobs with a request still running (or finished and awaiting delivery) in the system.
    func activeJobIDs() async -> Set<UUID> {
        Set(await session.allTasks.compactMap { Self.ticket(for: $0)?.jobID })
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let ticket = Self.ticket(for: dataTask) else { return }
        // Responses can be tens of megabytes of base64, so stream them to disk.
        // Appending (rather than truncating) keeps chunks delivered before a relaunch.
        state.withLock { state in
            let handle: FileHandle
            if let existing = state.responseFiles[ticket.jobID] {
                handle = existing
            } else {
                let url = Self.responseURL(for: ticket.jobID)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                guard let opened = try? FileHandle(forWritingTo: url) else { return }
                _ = try? opened.seekToEnd()
                state.responseFiles[ticket.jobID] = opened
                handle = opened
            }
            try? handle.write(contentsOf: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let ticket = Self.ticket(for: task) else { return }
        let responseURL = Self.responseURL(for: ticket.jobID)
        state.withLock { state in
            try? state.responseFiles.removeValue(forKey: ticket.jobID)?.close()
        }

        let outcome: Outcome
        let data = (try? Data(contentsOf: responseURL)) ?? Data()
        if let error {
            outcome = .failure(error)
        } else if let response = task.response {
            outcome = Result { try OpenAIImageClient.parseGeneration(data: data, response: response) }
        } else {
            outcome = .failure(OpenAIError.invalidResponse)
        }

        try? FileManager.default.removeItem(at: responseURL)
        try? FileManager.default.removeItem(at: Self.requestURL(for: ticket.jobID))
        var attemptLog: GenerationAttemptLog?
        if case .failure = outcome {
            attemptLog = GenerationAttemptLog(ticket: ticket, response: task.response, data: data)
        }
        deliver(Delivery(ticket: ticket, outcome: outcome, retryAfter: RetryPolicy.retryAfter(from: task.response),
                         attemptLog: attemptLog))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let inFlight = state.withLock { Array($0.processing.values) }
        Task { @MainActor in
            for task in inFlight { await task.value }
            let completion = self.state.withLock { state in
                defer { state.backgroundCompletion = nil }
                return state.backgroundCompletion
            }
            completion?()
        }
    }

    // MARK: Helpers

    private func deliver(_ delivery: Delivery) {
        state.withLock { state in
            guard let handler = state.handler else {
                state.undelivered.append(delivery)
                return
            }
            let id = UUID()
            // Created under the lock so the task can't remove itself before it's recorded.
            state.processing[id] = Task { @MainActor in
                await handler(delivery.ticket, delivery.outcome, delivery.retryAfter, delivery.attemptLog)
                _ = self.state.withLock { $0.processing.removeValue(forKey: id) }
            }
        }
    }

    private static func ticket(for task: URLSessionTask) -> GenerationTicket? {
        guard let description = task.taskDescription else { return nil }
        return try? JSONDecoder().decode(GenerationTicket.self, from: Data(description.utf8))
    }

    private static func requestURL(for jobID: UUID) -> URL {
        directory.appending(path: "\(jobID.uuidString)-request.json")
    }

    private static func responseURL(for jobID: UUID) -> URL {
        directory.appending(path: "\(jobID.uuidString)-response.json")
    }
}
