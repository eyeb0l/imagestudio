import CloudKit
import Foundation
import SwiftData
import Testing
@testable import ImageStudio

// MARK: - Helpers

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, LibraryDeletion.self,
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
}

private func makeStudio(container: ModelContainer) -> Studio {
    Studio(container: container, apiKeys: APIKeyStore(service: "LibrarySyncTests-\(UUID().uuidString)"),
           removeOrphanedReferences: { _ in })
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "LibrarySyncTests-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// A library image with every optional detail filled in, so a round trip checks them all.
private func fullImage(fileName: String, references: [String] = [], markup: String? = nil) -> GeneratedImage {
    var settings = GenerationSettings()
    settings.model = .flare26
    settings.outputFormat = .gif
    settings.frameCount = 6
    settings.frameDurationMs = 120
    settings.complexity = .high
    let image = GeneratedImage(
        createdAt: Date(timeIntervalSince1970: 1_800_000_000.25), prompt: "A lighthouse in fog", revisedPrompt: "A tall lighthouse",
        settings: settings, width: 1024, height: 1536, resolvedQuality: "high", resolvedBackground: "opaque",
        fileName: fileName, fileSize: 4321, batchID: UUID(), duration: 12.5, inputTokens: 10, outputTokens: 20,
        svgInputTokens: 3, svgOutputTokens: 4, referenceFileNames: references, markupFileName: markup)
    image.outputCompression = 80
    return image
}

/// A synced image whose files are in `directory`.
private func syncedImage(id: UUID = UUID(), fileName: String = "Synced-\(UUID().uuidString).png", in directory: URL,
                         references: [String: Data] = [:]) throws -> SyncedImage {
    let file = directory.appending(path: "asset-\(UUID().uuidString)")
    try Data("IMAGE".utf8).write(to: file)
    var storeFiles: [String: URL] = [:]
    for (name, data) in references {
        let url = directory.appending(path: "asset-\(UUID().uuidString)")
        try data.write(to: url)
        storeFiles[name] = url
    }
    return SyncedImage(
        id: id, createdAt: .now, prompt: "From another device", revisedPrompt: nil, modelID: "gpt-image-2",
        requestedSize: "1024x1024", quality: "high", complexity: nil, svgAuthorModel: nil, svgInputTokens: nil,
        svgOutputTokens: nil, background: "auto", outputFormat: "png", outputCompression: nil, moderation: "auto",
        frameCount: nil, frameDurationMs: nil, width: 1024, height: 1024, resolvedQuality: "high",
        resolvedBackground: nil, fileName: fileName, fileSize: 5, batchID: UUID(), duration: 3,
        inputTokens: nil, outputTokens: nil, referenceFileNames: Array(references.keys).sorted(), markupFileName: nil,
        file: file, storeFiles: storeFiles)
}

private final class RecordingObserver: LibraryObserver {
    var added: [[UUID]] = []
    var deleted: [[UUID]] = []
    func imagesAdded(_ ids: [UUID]) { added.append(ids) }
    func imagesDeleted(_ ids: [UUID]) { deleted.append(ids) }
}

// MARK: - Records

@Suite("iCloud records")
struct LibraryRecordTests {
    @Test func roundTripsEveryDetailAndItsFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appending(path: "Images")
        let references = directory.appending(path: "References")
        for folder in [images, references] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("GIF".utf8).write(to: images.appending(path: "ImageStudio-1.gif"))
        try Data("REF".utf8).write(to: references.appending(path: "ref-1.jpg"))
        try Data("OVERLAY".utf8).write(to: references.appending(path: "m.markup.png"))
        // "ref-2.jpg" and the markup's drawing are missing on this device.

        let image = fullImage(fileName: "ImageStudio-1.gif", references: ["ref-1.jpg", "ref-2.jpg"], markup: "m.markup.png")
        let record = try #require(LibraryRecord.record(for: image, imageDirectory: images, referenceDirectory: references))
        #expect(record.recordID.zoneID == LibraryRecord.zoneID)
        #expect(record.recordID.recordName == image.id.uuidString)
        #expect(record["prompt"] == nil, "Prompts are only stored encrypted.")

        let synced = try #require(LibraryRecord.decode(record))
        #expect(synced.id == image.id)
        #expect(synced.createdAt == image.createdAt)
        #expect(synced.prompt == image.prompt)
        #expect(synced.revisedPrompt == image.revisedPrompt)
        #expect(synced.modelID == image.modelID)
        #expect(synced.requestedSize == image.requestedSize)
        #expect(synced.quality == image.quality)
        #expect(synced.complexity == image.complexity)
        #expect(synced.svgAuthorModel == image.svgAuthorModel)
        #expect(synced.svgInputTokens == 3)
        #expect(synced.svgOutputTokens == 4)
        #expect(synced.background == image.background)
        #expect(synced.outputFormat == "gif")
        #expect(synced.outputCompression == 80)
        #expect(synced.moderation == image.moderation)
        #expect(synced.frameCount == 6)
        #expect(synced.frameDurationMs == 120)
        #expect(synced.width == 1024 && synced.height == 1536)
        #expect(synced.resolvedQuality == "high")
        #expect(synced.resolvedBackground == "opaque")
        #expect(synced.fileName == "ImageStudio-1.gif")
        #expect(synced.fileSize == 4321)
        #expect(synced.batchID == image.batchID)
        #expect(synced.duration == 12.5)
        #expect(synced.inputTokens == 10 && synced.outputTokens == 20)
        #expect(synced.referenceFileNames == ["ref-1.jpg", "ref-2.jpg"])
        #expect(synced.markupFileName == "m.markup.png")
        #expect(Set(synced.storeFiles.keys) == ["ref-1.jpg", "m.markup.png"])
        #expect(try Data(contentsOf: synced.file) == Data("GIF".utf8))

        // The library record made from it keeps the settings exactly as they were requested.
        let restored = GeneratedImage(synced: synced)
        #expect(restored.id == image.id)
        #expect(restored.settings == image.settings)
        #expect(restored.complexity == image.complexity && restored.frameCount == image.frameCount)
        #expect(restored.outputCompression == 80)
        #expect(restored.svgAuthorModel == image.svgAuthorModel)
    }

    @Test func leavesOutImagesWhoseFileIsMissing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(LibraryRecord.record(for: fullImage(fileName: "gone.png"), imageDirectory: directory,
                                     referenceDirectory: directory) == nil)
    }

    @Test func rejectsFileNamesThatLeaveTheirFolder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("PNG".utf8).write(to: directory.appending(path: "ok.png"))
        let base = try #require(LibraryRecord.record(for: fullImage(fileName: "ok.png"), imageDirectory: directory,
                                                     referenceDirectory: directory))
        #expect(LibraryRecord.decode(base) != nil)

        for name in ["../escape.png", "a/b.png", ".hidden", "", "x:y.png"] {
            let record = try #require(base.copy() as? CKRecord)
            record["fileName"] = name
            #expect(LibraryRecord.decode(record) == nil, "\(name)")

            let withReference = try #require(base.copy() as? CKRecord)
            withReference["referenceFileNames"] = [name]
            #expect(LibraryRecord.decode(withReference) == nil, "\(name)")
        }
    }

    @Test func ignoresFilesTheImageDoesNotUse() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("PNG".utf8).write(to: directory.appending(path: "ok.png"))
        try Data("REF".utf8).write(to: directory.appending(path: "ref.jpg"))
        let record = try #require(LibraryRecord.record(for: fullImage(fileName: "ok.png", references: ["ref.jpg"]),
                                                       imageDirectory: directory, referenceDirectory: directory))
        record["storeFileNames"] = ["ref.jpg", "unrelated.jpg"]
        let asset = CKAsset(fileURL: directory.appending(path: "ref.jpg"))
        record["storeFiles"] = [asset, asset]

        let synced = try #require(LibraryRecord.decode(record))
        #expect(Set(synced.storeFiles.keys) == ["ref.jpg"])
    }

    @Test func rejectsOtherZonesAndTypes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("PNG".utf8).write(to: directory.appending(path: "ok.png"))
        let image = fullImage(fileName: "ok.png")
        let base = try #require(LibraryRecord.record(for: image, imageDirectory: directory, referenceDirectory: directory))

        let otherType = CKRecord(recordType: "Other", recordID: base.recordID)
        for key in base.allKeys() { otherType[key] = base[key] }
        #expect(LibraryRecord.decode(otherType) == nil)

        let otherZone = CKRecordZone.ID(zoneName: "Elsewhere", ownerName: CKCurrentUserDefaultName)
        #expect(LibraryRecord.imageID(of: CKRecord.ID(recordName: image.id.uuidString, zoneID: otherZone)) == nil)
        #expect(LibraryRecord.imageID(of: LibraryRecord.recordID(for: image.id)) == image.id)
    }
}

