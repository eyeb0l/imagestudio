import ActivityKit
import Foundation

/// The Live Activity for background generations, shared by the app (which starts and updates it)
/// and the widget extension (which draws it). One activity covers every running generation; when
/// the last one finishes it ends with a summary of what was saved and what failed.
nonisolated struct GenerationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Generations still running.
        var running: Int
        /// Images the running generations will produce.
        var pendingImages: Int
        /// Images saved to the library since the activity started.
        var savedImages: Int
        /// Generations that failed since the activity started.
        var failed: Int
        /// The newest running generation's prompt, or the last finished one's.
        var prompt: String
        /// When the earliest running generation started. Drives the elapsed-time counter.
        var startedAt: Date
        /// Whether a running generation is waiting to retry after a transient failure.
        var isRetrying: Bool
    }
}

nonisolated extension GenerationActivityAttributes.ContentState {
    enum Phase: Equatable {
        case running
        case succeeded
        case partiallyFailed
        case failed
    }

    var phase: Phase {
        if running > 0 { return .running }
        if failed == 0 { return .succeeded }
        return savedImages == 0 ? .failed : .partiallyFailed
    }

    var title: String {
        switch phase {
        case .running:
            "Generating \(Self.images(pendingImages))"
        case .succeeded:
            savedImages == 1 ? "Image ready" : "\(savedImages) images ready"
        case .partiallyFailed:
            "\(Self.images(savedImages)) ready, \(failed) failed"
        case .failed:
            failed == 1 ? "Generation failed" : "\(failed) generations failed"
        }
    }

    /// A short status line under the title, if there's anything to add.
    var detail: String? {
        guard phase == .running else { return nil }
        if isRetrying { return "Retrying after an error" }
        if running > 1 { return "\(running) requests" }
        return nil
    }

    var symbolName: String {
        switch phase {
        case .running: "sparkles"
        case .succeeded: "checkmark.circle.fill"
        case .partiallyFailed, .failed: "exclamationmark.triangle.fill"
        }
    }

    private static func images(_ count: Int) -> String {
        count == 1 ? "1 image" : "\(count) images"
    }
}
