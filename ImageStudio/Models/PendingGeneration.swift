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
    /// Which request attempt is in flight (1-based). The default lets existing stores migrate.
    var attempt: Int = 1
    /// Reference images (in `ReferenceStore`) sent with the request.
    var referenceFileNames: [String] = []
    /// The annotation layer (see `MarkupStore`) sent with the request, if any.
    var markupFileName: String?
    /// Encoded `[GenerationAttemptLog]`: the failed attempts so far. `nil` for none.
    var attemptLogData: Data?

    init(id: UUID, prompt: String, settings: GenerationSettings, startedAt: Date,
         failureMessage: String? = nil, attempt: Int = 1, referenceFileNames: [String] = [],
         markupFileName: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.settingsData = (try? JSONEncoder().encode(settings)) ?? Data()
        self.startedAt = startedAt
        self.failureMessage = failureMessage
        self.attempt = attempt
        self.referenceFileNames = referenceFileNames
        self.markupFileName = markupFileName
    }
}

extension PendingGeneration {
    var attemptLog: [GenerationAttemptLog] {
        get { attemptLogData.flatMap { try? JSONDecoder().decode([GenerationAttemptLog].self, from: $0) } ?? [] }
        set { attemptLogData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var settings: GenerationSettings {
        get { (try? JSONDecoder().decode(GenerationSettings.self, from: settingsData)) ?? GenerationSettings() }
        set { settingsData = (try? JSONEncoder().encode(newValue)) ?? settingsData }
    }
}