// MARK: - Applying changes

@Suite("Applying iCloud changes", .serialized)
@MainActor
struct LibrarySyncApplyTests {
    @Test func addsImagesWithTheirFilesOnce() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let observer = RecordingObserver()
        studio.libraryObserver = observer
        let directory = try temporaryDirectory()
        let referenceName = "\(UUID().uuidString).jpg"
        let image = try syncedImage(in: directory, references: [referenceName: Data("REF".utf8)])
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? ImageStore.delete(fileName: image.fileName)
            ReferenceStore.delete([referenceName])
        }

        let first = studio.addSyncedImages([image])
        #expect(first.present == [image.id] && first.failed.isEmpty && first.incomplete.isEmpty)
        #expect(try Data(contentsOf: ImageStore.url(for: image.fileName)) == Data("IMAGE".utf8))
        #expect(try Data(contentsOf: ReferenceStore.url(for: referenceName)) == Data("REF".utf8))
        let saved = try #require(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()).first)
        #expect(saved.referenceFileNames == [referenceName])
        #expect(observer.added.isEmpty, "Images from iCloud aren't sent back to it.")

        // Delivered again (e.g. after a refetch): nothing changes.
        let second = studio.addSyncedImages([image])
        #expect(second.present == [image.id])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<GeneratedImage>()) == 1)
    }

    @Test func keepsAFileAlreadyOnThisDevice() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let directory = try temporaryDirectory()
        let image = try syncedImage(in: directory)
        try Data("LOCAL".utf8).write(to: ImageStore.url(for: image.fileName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? ImageStore.delete(fileName: image.fileName)
        }

        #expect(studio.addSyncedImages([image]).present == [image.id])
        #expect(try Data(contentsOf: ImageStore.url(for: image.fileName)) == Data("LOCAL".utf8))
    }

    @Test func reportsImagesWhoseFileCouldNotBeCopied() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try syncedImage(in: directory)

        struct DiskFull: Error {}
        let result = studio.addSyncedImages([image]) { _, _ in throw DiskFull() }

        #expect(result.present.isEmpty && result.failed == [image.id])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<GeneratedImage>()) == 0)
    }

    @Test func givesAnImageItsOwnFileWhenItsNameIsTaken() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let directory = try temporaryDirectory()
        let sharedName = "ImageStudio-20261117-120000-ABCDEF.png"
        let first = try syncedImage(fileName: sharedName, in: directory)
        var second = try syncedImage(fileName: sharedName, in: directory)
        try Data("OTHER IMAGE".utf8).write(to: second.file)
        second.fileSize = 11
        let secondName = Studio.uniqueFileName(for: second)
        defer {
            try? FileManager.default.removeItem(at: directory)
            for name in [sharedName, secondName] { try? ImageStore.delete(fileName: name) }
        }

        _ = studio.addSyncedImages([first])
        #expect(studio.addSyncedImages([second]).present == [second.id])

        let records = try container.mainContext.fetch(FetchDescriptor<GeneratedImage>())
        let stored = try #require(records.first { $0.id == second.id })
        #expect(stored.fileName == secondName)
        #expect(try Data(contentsOf: ImageStore.url(for: secondName)) == Data("OTHER IMAGE".utf8))

        // Deleting one never takes the other's file with it.
        studio.removeSyncedImages(ids: [first.id])
        #expect(try Data(contentsOf: ImageStore.url(for: secondName)) == Data("OTHER IMAGE".utf8))
    }

    @Test(arguments: ["SOMETHING ELSE ENTIRELY", "OTHER"])  // A different size, and the same size.
    func doesNotReuseADifferentLeftOverFile(leftOver: String) throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let directory = try temporaryDirectory()
        let image = try syncedImage(in: directory)
        try Data(leftOver.utf8).write(to: ImageStore.url(for: image.fileName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            for name in [image.fileName, Studio.uniqueFileName(for: image)] { try? ImageStore.delete(fileName: name) }
        }

        _ = studio.addSyncedImages([image])

        let stored = try #require(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()).first)
        #expect(stored.fileName == Studio.uniqueFileName(for: image))
        #expect(try Data(contentsOf: ImageStore.url(for: stored.fileName)) == Data("IMAGE".utf8))
    }

    @Test func deliversAgainUntilEveryReferenceIsInPlace() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let directory = try temporaryDirectory()
        let referenceName = "\(UUID().uuidString).jpg"
        let image = try syncedImage(in: directory, references: [referenceName: Data("REF".utf8)])
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? ImageStore.delete(fileName: image.fileName)
            ReferenceStore.delete([referenceName])
        }

        struct Interrupted: Error {}
        let first = studio.addSyncedImages([image]) { source, destination in
            if destination.lastPathComponent == referenceName { throw Interrupted() }
            return try Studio.copyIfMissing(from: source, to: destination)
        }
        #expect(first.incomplete == [image.id] && first.failed.isEmpty, "Added, but to be delivered again for its reference.")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<GeneratedImage>()) == 1)
        #expect(!ReferenceStore.fileExists(referenceName))

        let second = studio.addSyncedImages([image])
        #expect(second.present == [image.id])
        #expect(ReferenceStore.fileExists(referenceName))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<GeneratedImage>()) == 1)
    }

    @Test func removesImagesDeletedElsewhereWithoutEchoing() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let observer = RecordingObserver()
        studio.libraryObserver = observer
        let directory = try temporaryDirectory()
        let image = try syncedImage(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = studio.addSyncedImages([image])

        #expect(studio.removeSyncedImages(ids: [image.id, UUID()]).isEmpty, "Nothing left behind.")

        #expect(try container.mainContext.fetchCount(FetchDescriptor<GeneratedImage>()) == 0)
        #expect(!exists(ImageStore.url(for: image.fileName)))
        #expect(observer.deleted.isEmpty)
    }

    @Test func announcesLocalDeletions() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let observer = RecordingObserver()
        studio.libraryObserver = observer
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try (0..<3).map { _ in try syncedImage(in: directory) }
        _ = studio.addSyncedImages(images)
        let records = try container.mainContext.fetch(FetchDescriptor<GeneratedImage>())

        let first = try #require(records.first { $0.id == images[0].id })
        studio.delete([first])
        #expect(observer.deleted == [[images[0].id]])

        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        studio.deleteAll { try ImageStore.deleteAll(in: folder) }
        #expect(observer.deleted.count == 2)
        #expect(Set(observer.deleted[1]) == Set([images[1].id, images[2].id]))
        for image in images { try? ImageStore.delete(fileName: image.fileName) }
    }
}

