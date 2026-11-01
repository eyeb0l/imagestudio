import Foundation
import SwiftData

/// A generation that hasn't produced library images yet (running or failed).
/// Persisted so placeholder tiles survive the app being closed.
@Model
final class PendingGeneration {
    @Attribute(.unique) var id: UUID
    var prompt: String
    var settingsData: Data
    var startedAt: Date
    /// `nil` while running.
    var failureMessage: String?

    init(id: UUID, prompt: String, settings: GenerationSettings, startedAt: Date, failureMessage: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.settingsData = (try? JSONEncoder().encode(settings)) ?? Data()
        self.startedAt = startedAt
        self.failureMessage = failureMessage
    }
}

extension PendingGeneration {
    var settings: GenerationSettings {
        get { (try? JSONDecoder().decode(GenerationSettings.self, from: settingsData)) ?? GenerationSettings() }
        set { settingsData = (try? JSONEncoder().encode(newValue)) ?? settingsData }
    }
}
