import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

/// Runs generation requests and owns library mutations (insert, delete).
///
/// Requests run on `GenerationSession`'s background URLSession, so they keep going while the
/// app is suspended. Jobs are mirrored to `PendingGeneration` records so their tiles survive
/// the app being closed; results are matched back to jobs by ID whenever they arrive.
///
/// Transient failures (rate limits, 5xx, flaky connections) are retried automatically, up to
/// `RetryPolicy.maxAttempts` attempts in total. A retry is a new background task with an earliest
/// start date, so it fires even if the app is suspended in the meantime.
@Observable
final class Studio {
    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case running
            case failed(String)
        }

        let id: UUID
        let prompt: String
        let settings: GenerationSettings
        var startedAt: Date
        var state: State
        /// Which request attempt this is (1-based). Failed requests that are worth retrying are
        /// retried automatically while the job stays `.running`.
        var attempt: Int

        init(id: UUID = UUID(), prompt: String, settings: GenerationSettings,
             startedAt: Date = .now, state: State = .running, attempt: Int = 1) {
            self.id = id
            self.prompt = prompt
            self.settings = settings
            self.startedAt = startedAt
            self.state = state
            self.attempt = attempt
        }

        var isFailed: Bool {
            if case .failed = state { true } else { false }
        }
    }

    /// In-flight and failed generations, shown as placeholder tiles in the library.
    private(set) var jobs: [Job] = []
    /// Incremented on each success / failure; drives haptics.
    private(set) var completedCount = 0
    private(set) var failureCount = 0
    /// A library-level error to show the user (e.g. a failed delete). Cleared when dismissed.
    var alertMessage: String?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let apiKeys: APIKeyStore
    @ObservationIgnored private let session: GenerationSession
    /// Downloaded results whose save failed, kept so Retry can save them again without paying for
    /// a new request. In memory only: they last until the job is removed or the app quits.
    @ObservationIgnored private var heldOutputs: [Job.ID: (ticket: GenerationTicket, output: OpenAIImageClient.Output)] = [:]

    private static let log = Logger(subsystem: "com.eyeb0l.ImageStudio", category: "Studio")

    private var context: ModelContext { container.mainContext }

    static let interruptedMessage = "Image Studio was closed before this image finished. Retry to generate it again."

    init(container: ModelContainer, apiKeys: APIKeyStore, session: GenerationSession = .shared) {
        self.container = container
        self.apiKeys = apiKeys
        self.session = session

        let records: [PendingGeneration]
        do {
            records = try container.mainContext.fetch(
                FetchDescriptor<PendingGeneration>(sortBy: [SortDescriptor(\.startedAt)])
            )
        } catch {
            Self.log.error("Couldn't load pending generations: \(error.localizedDescription, privacy: .public)")
            records = []
        }
        jobs = records.map { record in
            Job(id: record.id, prompt: record.prompt, settings: record.settings, startedAt: record.startedAt,
                state: record.failureMessage.map { .failed($0) } ?? .running, attempt: record.attempt)
        }

        session.setResultHandler { [weak self] ticket, outcome, retryAfter in
            await self?.handle(ticket, outcome, retryAfter: retryAfter)
        }

        let restoredRunning = jobs.filter { !$0.isFailed }.map(\.id)
        if !restoredRunning.isEmpty {
            Task { await reconcile(restoredRunning) }
        }
    }

    // MARK: Generation

    func generate(prompt: String, settings: GenerationSettings) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let job = Job(prompt: prompt, settings: settings.normalized())
        withAnimation(.snappy) { jobs.append(job) }
        context.insert(PendingGeneration(id: job.id, prompt: job.prompt, settings: job.settings, startedAt: job.startedAt))
        // If this fails the request still runs and its images are still saved; only the
        // placeholder tile wouldn't survive a relaunch. The record is retried on the next save.
        saveContext("record pending generation")
        start(job)
    }

    /// Generates one new image per source image, using the same prompt and settings.
    func regenerate(_ images: [GeneratedImage]) {
        for image in images {
            generate(prompt: image.prompt, settings: image.settings)
        }
    }

    func retry(_ job: Job) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].state = .running
        if let held = heldOutputs[job.id] {
            // The image was generated (and paid for); only saving it failed. Save it again.
            updateRecord(jobs[index])
            Task { await finish(held.output, for: held.ticket) }
            return
        }
        jobs[index].startedAt = .now
        jobs[index].attempt = 1
        updateRecord(jobs[index])
        start(jobs[index])
    }

    /// Cancels a running job, or dismisses a failed one.
    func cancel(_ job: Job) {
        removeJob(job.id)
        Task { await session.cancel(jobID: job.id) }
    }

    private func start(_ job: Job) {
        let ticket = GenerationTicket(jobID: job.id, prompt: job.prompt, settings: job.settings,
                                      startedAt: job.startedAt, attempt: job.attempt)
        if let problem = submit(ticket) {
            markFailed(job.id, message: problem)
        }
    }

    /// Hands a request to the background session, reading the API key afresh each time (a retry
    /// may happen long after the first attempt). Returns a description of what went wrong, if anything.
    private func submit(_ ticket: GenerationTicket, notBefore: Date? = nil) -> String? {
        let apiKey: String
        do {
            guard let key = try apiKeys.loadKey() else { return OpenAIError.missingAPIKey.localizedDescription }
            apiKey = key
        } catch {
            return "Couldn't read your API key from the Keychain: \(error.localizedDescription)"
        }
        do {
            try session.start(ticket, apiKey: apiKey, notBefore: notBefore)
            return nil
        } catch {
            return "Couldn't start the request: \(error.localizedDescription)"
        }
    }

    /// Called for every finished request — including ones started before the app was relaunched.
    private func handle(_ ticket: GenerationTicket, _ outcome: GenerationSession.Outcome,
                        retryAfter: TimeInterval?) async {
        switch outcome {
        case .success(let output):
            await finish(output, for: ticket)
        case .failure(let error):
            // No job means the user cancelled or dismissed it; nothing to report.
            guard jobs.contains(where: { $0.id == ticket.jobID }) else { return }
            handleFailure(error, for: ticket, retryAfter: retryAfter)
        }
    }

    private func handleFailure(_ error: any Error, for ticket: GenerationTicket, retryAfter: TimeInterval?) {
        var message = Self.message(for: error)

        if let delay = RetryPolicy.retryDelay(after: error, attempt: ticket.attempt, retryAfter: retryAfter) {
            // A new background task with an earliest start date, so it also runs if the app is
            // suspended before the delay is over. The job stays `.running`.
            let next = ticket.nextAttempt()
            if let problem = submit(next, notBefore: Date.now.addingTimeInterval(delay)) {
                markFailed(ticket.jobID, message: "\(message) The automatic retry couldn't be scheduled: \(problem)")
                return
            }
            Self.log.info("Attempt \(ticket.attempt) failed (\(error.localizedDescription, privacy: .public)); retrying in \(Int(delay))s")
            if let index = jobs.firstIndex(where: { $0.id == ticket.jobID }) {
                jobs[index].attempt = next.attempt
                updateRecord(jobs[index])
            }
            return
        }

        if ticket.attempt >= RetryPolicy.maxAttempts, RetryPolicy.isTransient(error) {
            message = RetryPolicy.exhaustedMessage(message, attempts: ticket.attempt)
        }
        markFailed(ticket.jobID, message: message)
    }

    /// Saves a finished result to the library, then clears the job.
    private func finish(_ output: OpenAIImageClient.Output, for ticket: GenerationTicket) async {
        do {
            try await Self.commit(output, for: ticket, in: context)
            removeJob(ticket.jobID)
            completedCount += 1
        } catch {
            // Nothing was added to the library. Keep the output so Retry can save it again.
            if jobs.contains(where: { $0.id == ticket.jobID }) {
                heldOutputs[ticket.jobID] = (ticket, output)
            }
            markFailed(ticket.jobID, message: "Couldn't save the image: \(error.localizedDescription)")
        }
    }

    /// Jobs restored as running whose request no longer exists (e.g. the app was force-quit,
    /// which cancels background requests) can never finish, so mark them as failed.
    private func reconcile(_ restoredRunning: [Job.ID]) async {
        let active = await session.activeJobIDs()
        for id in restoredRunning where !active.contains(id) {
            guard let job = jobs.first(where: { $0.id == id }), !job.isFailed else { continue }
            markFailed(id, message: Self.interruptedMessage, haptic: false)
        }
    }

    /// Adds a batch to the library all-or-nothing: every file is written first, then all records
    /// are inserted and saved once. On any failure the library and the image folder are left as
    /// they were, so retrying can't create duplicates. The closures exist so tests can inject failures.
    static func commit(
        _ output: OpenAIImageClient.Output,
        for ticket: GenerationTicket,
        in context: ModelContext,
        now: Date = .now,
        writeFile: (Data, String) async throws -> Void = { try await ImageStore.save($0, fileName: $1) },
        removeFile: (String) throws -> Void = { try ImageStore.delete(fileName: $0) },
        persist: (ModelContext) throws -> Void = { try $0.save() }
    ) async throws {
        let batchID = UUID()
        let duration = now.timeIntervalSince(ticket.startedAt)
        let reportedSize = output.size.flatMap(ImageSize.init(apiValue:))
        // Tokens are reported for the whole request; attribute them evenly across images.
        let share = { (tokens: Int?) in tokens.map { $0 / max(output.images.count, 1) } }

        func discard(_ fileNames: [String]) {
            for name in fileNames {
                do { try removeFile(name) } catch {
                    log.error("Couldn't remove \(name, privacy: .public) after a failed save: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // 1. Write every file. A failure removes the ones already written.
        var written: [(fileName: String, data: Data)] = []
        for data in output.images {
            let fileName = ImageStore.makeFileName(format: ticket.settings.outputFormat, date: now)
            do {
                try await writeFile(data, fileName)
            } catch {
                discard(written.map(\.fileName) + [fileName])
                throw error
            }
            written.append((fileName, data))
        }

        // 2. Insert all records and save once. On failure take them out again, and the files too.
        var inserted: [GeneratedImage] = []
        for (index, item) in written.enumerated() {
            let pixels = ImageStore.pixelSize(of: item.data)
            let image = GeneratedImage(
                // Offset by a millisecond so a batch keeps its order in the library.
                createdAt: now.addingTimeInterval(Double(index) / 1000),
                prompt: ticket.prompt,
                revisedPrompt: output.revisedPrompts[safe: index] ?? nil,
                settings: ticket.settings,
                width: pixels?.width ?? reportedSize?.width ?? 0,
                height: pixels?.height ?? reportedSize?.height ?? 0,
                resolvedQuality: output.quality,
                resolvedBackground: output.background,
                fileName: item.fileName,
                fileSize: item.data.count,
                batchID: batchID,
                duration: duration,
                inputTokens: share(output.inputTokens),
                outputTokens: share(output.outputTokens)
            )
            context.insert(image)
            inserted.append(image)
        }
        do {
            try persist(context)
        } catch {
            for image in inserted { context.delete(image) }
            discard(written.map(\.fileName))
            throw error
        }
    }

    private static func message(for error: any Error) -> String {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            // A cancellation we didn't ask for: the system stopped it, e.g. after a force-quit.
            return interruptedMessage
        }
        return error.localizedDescription
    }

    // MARK: Job bookkeeping

    private func markFailed(_ id: Job.ID, message: String, haptic: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .failed(message)
        updateRecord(jobs[index])
        if haptic { failureCount += 1 }
    }

    private func removeJob(_ id: Job.ID) {
        withAnimation(.snappy) { jobs.removeAll { $0.id == id } }
        heldOutputs[id] = nil
        do {
            try context.delete(model: PendingGeneration.self, where: #Predicate { $0.id == id })
        } catch {
            Self.log.error("Couldn't delete pending record: \(error.localizedDescription, privacy: .public)")
        }
        // If this fails, the stale record comes back as a failed tile after a relaunch, which the
        // user can dismiss. The images themselves are already safe.
        saveContext("remove pending generation")
    }

    /// Mirrors a job to its record, creating the record if the original insert never made it.
    private func updateRecord(_ job: Job) {
        let id = job.id
        let record: PendingGeneration
        do {
            if let existing = try context.fetch(FetchDescriptor<PendingGeneration>(predicate: #Predicate { $0.id == id })).first {
                record = existing
            } else {
                record = PendingGeneration(id: job.id, prompt: job.prompt, settings: job.settings, startedAt: job.startedAt)
                context.insert(record)
            }
        } catch {
            Self.log.error("Couldn't look up pending record: \(error.localizedDescription, privacy: .public)")
            return
        }
        record.startedAt = job.startedAt
        record.attempt = job.attempt
        if case .failed(let message) = job.state {
            record.failureMessage = message
        } else {
            record.failureMessage = nil
        }
        saveContext("update pending generation")
    }

    @discardableResult
    private func saveContext(_ action: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            Self.log.error("Couldn't \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Library

    func delete(_ images: [GeneratedImage]) {
        if let problem = Self.deleteImages(images, in: context) { alertMessage = problem }
    }

    func deleteAll() {
        if let problem = Self.deleteEverything(in: context) { alertMessage = problem }
    }

    /// Deletes records first and files only once the records are gone, so a failure never leaves a
    /// library entry pointing at a missing file. Returns a message for the user if anything failed.
    static func deleteImages(
        _ images: [GeneratedImage],
        in context: ModelContext,
        removeFile: (String) throws -> Void = { try ImageStore.delete(fileName: $0) }
    ) -> String? {
        guard !images.isEmpty else { return nil }
        let fileNames = images.map(\.fileName)
        for image in images { context.delete(image) }
        do {
            try context.save()
        } catch {
            context.rollback()
            log.error("Couldn't delete images: \(error.localizedDescription, privacy: .public)")
            return "Couldn't delete \(images.count == 1 ? "the image" : "the images"): \(error.localizedDescription)"
        }
        var failures = 0
        for name in fileNames {
            do { try removeFile(name) } catch {
                failures += 1
                log.error("Couldn't remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard failures > 0 else { return nil }
        return "Removed from your library, but \(failures == 1 ? "1 file" : "\(failures) files") couldn't be deleted from storage and may still take up space."
    }

    static func deleteEverything(
        in context: ModelContext,
        removeAllFiles: () throws -> Void = { try ImageStore.deleteAll() }
    ) -> String? {
        do {
            try context.delete(model: GeneratedImage.self)
            try context.save()
        } catch {
            context.rollback()
            log.error("Couldn't delete all images: \(error.localizedDescription, privacy: .public)")
            return "Couldn't delete your images: \(error.localizedDescription)"
        }
        do {
            try removeAllFiles()
            return nil
        } catch {
            log.error("Couldn't remove image files: \(error.localizedDescription, privacy: .public)")
            return "Your library was cleared, but some files couldn't be deleted from storage and may still take up space. \(error.localizedDescription)"
        }
    }

    #if DEBUG
    /// Adds placeholder jobs without making a request, for previews and UI checks.
    func addSampleJobs() {
        var settings = GenerationSettings()
        settings.count = 2
        jobs.append(Job(prompt: "A quiet harbour at dawn", settings: settings))
        jobs.append(Job(prompt: "Sample failure", settings: GenerationSettings(),
                        state: .failed("OpenAI rejected this API key. Check it in Settings.")))
    }
    #endif
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
