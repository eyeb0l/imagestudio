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
/// moved into the backup when the library is reset, so a fresh library downloads everything again.
/// Images are identified by their record names (the image's UUID).
///
/// Deletions are kept in the library's store instead (`LibraryDeletion`), saved with the change
/// they record. What's here can fall behind the library without harm (an upload or a download
/// repeated), but a deletion that fell behind would bring the image back.
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
    // Deletions not in the store's `LibraryDeletion` journal yet: from a version that kept them here,
    // or recorded while the store couldn't be saved. They count as much as the journal's, and move
    // into it once the store takes them.
    /// Images deleted on this device, until iCloud confirms they're gone there too.
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
    /// Covers a deletion that was never recorded, e.g. by a version from before the store kept them.
    func deletedLocally(library: [UUID]) -> Set<String> {
        uploaded.subtracting(library.map(\.uuidString)).subtracting(failedDownloads).subtracting(remoteDeletions)
    }

    /// Forgets everything about an iCloud account's contents, for syncing with a different one.
    /// `remoteDeletions` stays: those images are still to be removed from this library. Pending
    /// deletions in the store are forgotten by `LibrarySync`.
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

/// Deletions iCloud hasn't been told about, set aside while the library is reset. Otherwise they'd go
/// into the backup with the old library, and the new library would download those images again.
/// They're kept with the account they're owed to, and taken on by the next library to sync with that
/// account (see `LibrarySync.adoptAccount`), so a reset that stops part way keeps them too.
nonisolated struct UnsentDeletions: Codable, Equatable {
    /// The iCloud account (user record name) the deletions are owed to. `nil` for a library that
    /// never synced, whose deletions iCloud has no images for.
    var accountID: String?
    var ids: Set<String> = []

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "Unsent Deletions.json", directoryHint: .notDirectory)

    static func load(from url: URL) -> UnsentDeletions? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UnsentDeletions.self, from: data)
    }

    /// Sets aside the pending deletions of the library at `storeURL`, from its store and from its
    /// sync state at `syncStateURL`, which says which account they're owed to. A sync state left by
    /// another library says nothing about this one, so then nothing is set aside, as before deletions
    /// were kept in the store. Throws if they can't be saved.
    static func setAside(from storeURL: URL, syncStateURL: URL, to url: URL) throws {
        guard let libraryID = LibraryStore.storeID(at: storeURL) else { return }
        let state = LibrarySyncState.load(from: syncStateURL)
        guard state.libraryID == libraryID else { return }
        var unsent = UnsentDeletions(accountID: state.accountID,
                                     ids: LibraryStore.pendingDeletions(inStoreAt: storeURL).union(state.pendingDeletions))
        guard !unsent.ids.isEmpty else { return }
        // Set aside by a reset that didn't finish: kept if they're owed to the same account.
        if let earlier = load(from: url), earlier.accountID == unsent.accountID { unsent.ids.formUnion(earlier.ids) }
        try JSONEncoder().encode(unsent).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
    @ObservationIgnored private let unsentDeletionsURL: URL
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
    static let accountNotSavedNotice = "iCloud Sync was turned off because Image Studio couldn't save which iCloud account this library syncs with. Turn it on to try again."

    private var context: ModelContext { container.mainContext }
    /// For changes to the deletion journal alone, so a failed save is rolled back without touching
    /// anything else waiting in the main context (e.g. a pending generation whose save failed).
    @ObservationIgnored private let journalContext: ModelContext
    /// The engine only exists once the signed-in account is confirmed as the one this library syncs
    /// with, so nothing is fetched from or sent to any other account.
    private var accountConfirmed: Bool { engine != nil }
    private var canSend: Bool { engine != nil }

    /// `libraryID` identifies the library's store (see `LibraryStore.storeID`). `usesCloudKit: false`
    /// keeps everything local, for unit tests (which host the app).
    init(studio: Studio, container: ModelContainer, defaults: UserDefaults = .standard,
         stateURL: URL = LibrarySyncState.defaultURL, unsentDeletionsURL: URL = UnsentDeletions.defaultURL,
         libraryID: String? = nil, usesCloudKit: Bool = !LibrarySync.isRunningTests) {
        self.studio = studio
        self.container = container
        self.defaults = defaults
        self.stateURL = stateURL
        self.unsentDeletionsURL = unsentDeletionsURL
        self.usesCloudKit = usesCloudKit
        self.journalContext = ModelContext(container)
        journalContext.autosaveEnabled = false
        self.state = LibrarySyncState.load(from: stateURL, libraryID: libraryID)
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        studio.libraryObserver = self
        journalStateDeletions()
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
        if let known = state.accountID, known != userID, !approvesAccountChange {
            // Kept as it was, in case the previous account comes back.
            Self.log.notice("The iCloud account changed; turning sync off until it's turned back on")
            isEnabled = false
            notice = Self.accountChangedNotice
            return
        }
        approvesAccountChange = false
        guard adoptAccount(userID) else {
            isEnabled = false
            notice = Self.accountNotSavedNotice
            return
        }
        startEngine()
        refreshStatus()
        sendOutstandingWork()
    }

    /// Makes `userID` the account this library syncs with, and takes on the deletions a reset set
    /// aside for it. Deletions are owed to the account the library syncs with, so changing it (from
    /// another account, or from none) first forgets those still to send, and the change has to reach
    /// disk: nothing deleted while syncing with one account is ever sent to another. Returns whether
    /// syncing can go ahead.
    func adoptAccount(_ userID: String) -> Bool {
        if state.accountID != userID {
            if state.accountID != nil { Self.log.notice("Syncing with a different iCloud account, as agreed") }
            stopEngine()
            guard forgetPendingDeletions() else { return false }
            var adopted = state
            adopted.forgetServer()
            adopted.accountID = userID
            do {
                try adopted.save(to: stateURL)
            } catch {
                Self.log.error("Couldn't save the iCloud account: \(error.localizedDescription, privacy: .public)")
                return false
            }
            state = adopted
        }
        takeUnsentDeletions(for: userID)
        return true
    }

    // MARK: Local changes

    func imagesAdded(_ ids: [UUID]) {
        guard canSend, let known = withJournal() else { return }  // Picked up once it can send.
        queueUploads(known.toUpload(ids))
    }

    /// The deletions are already recorded (`LibraryDeletion`), in the save that removed the images,
    /// so they reach iCloud eventually whatever happens next.
    func imagesDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        // A download still being retried is dropped: there's nothing left to fetch.
        state.failedDownloads.subtract(ids.map(\.uuidString))
        state.incompleteDownloads.subtract(ids.map(\.uuidString))
        persist()
        if canSend { queueDeletions(ids) }
    }

    /// Everything this device still owes iCloud, and what it still has to do with iCloud's changes.
    private func sendOutstandingWork() {
        guard canSend else { return }
        journalStateDeletions()
        retryRemoteDeletions()
        queueLocalImages()
        if let known = withJournal() {
            queueDeletions(known.pendingDeletions.compactMap(UUID.init(uuidString:)))
        }
        retryFailedDownloads()
        refreshStatus()
    }

    /// Queues an upload for every library image iCloud doesn't have yet, and finds images deleted
    /// here whose deletion was never recorded (e.g. by a version that kept them only in the state file).
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
        guard let known = withJournal() else { return }
        let missing = known.deletedLocally(library: library).subtracting(known.pendingDeletions)
        journal(missing.compactMap(UUID.init(uuidString:)), as: .pending)
        queueUploads(known.toUpload(library))
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

    /// Removes images deleted in iCloud whose removal here failed before. Their recorded deletions
    /// are forgotten in the same save.
    private func retryRemoteDeletions() {
        guard let known = withJournal(), !known.remoteDeletions.isEmpty else { return }
        let remaining = studio.removeSyncedImages(ids: known.remoteDeletions.compactMap(UUID.init(uuidString:)))
        state.remoteDeletions.formIntersection(remaining.map(\.uuidString))
        persist()
    }

    // MARK: Deletion journal

    /// The sync state with the deletions recorded in the store added: what decides which images are
    /// uploaded, accepted from iCloud and deleted there. `nil` if the store can't be read, as without
    /// it there's no telling which images were deleted.
    private func withJournal() -> LibrarySyncState? {
        do {
            let journal = try LibraryDeletion.all(in: journalContext)
            var known = state
            known.pendingDeletions.formUnion(journal.pending)
            known.remoteDeletions.formUnion(journal.remote)
            return known
        } catch {
            Self.log.error("Couldn't read recorded deletions: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private var hasUnfinishedDeletions: Bool {
        guard state.pendingDeletions.isEmpty, state.remoteDeletions.isEmpty else { return true }
        return ((try? journalContext.fetchCount(FetchDescriptor<LibraryDeletion>())) ?? 1) > 0
    }

    /// Records deletions in the store, or in the sync state if the store can't be saved.
    private func journal(_ ids: [UUID], as kind: LibraryDeletion.Kind) {
        guard !ids.isEmpty else { return }
        do {
            try LibraryDeletion.record(ids, as: kind, in: journalContext)
            try journalContext.save()
        } catch {
            journalContext.rollback()
            Self.log.error("Couldn't record deletions: \(error.localizedDescription, privacy: .public)")
            switch kind {
            case .pending: state.pendingDeletions.formUnion(ids.map(\.uuidString))
            case .remote: state.remoteDeletions.formUnion(ids.map(\.uuidString))
            }
            persist()
        }
    }

    /// Forgets deletions that are finished, wherever they're recorded.
    private func forgetDeletions(_ names: Set<String>, kind: LibraryDeletion.Kind) {
        guard !names.isEmpty else { return }
        switch kind {
        case .pending: state.pendingDeletions.subtract(names)
        case .remote: state.remoteDeletions.subtract(names)
        }
        do {
            try LibraryDeletion.forget(names.compactMap(UUID.init(uuidString:)), kind: kind, in: journalContext)
            try journalContext.save()
        } catch {
            // Only costs a deletion sent again, which finds nothing.
            journalContext.rollback()
            Self.log.error("Couldn't forget finished deletions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets every deletion still to send, when iCloud's contents are forgotten. Returns whether it
    /// did.
    @discardableResult
    private func forgetPendingDeletions() -> Bool {
        state.pendingDeletions = []
        do {
            try LibraryDeletion.forgetAll(.pending, in: journalContext)
            try journalContext.save()
            return true
        } catch {
            journalContext.rollback()
            Self.log.error("Couldn't forget pending deletions: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Moves deletions held in the sync state into the store. Returns whether there are none left
    /// there.
    @discardableResult
    private func journalStateDeletions() -> Bool {
        guard !state.pendingDeletions.isEmpty || !state.remoteDeletions.isEmpty else { return true }
        do {
            try LibraryDeletion.record(state.pendingDeletions.compactMap(UUID.init(uuidString:)), as: .pending, in: journalContext)
            try LibraryDeletion.record(state.remoteDeletions.compactMap(UUID.init(uuidString:)), as: .remote, in: journalContext)
            try journalContext.save()
        } catch {
            // Kept in the sync state, where they count all the same, and moved on a later try.
            journalContext.rollback()
            Self.log.error("Couldn't move deletions into the library: \(error.localizedDescription, privacy: .public)")
            return false
        }
        state.pendingDeletions = []
        state.remoteDeletions = []
        persist()
        return true
    }

    /// Takes on the deletions a library reset set aside for `userID` (see `UnsentDeletions`). Any owed
    /// to another account are dropped. The file goes once they're recorded here, in the store or else
    /// the sync state.
    private func takeUnsentDeletions(for userID: String) {
        guard let unsent = UnsentDeletions.load(from: unsentDeletionsURL) else { return }
        if unsent.accountID == userID {
            state.pendingDeletions.formUnion(unsent.ids)
            guard journalStateDeletions() || persist() else { return }
        } else {
            Self.log.notice("Dropped deletions set aside for another iCloud account")
        }
        do {
            try FileManager.default.removeItem(at: unsentDeletionsURL)
        } catch {
            // Taken on again next time, which changes nothing.
            Self.log.error("Couldn't remove unsent deletions: \(error.localizedDescription, privacy: .public)")
        }
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
                  engine.state.pendingRecordZoneChanges.isEmpty, engine.state.pendingDatabaseChanges.isEmpty,
                  !hasUnfinishedDeletions {
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
            forgetPendingDeletions()
            persist()
            queueLocalImages()
        default:
            // Deleted in Settings (Manage Storage). Uploading again would undo that, so stop instead.
            Self.log.notice("The iCloud zone was deleted; turning sync off")
            state.forgetServer()
            forgetPendingDeletions()
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
        }.filter { !deletedNames.contains($0.id.uuidString) }
        if let known = withJournal() {
            record(studio.addSyncedImages(images.filter { known.accepts($0.id) }))
        } else {
            // There's no telling which were deleted here, so they're fetched again later.
            record(([], [], images.map(\.id)))
        }

        if !deleted.isEmpty {
            // Gone from iCloud, so nothing is owed there; any queued upload is cancelled.
            engine?.state.remove(pendingRecordZoneChanges: deleted.map { .saveRecord(LibraryRecord.recordID(for: $0)) })
            state.uploaded.subtract(deletedNames)
            state.failedDownloads.subtract(deletedNames)
            state.incompleteDownloads.subtract(deletedNames)
            state.pendingDeletions.subtract(deletedNames)
            state.remoteDeletions.subtract(deletedNames)
            // Removed here in the same save that forgets their recorded deletions. Any that couldn't be
            // are recorded as deleted in iCloud, so a failure can't make them look like new images to upload.
            journal(studio.removeSyncedImages(ids: deleted), as: .remote)
        }
        persist()
    }

    private func handleSent(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        state.uploaded.formUnion(changes.savedRecords.compactMap { LibraryRecord.imageID(of: $0.recordID)?.uuidString })
        var deleted = Set(changes.deletedRecordIDs.map(\.recordName))
        state.uploaded.subtract(deleted)

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
                deleted.insert(recordID.recordName)
            } else {
                // Still recorded, so it's queued again when the app is next opened.
                Self.log.error("Couldn't delete \(recordID.recordName, privacy: .public) from iCloud: \(error.localizedDescription, privacy: .public)")
            }
        }
        if syncError?.hasPrefix("Your iCloud storage") == true, changes.failedRecordSaves.isEmpty, !changes.savedRecords.isEmpty {
            syncError = nil
        }
        forgetDeletions(deleted, kind: .pending)
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
            guard let known = withJournal() else { return }
            let decoded = records.compactMap(LibraryRecord.decode)
            for image in decoded where !known.accepts(image.id) {
                state.failedDownloads.remove(image.id.uuidString)
                state.incompleteDownloads.remove(image.id.uuidString)
            }
            let images = decoded.filter { known.accepts($0.id) }
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

    @discardableResult
    private func persist() -> Bool {
        do {
            try state.save(to: stateURL)
            return true
        } catch {
            Self.log.error("Couldn't save sync state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The images the engine asked for, read from the library when it's ready to send them.
    private func record(for recordID: CKRecord.ID, engine syncEngine: CKSyncEngine) -> CKRecord? {
        guard let id = LibraryRecord.imageID(of: recordID), syncEngine === engine, accountConfirmed else { return nil }
        let image = try? context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.id == id })).first
        guard let image, withJournal()?.accepts(id) == true, let record = LibraryRecord.record(for: image) else {
            // Deleted since, or its file is missing: nothing to upload.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return record
    }

    #if DEBUG
    /// For tests: what's remembered between launches.
    var persistedState: LibrarySyncState { state }
    /// For tests: that, with the deletions recorded in the store.
    var knownDeletions: LibrarySyncState? { withJournal() }
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
