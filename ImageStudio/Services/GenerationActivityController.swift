import ActivityKit
import Foundation
import OSLog

/// Builds Live Activity content from Studio's jobs and the results that arrived since the
/// activity started. Free of ActivityKit so it can be tested.
struct GenerationActivityTracker: Equatable {
    private(set) var savedImages = 0
    private(set) var failed = 0
    private var lastPrompt = ""

    init() {}

    /// Picks up the tallies of an activity that outlived the previous app process.
    init(resuming state: GenerationActivityAttributes.ContentState) {
        savedImages = state.savedImages
        failed = state.failed
        lastPrompt = state.prompt
    }

    mutating func recordSaved(_ count: Int, prompt: String) {
        savedImages += count
        lastPrompt = prompt
    }

    mutating func recordFailure(prompt: String) {
        failed += 1
        lastPrompt = prompt
    }

    /// Content for the current jobs, or `nil` when there's nothing to show: nothing is running
    /// and nothing finished (e.g. the only generation was cancelled).
    func state(for jobs: [Studio.Job]) -> GenerationActivityAttributes.ContentState? {
        let running = jobs.filter { !$0.isFailed }
        guard !running.isEmpty || savedImages > 0 || failed > 0 else { return nil }
        return GenerationActivityAttributes.ContentState(
            running: running.count,
            pendingImages: running.reduce(0) { $0 + $1.settings.count },
            savedImages: savedImages,
            failed: failed,
            prompt: running.max { $0.startedAt < $1.startedAt }?.prompt ?? lastPrompt,
            startedAt: running.map(\.startedAt).min() ?? .now,
            isRetrying: running.contains { $0.attempt > 1 }
        )
    }
}

/// Keeps one Live Activity in step with the running generations.
///
/// ActivityKit only lets an app start an activity while it's in the foreground, so the activity
/// starts when a generation does (or when the app comes back with generations still running).
/// Updates and the final summary also work from a background relaunch.
///
/// ActivityKit's `Activity` is thread-safe but not marked `Sendable`, hence the
/// `nonisolated(unsafe)` copies handed to its async methods.
final class GenerationActivityController {
    typealias Activity = ActivityKit.Activity<GenerationActivityAttributes>

    /// How long the finished summary stays on the Lock Screen when the app isn't open. The
    /// notification for the same result stays in Notification Center.
    static let summaryLifetime: TimeInterval = 15 * 60
    /// Requests time out after an hour (`GenerationSession`), so anything older than this without
    /// an update is likely stuck; the activity then says so.
    static let staleAfter: TimeInterval = 70 * 60

    private var activity: Activity?
    private var tracker = GenerationActivityTracker()
    private var jobs: [Studio.Job] = []
    /// Updates are applied in order; `settle()` waits for them.
    private var queue: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.eyeb0l.ImageStudio", category: "LiveActivity")

    init() {
        // Reconnect to an activity left by a previous process (e.g. before a background relaunch)
        // and end any extras.
        let existing = Activity.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        if let first = existing.first {
            activity = first
            tracker = GenerationActivityTracker(resuming: first.content.state)
        }
        for extra in existing.dropFirst() {
            nonisolated(unsafe) let extra = extra
            enqueue { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func recordSaved(_ count: Int, prompt: String) {
        tracker.recordSaved(count, prompt: prompt)
    }

    func recordFailure(prompt: String) {
        tracker.recordFailure(prompt: prompt)
    }

    func jobsChanged(_ jobs: [Studio.Job], appIsActive: Bool) {
        self.jobs = jobs
        sync(appIsActive: appIsActive)
    }

    /// Starts an activity if generations are running but none is showing, e.g. because they
    /// were started while the app couldn't start one, or the user dismissed it.
    func appBecameActive() {
        sync(appIsActive: true)
    }

    /// Waits for queued updates, so a background relaunch doesn't end before they're sent.
    func settle() async {
        while let current = queue {
            await current.value
            if queue == current { break }
        }
    }

    private func sync(appIsActive: Bool) {
        if let current = activity, current.activityState != .active, current.activityState != .stale {
            // Dismissed by the user or ended by the system.
            activity = nil
        }
        let isRunning = jobs.contains { !$0.isFailed }

        guard let current = activity else {
            // A new activity starts with fresh tallies.
            tracker = GenerationActivityTracker()
            guard isRunning, appIsActive, let state = tracker.state(for: jobs) else { return }
            start(state)
            return
        }
        guard let state = tracker.state(for: jobs) else {
            // Nothing ran to completion (e.g. everything was cancelled): just remove it.
            end(current, state: nil, dismissal: .immediate)
            return
        }
        if isRunning {
            let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter))
            nonisolated(unsafe) let current = current
            enqueue { await current.update(content) }
        } else {
            // In the app the result is already on screen, so the summary only matters elsewhere.
            end(current, state: state, dismissal: appIsActive ? .immediate : .after(.now.addingTimeInterval(Self.summaryLifetime)))
        }
    }

    private func start(_ state: GenerationActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: GenerationActivityAttributes(),
                content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
        } catch {
            Self.log.error("Couldn't start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func end(_ current: Activity, state: GenerationActivityAttributes.ContentState?,
                     dismissal: ActivityUIDismissalPolicy) {
        activity = nil
        tracker = GenerationActivityTracker()
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        nonisolated(unsafe) let current = current
        enqueue { await current.end(content, dismissalPolicy: dismissal) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }
}
