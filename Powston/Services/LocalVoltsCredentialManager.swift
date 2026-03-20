//
//  LocalVoltsCredentialManager.swift
//  Powston
//
//  Keychain wrapper for secure LocalVolts credential storage
//  Credentials are stored per-site using siteId in keychain keys
//  Uses kSecAttrAccessibleAfterFirstUnlock for background access
//

import Foundation
import Security

class LocalVoltsCredentialManager {
    static let shared = LocalVoltsCredentialManager()

    private let service = "com.bollar.powston.localvolts"

    struct Credentials {
        let username: String
        let password: String
    }

    private init() {}

    // MARK: - Per-Site Public API

    func hasCredentials(siteId: Int) -> Bool {
        load(siteId: siteId) != nil
    }

    func save(username: String, password: String, siteId: Int) throws {
        try? delete(siteId: siteId)
        try saveItem(key: "username_\(siteId)", value: username)
        try saveItem(key: "password_\(siteId)", value: password)
    }

    func load(siteId: Int) -> Credentials? {
        // Try per-site credentials first
        if let username = loadItem(key: "username_\(siteId)"),
           let password = loadItem(key: "password_\(siteId)") {
            return Credentials(username: username, password: password)
        }
        // Fall back to legacy global credentials for migration
        return loadLegacy()
    }

    func delete(siteId: Int) throws {
        try deleteItem(key: "username_\(siteId)")
        try deleteItem(key: "password_\(siteId)")
    }

    // MARK: - Legacy Migration

    /// Load from old global keys (no siteId suffix)
    private func loadLegacy() -> Credentials? {
        guard let username = loadItem(key: "username"),
              let password = loadItem(key: "password") else {
            return nil
        }
        return Credentials(username: username, password: password)
    }

    /// Migrate legacy global credentials to a specific site
    func migrateLegacyCredentials(toSiteId siteId: Int) {
        guard let legacy = loadLegacy() else { return }
        // Only migrate if the site doesn't already have per-site credentials
        if loadItem(key: "username_\(siteId)") == nil {
            try? save(username: legacy.username, password: legacy.password, siteId: siteId)
            print("🔑 Migrated legacy LV credentials to site \(siteId)")
        }
    }

    /// Delete legacy global credentials after migration
    func deleteLegacyCredentials() {
        try? deleteItem(key: "username")
        try? deleteItem(key: "password")
    }

    // MARK: - Private Keychain Operations

    private func saveItem(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw CredentialError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            // Note: NOT using kSecAttrSynchronizable - don't sync passwords via iCloud
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Update existing item
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]

            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CredentialError.saveFailed(status: updateStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialError.saveFailed(status: status)
        }
    }

    private func loadItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private func deleteItem(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        // It's OK if the item doesn't exist
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.deleteFailed(status: status)
        }
    }

    // MARK: - Errors

    enum CredentialError: LocalizedError {
        case encodingFailed
        case saveFailed(status: OSStatus)
        case deleteFailed(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode credentials"
            case .saveFailed(let status):
                return "Failed to save credentials (status: \(status))"
            case .deleteFailed(let status):
                return "Failed to delete credentials (status: \(status))"
            }
        }
    }
}
