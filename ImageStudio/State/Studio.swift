import Foundation
import Observation
import SwiftData
import SwiftUI

/// Runs generation requests and owns library mutations (insert, delete).
///
/// Requests run on `GenerationSession`'s background URLSession, so they keep going while the
/// app is suspended. Jobs are mirrored to `PendingGeneration` records so their tiles survive
/// the app being closed; results are matched back to jobs by ID whenever they arrive.
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

        init(id: UUID = UUID(), prompt: String, settings: GenerationSettings,
             startedAt: Date = .now, state: State = .running) {
            self.id = id
            self.prompt = prompt
            self.settings = settings
            self.startedAt = startedAt
            self.state = state
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

    private var context: ModelContext { container.mainContext }

    static let interruptedMessage = "Image Studio was closed before this image finished. Retry to generate it again."

    init(container: ModelContainer, apiKeys: APIKeyStore, session: GenerationSession = .shared) {
        self.container = container
        self.apiKeys = apiKeys
        self.session = session

        let records = (try? container.mainContext.fetch(
            FetchDescriptor<PendingGeneration>(sortBy: [SortDescriptor(\.startedAt)])
        )) ?? []
        jobs = records.map { record in
            Job(id: record.id, prompt: record.prompt, settings: record.settings, startedAt: record.startedAt,
                state: record.failureMessage.map { .failed($0) } ?? .running)
        }

        session.setResultHandler { [weak self] ticket, outcome in
            await self?.handle(ticket, outcome)
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
        try? context.save()
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
        jobs[index].startedAt = .now
        updateRecord(jobs[index])
        start(jobs[index])
    }

    /// Cancels a running job, or dismisses a failed one.
    func cancel(_ job: Job) {
        removeJob(job.id)
        Task { await session.cancel(jobID: job.id) }
    }

    private func start(_ job: Job) {
        let apiKey: String
        do {
            guard let key = try apiKeys.loadKey() else {
                markFailed(job.id, message: OpenAIError.missingAPIKey.localizedDescription)
                return
            }
            apiKey = key
        } catch {
            markFailed(job.id, message: "Couldn't read your API key from the Keychain: \(error.localizedDescription)")
            return
        }
        do {
            let ticket = GenerationTicket(jobID: job.id, prompt: job.prompt, settings: job.settings, startedAt: job.startedAt)
            try session.start(ticket, apiKey: apiKey)
        } catch {
            markFailed(job.id, message: "Couldn't start the request: \(error.localizedDescription)")
        }
    }

    /// Called for every finished request — including ones started before the app was relaunched.
    private func handle(_ ticket: GenerationTicket, _ outcome: GenerationSession.Outcome) async {
        switch outcome {
        case .success(let output):
            do {
                try await save(output, for: ticket)
                removeJob(ticket.jobID)
                completedCount += 1
            } catch {
                markFailed(ticket.jobID, message: "Couldn't save the image: \(error.localizedDescription)")
            }
        case .failure(let error):
            // No job means the user cancelled or dismissed it; nothing to report.
            guard jobs.contains(where: { $0.id == ticket.jobID }) else { return }
            markFailed(ticket.jobID, message: Self.message(for: error))
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

    private func save(_ output: OpenAIImageClient.Output, for ticket: GenerationTicket) async throws {
        let batchID = UUID()
        let now = Date.now
        let duration = now.timeIntervalSince(ticket.startedAt)
        let reportedSize = output.size.flatMap(ImageSize.init(apiValue:))
        // Tokens are reported for the whole request; attribute them evenly across images.
        let share = { (tokens: Int?) in tokens.map { $0 / max(output.images.count, 1) } }

        for (index, data) in output.images.enumerated() {
            let fileName = ImageStore.makeFileName(format: ticket.settings.outputFormat, date: now)
            try await ImageStore.save(data, fileName: fileName)
            let pixels = ImageStore.pixelSize(of: data)
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
                fileName: fileName,
                fileSize: data.count,
                batchID: batchID,
                duration: duration,
                inputTokens: share(output.inputTokens),
                outputTokens: share(output.outputTokens)
            )
            context.insert(image)
        }
        try context.save()
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
        try? context.delete(model: PendingGeneration.self, where: #Predicate { $0.id == id })
        try? context.save()
    }

    private func updateRecord(_ job: Job) {
        let id = job.id
        guard let record = try? context.fetch(FetchDescriptor<PendingGeneration>(predicate: #Predicate { $0.id == id })).first
        else { return }
        record.startedAt = job.startedAt
        if case .failed(let message) = job.state {
            record.failureMessage = message
        } else {
            record.failureMessage = nil
        }
        try? context.save()
    }

    // MARK: Library

    func delete(_ images: [GeneratedImage]) {
        for image in images {
            ImageStore.delete(fileName: image.fileName)
            context.delete(image)
        }
        try? context.save()
    }

    func deleteAll() {
        try? context.delete(model: GeneratedImage.self)
        try? context.save()
        ImageStore.deleteAll()
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
