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
/// deleted when the library is reset, so a fresh library downloads everything again. Images are
/// identified by their record names (the image's UUID).
nonisolated struct LibrarySyncState: Codable {
    /// `CKSyncEngine`'s own state: what it has fetched, and the changes it still has to send.
    var engineState: CKSyncEngine.State.Serialization?
    /// The iCloud account (user record name) this library syncs with.
    var accountID: String?
    var zoneCreated = false
    /// Images known to be in iCloud, so the library's other images can be uploaded.
    var uploaded: Set<String> = []
    /// Images deleted on this device, until iCloud confirms they're gone there too. Kept here rather
    /// than only in the engine, so a deletion survives syncing being off, a relaunch or a failure.
    var pendingDeletions: Set<String> = []
    /// Images deleted in iCloud that couldn't be removed here yet. Never uploaded again.
    var remoteDeletions: Set<String> = []
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

    /// The local images that should be uploaded: not in iCloud, and not on their way out.
    func toUpload(_ ids: [UUID]) -> [UUID] {
        ids.filter {
            let name = $0.uuidString
            return !uploaded.contains(name) && !pendingDeletions.contains(name) && !remoteDeletions.contains(name)
        }
    }

    /// Whether an image arriving from iCloud should be added: not deleted here in the meantime.
    func accepts(_ id: UUID) -> Bool {
        !pendingDeletions.contains(id.uuidString) && !remoteDeletions.contains(id.uuidString)
    }

    /// Forgets everything about an iCloud account's contents, for syncing with a different one.
    mutating func forgetServer() {
        engineState = nil
        accountID = nil
        zoneCreated = false
        uploaded = []
        pendingDeletions = []
        remoteDeletions = []
        failedDownloads = []
    }
}

