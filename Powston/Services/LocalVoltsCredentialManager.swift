//
//  LocalVoltsCredentialManager.swift
//  Powston
//
//  Keychain wrapper for secure LocalVolts credential storage
//  Uses kSecAttrAccessibleAfterFirstUnlock for background access
//

import Foundation
import Security

class LocalVoltsCredentialManager {
    static let shared = LocalVoltsCredentialManager()

    private let service = "com.bollar.powston.localvolts"
    private let usernameKey = "username"
    private let passwordKey = "password"

    struct Credentials {
        let username: String
        let password: String
    }

    private init() {}

    // MARK: - Public API

    var hasCredentials: Bool {
        load() != nil
    }

    func save(username: String, password: String) throws {
        // Delete existing credentials first
        try? delete()

        // Save username
        try saveItem(key: usernameKey, value: username)

        // Save password
        try saveItem(key: passwordKey, value: password)
    }

    func load() -> Credentials? {
        guard let username = loadItem(key: usernameKey),
              let password = loadItem(key: passwordKey) else {
            return nil
        }
        return Credentials(username: username, password: password)
    }

    func delete() throws {
        try deleteItem(key: usernameKey)
        try deleteItem(key: passwordKey)
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
