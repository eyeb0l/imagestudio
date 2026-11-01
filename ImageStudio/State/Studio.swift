import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

/// Runs generation requests and owns library mutations (insert, delete).
@Observable
final class Studio {
    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case running
            case failed(String)
        }

        let id = UUID()
        let prompt: String
        let settings: GenerationSettings
        var startedAt: Date = .now
        var state: State = .running

        var isFailed: Bool {
            if case .failed = state { true } else { false }
        }
    }

    /// In-flight and failed generations, shown as placeholder tiles in the library.
    private(set) var jobs: [Job] = []
    /// Incremented on each success / failure; drives haptics.
    private(set) var completedCount = 0
    private(set) var failureCount = 0

    @ObservationIgnored private var tasks: [Job.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let apiKeys: APIKeyStore
    @ObservationIgnored private let client: OpenAIImageClient

    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer, apiKeys: APIKeyStore, client: OpenAIImageClient = .shared) {
        self.container = container
        self.apiKeys = apiKeys
        self.client = client
    }

    // MARK: Generation

    func generate(prompt: String, settings: GenerationSettings) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let job = Job(prompt: prompt, settings: settings.normalized())
        withAnimation(.snappy) { jobs.append(job) }
        start(job.id)
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
        start(job.id)
    }

    func cancel(_ job: Job) {
        tasks[job.id]?.cancel()
        tasks[job.id] = nil
        withAnimation(.snappy) { jobs.removeAll { $0.id == job.id } }
    }

    private func start(_ jobID: Job.ID) {
        tasks[jobID] = Task { await perform(jobID) }
    }

    private func perform(_ jobID: Job.ID) async {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        // Keep the request alive briefly if the app is backgrounded mid-generation.
        let activity = BackgroundActivity(name: "Image generation")
        defer {
            activity.end()
            tasks[jobID] = nil
        }

        do {
            guard let apiKey = apiKeys.key() else { throw OpenAIError.missingAPIKey }
            let started = Date.now
            let output = try await client.generate(prompt: job.prompt, settings: job.settings, apiKey: apiKey)
            guard jobs.contains(where: { $0.id == jobID }) else { return } // cancelled meanwhile
            try await save(output, for: job, duration: Date.now.timeIntervalSince(started))
            withAnimation(.snappy) { jobs.removeAll { $0.id == jobID } }
            completedCount += 1
        } catch {
            if Self.isCancellation(error) {
                jobs.removeAll { $0.id == jobID }
                return
            }
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[index].state = .failed(error.localizedDescription)
            failureCount += 1
        }
    }

    private func save(_ output: OpenAIImageClient.Output, for job: Job, duration: TimeInterval) async throws {
        let batchID = UUID()
        let now = Date.now
        let reportedSize = output.size.flatMap(ImageSize.init(apiValue:))
        // Tokens are reported for the whole request; attribute them evenly across images.
        let share = { (tokens: Int?) in tokens.map { $0 / max(output.images.count, 1) } }

        for (index, data) in output.images.enumerated() {
            let fileName = ImageStore.makeFileName(format: job.settings.outputFormat, date: now)
            try await ImageStore.save(data, fileName: fileName)
            let pixels = ImageStore.pixelSize(of: data)
            let image = GeneratedImage(
                // Offset by a millisecond so a batch keeps its order in the library.
                createdAt: now.addingTimeInterval(Double(index) / 1000),
                prompt: job.prompt,
                revisedPrompt: output.revisedPrompts[safe: index] ?? nil,
                settings: job.settings,
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

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
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

/// Requests extra background execution time and ends it exactly once.
@MainActor
private final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
