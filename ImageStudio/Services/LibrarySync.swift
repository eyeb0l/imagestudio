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
    /// The library this state describes (its store's UUID). State for another library is ignored.
    var libraryID: String?
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
    /// Images added without a reference or markup file that came with them, fetched again to fill
    /// the gap. Only ever repaired, never added again: if one is deleted here, it stays deleted.
    var incompleteDownloads: Set<String> = []

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "Library Sync.json", directoryHint: .notDirectory)

    init() {}

    /// Missing keys (e.g. from an older version) take their defaults rather than losing the rest.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineState = try container.decodeIfPresent(CKSyncEngine.State.Serialization.self, forKey: .engineState)
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        zoneCreated = try container.decodeIfPresent(Bool.self, forKey: .zoneCreated) ?? false
        uploaded = try container.decodeIfPresent(Set<String>.self, forKey: .uploaded) ?? []
        pendingDeletions = try container.decodeIfPresent(Set<String>.self, forKey: .pendingDeletions) ?? []
        remoteDeletions = try container.decodeIfPresent(Set<String>.self, forKey: .remoteDeletions) ?? []
        failedDownloads = try container.decodeIfPresent(Set<String>.self, forKey: .failedDownloads) ?? []
        incompleteDownloads = try container.decodeIfPresent(Set<String>.self, forKey: .incompleteDownloads) ?? []
    }

    static func load(from url: URL) -> LibrarySyncState {
        guard let data = try? Data(contentsOf: url) else { return LibrarySyncState() }
        // Unreadable state only costs a fresh download; the library itself is unaffected.
        return (try? JSONDecoder().decode(LibrarySyncState.self, from: data)) ?? LibrarySyncState()
    }

    /// The saved state, if it belongs to the library with `libraryID`; otherwise a fresh start. Used
    /// with another library (e.g. a reset one left with the old state), it would take every image
    /// missing from it as deleted, and delete it from iCloud, or bind it to an account it never chose.
    static func load(from url: URL, libraryID: String?) -> LibrarySyncState {
        var state = load(from: url)
        guard let libraryID else { return state }
        if let saved = state.libraryID, saved != libraryID { state = LibrarySyncState() }
        state.libraryID = libraryID
        return state
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

    /// Images that were in iCloud and aren't in the library any more, so are owed a deletion there.
    /// Covers a deletion whose record in `pendingDeletions` never reached disk.
    func deletedLocally(library: [UUID]) -> Set<String> {
        uploaded.subtracting(library.map(\.uuidString)).subtracting(failedDownloads).subtracting(remoteDeletions)
    }

    /// Forgets everything about an iCloud account's contents, for syncing with a different one.
    /// `remoteDeletions` stays: those images are still to be removed from this library.
    mutating func forgetServer() {
        engineState = nil
        accountID = nil
        zoneCreated = false
        uploaded = []
        pendingDeletions = []
        failedDownloads = []
        incompleteDownloads = []
    }
}

