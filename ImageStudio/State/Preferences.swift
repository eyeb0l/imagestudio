import Foundation
import Observation

/// Default settings for new generations, persisted in UserDefaults.
@Observable
final class Preferences {
    var defaults: GenerationSettings {
        didSet { persist() }
    }

    @ObservationIgnored private let store: UserDefaults
    private static let defaultsKey = "generationDefaults"

    init(store: UserDefaults = .standard) {
        self.store = store
        if let data = store.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(GenerationSettings.self, from: data) {
            defaults = saved.normalized()
        } else {
            defaults = GenerationSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(defaults) else { return }
        store.set(data, forKey: Self.defaultsKey)
    }
}

/// The prompt box draft. Settings are the user's defaults unless overridden for this session.
@Observable
final class Composer {
    var prompt = ""
    /// `nil` means "use the defaults".
    var overrides: GenerationSettings?

    func settings(defaults: GenerationSettings) -> GenerationSettings {
        (overrides ?? defaults).normalized()
    }

    func setSettings(_ settings: GenerationSettings, defaults: GenerationSettings) {
        let settings = settings.normalized()
        overrides = settings == defaults.normalized() ? nil : settings
    }

    /// Loads an existing image's prompt and settings into the draft.
    func reuse(_ image: GeneratedImage, defaults: GenerationSettings) {
        prompt = image.prompt
        var settings = image.settings
        settings.count = defaults.count
        setSettings(settings, defaults: defaults)
    }
}
