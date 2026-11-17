import CloudKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Told about images added to or deleted from the library on this device.
protocol LibraryObserver: AnyObject {
    func imagesAdded(_ ids: [UUID])
    func imagesDeleted(_ ids: [UUID])
}

/// What `LibrarySync` remembers between launches. Kept in its own file next to the library, and
/// deleted when the library is reset, so a fresh library downloads everything again.
nonisolated struct LibrarySyncState: Codable {
    /// `CKSyncEngine`'s own state: what it has fetched, and the changes it still has to send.
    var engineState: CKSyncEngine.State.Serialization?
    var zoneCreated = false
    /// Images known to be in iCloud (record names), so the library's other images can be uploaded.
    var uploaded: Set<String> = []
    /// Images deleted while syncing was off that are in iCloud, deleted there when it's turned on.
    var pausedDeletions: Set<String> = []
    /// Images that arrived but couldn't be added (e.g. the disk was full), fetched again later.
    var failedDownloads: Set<String> = []

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "Library Sync.json", directoryHint: .notDirectory)

    static func load(from url: URL) -> LibrarySyncState {
        guard let data = try? Data(contentsOf: url) else { return LibrarySyncState() }
        // Unreadable state only costs a fresh download; the library itself is unaffected.
        return (try? JSONDecoder().decode(LibrarySyncState.self, from: data)) ?? LibrarySyncState()
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The local images iCloud doesn't have yet.
    func notUploaded(_ ids: [UUID]) -> [UUID] {
        ids.filter { !uploaded.contains($0.uuidString) }
    }

    /// Forgets everything about iCloud's contents, e.g. after a change of account.
    mutating func forgetServer() {
        engineState = nil
        zoneCreated = false
        uploaded = []
        pausedDeletions = []
        failedDownloads = []
    }
}

/// Keeps the library in step with the user's private iCloud database, using `CKSyncEngine`.
///
/// Local images that iCloud doesn't have are uploaded, images from other devices are downloaded
/// into the library, and deletions go both ways. Pending generations, the prompt box and the API
/// key stay on this device. Turning sync off pauses it: images deleted in the meantime are
/// deleted from iCloud when it's turned back on, and new ones are uploaded.
@Observable
final class LibrarySync: LibraryObserver {
    enum Status: Equatable {
        case off
        case syncing
        case upToDate
        case unavailable(String)
        case failed(String)
    }