// MARK: - Library store

@Suite("Library store with iCloud entitlements")
struct LibraryStoreCloudKitTests {
    /// The app has an iCloud container, so SwiftData would mirror the store to CloudKit unless told
    /// not to, and this schema can't be mirrored: the library would fail to open at every launch.
    @Test func opensWithoutCloudKitMirroring() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try LibraryStore.open(at: directory.appending(path: "default.store"))
        #expect(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
    }

    @Test func identifiesEachStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first.store")
        let second = directory.appending(path: "second.store")
        _ = try LibraryStore.open(at: first)
        _ = try LibraryStore.open(at: second)

        let id = try #require(LibraryStore.storeID(at: first))
        _ = try LibraryStore.open(at: first)
        #expect(LibraryStore.storeID(at: first) == id, "Reopening a library keeps its ID.")
        #expect(LibraryStore.storeID(at: second) != id, "A new library gets a new one.")
        #expect(LibraryStore.storeID(at: directory.appending(path: "missing.store")) == nil)
    }

    @Test func keepsTheExistingStoreLocation() {
        #expect(LibraryStore.defaultStoreURL == URL.applicationSupportDirectory.appending(path: "default.store"))
    }
}

// MARK: - Sync state

@Suite("iCloud sync state", .serialized)
@MainActor
struct LibrarySyncStateTests {
    @Test func persistsWhatItKnows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Library Sync.json")
        var state = LibrarySyncState()
        state.zoneCreated = true
        state.uploaded = ["a", "b"]
        state.pendingDeletions = ["c"]
        state.failedDownloads = ["d"]
        state.remoteDeletions = ["e"]
        state.accountID = "_user"
        try state.save(to: url)