/// Keeps the library in step with the user's private iCloud database, using `CKSyncEngine`.
///
/// Local images that iCloud doesn't have are uploaded, images from other devices are downloaded
/// into the library, and deletions go both ways. Pending generations, the prompt box and the API
/// key stay on this device. Turning sync off pauses it: images deleted in the meantime are
/// deleted from iCloud when it's turned back on, and new ones are uploaded.
///
/// Nothing is fetched or sent until the signed-in account is known to be the one this library syncs with. If
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
    /// The user turned syncing on, agreeing to sync with whichever account is signed in. Lasts only
    /// until the next account check, so it can't apply to an account that signs in later.
    @ObservationIgnored private var approvesAccountChange = false
    /// The account check under way, if any. Replaced or cleared to make its answer out of date.
    @ObservationIgnored private var accountCheck: UUID?
    /// The account may have changed while a check was under way, so its answer is out of date.
    @ObservationIgnored private var recheckAccount = false

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
    /// The engine only exists once the signed-in account is confirmed as the one this library syncs
    /// with, so nothing is fetched from or sent to any other account.
    private var accountConfirmed: Bool { engine != nil }
    private var canSend: Bool { engine != nil }

    /// `libraryID` identifies the library's store (see `LibraryStore.storeID`). `usesCloudKit: false`
    /// keeps everything local, for unit tests (which host the app).
    init(studio: Studio, container: ModelContainer, defaults: UserDefaults = .standard,
         stateURL: URL = LibrarySyncState.defaultURL, libraryID: String? = nil,
         usesCloudKit: Bool = !LibrarySync.isRunningTests) {
        self.studio = studio
        self.container = container
        self.defaults = defaults
        self.stateURL = stateURL
        self.usesCloudKit = usesCloudKit
        self.state = LibrarySyncState.load(from: stateURL, libraryID: libraryID)
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        studio.libraryObserver = self
        persist()
        if isEnabled { start() }
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: Lifecycle

    private func start() {
        guard engine == nil else { return }
        accountProblem = nil
        syncError = nil
        hasFetched = false
        isBusy = false
        refreshStatus()
        guard usesCloudKit else { return }
        if accountObserver == nil {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkAccount(invalidating: true) }
            }
        }
        checkAccount()
    }

    /// Turns syncing off: stops the engine and any account check.
    private func stop() {
        accountCheck = nil
        stopEngine()
        refreshStatus()
    }

    private func stopEngine() {
        guard let stopping = engine else { return }
        engine = nil
        Task { await stopping.cancelOperations() }
    }

    /// Starts the engine for the account just confirmed.
    private func startEngine() {
        guard engine == nil else { return }
        hasFetched = false
        isBusy = false
        let cloud = CKContainer(identifier: LibraryRecord.containerIdentifier)
        engine = CKSyncEngine(CKSyncEngine.Configuration(database: cloud.privateCloudDatabase,
                                                         stateSerialization: state.engineState, delegate: self))
    }

    /// Picks up anything missed: images iCloud doesn't have, deletions still to make, and downloads
    /// that failed. Cheap when there's nothing to do; `CKSyncEngine` fetches by itself.
    func appBecameActive() {
        // e.g. the last check couldn't reach iCloud.
        if isEnabled, engine == nil { checkAccount() }
        sendOutstandingWork()
    }

    /// Checks which account is signed in; the engine runs only once it's the one this library syncs
    /// with. `invalidating` (the account may have changed) makes a check already under way out of
    /// date; otherwise that check is left to answer. `stopping` stops the engine until it's checked.
    private func checkAccount(invalidating: Bool = false, stopping: Bool = false) {
        guard usesCloudKit, isEnabled else { return }
        if stopping { stopEngine() }
        guard accountCheck == nil else {
            if invalidating { recheckAccount = true }
            return
        }
        let check = UUID()
        accountCheck = check
        recheckAccount = false
        refreshStatus()
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
            guard accountCheck == check else { return }
            accountCheck = nil
            if recheckAccount {
                // The account may have changed, so agreeing to sync no longer says with which one.
                approvesAccountChange = false
                checkAccount()
                return
            }
            accountProblem = problem
            if let userID {
                confirmAccount(userID)
            } else {
                // Agreeing to sync applies to the account signed in now, not one that signs in later.
                approvesAccountChange = false
                stopEngine()
                refreshStatus()
            }
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
            stopEngine()
            state.forgetServer()
        }
        approvesAccountChange = false
        if state.accountID != userID {
            state.accountID = userID
            persist()
        }
        startEngine()
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
        // Recorded first, whatever happens next, so the deletion reaches iCloud eventually. A download
        // still being retried is dropped, so it can't bring the image back.
        state.pendingDeletions.formUnion(ids.map(\.uuidString))
        state.failedDownloads.subtract(ids.map(\.uuidString))
        state.incompleteDownloads.subtract(ids.map(\.uuidString))
        persist()
        if canSend { queueDeletions(ids) }
    }

    /// Everything this device still owes iCloud, and what it still has to do with iCloud's changes.
    private func sendOutstandingWork() {
        guard canSend else { return }
        retryRemoteDeletions()
        queueLocalImages()
        queueDeletions(state.pendingDeletions.compactMap(UUID.init(uuidString:)))
        retryFailedDownloads()
        refreshStatus()
    }

    /// Queues an upload for every library image iCloud doesn't have yet, and finds images deleted
    /// here whose deletion was never recorded (e.g. the state file couldn't be written).
    private func queueLocalImages() {
        let library: [UUID]
        do {
            var descriptor = FetchDescriptor<GeneratedImage>()
            descriptor.propertiesToFetch = [\.id]
            library = try context.fetch(descriptor).map(\.id)
        } catch {
            // Without the library there's no telling what's missing, so nothing is inferred.
            Self.log.error("Couldn't list images to upload: \(error.localizedDescription, privacy: .public)")
            return
        }
        let missing = state.deletedLocally(library: library).subtracting(state.pendingDeletions)
        if !missing.isEmpty {
            state.pendingDeletions.formUnion(missing)
            persist()
        }
        queueUploads(state.toUpload(library))
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
                if syncError?.hasPrefix("Couldn't set up iCloud") == true { syncError = nil }
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
        } else if !state.failedDownloads.isEmpty || !state.incompleteDownloads.isEmpty {
            .failed("Some images couldn't be downloaded. Image Studio will try again.")
        } else if let engine, accountConfirmed, hasFetched, !isBusy,
                  state.pendingDeletions.isEmpty, state.remoteDeletions.isEmpty,
                  engine.state.pendingRecordZoneChanges.isEmpty, engine.state.pendingDatabaseChanges.isEmpty {
            .upToDate
        } else {
            .syncing
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signIn(let user), .switchAccounts(_, let user):
            // A new engine reports the account it starts with: the one just confirmed.
            guard user.recordName != state.accountID else { return }
            // Another account: stopped at once, so nothing more is fetched into this library.
            checkAccount(invalidating: true, stopping: true)
        case .signOut:
            // The library stays on this device, and remembers its account in case it signs back in.
            state.engineState = nil
            persist()
            checkAccount(invalidating: true, stopping: true)
        @unknown default:
            checkAccount(invalidating: true, stopping: true)
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
        record(studio.addSyncedImages(images))

        if !deleted.isEmpty {
            // Gone from iCloud, so nothing is owed there; any queued upload is cancelled.
            engine?.state.remove(pendingRecordZoneChanges: deleted.map { .saveRecord(LibraryRecord.recordID(for: $0)) })
            state.uploaded.subtract(deletedNames)
            state.failedDownloads.subtract(deletedNames)
            state.incompleteDownloads.subtract(deletedNames)
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
            if error.code == .unknownItem || error.code == .zoneNotFound {
                // Never made it to iCloud, or already deleted (with its zone, if there isn't one).
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

    /// Notes how adding downloaded images went. Images in the library count as in iCloud.
    private func record(_ result: (present: [UUID], incomplete: [UUID], failed: [UUID])) {
        let present = Set(result.present.map(\.uuidString))
        let incomplete = Set(result.incomplete.map(\.uuidString))
        let failed = Set(result.failed.map(\.uuidString))
        state.uploaded.formUnion(present.union(incomplete))
        state.failedDownloads.subtract(present.union(incomplete))
        state.failedDownloads.formUnion(failed)
        state.incompleteDownloads.subtract(present)
        state.incompleteDownloads.formUnion(incomplete)
    }

    /// Fetches records again whose images couldn't be added, or were added without all their files.
    private func retryFailedDownloads() {
        let names = state.failedDownloads.union(state.incompleteDownloads)
        guard canSend, let engine, !names.isEmpty else { return }
        let recordIDs = names.map { CKRecord.ID(recordName: $0, zoneID: LibraryRecord.zoneID) }
        Task {
            guard let results = try? await engine.database.records(for: recordIDs) else { return }
            guard engine === self.engine else { return }
            var records: [CKRecord] = []
            for (recordID, result) in results {
                switch result {
                case .success(let record): records.append(record)
                case .failure(let error as CKError) where error.code == .unknownItem:
                    state.failedDownloads.remove(recordID.recordName)
                    state.incompleteDownloads.remove(recordID.recordName)
                case .failure: break
                }
            }
            // Only what's still wanted: the image may have been deleted while this was fetched. An
            // incomplete image is only repaired if it's still in the library.
            let images = records.compactMap(LibraryRecord.decode).filter { state.accepts($0.id) }
            let inLibrary = Set(studio.existingImageIDs(among: images.map(\.id)))
            let wanted = images.filter { image in
                let name = image.id.uuidString
                if state.failedDownloads.contains(name) { return true }
                guard state.incompleteDownloads.contains(name) else { return false }
                if !inLibrary.contains(image.id) { state.incompleteDownloads.remove(name) }
                return inLibrary.contains(image.id)
            }
            record(studio.addSyncedImages(wanted))
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
