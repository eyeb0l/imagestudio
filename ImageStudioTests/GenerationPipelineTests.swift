import Foundation
import SwiftData
import Testing
@testable import ImageStudio

// MARK: Retry policy

@Suite("Retry policy")
struct RetryPolicyTests {
    private func api(_ status: Int, message: String? = nil, code: String? = nil) -> OpenAIError {
        .api(status: status, message: message, code: code)
    }

    @Test func retriesRateLimits() {
        #expect(RetryPolicy.isTransient(api(429, message: "Rate limit reached for requests", code: "rate_limit_exceeded")))
        #expect(RetryPolicy.isTransient(api(429)))
    }

    @Test func doesNotRetryQuotaProblems() {
        #expect(!RetryPolicy.isTransient(api(429, message: "You exceeded your current quota.", code: "insufficient_quota")))
        #expect(!RetryPolicy.isTransient(api(429, message: nil, code: "billing_hard_limit_reached")))
        // Even without a code, the quota wording gives it away.
        #expect(!RetryPolicy.isTransient(api(429, message: "You exceeded your current quota, please check your plan.")))
    }

    @Test func retriesServerErrors() {
        for status in [500, 502, 503, 504] {
            #expect(RetryPolicy.isTransient(api(status)), "HTTP \(status)")
        }
    }

    @Test func doesNotRetryClientErrors() {
        for status in [400, 401, 403, 404, 422] {
            #expect(!RetryPolicy.isTransient(api(status)), "HTTP \(status)")
        }
        #expect(!RetryPolicy.isTransient(OpenAIError.invalidAPIKey))
        #expect(!RetryPolicy.isTransient(OpenAIError.blockedBySafetySystem(nil)))
        #expect(!RetryPolicy.isTransient(OpenAIError.invalidResponse))
        #expect(!RetryPolicy.isTransient(OpenAIError.noImages))
        #expect(!RetryPolicy.isTransient(OpenAIError.missingAPIKey))
    }

    @Test func retriesTransientNetworkErrors() {
        let transient: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                          .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost]
        for code in transient {
            #expect(RetryPolicy.isTransient(URLError(code)), "\(code)")
        }
    }

    @Test func doesNotRetryOtherNetworkErrorsOrCancellation() {
        #expect(!RetryPolicy.isTransient(URLError(.cancelled)))
        #expect(!RetryPolicy.isTransient(URLError(.badURL)))
        #expect(!RetryPolicy.isTransient(URLError(.secureConnectionFailed)))
        #expect(!RetryPolicy.isTransient(CocoaError(.fileWriteOutOfSpace)))
    }

    @Test func backoffGrowsExponentiallyWithJitter() {
        // Mid-range jitter gives the nominal 2s, then 8s.
        #expect(RetryPolicy.delay(afterAttempt: 1, retryAfter: nil, jitter: 0.5) == 2)
        #expect(RetryPolicy.delay(afterAttempt: 2, retryAfter: nil, jitter: 0.5) == 8)
        // Jitter spans +/-25%.
        #expect(RetryPolicy.delay(afterAttempt: 1, retryAfter: nil, jitter: 0) == 1.5)
        #expect(RetryPolicy.delay(afterAttempt: 1, retryAfter: nil, jitter: 1) == 2.5)
        #expect(RetryPolicy.delay(afterAttempt: 2, retryAfter: nil, jitter: 0) == 6)
        // Out-of-range jitter is clamped.
        #expect(RetryPolicy.delay(afterAttempt: 1, retryAfter: nil, jitter: 7) == 2.5)
    }

    @Test func honoursRetryAfter() {
        #expect(RetryPolicy.delay(afterAttempt: 1, retryAfter: 12, jitter: 0.5) == 12)
        // Capped, and never zero.
        #expect(RetryPolicy.delay(afterAttempt: 1, retryAfter: 600, jitter: 0.5) == 60)
        #expect(RetryPolicy.delay(afterAttempt: 1, retryAfter: 0, jitter: 0.5) == 1)
    }

    @Test func parsesRetryAfterHeader() throws {
        let url = try #require(URL(string: "https://api.openai.com/v1/images/generations"))
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: headers)!
        }
        #expect(RetryPolicy.retryAfter(from: response(["Retry-After": "7"])) == 7)
        #expect(RetryPolicy.retryAfter(from: response(["retry-after": " 2.5 "])) == 2.5)
        #expect(RetryPolicy.retryAfter(from: response([:])) == nil)
        #expect(RetryPolicy.retryAfter(from: response(["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])) == nil)
        #expect(RetryPolicy.retryAfter(from: response(["Retry-After": "-5"])) == nil)
        #expect(RetryPolicy.retryAfter(from: nil) == nil)
    }

    @Test func stopsAfterThreeAttempts() {
        let error = api(503)
        #expect(RetryPolicy.retryDelay(after: error, attempt: 1, jitter: 0.5) == 2)
        #expect(RetryPolicy.retryDelay(after: error, attempt: 2, jitter: 0.5) == 8)
        #expect(RetryPolicy.retryDelay(after: error, attempt: 3, jitter: 0.5) == nil)
    }

    @Test func neverSchedulesRetriesForPermanentErrors() {
        #expect(RetryPolicy.retryDelay(after: OpenAIError.invalidAPIKey, attempt: 1) == nil)
        #expect(RetryPolicy.retryDelay(after: api(429, code: "insufficient_quota"), attempt: 1) == nil)
        #expect(RetryPolicy.retryDelay(after: URLError(.cancelled), attempt: 1) == nil)
    }

    @Test func retryAfterAppliesToScheduledRetries() {
        #expect(RetryPolicy.retryDelay(after: api(429), attempt: 1, retryAfter: 20, jitter: 0.5) == 20)
    }

    @Test func exhaustedMessageKeepsOriginalText() {
        #expect(RetryPolicy.exhaustedMessage("Rate limit reached.", attempts: 3) == "Rate limit reached (after 3 attempts).")
        #expect(RetryPolicy.exhaustedMessage("The request timed out", attempts: 3) == "The request timed out (after 3 attempts)")
    }

    @Test func errorMessagesAreUnchanged() {
        #expect(api(503).localizedDescription == "OpenAI returned an error (HTTP 503).")
        #expect(api(429, message: "Slow down").localizedDescription == "Slow down")
    }
}