        let loaded = LibrarySyncState.load(from: url)
        #expect(loaded.zoneCreated && loaded.accountID == "_user")
        #expect(loaded.uploaded == ["a", "b"] && loaded.pendingDeletions == ["c"] && loaded.failedDownloads == ["d"])
        #expect(loaded.remoteDeletions == ["e"])

        try Data("not json".utf8).write(to: url)
        let damaged = LibrarySyncState.load(from: url)
        #expect(!damaged.zoneCreated && damaged.uploaded.isEmpty, "Damaged state starts over rather than failing.")
    }

    @Test func readsStateMissingNewerKeys() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Library Sync.json")
        try Data(#"{"accountID":"_user","zoneCreated":true,"uploaded":["a"],"pendingDeletions":["b"]}"#.utf8).write(to: url)

        let loaded = LibrarySyncState.load(from: url)
        #expect(loaded.accountID == "_user" && loaded.zoneCreated)
        #expect(loaded.uploaded == ["a"] && loaded.pendingDeletions == ["b"])
        #expect(loaded.incompleteDownloads.isEmpty && loaded.failedDownloads.isEmpty && loaded.remoteDeletions.isEmpty)
    }

    @Test func ignoresStateBelongingToAnotherLibrary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Library Sync.json")
        var state = LibrarySyncState()
        state.libraryID = "old-library"
        state.accountID = "_previous"
        state.uploaded = ["a"]
        state.pendingDeletions = ["b"]
        try state.save(to: url)

        // e.g. a reset that stopped before the old state was moved away with the old library.
        let other = LibrarySyncState.load(from: url, libraryID: "new-library")
        #expect(other.libraryID == "new-library")
        #expect(other.accountID == nil && other.uploaded.isEmpty && other.pendingDeletions.isEmpty)

        let same = LibrarySyncState.load(from: url, libraryID: "old-library")
        #expect(same.accountID == "_previous" && same.uploaded == ["a"] && same.pendingDeletions == ["b"])

        // State saved before libraries had IDs is adopted by the library it's used with.
        state.libraryID = nil
        try state.save(to: url)
        let adopted = LibrarySyncState.load(from: url, libraryID: "new-library")
        #expect(adopted.libraryID == "new-library" && adopted.uploaded == ["a"])
    }

    @Test func syncStartsFreshWithAnotherLibrarysState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Library Sync.json")
        var state = LibrarySyncState()
        state.libraryID = "old-library"
        state.uploaded = [UUID().uuidString]
        try state.save(to: url)
        let defaults = try #require(UserDefaults(suiteName: "LibrarySyncTests-\(UUID().uuidString)"))

        let container = try makeContainer()
        let sync = LibrarySync(studio: makeStudio(container: container), container: container, defaults: defaults,
                               stateURL: url, libraryID: "new-library", usesCloudKit: false)

        #expect(sync.persistedState.uploaded.isEmpty)
        #expect(LibrarySyncState.load(from: url).libraryID == "new-library", "Saved straight away.")
    }

    @Test func findsImagesNotYetUploaded() {
        let (a, b) = (UUID(), UUID())
        var state = LibrarySyncState()
        state.uploaded = [a.uuidString]
        #expect(state.toUpload([a, b]) == [b])
    }

    @Test func remembersEveryDeletionUntilICloudConfirmsIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Library Sync.json")
        let uploaded = try syncedImage(in: directory)
        let inFlight = try syncedImage(in: directory)
        defer { for image in [uploaded, inFlight] { try? ImageStore.delete(fileName: image.fileName) } }
        var state = LibrarySyncState()
        state.uploaded = [uploaded.id.uuidString]
        // A download being retried for it mustn't bring it back.
        state.failedDownloads = [inFlight.id.uuidString]
        try state.save(to: url)
        let defaults = try #require(UserDefaults(suiteName: "LibrarySyncTests-\(UUID().uuidString)"))
        defaults.set(false, forKey: LibrarySync.enabledKey)

        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let sync = LibrarySync(studio: studio, container: container, defaults: defaults,
                               stateURL: url, unsentDeletionsURL: directory.appending(path: "Unsent.json"), usesCloudKit: false)
        #expect(!sync.isEnabled && sync.status == .off)
        _ = studio.addSyncedImages([uploaded, inFlight])

        // `inFlight` may have reached iCloud without this device hearing back, so it's kept too.
        studio.delete(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()))

        #expect(LibrarySyncState.load(from: url).failedDownloads.isEmpty)
        let known = try #require(sync.knownDeletions)
        #expect(known.pendingDeletions == [uploaded.id.uuidString, inFlight.id.uuidString])
        #expect(known.toUpload([uploaded.id, inFlight.id]).isEmpty)
    }

    @Test func infersDeletionsThatWereNeverRecorded() {
        let (kept, deleted, downloading, removing, incomplete) = (UUID(), UUID(), UUID(), UUID(), UUID())
        var state = LibrarySyncState()
        state.uploaded = Set([kept, deleted, removing, incomplete].map(\.uuidString))
        state.failedDownloads = [downloading.uuidString]
        state.remoteDeletions = [removing.uuidString]
        // Added without its reference, then deleted: still a deletion, not a download to retry.
        state.incompleteDownloads = [incomplete.uuidString]

        // Only `kept` is in the library: the others went without their deletion reaching the state file.
        #expect(state.deletedLocally(library: [kept]) == [deleted.uuidString, incomplete.uuidString])
    }

    @Test func aNewAccountStillRemovesWhatWasDeletedInICloud() {
        var state = LibrarySyncState()
        state.remoteDeletions = ["gone-in-icloud"]
        state.forgetServer()
        #expect(state.remoteDeletions == ["gone-in-icloud"])
    }

    @Test func neverUploadsOrAcceptsImagesOnTheirWayOut() {
        let (local, deletedHere, deletedThere, inICloud) = (UUID(), UUID(), UUID(), UUID())
        var state = LibrarySyncState()
        state.uploaded = [inICloud.uuidString]
        state.pendingDeletions = [deletedHere.uuidString]
        state.remoteDeletions = [deletedThere.uuidString]

        #expect(state.toUpload([local, deletedHere, deletedThere, inICloud]) == [local])
        #expect(state.accepts(local) && state.accepts(inICloud))
        #expect(!state.accepts(deletedHere) && !state.accepts(deletedThere))

        state.accountID = "_abc"
        state.forgetServer()
        #expect(state.accountID == nil && state.uploaded.isEmpty && state.pendingDeletions.isEmpty)
    }

    @Test func isOnByDefaultAndRemembersTheChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "LibrarySyncTests-\(UUID().uuidString)"))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let sync = LibrarySync(studio: makeStudio(container: container), container: container, defaults: defaults,
                               stateURL: directory.appending(path: "s.json"), usesCloudKit: false)
        #expect(sync.isEnabled)

        sync.isEnabled = false
        #expect(sync.status == .off)
        #expect(defaults.bool(forKey: LibrarySync.enabledKey) == false)
    }

    @Test func resettingTheLibraryForgetsSyncState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "default.store")
        try Data("corrupt".utf8).write(to: store)
        let syncState = directory.appending(path: "Library Sync.json")
        var old = LibrarySyncState()
        old.uploaded = ["from-the-old-library"]
        try old.save(to: syncState)

        let backups = directory.appending(path: "Library Backups")
        let model = AppModel(simulatesFailure: true, storeURL: store, backupsDirectory: backups, syncStateURL: syncState) {
            try makeContainer()
        }
        model.resetLibrary()

        // A fresh library downloads everything in iCloud again. With the old state it would take
        // every image as deleted here, and delete it from iCloud.
        #expect(LibrarySyncState.load(from: syncState).uploaded.isEmpty)
        let backup = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        #expect(exists(backup.appending(path: "default.store")))
        #expect(LibrarySyncState.load(from: backup.appending(path: "Library Sync.json")).uploaded == ["from-the-old-library"])
    }

    @Test func movesSyncStateEvenWithoutAStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncState = directory.appending(path: "Library Sync.json")
        try LibrarySyncState().save(to: syncState)

        let backup = try LibraryStore.moveStoreFiles(from: directory.appending(path: "default.store"),
                                                     to: directory.appending(path: "Library Backups"),
                                                     companions: [syncState])
        #expect(!exists(syncState))
        #expect(exists(try #require(backup).appending(path: "Library Sync.json")))
    }
}

