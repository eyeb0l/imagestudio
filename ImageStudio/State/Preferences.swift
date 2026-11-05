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
///
/// Markup belongs to the first reference: it's a drawing on that image and nothing else. Whenever
/// the first reference changes, for any reason, `references` drops the markup and its files.
@Observable
final class Composer {
    /// An annotation layer attached to the draft, and the reference it was drawn on.
    struct AttachedMarkup: Equatable {
        let overlayFileName: String
        let referenceFileName: String
    }

    /// The canvas, open on a reference image.
    struct MarkupRequest: Identifiable, Equatable {
        let id = UUID()
        let referenceFileName: String
        /// The composer doesn't hold this reference yet. It becomes the first one when the canvas
        /// is finished with, and is deleted if the canvas is cancelled, so cancelling changes nothing.
        let isNewAttachment: Bool
        /// The markup being edited, whose drawing the canvas restores.
        let existingOverlayFileName: String?
    }

    var prompt = ""
    /// `nil` means "use the defaults".
    var overrides: GenerationSettings?
    /// Attached reference images, in order (file names in `ReferenceStore`).
    private(set) var references: [String] = [] {
        didSet {
            if let markup, markup.referenceFileName != references.first {
                discardMarkup()
                markupNotice = "Markup removed: the first reference changed"
            }
        }
    }
    /// The annotation layer for the first reference, if any.
    private(set) var markup: AttachedMarkup?
    /// Set while the canvas is open.
    var markupRequest: MarkupRequest?
    /// Set when markup was dropped; the view shows it and clears it.
    var markupNotice: String?
    /// A library image is being imported for the canvas. It isn't attached yet, and won't be if
    /// the canvas is cancelled, so it doesn't count as a reference, only as a slot taken.
    private var isPreparingMarkup = false
    /// Imports in progress, shown as placeholders.
    private(set) var importingCount = 0
    /// Set when an attachment couldn't be imported; the view shows it and clears it.
    var importFailure: String?

    var remainingReferenceSlots: Int {
        let markupSlot = isPreparingMarkup || markupRequest?.isNewAttachment == true ? 1 : 0
        return max(ReferenceStore.maxReferences - references.count - importingCount - markupSlot, 0)
    }

    /// Whether the next generation will use reference images. Includes imports in progress, as
    /// they can't be sent until they finish.
    var hasReferences: Bool {
        !references.isEmpty || importingCount > 0
    }

    var hasMarkup: Bool { markup != nil }

    /// The files in `ReferenceStore` the composer relies on.
    var heldFileNames: [String] {
        references + MarkupStore.fileNames(forOverlay: markup?.overlayFileName)
            + [markupRequest].compactMap { $0?.isNewAttachment == true ? $0?.referenceFileName : nil }
    }

    /// The settings the next generation will use.
    func settings(defaults: GenerationSettings) -> GenerationSettings {
        (overrides ?? defaults).normalized(hasReferences: hasReferences, hasMarkup: hasMarkup)
    }

    /// The user's choices, before attached references and markup rule anything out. A format that
    /// references hold back, or a model that markup holds back (see `settings(defaults:)`), stays
    /// here, and comes back when they're removed.
    func draftSettings(defaults: GenerationSettings) -> GenerationSettings {
        (overrides ?? defaults).normalized()
    }

    func setSettings(_ settings: GenerationSettings, defaults: GenerationSettings) {
        let settings = settings.normalized()
        overrides = settings == defaults.normalized() ? nil : settings
    }

    /// Applies a change made in the controls, which show `settings(defaults:)`. Only what changed
    /// is applied to the draft, so the fallbacks the controls show for a format or model that's
    /// being held back aren't taken for new choices.
    ///
    /// While something is held back the draft is kept as it stands, not normalised for the format
    /// or model held back: the edit is for what's being sent, and may use options they don't have
    /// (a count above one SVG, a quality GPT Image 1.5 lacks). They apply again when released, and
    /// a conflict then resolves as usual: a transparent background chosen in the meantime can't be
    /// a GIF, so it becomes a PNG.
    func applyEdit(_ edited: GenerationSettings, defaults: GenerationSettings) {
        let shown = settings(defaults: defaults)
        var draft = overrides ?? defaults.normalized()
        func apply<Value: Equatable>(_ option: WritableKeyPath<GenerationSettings, Value>) {
            if edited[keyPath: option] != shown[keyPath: option] {
                draft[keyPath: option] = edited[keyPath: option]
            }
        }
        apply(\.model)
        apply(\.size)
        apply(\.quality)
        apply(\.complexity)
        apply(\.background)
        apply(\.outputFormat)
        apply(\.compression)
        apply(\.moderation)
        apply(\.count)
        apply(\.frameCount)
        apply(\.frameDurationMs)

        let holdsBack = hasReferences || hasMarkup
        let matchesDefaults = draft.normalized() == defaults.normalized()
            && draft.normalized(hasReferences: hasReferences, hasMarkup: hasMarkup)
                == defaults.normalized(hasReferences: hasReferences, hasMarkup: hasMarkup)
        overrides = matchesDefaults ? nil : (holdsBack ? draft : draft.normalized())
    }

