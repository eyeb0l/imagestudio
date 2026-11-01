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
///
/// Attached reference images are files in `ReferenceStore` owned by the composer: removing one
/// deletes its file, and sending hands the files to `Studio` via `takeReferences()`.
@Observable
final class Composer {
    var prompt = ""
    /// `nil` means "use the defaults".
    var overrides: GenerationSettings?
    /// Attached reference images, in order (file names in `ReferenceStore`).
    private(set) var references: [String] = []
    /// Imports in progress, shown as placeholders.
    private(set) var importingCount = 0
    /// Set when an attachment couldn't be imported; the view shows it and clears it.
    var importFailure: String?

    var remainingReferenceSlots: Int {
        max(ReferenceStore.maxReferences - references.count - importingCount, 0)
    }

    func settings(defaults: GenerationSettings) -> GenerationSettings {
        (overrides ?? defaults).normalized()
    }

    func setSettings(_ settings: GenerationSettings, defaults: GenerationSettings) {
        let settings = settings.normalized()
        overrides = settings == defaults.normalized() ? nil : settings
    }

    /// Loads an existing image's prompt, settings and reference images into the draft.
    func reuse(_ image: GeneratedImage, defaults: GenerationSettings) {
        prompt = image.prompt
        var settings = image.settings
        settings.count = defaults.count
        setSettings(settings, defaults: defaults)

        replaceReferences(withCopiesOf: image.referenceFileNames)
    }

    /// Replaces the attachments with copies of existing references (e.g. from an image or a
    /// failed job), so deleting the original owner can't remove files the draft relies on.
    func replaceReferences(withCopiesOf names: [String]) {
        ReferenceStore.delete(references)
        references = names.compactMap { try? ReferenceStore.duplicate($0) }
        if references.count < names.count {
            importFailure = "Some reference images are no longer available"
        }
    }

    /// Attaches images in order. Each loader returns the image's data (e.g. from Photos).
    func addReferences(_ loaders: [@Sendable () async throws -> Data?]) async {
        await importAll(loaders.map { load in
            {
                guard let data = try await load() else { throw ReferenceStore.ImportError.unreadable }
                return try await ReferenceStore.importImage(data)
            }
        })
    }

    /// Attaches library images as references.
    func addReferences(from images: [GeneratedImage]) async {
        await importAll(images.map(\.fileURL).map { url in
            { try await ReferenceStore.importFile(at: url) }
        })
    }

    private func importAll(_ importers: [() async throws -> String]) async {
        let importers = Array(importers.prefix(remainingReferenceSlots))
        guard !importers.isEmpty else { return }
        importingCount += importers.count
        var failures = 0
        for importer in importers {
            do {
                references.append(try await importer())
            } catch {
                failures += 1
            }
            importingCount -= 1
        }
        if failures > 0 {
            importFailure = failures == 1 ? "An image couldn't be attached" : "\(failures) images couldn't be attached"
        }
    }

    func removeReference(_ name: String) {
        references.removeAll { $0 == name }
        ReferenceStore.delete([name])
    }

    /// Hands the attached files to a new generation, which now owns them.
    func takeReferences() -> [String] {
        defer { references = [] }
        return references
    }
}