// MARK: - Deletion journal

/// Made by `main` (before deletions were kept in the store), with its own code: a library holding
/// `remote` and `kept`, and a failed job. Its sync state records `pending` as deleted here and not
/// yet confirmed by iCloud, and `remote` as deleted in iCloud but not removed here yet.
private enum MainFixture {
    static let pending = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    static let remote = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
    static let kept = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!
    static let job = UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000004")!
    static let libraryID = "69E99357-12F8-4289-B7E4-944E63F676AF"

    private final class BundleToken {}

    /// Copies the library, and with `syncState` its sync state, to where the app keeps them.
    static func install(in directory: URL, syncState: Bool) throws -> (store: URL, syncState: URL) {
        let bundle = Bundle(for: BundleToken.self)
        let store = directory.appending(path: "default.store")
        let state = directory.appending(path: "Library Sync.json")
        try FileManager.default.copyItem(at: try #require(bundle.url(forResource: "MainLibrary", withExtension: "store")), to: store)
        if syncState {
            try FileManager.default.copyItem(at: try #require(bundle.url(forResource: "MainLibrary Sync", withExtension: "json")), to: state)
        }
        return (store, state)
    }
}

@Suite("Deletion journal", .serialized)
@MainActor
struct DeletionJournalTests {
    private struct Stopped: Error {}

    private func offDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "LibrarySyncTests-\(UUID().uuidString)"))
        defaults.set(false, forKey: LibrarySync.enabledKey)
        return defaults
    }

    @Test func aLibraryFromMainOpensAndMigrates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = try MainFixture.install(in: directory, syncState: false)

        do {
            let container = try LibraryStore.open(at: store)
            #expect(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
            let images = try container.mainContext.fetch(FetchDescriptor<GeneratedImage>(sortBy: [SortDescriptor(\.createdAt)]))
            #expect(images.map(\.id) == [MainFixture.remote, MainFixture.kept])
            #expect(images.map(\.prompt) == ["Main fixture 1", "Main fixture 2"])
            #expect(images.last?.referenceFileNames == ["ref.jpg"])
            let job = try #require(try container.mainContext.fetch(FetchDescriptor<PendingGeneration>()).first)
            #expect(job.id == MainFixture.job && job.failureMessage == "Failed")
            #expect(try container.mainContext.fetchCount(FetchDescriptor<LibraryDeletion>()) == 0)
            #expect(LibraryStore.storeID(at: store) == MainFixture.libraryID, "Still the same library.")

            // The migrated library records deletions.
            let kept = try #require(images.last)
            makeStudio(container: container).delete([kept])
        }

        let reopened = try LibraryStore.open(at: store)
        #expect(try LibraryDeletion.all(in: reopened.mainContext).pending == [MainFixture.kept.uuidString])
        let remaining = try reopened.mainContext.fetch(FetchDescriptor<GeneratedImage>())
        #expect(remaining.map(\.id) == [MainFixture.remote])
        // What a reset reads from a library that won't open, including a deletion still only in the
        // write-ahead log of a store that's open.
        makeStudio(container: reopened).delete(remaining)
        let wal = try FileManager.default.attributesOfItem(atPath: store.path(percentEncoded: false) + "-wal")[.size] as? Int
        #expect((wal ?? 0) > 0)
        #expect(LibraryStore.pendingDeletions(inStoreAt: store) == Set([MainFixture.kept, MainFixture.remote].map(\.uuidString)))
        #expect(LibraryStore.pendingDeletions(inStoreAt: directory.appending(path: "missing.store")).isEmpty)
        let damaged = directory.appending(path: "damaged.store")
        try Data("not a database".utf8).write(to: damaged)
        #expect(LibraryStore.pendingDeletions(inStoreAt: damaged).isEmpty)
    }

    @Test func movesTheSyncStatesDeletionsIntoTheStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, syncState) = try MainFixture.install(in: directory, syncState: true)
        let container = try LibraryStore.open(at: store)

        let sync = LibrarySync(studio: makeStudio(container: container), container: container, defaults: try offDefaults(),
                               stateURL: syncState, unsentDeletionsURL: directory.appending(path: "Unsent Deletions.json"),
                               libraryID: LibraryStore.storeID(at: store), usesCloudKit: false)

        let journal = try LibraryDeletion.all(in: container.mainContext)
        #expect(journal.pending == [MainFixture.pending.uuidString])
        #expect(journal.remote == [MainFixture.remote.uuidString])
        let saved = LibrarySyncState.load(from: syncState)
        #expect(saved.pendingDeletions.isEmpty && saved.remoteDeletions.isEmpty, "Moved, not copied.")
        #expect(saved.libraryID == MainFixture.libraryID, "The rest stays.")
        #expect(saved.uploaded == Set([MainFixture.pending, MainFixture.remote, MainFixture.kept].map(\.uuidString)))

        let known = try #require(sync.knownDeletions)
        #expect(!known.accepts(MainFixture.pending) && !known.accepts(MainFixture.remote) && known.accepts(MainFixture.kept))
        #expect(known.toUpload([MainFixture.remote, MainFixture.kept]).isEmpty)
        #expect(known.deletedLocally(library: [MainFixture.remote, MainFixture.kept]) == [MainFixture.pending.uuidString])
    }

    /// The sync state can't be written from just before a retried download succeeds until after the
    /// image is deleted. The state file still says the download is to be retried, and nothing about
    /// the deletion, so with the deletion kept only there the image would come back.
    @Test func aDeletionSurvivesASyncStateThatCantBeWritten() throws {
        let directory = try temporaryDirectory()
        let stateFolder = directory.appending(path: "State", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stateFolder.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        let store = directory.appending(path: "default.store")
        let syncState = stateFolder.appending(path: "Library Sync.json")
        let unsent = directory.appending(path: "Unsent Deletions.json")
        let defaults = try offDefaults()
        let image = try syncedImage(in: directory)
        defer { try? ImageStore.delete(fileName: image.fileName) }

        do {
            let container = try LibraryStore.open(at: store)
            let libraryID = try #require(LibraryStore.storeID(at: store))
            var state = LibrarySyncState()
            state.libraryID = libraryID
            state.failedDownloads = [image.id.uuidString]
            try state.save(to: syncState)
            let studio = makeStudio(container: container)
            let sync = LibrarySync(studio: studio, container: container, defaults: defaults, stateURL: syncState,
                                   unsentDeletionsURL: unsent, libraryID: libraryID, usesCloudKit: false)

            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stateFolder.path(percentEncoded: false))
            #expect(studio.addSyncedImages([image]).present == [image.id], "The retried download succeeds.")
            studio.delete(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()))
            #expect(try container.mainContext.fetchCount(FetchDescriptor<GeneratedImage>()) == 0)
            _ = sync
        }
        let onDisk = LibrarySyncState.load(from: syncState)
        #expect(onDisk.failedDownloads == [image.id.uuidString] && onDisk.pendingDeletions.isEmpty,
                "Nothing reached the sync state.")

        // Next launch.
        let container = try LibraryStore.open(at: store)
        let sync = LibrarySync(studio: makeStudio(container: container), container: container, defaults: defaults,
                               stateURL: syncState, unsentDeletionsURL: unsent, libraryID: LibraryStore.storeID(at: store),
                               usesCloudKit: false)
        let known = try #require(sync.knownDeletions)
        #expect(known.pendingDeletions == [image.id.uuidString], "Still to be deleted from iCloud.")
        #expect(!known.accepts(image.id), "The download retried for it can't bring it back.")
    }

    nonisolated enum ResetEnding: CaseIterable, Sendable {
        case finished
        /// The app stops after the old library is moved away, before the new one is opened.
        case stoppedBeforeOpening
        /// The app stops after the store is moved, before its sync state is.
        case stoppedBetweenMoves
    }

    @Test(arguments: ResetEnding.allCases)
    func pendingDeletionsSurviveAReset(ending: ResetEnding) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "default.store")
        let syncState = directory.appending(path: "Library Sync.json")
        let unsent = directory.appending(path: "Unsent Deletions.json")
        let backups = directory.appending(path: "Library Backups")
        let (deleted, kept) = (try syncedImage(in: directory), try syncedImage(in: directory))
        defer { for image in [deleted, kept] { try? ImageStore.delete(fileName: image.fileName) } }

        let oldID: String
        do {
            let container = try LibraryStore.open(at: store)
            oldID = try #require(LibraryStore.storeID(at: store))
            let studio = makeStudio(container: container)
            let sync = LibrarySync(studio: studio, container: container, defaults: try offDefaults(), stateURL: syncState,
                                   unsentDeletionsURL: unsent, libraryID: oldID, usesCloudKit: false)
            #expect(sync.adoptAccount("_A"))
            _ = studio.addSyncedImages([deleted, kept])
            let record = try #require(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()).first { $0.id == deleted.id })
            studio.delete([record])  // Not sent: syncing is off.
        }

        // The library won't open, so it's reset.
        let open: @MainActor @Sendable () throws -> ModelContainer = { try LibraryStore.open(at: store) }
        let launched: AppModel
        switch ending {
        case .finished:
            launched = AppModel(simulatesFailure: true, storeURL: store, backupsDirectory: backups, syncStateURL: syncState,
                                unsentDeletionsURL: unsent, opener: open)
            launched.resetLibrary()
        case .stoppedBeforeOpening:
            let model = AppModel(simulatesFailure: true, storeURL: store, backupsDirectory: backups, syncStateURL: syncState,
                                 unsentDeletionsURL: unsent) { throw Stopped() }
            model.resetLibrary()
            launched = AppModel(simulatesFailure: false, storeURL: store, backupsDirectory: backups, syncStateURL: syncState,
                                unsentDeletionsURL: unsent, opener: open)
        case .stoppedBetweenMoves:
            // What `resetLibrary` does before the sync state is moved.
            try UnsentDeletions.setAside(from: store, syncStateURL: syncState, to: unsent)
            try LibraryStore.moveStoreFiles(from: store, to: backups)
            launched = AppModel(simulatesFailure: false, storeURL: store, backupsDirectory: backups, syncStateURL: syncState,
                                unsentDeletionsURL: unsent, opener: open)
        }

        guard case .ready(let services) = launched.state else {
            Issue.record("The new library didn't open: \(launched.openFailure ?? "")")
            return
        }
        #expect(LibraryStore.storeID(at: store) != oldID, "A new library.")
        #expect(exists(unsent), "Kept until the library syncs with their account.")

        #expect(services.sync.adoptAccount("_A"))
        #expect(try LibraryDeletion.all(in: services.container.mainContext).pending == [deleted.id.uuidString])
        let known = try #require(services.sync.knownDeletions)
        #expect(!known.accepts(deleted.id), "Its download from iCloud is refused.")
        #expect(known.accepts(kept.id), "Everything else downloads again.")
        #expect(!exists(unsent), "Taken on by the new library.")
    }

    @Test func setAsideDeletionsAreOnlySentToTheirAccount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsent = directory.appending(path: "Unsent Deletions.json")
        let id = UUID().uuidString
        try JSONEncoder().encode(UnsentDeletions(accountID: "_A", ids: [id])).write(to: unsent)
        let container = try makeContainer()
        let sync = LibrarySync(studio: makeStudio(container: container), container: container, defaults: try offDefaults(),
                               stateURL: directory.appending(path: "Library Sync.json"), unsentDeletionsURL: unsent,
                               usesCloudKit: false)

        #expect(sync.adoptAccount("_B"))
        #expect(try #require(sync.knownDeletions).pendingDeletions.isEmpty, "Account A's deletion isn't sent to B.")
        #expect(!exists(unsent))
    }

    @Test func aResetThatCantSetDeletionsAsideChangesNothing() throws {
        let directory = try temporaryDirectory()
        let locked = directory.appending(path: "Locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        let store = directory.appending(path: "default.store")
        let syncState = directory.appending(path: "Library Sync.json")
        let image = try syncedImage(in: directory)
        defer { try? ImageStore.delete(fileName: image.fileName) }
        do {
            let container = try LibraryStore.open(at: store)
            let studio = makeStudio(container: container)
            let sync = LibrarySync(studio: studio, container: container, defaults: try offDefaults(), stateURL: syncState,
                                   unsentDeletionsURL: locked.appending(path: "Unsent Deletions.json"),
                                   libraryID: LibraryStore.storeID(at: store), usesCloudKit: false)
            #expect(sync.adoptAccount("_A"))
            _ = studio.addSyncedImages([image])
            studio.delete(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path(percentEncoded: false))

        let model = AppModel(simulatesFailure: true, storeURL: store, backupsDirectory: directory.appending(path: "Library Backups"),
                             syncStateURL: syncState, unsentDeletionsURL: locked.appending(path: "Unsent Deletions.json")) {
            try LibraryStore.open(at: store)
        }
        model.resetLibrary()

        #expect(model.resetFailure != nil)
        #expect(exists(store) && exists(syncState), "The library stays where it is.")
        #expect(LibraryStore.pendingDeletions(inStoreAt: store) == [image.id.uuidString])
    }

    @Test func switchingAccountsForgetsWhatWasOwedToTheOldOne() throws {
        let directory = try temporaryDirectory()
        let stateFolder = directory.appending(path: "State", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stateFolder.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        let syncState = stateFolder.appending(path: "Library Sync.json")
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let sync = LibrarySync(studio: studio, container: container, defaults: try offDefaults(), stateURL: syncState,
                               unsentDeletionsURL: directory.appending(path: "Unsent Deletions.json"), usesCloudKit: false)
        let image = try syncedImage(in: directory)
        defer { try? ImageStore.delete(fileName: image.fileName) }
        #expect(sync.adoptAccount("_A"))
        _ = studio.addSyncedImages([image])
        studio.delete(try container.mainContext.fetch(FetchDescriptor<GeneratedImage>()))
        #expect(try #require(sync.knownDeletions).pendingDeletions == [image.id.uuidString])

        #expect(sync.adoptAccount("_B"))
        #expect(try #require(sync.knownDeletions).pendingDeletions.isEmpty, "A's deletion isn't sent to B.")
        #expect(LibrarySyncState.load(from: syncState).accountID == "_B")

        // If the new account can't be saved, syncing doesn't go ahead with it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stateFolder.path(percentEncoded: false))
        #expect(!sync.adoptAccount("_C"))
        #expect(sync.persistedState.accountID == "_B" && LibrarySyncState.load(from: syncState).accountID == "_B")
    }

    @Test func recordsDeletionsWithTheLibraryChange() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try (0..<4).map { _ in try syncedImage(in: directory) }
        defer { for image in images { try? ImageStore.delete(fileName: image.fileName) } }
        _ = studio.addSyncedImages(images)
        let context = container.mainContext

        let first = try #require(try context.fetch(FetchDescriptor<GeneratedImage>()).first { $0.id == images[0].id })
        studio.delete([first])
        #expect(try LibraryDeletion.all(in: context).pending == [images[0].id.uuidString])

        // Deleted in iCloud: removed with its recorded deletion, and one already gone here is forgotten.
        try LibraryDeletion.record([images[1].id], as: .remote, in: context)
        try context.save()
        #expect(studio.removeSyncedImages(ids: [images[0].id, images[1].id]).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<LibraryDeletion>()) == 0)

        // Forgetting a deletion alone leaves anything else waiting in the main context alone.
        try LibraryDeletion.record([images[0].id], as: .pending, in: context)
        try context.save()
        context.insert(PendingGeneration(id: UUID(), prompt: "Waiting", settings: GenerationSettings(), startedAt: .now))
        #expect(studio.removeSyncedImages(ids: [images[0].id]).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<LibraryDeletion>()) == 0)
        #expect(context.hasChanges, "The generation's insert is still waiting for the main context's own save.")
        try context.save()

        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        studio.deleteAll { try ImageStore.deleteAll(in: folder) }
        #expect(try LibraryDeletion.all(in: context).pending == Set(images[2...].map(\.id.uuidString)))

        // An image deleted in iCloud stays recorded as that.
        try LibraryDeletion.record([images[2].id], as: .remote, in: context)
        try LibraryDeletion.record([images[2].id], as: .pending, in: context)
        try context.save()
        #expect(try LibraryDeletion.all(in: context).remote == [images[2].id.uuidString])
    }
}
