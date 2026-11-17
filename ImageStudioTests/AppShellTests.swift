import Foundation
import Security
import SwiftData
import Testing
@testable import ImageStudio

/// A fresh temporary directory, removed when the value is released.
private final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory.appending(path: "ImageStudioTests-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ contents: String, to name: String) throws -> URL {
        let file = url.appending(path: name)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

@Suite("Library store backup")
struct LibraryBackupTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func movesStoreAndCompanionFiles() throws {
        let directory = try TemporaryDirectory()
        let store = try directory.write("db", to: "default.store")
        let shm = try directory.write("shm", to: "default.store-shm")
        let wal = try directory.write("wal", to: "default.store-wal")
        let other = try directory.write("keep", to: "other.store")
        let backups = directory.url.appending(path: "Library Backups")

        let backup = try #require(try LibraryStore.moveStoreFiles(from: store, to: backups, date: date))

        #expect(backup.deletingLastPathComponent().lastPathComponent == "Library Backups")
        for original in [store, shm, wal] { #expect(!exists(original)) }
        #expect(try String(contentsOf: backup.appending(path: "default.store"), encoding: .utf8) == "db")
        #expect(try String(contentsOf: backup.appending(path: "default.store-shm"), encoding: .utf8) == "shm")
        #expect(try String(contentsOf: backup.appending(path: "default.store-wal"), encoding: .utf8) == "wal")
        #expect(exists(other))
    }

    @Test func movesOnlyFilesThatExist() throws {
        let directory = try TemporaryDirectory()
        let store = try directory.write("db", to: "default.store")
        let backups = directory.url.appending(path: "Library Backups")

        let backup = try #require(try LibraryStore.moveStoreFiles(from: store, to: backups, date: date))

        #expect(exists(backup.appending(path: "default.store")))
        #expect(!exists(backup.appending(path: "default.store-wal")))
    }

    @Test func doesNothingWithoutAStore() throws {
        let directory = try TemporaryDirectory()
        let backups = directory.url.appending(path: "Library Backups")

        let backup = try LibraryStore.moveStoreFiles(from: directory.url.appending(path: "default.store"),
                                                     to: backups, date: date)

        #expect(backup == nil)
        #expect(!exists(backups))
    }

    @Test func neverReusesAnExistingBackupFolder() throws {
        let directory = try TemporaryDirectory()
        let backups = directory.url.appending(path: "Library Backups")

        let first = try #require(try LibraryStore.moveStoreFiles(
            from: directory.write("one", to: "default.store"), to: backups, date: date))
        let second = try #require(try LibraryStore.moveStoreFiles(
            from: directory.write("two", to: "default.store"), to: backups, date: date))

        #expect(first != second)
        #expect(try String(contentsOf: first.appending(path: "default.store"), encoding: .utf8) == "one")
        #expect(try String(contentsOf: second.appending(path: "default.store"), encoding: .utf8) == "two")
    }

    @Test func defaultStoreLivesInApplicationSupport() {
        #expect(LibraryStore.defaultStoreURL.lastPathComponent == "default.store")
        #expect(LibraryStore.defaultStoreURL.deletingLastPathComponent().standardizedFileURL
                == URL.applicationSupportDirectory.standardizedFileURL)
        #expect(LibraryStore.backupsDirectory.deletingLastPathComponent().standardizedFileURL
                == URL.applicationSupportDirectory.standardizedFileURL)
    }
}

@Suite("Launch recovery", .serialized)
@MainActor
struct AppModelTests {
    private struct OpenError: Error {}

    private final class Flag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, LibraryDeletion.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func isReady(_ model: AppModel) -> Bool {
        if case .ready = model.state { return true }
        return false
    }

    @Test func opensNormally() throws {
        let model = AppModel(simulatesFailure: false, opener: Self.inMemoryContainer)
        #expect(isReady(model))
        #expect(model.openFailure == nil)
    }

    @Test func showsRecoveryWhenOpeningFailsAndRetries() throws {
        let failure = Flag(true)
        let model = AppModel(simulatesFailure: false) {
            if failure.value { throw OpenError() }
            return try Self.inMemoryContainer()
        }
        #expect(!isReady(model))
        #expect(model.openFailure != nil)

        model.retry()
        #expect(!isReady(model))

        failure.value = false
        model.retry()
        #expect(isReady(model))
        #expect(model.openFailure == nil)
    }

