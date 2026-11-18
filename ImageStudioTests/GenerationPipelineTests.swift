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
        let container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, LibraryDeletion.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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
    let container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, LibraryDeletion.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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
        let saved = try await Studio.commit(output(count: 3), for: ticket, in: context,
                                            writeFile: disk.write, removeFile: disk.remove)

        let images = try context.fetch(FetchDescriptor<GeneratedImage>(sortBy: [SortDescriptor(\.createdAt)]))
        #expect(images.count == 3)
        // Returns the new images in batch order (used for the notification thumbnail).
        #expect(saved.map(\.id) == images.map(\.id))
        #expect(Set(images.map(\.fileName)) == Set(disk.files.keys))
        #expect(Set(images.map(\.batchID)).count == 1)
        #expect(images.allSatisfy { $0.inputTokens == 3 }) // 10 tokens shared across 3 images
    }

    @Test func failedWriteLeavesNothingBehind() async throws {
        let context = try makeContext()
        let disk = FakeDisk()
        disk.failOnWrite = 3 // the third of four files fails

        await #expect(throws: Boom.self) {
            _ = try await Studio.commit(output(count: 4), for: ticket, in: context,
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
            _ = try await Studio.commit(output(count: 2), for: ticket, in: context,
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
            _ = try await Studio.commit(result, for: ticket, in: context,
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
            _ = try await Studio.commit(output(count: 1), for: ticket, in: context,
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

@Suite("Failure log")
struct GenerationFailureLogTests {
    private let url = URL(string: "https://api.openai.com/v1/images/generations")!
    private let started = Date(timeIntervalSince1970: 1_000)

    private func ticket(attempt: Int = 2, attemptStartedAt: Date? = nil) -> GenerationTicket {
        var ticket = GenerationTicket(jobID: UUID(), prompt: "A logo", settings: GenerationSettings(), startedAt: started, attempt: attempt)
        ticket.attemptStartedAt = attemptStartedAt
        return ticket
    }

    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test func recordsAGatewayFailure() {
        let page = Data("<html>\r\n  <head><title>502 Bad Gateway</title></head>\r\n</html>".utf8)
        let log = GenerationAttemptLog(ticket: ticket(attemptStartedAt: started.addingTimeInterval(100)),
                                       response: response(502, ["Server": "cloudflare", "CF-Ray": "abc-LHR", "Content-Type": "text/html"]),
                                       data: page, finishedAt: started.addingTimeInterval(190))
        #expect(log.attempt == 2)
        #expect(log.duration == 90)
        #expect(log.status == 502)
        #expect(log.requestID == nil)
        #expect(log.server == "cloudflare")
        #expect(log.rayID == "abc-LHR")
        #expect(log.contentType == "text/html")
        #expect(log.responseExcerpt == "502 Bad Gateway")
    }

    @Test func aPageTitleIsFoundPastItsBoilerplateAndAKeptRetryAfterIsRecorded() {
        let page = "<!DOCTYPE html>\n<!--[if lt IE 7]> <html class=\"ie6\"> <![endif]-->\n" + String(repeating: " ", count: 1000)
            + "<head>\n<TITLE>\n  api.openai.com | 502: Bad gateway\n</TITLE><meta charset=\"UTF-8\" /></head>"
        let log = GenerationAttemptLog(ticket: ticket(), response: response(502, ["Retry-After": "120"]), data: Data(page.utf8))
        #expect(log.responseExcerpt == "api.openai.com | 502: Bad gateway")
        #expect(log.retryAfter == "120")
        #expect(GenerationFailureReport.attemptRows(log).contains { $0.0 == "Retry-After" && $0.1 == "120" })
    }

    @Test func aLogSavedBeforeRetryAfterWasRecordedStillDecodes() throws {
        let saved = try JSONEncoder().encode(GenerationAttemptLog(ticket: ticket(), response: response(502), data: Data()))
        var fields = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        fields["retryAfter"] = nil
        let old = try JSONSerialization.data(withJSONObject: fields)
        #expect(try JSONDecoder().decode(GenerationAttemptLog.self, from: old).status == 502)
    }

    @Test func aBadGatewayForAnSVGIsNotRetriedAutomatically() {
        let badGateway = OpenAIError.api(status: 502, message: nil, code: nil)
        #expect(RetryPolicy.retryDelay(after: badGateway, attempt: 1, format: .svg) == nil)
        for format in [OutputFormat.png, .jpeg, .webp, .gif] {
            #expect(RetryPolicy.retryDelay(after: badGateway, attempt: 1, format: format) != nil, "\(format)")
        }
        // Other temporary failures for an SVG still are.
        for status in [429, 500, 503, 504] {
            let error = OpenAIError.api(status: status, message: nil, code: nil)
            #expect(RetryPolicy.retryDelay(after: error, attempt: 1, format: .svg) != nil, "\(status)")
        }
        #expect(RetryPolicy.retryDelay(after: URLError(.timedOut), attempt: 1, format: .svg) != nil)
    }

    @Test func aBadGatewayForAnSVGSuggestsAnotherAuthor() {
        let badGateway = OpenAIError.api(status: 502, message: nil, code: nil)
        var settings = GenerationSettings()
        #expect(Studio.message(for: badGateway, settings: settings) == "OpenAI returned an error (HTTP 502).")
        settings.outputFormat = .svg
        #expect(Studio.message(for: badGateway, settings: settings).contains("another SVG Author"))
    }

    @Test func recordsOpenAIsRequestDetails() {
        let log = GenerationAttemptLog(ticket: ticket(), response: response(500, ["x-request-id": "req_123", "openai-processing-ms": "4100"]),
                                       data: Data(#"{"error":{"message":"Oops"}}"#.utf8))
        #expect(log.requestID == "req_123")
        #expect(log.processingMilliseconds == 4100)
    }

    @Test func recordsAnAttemptWithNoResponse() {
        let log = GenerationAttemptLog(ticket: ticket(), response: nil, data: Data(), finishedAt: started.addingTimeInterval(5))
        #expect(log.status == nil)
        #expect(log.resultLabel == "No response")
        #expect(log.responseExcerpt == nil)
        #expect(log.duration == 5) // falls back to the job's start
    }

    @Test func masksAnythingThatLooksLikeAKey() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-abc123_XYZ. Check it."}}"#.utf8)
        let excerpt = GenerationAttemptLog.excerpt(of: body)
        #expect(excerpt?.contains("sk-proj") == false)
        #expect(excerpt?.contains("abc123") == false)
        #expect(excerpt?.contains("Incorrect API key") == true)
    }

    @Test func limitsTheExcerpt() throws {
        let excerpt = try #require(GenerationAttemptLog.excerpt(of: Data(repeating: 65, count: 5000)))
        #expect(excerpt.count == GenerationAttemptLog.maxExcerptLength)
    }

    @Test func aLogKeepsTheMostRecentAttempts() {
        var log: [GenerationAttemptLog] = []
        for attempt in 1...20 {
            log = GenerationFailureReport.appending(GenerationAttemptLog(ticket: ticket(attempt: attempt), response: nil, data: Data()), to: log)
        }
        #expect(log.count == GenerationFailureReport.maxAttempts)
        #expect(log.last?.attempt == 20)
    }

    @Test func aReportHasWhatSupportNeedsAndNoKey() {
        var settings = GenerationSettings()
        settings.outputFormat = .svg
        var attempt = GenerationAttemptLog(ticket: ticket(), response: response(502, ["x-request-id": "req_9", "Authorization": "Bearer sk-secret"]), data: Data("Bad Gateway".utf8))
        attempt.message = "OpenAI returned an error (HTTP 502)"
        let text = GenerationFailureReport.text(prompt: "Spoke & Chain", settings: settings, referenceCount: 0, hasMarkup: false,
                                                message: "after 3 attempts", attempts: [attempt])
        for expected in ["Attempt 2", "HTTP 502", "req_9", "Bad Gateway", "Spoke & Chain", "svg", "gpt-image-2.6-flare", "gpt-6.1-terra", "after 3 attempts"] {
            #expect(text.contains(expected), "\(expected)")
        }
        #expect(!text.contains("sk-secret"))
    }

    @Test func survivesInARecord() {
        let record = PendingGeneration(id: UUID(), prompt: "p", settings: GenerationSettings(), startedAt: started)
        #expect(record.attemptLog.isEmpty)
        #expect(record.attemptLogData == nil)
        let attempt = GenerationAttemptLog(ticket: ticket(), response: response(502), data: Data("x".utf8))
        record.attemptLog = [attempt]
        #expect(record.attemptLog == [attempt])
    }

    @Test func ticketsWithoutAnAttemptStartDecode() throws {
        var saved = ticket()
        saved.attemptStartedAt = started
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(GenerationTicket.self, from: data).attemptStartedAt == started)
        var dictionary = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dictionary["attemptStartedAt"] = nil
        let old = try JSONSerialization.data(withJSONObject: dictionary)
        #expect(try JSONDecoder().decode(GenerationTicket.self, from: old).attemptStartedAt == nil)
    }
}
