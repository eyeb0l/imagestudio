import Foundation
import Observation
import Security

/// Minimal wrapper around generic-password Keychain items.
nonisolated enum Keychain {
    struct Error: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }

    static func read(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Error(status: status)
        }
    }

    static func save(_ value: String, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Readable only while unlocked, never synced to iCloud or restored to another device.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error(status: addStatus) }
        } else if status != errSecSuccess {
            throw Error(status: status)
        }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error(status: status) }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Observable access to the OpenAI API key. The key itself is only read from the
/// Keychain when needed and is never kept in memory by this object.
@Observable
final class APIKeyStore {
    private(set) var isConfigured = false
    private(set) var maskedKey: String?

    @ObservationIgnored private let service: String
    @ObservationIgnored private let account = "openai-api-key"

    init(service: String = "com.eyeb0l.ImageStudio.openai") {
        self.service = service
        refresh()
    }

    func key() -> String? {
        try? loadKey()
    }

    /// Reads the key, distinguishing "no key stored" (`nil`) from a Keychain failure (throws),
    /// e.g. when the device is locked.
    func loadKey() throws -> String? {
        try Keychain.read(service: service, account: account)
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try Keychain.save(trimmed, service: service, account: account)
        refresh()
    }

    func remove() throws {
        try Keychain.delete(service: service, account: account)
        refresh()
    }

    private func refresh() {
        let key = key()
        isConfigured = key != nil
        maskedKey = key.map(Self.mask)
    }

    /// "sk-proj-abcdef…wxyz" → "sk-proj-••••wxyz"
    nonisolated static func mask(_ key: String) -> String {
        let prefix = ["sk-proj-", "sk-svcacct-", "sk-admin-", "sk-"].first { key.hasPrefix($0) } ?? ""
        return prefix + "••••" + String(key.suffix(4))
    }
}
