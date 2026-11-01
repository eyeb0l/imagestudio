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
}

/// Runs generation requests on a background URLSession. The system keeps these requests
/// going while the app is suspended or after it's terminated by the system, then relaunches
/// the app in the background to deliver the result.
nonisolated final class GenerationSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.eyeb0l.ImageStudio.generation"
    static let shared = GenerationSession()

    typealias Outcome = Result<OpenAIImageClient.Output, any Error>
    typealias ResultHandler = @MainActor @Sendable (GenerationTicket, Outcome) async -> Void

    private struct State {
        var handler: ResultHandler?
        /// Results that arrived before a handler was registered.
        var undelivered: [(GenerationTicket, Outcome)] = []
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
        for (ticket, outcome) in pending { deliver(ticket, outcome) }
    }

    /// Stores the system's completion handler from a background relaunch; it's called once
    /// all delivered results have been processed.
    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.backgroundCompletion = handler }
    }

    func start(_ ticket: GenerationTicket, apiKey: String) throws {
        let bodyURL = Self.requestURL(for: ticket.jobID)
        try? FileManager.default.removeItem(at: Self.responseURL(for: ticket.jobID))
        try OpenAIImageClient.requestBody(prompt: ticket.prompt, settings: ticket.settings)
            .write(to: bodyURL, options: .atomic)

        // Background sessions only support uploads from a file, not in-memory bodies.
        let task = session.uploadTask(with: OpenAIImageClient.generationRequest(apiKey: apiKey), fromFile: bodyURL)
        task.taskDescription = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        task.resume()
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
        if let error {
            outcome = .failure(error)
        } else if let response = task.response {
            let data = (try? Data(contentsOf: responseURL)) ?? Data()
            outcome = Result { try OpenAIImageClient.parseGeneration(data: data, response: response) }
        } else {
            outcome = .failure(OpenAIError.invalidResponse)
        }

        try? FileManager.default.removeItem(at: responseURL)
        try? FileManager.default.removeItem(at: Self.requestURL(for: ticket.jobID))
        deliver(ticket, outcome)
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

    private func deliver(_ ticket: GenerationTicket, _ outcome: Outcome) {
        state.withLock { state in
            guard let handler = state.handler else {
                state.undelivered.append((ticket, outcome))
                return
            }
            let id = UUID()
            // Created under the lock so the task can't remove itself before it's recorded.
            state.processing[id] = Task { @MainActor in
                await handler(ticket, outcome)
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