    private(set) var status: Status = .off
    /// Something the user should know that outlasts the status, e.g. why syncing was turned off.
    private(set) var notice: String?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            notice = nil
            if isEnabled { start() } else { stop() }
        }
    }

    @ObservationIgnored private let studio: Studio
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let usesCloudKit: Bool
    @ObservationIgnored private var state: LibrarySyncState
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?

    private static let log = Logger(subsystem: "com.eyeb0l.ImageStudio", category: "LibrarySync")
    static let enabledKey = "iCloudSyncEnabled"

    private var context: ModelContext { container.mainContext }

    /// `usesCloudKit: false` keeps everything local, for unit tests (which host the app).
    init(studio: Studio, container: ModelContainer, defaults: UserDefaults = .standard,
         stateURL: URL = LibrarySyncState.defaultURL, usesCloudKit: Bool = !LibrarySync.isRunningTests) {
        self.studio = studio
        self.container = container
        self.defaults = defaults
        self.stateURL = stateURL
        self.usesCloudKit = usesCloudKit
        self.state = LibrarySyncState.load(from: stateURL)
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        studio.libraryObserver = self
        if isEnabled { start() }
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: Lifecycle

    private func start() {
        guard engine == nil else { return }
        status = .syncing
        guard usesCloudKit else { return }

        let cloud = CKContainer(identifier: LibraryRecord.containerIdentifier)
        let configuration = CKSyncEngine.Configuration(database: cloud.privateCloudDatabase,
                                                       stateSerialization: state.engineState, delegate: self)
        engine = CKSyncEngine(configuration)

        // Deletions made while syncing was off.
        if !state.pausedDeletions.isEmpty {
            let ids = state.pausedDeletions.compactMap(UUID.init(uuidString:))
            state.pausedDeletions = []
            queueDeletions(ids)
        }
        queueLocalImages()

        if accountObserver == nil {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkAccount() }
            }
        }
        checkAccount()
    }

    private func stop() {
        let stopping = engine
        engine = nil
        status = .off
        if let stopping { Task { await stopping.cancelOperations() } }
    }

    /// Picks up anything missed: images iCloud doesn't have, and downloads that failed. Cheap when
    /// there's nothing to do; `CKSyncEngine` fetches by itself when told of changes.
    func appBecameActive() {
        guard engine != nil else { return }
        queueLocalImages()
        retryFailedDownloads()
    }

    private func checkAccount() {
        guard usesCloudKit else { return }
        Task {
            do {
                let accountStatus = try await CKContainer(identifier: LibraryRecord.containerIdentifier).accountStatus()
                guard engine != nil else { return }
                switch accountStatus {
                case .available:
                    if case .unavailable = status { status = .syncing }
                    updateIdleStatus()
                case .noAccount:
                    status = .unavailable("Sign in to iCloud in the Settings app to sync your library.")
                case .restricted:
                    status = .unavailable("iCloud is restricted on this device.")
                case .temporarilyUnavailable:
                    status = .unavailable("iCloud is temporarily unavailable. Check your Apple Account in the Settings app.")
                case .couldNotDetermine:
                    status = .unavailable("Couldn't check your iCloud account.")
                @unknown default:
                    status = .unavailable("Couldn't check your iCloud account.")
                }
            } catch {
                status = .unavailable("Couldn't check your iCloud account: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Local changes

    func imagesAdded(_ ids: [UUID]) {
        guard engine != nil else { return }
        queueUploads(state.notUploaded(ids))
    }

    func imagesDeleted(_ ids: [UUID]) {
        guard engine != nil else {
            // Remembered so other devices delete them too once syncing is back on.
            state.pausedDeletions.formUnion(ids.map(\.uuidString).filter(state.uploaded.contains))
            persist()
            return
        }
        queueDeletions(ids)
    }

    /// Queues an upload for every library image iCloud doesn't have yet.
    private func queueLocalImages() {
        do {
            var descriptor = FetchDescriptor<GeneratedImage>()
            descriptor.propertiesToFetch = [\.id]
            let ids = try context.fetch(descriptor).map(\.id)
            queueUploads(state.notUploaded(ids))
        } catch {
            Self.log.error("Couldn't list images to upload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func queueUploads(_ ids: [UUID]) {
        guard let engine, !ids.isEmpty else { return }
        if !state.zoneCreated {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: LibraryRecord.zoneID))])
        }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(LibraryRecord.recordID(for: $0)) })
    }

    private func queueDeletions(_ ids: [UUID]) {
        guard let engine, !ids.isEmpty else { return }
        let recordIDs = ids.map(LibraryRecord.recordID(for:))
        engine.state.remove(pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
        engine.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
    }

    // MARK: Engine events

    private func handle(_ event: CKSyncEngine.Event, from syncEngine: CKSyncEngine) {
        // Events from an engine that's been replaced or stopped are out of date.
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            state.engineState = update.stateSerialization
            persist()

        case .accountChange(let change):
            handleAccountChange(change.changeType)

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == LibraryRecord.zoneID {
                handleZoneDeletion(deletion.reason)
            }

        case .fetchedRecordZoneChanges(let changes):
            apply(changes)

        case .sentDatabaseChanges(let changes):
            if changes.savedZones.contains(where: { $0.zoneID == LibraryRecord.zoneID }) {
                state.zoneCreated = true
                persist()
            }
            for failure in changes.failedZoneSaves {
                Self.log.error("Couldn't create the iCloud zone: \(failure.error.localizedDescription, privacy: .public)")
                status = .failed("Couldn't set up iCloud: \(failure.error.localizedDescription)")
            }

        case .sentRecordZoneChanges(let changes):
            handleSent(changes)

        case .willFetchChanges, .willSendChanges:
            if status != .off, !isUnavailable { status = .syncing }

        case .didFetchChanges:
            retryFailedDownloads()
            updateIdleStatus()

        case .didSendChanges:
            updateIdleStatus()

        case .didFetchRecordZoneChanges(let result):
            if let error = result.error {
                Self.log.error("Fetching changes failed: \(error.localizedDescription, privacy: .public)")
            }

        case .willFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = status { true } else { false }
    }

    private func updateIdleStatus() {
        guard let engine, !isUnavailable else { return }
        if case .failed = status { return }
        if engine.state.pendingRecordZoneChanges.isEmpty && engine.state.pendingDatabaseChanges.isEmpty {
            status = .upToDate
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signIn:
            status = .syncing
            queueLocalImages()
        case .signOut:
            // The library stays on this device; it's synced to whichever account signs in next.
            restartEngine()
            status = .unavailable("Sign in to iCloud in the Settings app to sync your library.")
        case .switchAccounts:
            restartEngine()
            queueLocalImages()
        @unknown default:
            break
        }
    }

    /// Starts again with no knowledge of iCloud's contents, e.g. for a different account.
    private func restartEngine() {
        state.forgetServer()
        persist()
        stop()
        start()
    }

    private func handleZoneDeletion(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) {
        switch reason {
        case .encryptedDataReset:
            // The keys protecting encrypted fields were reset, so iCloud's copy is gone. Upload again.
            Self.log.notice("iCloud's encrypted data was reset; uploading the library again")
            state.zoneCreated = false
            state.uploaded = []
            persist()
            queueLocalImages()
        default:
            // Deleted in Settings (Manage Storage). Uploading again would undo that, so stop instead.
            Self.log.notice("The iCloud zone was deleted; turning sync off")
            state.forgetServer()
            persist()
            isEnabled = false
            notice = "iCloud Sync was turned off because Image Studio's data was deleted from iCloud. Your library on this device hasn't changed."
        }
    }

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let images = changes.modifications.compactMap { modification -> SyncedImage? in
            guard let image = LibraryRecord.decode(modification.record) else {
                Self.log.error("Skipped an unreadable iCloud record: \(modification.record.recordID.recordName, privacy: .public)")
                return nil
            }
            return image
        }
        let result = studio.addSyncedImages(images)
        state.uploaded.formUnion(result.present.map(\.uuidString))
        state.failedDownloads.subtract(result.present.map(\.uuidString))
        state.failedDownloads.formUnion(result.failed.map(\.uuidString))

        let deleted = changes.deletions
            .filter { $0.recordType == LibraryRecord.recordType }
            .compactMap { LibraryRecord.imageID(of: $0.recordID) }
        studio.removeSyncedImages(ids: deleted)
        state.uploaded.subtract(deleted.map(\.uuidString))
        state.failedDownloads.subtract(deleted.map(\.uuidString))
        persist()
    }

    private func handleSent(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        state.uploaded.formUnion(changes.savedRecords.compactMap { LibraryRecord.imageID(of: $0.recordID)?.uuidString })
        state.uploaded.subtract(changes.deletedRecordIDs.map(\.recordName))

        var retry: [UUID] = []
        for failure in changes.failedRecordSaves {
            guard let id = LibraryRecord.imageID(of: failure.record.recordID) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                // Already in iCloud, and images never change, so there's nothing to merge.
                state.uploaded.insert(id.uuidString)
            case .zoneNotFound:
                state.zoneCreated = false
                retry.append(id)
            case .quotaExceeded:
                // Tried again when the app is next opened.
                status = .failed("Your iCloud storage is full, so some images haven't been uploaded.")
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                 .notAuthenticated, .operationCancelled:
                // `CKSyncEngine` retries these itself.
                break
            default:
                Self.log.error("Couldn't upload \(id, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        for (recordID, error) in changes.failedRecordDeletes where error.code == .unknownItem {
            // Never made it to iCloud, or already deleted.
            state.uploaded.remove(recordID.recordName)
        }
        persist()
        queueUploads(retry)
    }

    /// Fetches records again whose images couldn't be added when they first arrived.
    private func retryFailedDownloads() {
        guard let engine, !state.failedDownloads.isEmpty else { return }
        let recordIDs = state.failedDownloads.map { CKRecord.ID(recordName: $0, zoneID: LibraryRecord.zoneID) }
        Task {
            guard let results = try? await engine.database.records(for: recordIDs) else { return }
            guard engine === self.engine else { return }
            var records: [CKRecord] = []
            for (recordID, result) in results {
                switch result {
                case .success(let record): records.append(record)
                case .failure(let error as CKError) where error.code == .unknownItem:
                    state.failedDownloads.remove(recordID.recordName)
                case .failure: break
                }
            }
            let result = studio.addSyncedImages(records.compactMap(LibraryRecord.decode))
            state.uploaded.formUnion(result.present.map(\.uuidString))
            state.failedDownloads.subtract(result.present.map(\.uuidString))
            persist()
        }
    }

    private func persist() {
        do {
            try state.save(to: stateURL)
        } catch {
            Self.log.error("Couldn't save sync state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The images the engine asked for, read from the library when it's ready to send them.
    private func record(for recordID: CKRecord.ID, engine syncEngine: CKSyncEngine) -> CKRecord? {
        guard let id = LibraryRecord.imageID(of: recordID) else { return nil }
        let image = try? context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.id == id })).first
        guard let image, let record = LibraryRecord.record(for: image) else {
            // Deleted since, or its file is missing: nothing to upload.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return record
    }
}

extension LibrarySync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.record(for: recordID, engine: syncEngine)
        }
    }
}