// MARK: Tickets and pending records

@Suite("Generation tickets")
struct GenerationTicketTests {
    @Test func decodesTicketsWithoutAttempt() throws {
        // A task description written by a build from before retries existed.
        let id = UUID()
        var settings = GenerationSettings()
        settings.count = 2
        let current = GenerationTicket(jobID: id, prompt: "A fox", settings: settings, startedAt: Date(timeIntervalSince1970: 1_000))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        #expect(json["attempt"] as? Int == 1)
        json["attempt"] = nil

        let old = try JSONDecoder().decode(GenerationTicket.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old == current)
        #expect(old.attempt == 1)
    }

    @Test func attemptRoundTrips() throws {
        let ticket = GenerationTicket(jobID: UUID(), prompt: "x", settings: GenerationSettings(),
                                      startedAt: .now, attempt: 2)
        let decoded = try JSONDecoder().decode(GenerationTicket.self, from: JSONEncoder().encode(ticket))
        #expect(decoded.attempt == 2)
        #expect(decoded.nextAttempt().attempt == 3)
        #expect(decoded.nextAttempt().jobID == ticket.jobID)
    }

    @MainActor
    @Test func pendingRecordsDefaultToFirstAttempt() throws {
        let container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let record = PendingGeneration(id: UUID(), prompt: "p", settings: GenerationSettings(), startedAt: .now)
        #expect(record.attempt == 1)
        container.mainContext.insert(record)
        record.attempt = 3
        try container.mainContext.save()
        let fetched = try container.mainContext.fetch(FetchDescriptor<PendingGeneration>())
        #expect(fetched.first?.attempt == 3)
    }
}

// MARK: Atomic batch saves

/// A ModelContext doesn't keep its container alive, so tests park their containers here.
@MainActor private var retainedContainers: [ModelContainer] = []

@MainActor private func makeInMemoryContext() throws -> ModelContext {
    let container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    retainedContainers.append(container)
    return container.mainContext
}

@Suite("Batch saves")
@MainActor
struct BatchSaveTests {
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    /// An in-memory stand-in for the image folder.
    private final class FakeDisk {
        var files: [String: Data] = [:]
        var failOnWrite: Int?
        private var writes = 0

        func write(_ data: Data, _ name: String) async throws {
            writes += 1
            if writes == failOnWrite { throw Boom() }
            files[name] = data
        }

        func remove(_ name: String) throws { files[name] = nil }
    }

    private func makeContext() throws -> ModelContext { try makeInMemoryContext() }

    private func output(count: Int) -> OpenAIImageClient.Output {
        OpenAIImageClient.Output(
            images: (0..<count).map { Data([UInt8($0), 1, 2, 3]) },
            revisedPrompts: Array(repeating: nil, count: count),
            size: "1024x1024", quality: "high", background: "opaque", outputFormat: "png",
            inputTokens: 10, outputTokens: 400
        )
    }

    private var ticket: GenerationTicket {
        GenerationTicket(jobID: UUID(), prompt: "A fox", settings: GenerationSettings(), startedAt: .now)
    }

    @Test func savesWholeBatch() async throws {
        let context = try makeContext()
        let disk = FakeDisk()
        try await Studio.commit(output(count: 3), for: ticket, in: context,
                                writeFile: disk.write, removeFile: disk.remove)

        let images = try context.fetch(FetchDescriptor<GeneratedImage>())
        #expect(images.count == 3)
        #expect(Set(images.map(\.fileName)) == Set(disk.files.keys))
        #expect(Set(images.map(\.batchID)).count == 1)
        #expect(images.allSatisfy { $0.inputTokens == 3 }) // 10 tokens shared across 3 images
    }

