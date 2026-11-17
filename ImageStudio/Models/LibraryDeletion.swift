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

    init(imageID: UUID, kind: Kind) {
        self.imageID = imageID
        self.kind = kind.rawValue
    }
}

extension LibraryDeletion {
    /// Records deletions in `context`, without saving it, so they're saved with the change they
    /// describe. An image already deleted in iCloud stays recorded as that: its deletion has nothing
    /// left to tell iCloud.
    static func record(_ ids: some Collection<UUID>, as kind: Kind, in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let ids = Array(Set(ids))
        var known = Dictionary(try context.fetch(FetchDescriptor<LibraryDeletion>(predicate: #Predicate { ids.contains($0.imageID) }))
            .map { ($0.imageID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            if let entry = known[id] {
                if kind == .remote { entry.kind = Kind.remote.rawValue }
            } else {
                let entry = LibraryDeletion(imageID: id, kind: kind)
                context.insert(entry)
                known[id] = entry
            }
        }
    }

    /// Forgets the deletions of these images (only those of `kind`, if given), without saving.
    static func forget(_ ids: some Collection<UUID>, kind: Kind? = nil, in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let ids = Array(Set(ids))
        for entry in try context.fetch(FetchDescriptor<LibraryDeletion>(predicate: #Predicate { ids.contains($0.imageID) }))
        where kind == nil || entry.kind == kind?.rawValue {
            context.delete(entry)
        }
    }

    /// Forgets every deletion of `kind`, without saving.
    static func forgetAll(_ kind: Kind, in context: ModelContext) throws {
        let raw = kind.rawValue
        try context.delete(model: LibraryDeletion.self, where: #Predicate { $0.kind == raw })
    }

    /// Every recorded deletion, by kind, as record names (the images' UUID strings).
    static func all(in context: ModelContext) throws -> (pending: Set<String>, remote: Set<String>) {
        var pending: Set<String> = []
        var remote: Set<String> = []
        for entry in try context.fetch(FetchDescriptor<LibraryDeletion>()) {
            if entry.kind == Kind.remote.rawValue {
                remote.insert(entry.imageID.uuidString)
            } else {
                pending.insert(entry.imageID.uuidString)
            }
        }
        return (pending, remote)
    }
}
