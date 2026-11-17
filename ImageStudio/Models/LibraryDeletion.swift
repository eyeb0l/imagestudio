import Foundation
import SwiftData

/// A deletion iCloud Sync hasn't finished yet (see `LibrarySync`), kept in the library's own store.
///
/// It's saved with the change it records: deleting an image here and recording that iCloud has to be
/// told is one save, as is removing an image deleted in iCloud and forgetting it. So the library and
/// its deletions can't disagree, whatever happens to the sync state file, and a deleted image can't
/// come back from iCloud.
@Model
final class LibraryDeletion {
    nonisolated enum Kind: String, Sendable {
        /// Deleted on this device, until iCloud confirms it's gone there too.
        case pending
        /// Deleted in iCloud, and still to be removed from this library. Never uploaded again.
        case remote
    }

    @Attribute(.unique) var imageID: UUID
    /// A `Kind`'s raw value.
    var kind: String
    /// For a pending deletion, the iCloud account (user record name) it's owed to: the one the library
    /// synced with when the image was deleted. It's only ever sent there, so it can't delete another
    /// account's copy. `nil` if the library synced with none, and then it's never sent. Either way it
    /// keeps the image out of this library.
    var accountID: String?

    init(imageID: UUID, kind: Kind, accountID: String? = nil) {
        self.imageID = imageID
        self.kind = kind.rawValue
        self.accountID = kind == .pending ? accountID : nil
    }
}

extension LibraryDeletion {
    /// What's recorded, by record name (the image's UUID string).
    nonisolated struct Summary: Sendable {
        /// Every image deleted here that iCloud hasn't confirmed.
        var pending: Set<String> = []
        /// Those, by the account they're owed to.
        var owed: [String: Set<String>] = [:]
        var remote: Set<String> = []
    }

    /// Records deletions in `context`, without saving it, so they're saved with the change they
    /// describe. A pending deletion is owed to `accountID`. One already recorded stays as it is: a
    /// pending one is never in the library, so has nothing to remove here, and keeps its account.
    static func record(_ ids: some Collection<UUID>, as kind: Kind, owedTo accountID: String? = nil,
                       in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let ids = Array(Set(ids))
        let known = Set(try context.fetch(FetchDescriptor<LibraryDeletion>(predicate: #Predicate { ids.contains($0.imageID) })).map(\.imageID))
        for id in ids where !known.contains(id) {
            context.insert(LibraryDeletion(imageID: id, kind: kind, accountID: accountID))
        }
    }

    /// Forgets the deletions of these images that `accountID` has finished, without saving: those of
    /// `kind` (both if `nil`), but of pending ones only those owed to `accountID`. The others are
    /// still owed to another account, or to none, and keep the images out of this library.
    static func forget(_ ids: some Collection<UUID>, kind: Kind? = nil, finishedBy accountID: String?,
                       in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let ids = Array(Set(ids))
        for entry in try context.fetch(FetchDescriptor<LibraryDeletion>(predicate: #Predicate { ids.contains($0.imageID) }))
        where kind == nil || entry.kind == kind?.rawValue {
            guard entry.kind == Kind.remote.rawValue || entry.accountID == accountID else { continue }
            context.delete(entry)
        }
    }

    /// Forgets the pending deletions owed to `accountID`, without saving.
    static func forgetPending(owedTo accountID: String, in context: ModelContext) throws {
        let pending = Kind.pending.rawValue
        try context.delete(model: LibraryDeletion.self, where: #Predicate { $0.kind == pending && $0.accountID == accountID })
    }

    static func all(in context: ModelContext) throws -> Summary {
        var summary = Summary()
        for entry in try context.fetch(FetchDescriptor<LibraryDeletion>()) {
            let name = entry.imageID.uuidString
            if entry.kind == Kind.remote.rawValue {
                summary.remote.insert(name)
            } else {
                summary.pending.insert(name)
                if let account = entry.accountID { summary.owed[account, default: []].insert(name) }
            }
        }
        return summary
    }
}