/// Keeps the library in step with the user's private iCloud database, using `CKSyncEngine`.
///
/// Local images that iCloud doesn't have are uploaded, images from other devices are downloaded
/// into the library, and deletions go both ways. Pending generations, the prompt box and the API
/// key stay on this device. Turning sync off pauses it: images deleted in the meantime are
/// deleted from iCloud when it's turned back on, and new ones are uploaded.
///
/// Nothing is sent until the signed-in account is known to be the one this library syncs with. If
/// it's a different one, syncing turns off rather than copy the library into that account; turning
/// it back on agrees to sync with the account signed in at the time.
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
            if isEnabled {
                approvesAccountChange = true
                start()
            } else {
                stop()
            }
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
    /// The signed-in account is the one this library syncs with, so changes may be sent.
    @ObservationIgnored private var accountConfirmed = false
    /// The user turned syncing on, agreeing to sync with whichever account is signed in.
    @ObservationIgnored private var approvesAccountChange = false

    // What the status is worked out from.
    @ObservationIgnored private var accountProblem: String?
    @ObservationIgnored private var syncError: String?
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var hasFetched = false

    private static let log = Logger(subsystem: "com.eyeb0l.ImageStudio", category: "LibrarySync")
    static let enabledKey = "iCloudSyncEnabled"
    static let signedOutMessage = "Sign in to iCloud in the Settings app to sync your library."
    static let accountChangedNotice = "Your iCloud account changed, so iCloud Sync was turned off rather than copy this library into a different account. Turn it on to sync with the account you're signed in to now."

    private var context: ModelContext { container.mainContext }
    private var canSend: Bool { engine != nil && accountConfirmed }

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
        accountConfirmed = false
        accountProblem = nil
        syncError = nil
        hasFetched = false
        isBusy = false
        refreshStatus()
        guard usesCloudKit else { return }

        let cloud = CKContainer(identifier: LibraryRecord.containerIdentifier)
        engine = CKSyncEngine(CKSyncEngine.Configuration(database: cloud.privateCloudDatabase,
                                                         stateSerialization: state.engineState, delegate: self))
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
        accountConfirmed = false
        refreshStatus()
        if let stopping { Task { await stopping.cancelOperations() } }
    }

    private func restart() {
        stop()
        start()
    }

    /// Picks up anything missed: images iCloud doesn't have, deletions still to make, and downloads
    /// that failed. Cheap when there's nothing to do; `CKSyncEngine` fetches by itself.
    func appBecameActive() {
        sendOutstandingWork()
    }

    /// Checks which account is signed in before anything is sent to it.
    private func checkAccount() {
        guard usesCloudKit, let current = engine else { return }
        accountConfirmed = false
        Task {
            let cloud = CKContainer(identifier: LibraryRecord.containerIdentifier)
            let problem: String?
            var userID: String?
            do {
                switch try await cloud.accountStatus() {
                case .available:
                    userID = try await cloud.userRecordID().recordName
                    problem = nil
                case .noAccount: problem = Self.signedOutMessage
                case .restricted: problem = "iCloud is restricted on this device."
                case .temporarilyUnavailable: problem = "iCloud is temporarily unavailable. Check your Apple Account in the Settings app."
                case .couldNotDetermine: problem = "Couldn't check your iCloud account."
                @unknown default: problem = "Couldn't check your iCloud account."
                }
            } catch {
                problem = "Couldn't check your iCloud account: \(error.localizedDescription)"
            }
            guard current === engine else { return }
            accountProblem = problem
            if let userID { confirmAccount(userID) } else { refreshStatus() }
        }
    }

    private func confirmAccount(_ userID: String) {
        if let known = state.accountID, known != userID {
            guard approvesAccountChange else {
                // Kept as it was, in case the previous account comes back.
                Self.log.notice("The iCloud account changed; turning sync off until it's turned back on")
                isEnabled = false
                notice = Self.accountChangedNotice
                return
            }
            Self.log.notice("Syncing with a different iCloud account, as agreed")
            state.forgetServer()
            state.accountID = userID
            persist()
            restart()
            return
        }
        approvesAccountChange = false
        if state.accountID == nil {
            state.accountID = userID
            persist()
        }
        accountConfirmed = true
        refreshStatus()
        sendOutstandingWork()
    }

    // MARK: Local changes

    func imagesAdded(_ ids: [UUID]) {
        guard canSend else { return }  // Picked up once it can send.
        queueUploads(state.toUpload(ids))
    }

    func imagesDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        // Recorded first, whatever happens next, so the deletion reaches iCloud eventually.
        state.pendingDeletions.formUnion(ids.map(\.uuidString))
        persist()
        if canSend { queueDeletions(ids) }
    }

    /// Everything this device still owes iCloud, and what it still has to do with iCloud's changes.
    private func sendOutstandingWork() {
        guard canSend else { return }
        retryRemoteDeletions()
        queueDeletions(state.pendingDeletions.compactMap(UUID.init(uuidString:)))
        queueLocalImages()
        retryFailedDownloads()
        refreshStatus()
    }

    /// Queues an upload for every library image iCloud doesn't have yet.
    private func queueLocalImages() {
        do {
            var descriptor = FetchDescriptor<GeneratedImage>()
            descriptor.propertiesToFetch = [\.id]
            queueUploads(state.toUpload(try context.fetch(descriptor).map(\.id)))
        } catch {
            Self.log.error("Couldn't list images to upload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func queueUploads(_ ids: [UUID]) {
        guard canSend, let engine, !ids.isEmpty else { return }
        if !state.zoneCreated {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: LibraryRecord.zoneID))])
        }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(LibraryRecord.recordID(for: $0)) })
    }

    private func queueDeletions(_ ids: [UUID]) {
        guard canSend, let engine, !ids.isEmpty else { return }
        let recordIDs = ids.map(LibraryRecord.recordID(for:))
        engine.state.remove(pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
        engine.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
    }

    /// Removes images deleted in iCloud whose removal here failed before.
    private func retryRemoteDeletions() {
        guard !state.remoteDeletions.isEmpty else { return }
        let remaining = studio.removeSyncedImages(ids: state.remoteDeletions.compactMap(UUID.init(uuidString:)))
        state.remoteDeletions = Set(remaining.map(\.uuidString))
        persist()
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
                syncError = "Couldn't set up iCloud: \(failure.error.localizedDescription)"
            }

        case .sentRecordZoneChanges(let changes):
            handleSent(changes)

        case .willFetchChanges, .willSendChanges:
            isBusy = true

        case .didFetchChanges:
            isBusy = false
            hasFetched = true
            retryFailedDownloads()

        case .didSendChanges:
            isBusy = false

        case .didFetchRecordZoneChanges(let result):
            if let error = result.error {
                Self.log.error("Fetching changes failed: \(error.localizedDescription, privacy: .public)")
                syncError = "Couldn't download changes from iCloud: \(error.localizedDescription)"
            } else if syncError?.hasPrefix("Couldn't download") == true {
                syncError = nil
            }

        case .willFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
        refreshStatus()
    }

    private func refreshStatus() {
        status = if !isEnabled {
            .off
        } else if let accountProblem {
            .unavailable(accountProblem)
        } else if let syncError {
            .failed(syncError)
        } else if !state.failedDownloads.isEmpty {
            .failed("Some images couldn't be downloaded. Image Studio will try again.")
        } else if let engine, accountConfirmed, hasFetched, !isBusy,
                  engine.state.pendingRecordZoneChanges.isEmpty, engine.state.pendingDatabaseChanges.isEmpty {
            .upToDate
        } else {
            .syncing
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signIn, .switchAccounts:
            // Nothing is sent until the account is checked against the one this library syncs with.
            checkAccount()
        case .signOut:
            // The library stays on this device, and remembers its account in case it signs back in.
            state.engineState = nil
            persist()
            restart()
        @unknown default:
            checkAccount()
        }
    }

    private func handleZoneDeletion(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) {
        switch reason {
        case .encryptedDataReset:
            // The keys protecting encrypted fields were reset, so iCloud's copy is gone. Upload again.
            Self.log.notice("iCloud's encrypted data was reset; uploading the library again")
            state.zoneCreated = false
            state.uploaded = []
            state.pendingDeletions = []
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
        let deleted = changes.deletions
            .filter { $0.recordType == LibraryRecord.recordType }
            .compactMap { LibraryRecord.imageID(of: $0.recordID) }
        let deletedNames = Set(deleted.map(\.uuidString))

        let images = changes.modifications.compactMap { modification -> SyncedImage? in
            guard let image = LibraryRecord.decode(modification.record) else {
                Self.log.error("Skipped an unreadable iCloud record: \(modification.record.recordID.recordName, privacy: .public)")
                return nil
            }
            return image
        }.filter { state.accepts($0.id) && !deletedNames.contains($0.id.uuidString) }
        let result = studio.addSyncedImages(images)
        state.uploaded.formUnion(result.present.map(\.uuidString))
        state.uploaded.formUnion(result.failed.map(\.uuidString))
        state.failedDownloads.subtract(result.present.map(\.uuidString))
        state.failedDownloads.formUnion(result.failed.map(\.uuidString))

        if !deleted.isEmpty {
            // Gone from iCloud, so nothing is owed there; any queued upload is cancelled.
            engine?.state.remove(pendingRecordZoneChanges: deleted.map { .saveRecord(LibraryRecord.recordID(for: $0)) })
            state.uploaded.subtract(deletedNames)
            state.failedDownloads.subtract(deletedNames)
            state.pendingDeletions.subtract(deletedNames)
            // Kept until removed here, so a failure can't make them look like new images to upload.
            state.remoteDeletions.formUnion(deletedNames)
            let remaining = Set(studio.removeSyncedImages(ids: deleted).map(\.uuidString))
            state.remoteDeletions.subtract(deletedNames.subtracting(remaining))
        }
        persist()
    }

    private func handleSent(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        state.uploaded.formUnion(changes.savedRecords.compactMap { LibraryRecord.imageID(of: $0.recordID)?.uuidString })
        let deleted = Set(changes.deletedRecordIDs.map(\.recordName))
        state.uploaded.subtract(deleted)
        state.pendingDeletions.subtract(deleted)

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
                syncError = "Your iCloud storage is full, so some images haven't been uploaded."
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                 .notAuthenticated, .operationCancelled:
                // `CKSyncEngine` retries these itself.
                break
            default:
                Self.log.error("Couldn't upload \(id, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        for (recordID, error) in changes.failedRecordDeletes {
            if error.code == .unknownItem {
                // Never made it to iCloud, or already deleted.
                state.uploaded.remove(recordID.recordName)
                state.pendingDeletions.remove(recordID.recordName)
            } else {
                // Still in `pendingDeletions`, so it's queued again when the app is next opened.
                Self.log.error("Couldn't delete \(recordID.recordName, privacy: .public) from iCloud: \(error.localizedDescription, privacy: .public)")
            }
        }
        if syncError?.hasPrefix("Your iCloud storage") == true, changes.failedRecordSaves.isEmpty, !changes.savedRecords.isEmpty {
            syncError = nil
        }
        persist()
        queueUploads(retry)
    }

    /// Fetches records again whose images couldn't be added when they first arrived.
    private func retryFailedDownloads() {
        guard canSend, let engine, !state.failedDownloads.isEmpty else { return }
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
            // Only what's still wanted: the image may have been deleted while this was fetched.
            let wanted = records.compactMap(LibraryRecord.decode)
                .filter { state.failedDownloads.contains($0.id.uuidString) && state.accepts($0.id) }
            let result = studio.addSyncedImages(wanted)
            state.failedDownloads.subtract(result.present.map(\.uuidString))
            persist()
            refreshStatus()
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
        guard let id = LibraryRecord.imageID(of: recordID), syncEngine === engine, accountConfirmed else { return nil }
        let image = try? context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.id == id })).first
        guard let image, state.accepts(id), let record = LibraryRecord.record(for: image) else {
            // Deleted since, or its file is missing: nothing to upload.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return record
    }

    #if DEBUG
    /// For tests: what's remembered between launches.
    var persistedState: LibrarySyncState { state }
    #endif
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