    /// Loads an existing image's prompt, settings, reference images and markup into the draft.
    func reuse(_ image: GeneratedImage, defaults: GenerationSettings) {
        prompt = image.prompt
        var settings = image.settings
        settings.count = defaults.count
        setSettings(settings, defaults: defaults)

        replaceReferences(withCopiesOf: image.referenceFileNames, markup: image.markupFileName)
    }

    /// Replaces the attachments with copies of existing references and markup (e.g. from an image
    /// or a failed job), so deleting the original owner can't remove files the draft relies on.
    func replaceReferences(withCopiesOf names: [String], markup source: String? = nil) {
        discardMarkup()
        ReferenceStore.delete(references)
        let firstCopy = names.first.flatMap { try? ReferenceStore.duplicate($0) }
        references = [firstCopy].compactMap(\.self) + names.dropFirst().compactMap { try? ReferenceStore.duplicate($0) }
        if references.count < names.count {
            importFailure = "Some reference images are no longer available"
        }
        guard let source else { return }
        // Without its own first reference the markup would land on whichever image moved up.
        if let firstCopy, let overlay = try? MarkupStore.duplicate(source) {
            markup = AttachedMarkup(overlayFileName: overlay, referenceFileName: firstCopy)
        } else {
            markupNotice = "The markup for this image is no longer available"
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

    /// Attaches library images as references, leaving out formats that can't be one.
    func addReferences(from images: [GeneratedImage]) async {
        await importAll(images.filter(\.format.canBeReference).map(\.fileURL).map { url in
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
    func takeReferences() -> (references: [String], markup: String?) {
        let taken = (references, markup?.overlayFileName)
        // First, so the change to `references` doesn't take the markup's files with it.
        markup = nil
        references = []
        return taken
    }

    // MARK: Markup

    /// Opens the canvas on the first reference, with its markup if it has any.
    func beginMarkup() {
        guard let first = references.first, markupRequest == nil else { return }
        markupRequest = MarkupRequest(referenceFileName: first, isNewAttachment: false,
                                      existingOverlayFileName: markup?.overlayFileName)
    }

    /// Imports a library image and opens the canvas on it. It's only attached, as the first
    /// reference, when the canvas is finished with. Other references stay, behind it.
    func beginMarkup(from image: GeneratedImage) async {
        guard image.format.canBeReference, markupRequest == nil, !isPreparingMarkup else { return }
        guard remainingReferenceSlots > 0 else {
            importFailure = "Up to \(ReferenceStore.maxReferences) reference images"
            return
        }
        isPreparingMarkup = true
        defer { isPreparingMarkup = false }
        do {
            let name = try await ReferenceStore.importFile(at: image.fileURL)
            markupRequest = MarkupRequest(referenceFileName: name, isNewAttachment: true, existingOverlayFileName: nil)
        } catch {
            importFailure = "An image couldn't be attached"
        }
    }

    /// Closes the canvas with its result: the markup's overlay, or `nil` for no markup.
    func finishMarkup(_ request: MarkupRequest, overlay: String?) {
        markupRequest = nil
        if request.isNewAttachment {
            references.insert(request.referenceFileName, at: 0)
        } else if references.first != request.referenceFileName {
            // Nothing should change the references while the canvas is open, but a drawing must
            // never end up on another image.
            if overlay != request.existingOverlayFileName { MarkupStore.delete(overlay: overlay) }
            markupNotice = "Markup removed: the first reference changed"
            return
        }
        if overlay != markup?.overlayFileName {
            discardMarkup()
        }
        markup = overlay.map { AttachedMarkup(overlayFileName: $0, referenceFileName: request.referenceFileName) }
    }

    /// Closes the canvas, leaving the composer as it was.
    func cancelMarkup(_ request: MarkupRequest) {
        markupRequest = nil
        if request.isNewAttachment {
            ReferenceStore.delete([request.referenceFileName])
        }
    }

    func removeMarkup() {
        discardMarkup()
    }

    private func discardMarkup() {
        MarkupStore.delete(overlay: markup?.overlayFileName)
        markup = nil
    }
}
