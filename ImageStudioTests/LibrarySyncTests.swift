import CloudKit
import Foundation
import SwiftData
import Testing
@testable import ImageStudio

// MARK: - Helpers

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: GeneratedImage.self, PendingGeneration.self,
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
        #expect(first.present == [image.id] && first.failed.isEmpty)
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

    @Test func removesImagesDeletedElsewhereWithoutEchoing() throws {
        let container = try makeContainer()
        let studio = makeStudio(container: container)
        let observer = RecordingObserver()
        studio.libraryObserver = observer
        let directory = try temporaryDirectory()
        let image = try syncedImage(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = studio.addSyncedImages([image])

        studio.removeSyncedImages(ids: [image.id, UUID()])

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
        state.pausedDeletions = ["c"]
        state.failedDownloads = ["d"]
        try state.save(to: url)

        let loaded = LibrarySyncState.load(from: url)
        #expect(loaded.zoneCreated)
        #expect(loaded.uploaded == ["a", "b"] && loaded.pausedDeletions == ["c"] && loaded.failedDownloads == ["d"])

        try Data("not json".utf8).write(to: url)
        let damaged = LibrarySyncState.load(from: url)
        #expect(!damaged.zoneCreated && damaged.uploaded.isEmpty, "Damaged state starts over rather than failing.")
    }

    @Test func findsImagesNotYetUploaded() {
        let (a, b) = (UUID(), UUID())
        var state = LibrarySyncState()
        state.uploaded = [a.uuidString]
        #expect(state.notUploaded([a, b]) == [b])
    }

    @Test func remembersDeletionsWhileOff() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Library Sync.json")
        let (uploaded, localOnly) = (UUID(), UUID())
        var state = LibrarySyncState()
        state.uploaded = [uploaded.uuidString]
        try state.save(to: url)
        let defaults = try #require(UserDefaults(suiteName: "LibrarySyncTests-\(UUID().uuidString)"))
        defaults.set(false, forKey: LibrarySync.enabledKey)

        let container = try makeContainer()
        let sync = LibrarySync(studio: makeStudio(container: container), container: container, defaults: defaults,
                               stateURL: url, usesCloudKit: false)
        #expect(!sync.isEnabled && sync.status == .off)

        sync.imagesDeleted([uploaded, localOnly])

        #expect(LibrarySyncState.load(from: url).pausedDeletions == [uploaded.uuidString],
                "Only images iCloud has need deleting there.")
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
        try LibrarySyncState().save(to: syncState)

        let model = AppModel(simulatesFailure: true, storeURL: store,
                             backupsDirectory: directory.appending(path: "Library Backups"), syncStateURL: syncState) {
            try makeContainer()
        }
        model.resetLibrary()

        #expect(!exists(syncState), "A fresh library downloads everything in iCloud again.")
    }
}