    @Test func resetMovesTheStoreAndOpensAFreshLibrary() throws {
        let directory = try TemporaryDirectory()
        let store = try directory.write("corrupt", to: "default.store")
        let backups = directory.url.appending(path: "Library Backups")
        let model = AppModel(simulatesFailure: true, storeURL: store, backupsDirectory: backups,
                             opener: Self.inMemoryContainer)
        #expect(!isReady(model))

        model.retry()
        #expect(!isReady(model), "A simulated failure persists until the library is reset.")

        model.resetLibrary()

        #expect(isReady(model))
        #expect(model.resetFailure == nil)
        #expect(!exists(store))
        let folders = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(folders.count == 1)
        #expect(exists(try #require(folders.first).appending(path: "default.store")))
    }

    @Test func failedResetReportsAndLeavesTheStoreInPlace() throws {
        let directory = try TemporaryDirectory()
        let store = try directory.write("corrupt", to: "default.store")
        // A file where the backups folder should be makes the move impossible.
        let backups = try directory.write("in the way", to: "Library Backups")
        let model = AppModel(simulatesFailure: true, storeURL: store, backupsDirectory: backups,
                             opener: Self.inMemoryContainer)

        model.resetLibrary()

        #expect(!isReady(model))
        #expect(model.resetFailure != nil)
        #expect(exists(store))
    }
}

@Suite("Keychain accessibility", .serialized)
@MainActor
struct KeychainAccessibilityTests {
    private static func newService() -> String { "com.eyeb0l.ImageStudio.tests.\(UUID().uuidString)" }

    private func query(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "openai-api-key",
        ]
    }

    private func add(_ data: Data, service: String, accessible: CFString) {
        var attributes = query(service)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = accessible
        #expect(SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess)
    }

    private func accessibility(_ service: String) -> String? {
        var query = query(service)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }

    @Test func newKeysAreReadableAfterFirstUnlock() throws {
        let service = Self.newService()
        let store = APIKeyStore(service: service)
        try store.save("sk-test-1111")
        defer { try? store.remove() }

        #expect(accessibility(service) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func migratesExistingKeys() throws {
        let service = Self.newService()
        add(Data("sk-test-3333".utf8), service: service, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(accessibility(service) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        let store = APIKeyStore(service: service)
        defer { try? store.remove() }

        #expect(accessibility(service) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(store.key() == "sk-test-3333")
        #expect(store.isConfigured)
    }

    @Test func migrationWithoutAKeyIsHarmless() {
        let store = APIKeyStore(service: Self.newService())
        #expect(!store.isConfigured)
        #expect(store.readError == nil)
    }

    @Test func unreadableKeyIsAnErrorNotAMissingKey() throws {
        let service = Self.newService()
        add(Data([0xFF, 0xFE, 0xFD]), service: service, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        let store = APIKeyStore(service: service)
        defer { try? store.remove() }

        #expect(!store.isConfigured)
        #expect(store.readError != nil)
        #expect(throws: (any Error).self) { try store.loadKey() }

        // Saving a new key replaces the unreadable one and clears the error.
        try store.save("sk-test-4444")
        #expect(store.readError == nil)
        #expect(store.isConfigured)
        #expect(store.key() == "sk-test-4444")
    }

    @Test func reloadClearsAResolvedError() throws {
        let service = Self.newService()
        add(Data([0xFF, 0xFE]), service: service, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        let store = APIKeyStore(service: service)
        #expect(store.readError != nil)

        try Keychain.delete(service: service, account: "openai-api-key")
        store.reload()

        #expect(store.readError == nil)
        #expect(!store.isConfigured)
    }
}

@Suite("Missing image files", .serialized)
@MainActor
struct MissingFileTests {
    private func makeImage(fileName: String) -> GeneratedImage {
        GeneratedImage(prompt: "test", settings: GenerationSettings(), width: 64, height: 64, fileName: fileName,
                       fileSize: 3, batchID: UUID(), duration: 1)
    }

    @Test func reportsMissingFilesAndFailsToCopy() {
        let image = makeImage(fileName: "ImageStudio-missing-\(UUID().uuidString).png")
        #expect(!image.fileIsAvailable)
        #expect(!image.copyToPasteboard())
    }

    @Test func reportsPresentFiles() throws {
        let name = "ImageStudio-test-\(UUID().uuidString).png"
        let image = makeImage(fileName: name)
        try Data([1, 2, 3]).write(to: image.fileURL)
        defer { try? ImageStore.delete(fileName: name) }

        #expect(image.fileIsAvailable)
        #expect(image.copyToPasteboard())
    }
}
