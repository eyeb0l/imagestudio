import Foundation
import UIKit

/// Receives Studio's generation events so they can be shown outside the app.
protocol GenerationObserver: AnyObject {
    func generationStarted()
    func generationSaved(jobID: UUID, prompt: String, images: [GeneratedImage])
    func generationFailed(jobID: UUID, prompt: String, message: String)
    func jobsChanged(_ jobs: [Studio.Job])
    /// Waits until everything triggered so far has been handed to the system.
    func settle() async
}

/// Shows generations in a Live Activity, and posts a notification for each one that finishes
/// while the app isn't in the foreground.
final class GenerationUpdates: GenerationObserver {
    private let activity = GenerationActivityController()
    private let notifier: GenerationNotifier
    /// Notification work in flight, awaited by `settle()`.
    private var announcements: [UUID: Task<Void, Never>] = [:]

    init(notifier: GenerationNotifier = .shared) {
        self.notifier = notifier
    }

    func appBecameActive() {
        activity.appBecameActive()
    }

    func generationStarted() {
        // Not tracked: `settle()` shouldn't wait for the user to answer the permission prompt.
        Task { [notifier] in await notifier.requestAuthorizationIfNeeded() }
    }

    func generationSaved(jobID: UUID, prompt: String, images: [GeneratedImage]) {
        activity.recordSaved(images.count, prompt: prompt)
        let files = images.map { (id: $0.id, fileName: $0.fileName) }
        track { [notifier] in await notifier.announceSaved(jobID: jobID, prompt: prompt, images: files) }
    }

    func generationFailed(jobID: UUID, prompt: String, message: String) {
        activity.recordFailure(prompt: prompt)
        track { [notifier] in await notifier.announceFailure(jobID: jobID, prompt: prompt, message: message) }
    }

    func jobsChanged(_ jobs: [Studio.Job]) {
        activity.jobsChanged(jobs, appIsActive: UIApplication.shared.applicationState == .active)
    }

    func settle() async {
        await activity.settle()
        while let task = announcements.values.first {
            await task.value
        }
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        announcements[id] = Task {
            await work()
            announcements[id] = nil
        }
    }
}