    @Test func failedWriteLeavesNothingBehind() async throws {
        let context = try makeContext()
        let disk = FakeDisk()
        disk.failOnWrite = 3 // the third of four files fails

        await #expect(throws: Boom.self) {
            try await Studio.commit(output(count: 4), for: ticket, in: context,
                                    writeFile: disk.write, removeFile: disk.remove)
        }
        #expect(disk.files.isEmpty)
        #expect(try context.fetch(FetchDescriptor<GeneratedImage>()).isEmpty)
        #expect(!context.hasChanges)
    }

    @Test func failedSaveRollsBackRecordsAndFiles() async throws {
        let context = try makeContext()
        let disk = FakeDisk()

        await #expect(throws: Boom.self) {
            try await Studio.commit(output(count: 2), for: ticket, in: context,
                                    writeFile: disk.write, removeFile: disk.remove,
                                    persist: { _ in throw Boom() })
        }
        #expect(disk.files.isEmpty)
        #expect(try context.fetch(FetchDescriptor<GeneratedImage>()).isEmpty)
    }

    @Test func retryAfterFailedSaveDoesNotDuplicate() async throws {
        let context = try makeContext()
        let disk = FakeDisk()
        let result = output(count: 2)
        let ticket = self.ticket

        await #expect(throws: Boom.self) {
            try await Studio.commit(result, for: ticket, in: context,
                                    writeFile: disk.write, removeFile: disk.remove,
                                    persist: { _ in throw Boom() })
        }
        // Saving the same output again (what Retry does) yields exactly one copy.
        try await Studio.commit(result, for: ticket, in: context, writeFile: disk.write, removeFile: disk.remove)
        #expect(try context.fetch(FetchDescriptor<GeneratedImage>()).count == 2)
        #expect(disk.files.count == 2)
    }

    @Test func removalFailureDuringCleanupStillThrowsOriginalError() async throws {
        let context = try makeContext()
        let disk = FakeDisk()
        await #expect(throws: Boom.self) {
            try await Studio.commit(output(count: 1), for: ticket, in: context,
                                    writeFile: disk.write, removeFile: { _ in throw CocoaError(.fileWriteNoPermission) },
                                    persist: { _ in throw Boom() })
        }
        #expect(try context.fetch(FetchDescriptor<GeneratedImage>()).isEmpty)
    }
}

// MARK: Deleting

@Suite("Library deletion")
@MainActor
struct LibraryDeletionTests {
    private func makeContext() throws -> ModelContext { try makeInMemoryContext() }

    private func insertImages(_ names: [String], into context: ModelContext) throws -> [GeneratedImage] {
        let images = names.map {
            GeneratedImage(prompt: "p", settings: GenerationSettings(), width: 1, height: 1,
                           fileName: $0, fileSize: 1, batchID: UUID(), duration: 1)
        }
        images.forEach(context.insert)
        try context.save()
        return images
    }

    @Test func deletesRecordsThenFiles() throws {
        let context = try makeContext()
        let images = try insertImages(["a.png", "b.png"], into: context)
        var removed: [String] = []

        let problem = Studio.deleteImages(images, in: context, removeFile: { removed.append($0) })
        #expect(problem == nil)
        #expect(removed == ["a.png", "b.png"])
        #expect(try context.fetch(FetchDescriptor<GeneratedImage>()).isEmpty)
    }

    @Test func reportsFileFailuresButStillRemovesRecords() throws {
        let context = try makeContext()
        let images = try insertImages(["a.png", "b.png", "c.png"], into: context)
        var attempted: [String] = []

        let problem = Studio.deleteImages(images, in: context, removeFile: {
            attempted.append($0)
            if $0 == "b.png" { throw CocoaError(.fileWriteNoPermission) }
        })
        #expect(attempted == ["a.png", "b.png", "c.png"]) // carried on past the failure
        #expect(problem?.contains("1 file") == true)
        #expect(try context.fetch(FetchDescriptor<GeneratedImage>()).isEmpty)
    }

    @Test func deleteAllReportsFileFailures() throws {
        let context = try makeContext()
        _ = try insertImages(["a.png"], into: context)

        let problem = Studio.deleteEverything(in: context, removeAllFiles: { throw CocoaError(.fileWriteNoPermission) })
        #expect(problem != nil)
        #expect(try context.fetch(FetchDescriptor<GeneratedImage>()).isEmpty)
        #expect(Studio.deleteEverything(in: context, removeAllFiles: {}) == nil)
    }

    @Test func missingFileCountsAsDeleted() throws {
        #expect(throws: Never.self) { try ImageStore.delete(fileName: "does-not-exist-\(UUID().uuidString).png") }
    }

    @Test func deletesExistingFile() throws {
        let name = "test-\(UUID().uuidString).png"
        let url = ImageStore.url(for: name)
        try Data([1, 2, 3]).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try ImageStore.delete(fileName: name)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
