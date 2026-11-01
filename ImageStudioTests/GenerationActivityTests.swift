import Foundation
import Testing
import UserNotifications
@testable import ImageStudio

@Suite("Live Activity content")
struct GenerationActivityTests {
    private typealias State = GenerationActivityAttributes.ContentState

    private func job(_ prompt: String, count: Int = 1, startedAt: Date, attempt: Int = 1,
                     failed: Bool = false) -> Studio.Job {
        var settings = GenerationSettings()
        settings.count = count
        return Studio.Job(prompt: prompt, settings: settings, startedAt: startedAt,
                          state: failed ? .failed("Nope") : .running, attempt: attempt)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func summarisesRunningJobs() throws {
        let tracker = GenerationActivityTracker()
        let jobs = [
            job("first", count: 2, startedAt: t0),
            job("second", count: 1, startedAt: t0.addingTimeInterval(30)),
            job("old failure", count: 4, startedAt: t0.addingTimeInterval(-600), failed: true),
        ]
        let state = try #require(tracker.state(for: jobs))
        #expect(state.running == 2)
        #expect(state.pendingImages == 3)
        // The newest running prompt; the earliest running start (failed jobs don't count).
        #expect(state.prompt == "second")
        #expect(state.startedAt == t0)
        #expect(!state.isRetrying)
        #expect(state.phase == .running)
        #expect(state.title == "Generating 3 images")
        #expect(state.detail == "2 requests")
    }

    @Test func flagsAutomaticRetries() throws {
        let state = try #require(GenerationActivityTracker().state(for: [job("a", startedAt: t0, attempt: 2)]))
        #expect(state.isRetrying)
        #expect(state.title == "Generating 1 image")
        #expect(state.detail == "Retrying after an error")
    }

    @Test func nothingToShowWhenNothingRanOrFinished() {
        let tracker = GenerationActivityTracker()
        #expect(tracker.state(for: []) == nil)
        // Failed tiles left over from before the activity don't count either.
        #expect(tracker.state(for: [job("old", startedAt: t0, failed: true)]) == nil)
    }

    @Test func endsWithSummaryOfResults() throws {
        var tracker = GenerationActivityTracker()
        tracker.recordSaved(2, prompt: "first")
        tracker.recordSaved(1, prompt: "second")
        let done = try #require(tracker.state(for: []))
        #expect(done.phase == .succeeded)
        #expect(done.title == "3 images ready")
        #expect(done.prompt == "second")
        #expect(done.detail == nil)

        tracker.recordFailure(prompt: "third")
        let partial = try #require(tracker.state(for: []))
        #expect(partial.phase == .partiallyFailed)
        #expect(partial.title == "3 images ready, 1 failed")
        #expect(partial.prompt == "third")
    }

    @Test func failureOnlySummary() throws {
        var tracker = GenerationActivityTracker()
        tracker.recordFailure(prompt: "a")
        #expect(try #require(tracker.state(for: [])).title == "Generation failed")
        tracker.recordFailure(prompt: "b")
        let state = try #require(tracker.state(for: []))
        #expect(state.phase == .failed)
        #expect(state.title == "2 generations failed")
    }

    @Test func singleImageWording() throws {
        var tracker = GenerationActivityTracker()
        tracker.recordSaved(1, prompt: "a")
        #expect(try #require(tracker.state(for: [])).title == "Image ready")
    }

    @Test func keepsLongPromptsWithinActivityKitLimits() throws {
        let long = String(repeating: "a", count: 5_000)
        let running = try #require(GenerationActivityTracker().state(for: [job(long, startedAt: t0)]))
        #expect(running.prompt.count == GenerationActivityTracker.maxPromptLength)
        #expect(try JSONEncoder().encode(running).count < 4096)

        var tracker = GenerationActivityTracker()
        tracker.recordSaved(1, prompt: long)
        #expect(try #require(tracker.state(for: [])).prompt.count == GenerationActivityTracker.maxPromptLength)
    }

    @Test func resumesTalliesFromAnEarlierProcess() throws {
        let previous = State(running: 1, pendingImages: 1, savedImages: 2, failed: 1, prompt: "earlier",
                             startedAt: t0, isRetrying: false)
        var tracker = GenerationActivityTracker(resuming: previous)
        tracker.recordSaved(1, prompt: "last")
        let state = try #require(tracker.state(for: []))
        #expect(state.savedImages == 3)
        #expect(state.failed == 1)
        #expect(state.prompt == "last")
    }
}

@Suite("Generation notifications")
struct GenerationNotificationTests {
    @Test func successPointsAtTheFirstImage() {
        let id = UUID()
        let content = GenerationNotifier.savedContent(prompt: "A fox", imageCount: 3, firstImageID: id)
        #expect(content.title == "3 images ready")
        #expect(content.body == "A fox")
        #expect(content.threadIdentifier == GenerationNotifier.threadIdentifier)
        // Tapping it opens that image.
        #expect(GenerationNotifier.imageID(in: content.userInfo) == id)
        #expect(GenerationNotifier.savedContent(prompt: "A fox", imageCount: 1, firstImageID: id).title == "Image ready")
    }

    @Test func failureOpensTheLibrary() {
        let content = GenerationNotifier.failureContent(prompt: "A fox", message: "Rate limited")
        #expect(content.title == "Generation failed")
        #expect(content.subtitle == "A fox")
        #expect(content.body == "Rate limited")
        #expect(GenerationNotifier.imageID(in: content.userInfo) == nil)
    }

    @Test func ignoresMalformedPayloads() {
        #expect(GenerationNotifier.imageID(in: [GenerationNotifier.imageIDKey: "not-a-uuid"]) == nil)
        #expect(GenerationNotifier.imageID(in: [GenerationNotifier.imageIDKey: 42]) == nil)
    }
}
