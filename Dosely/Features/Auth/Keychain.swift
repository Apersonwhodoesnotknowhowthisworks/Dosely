import Foundation
import Security

// Thin wrapper around the iOS keychain for a fixed set of small strings.
// We deliberately never store passwords here; only the biometric flag, last-
// used email, and the refreshed Firebase ID token.
enum KeychainKey: String {
    case biometricEnabled = "dosely.biometric_enabled"
    case lastEmail        = "dosely.last_email"
    case idToken          = "dosely.id_token"
}

enum Keychain {
    @discardableResult
    static func set(_ value: String, for key: KeychainKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.placeholder.dosely",
            kSecAttrAccount as String: key.rawValue
        ]
        let attrs: [String: Any] = [
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attrs) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.placeholder.dosely",
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.placeholder.dosely",
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func setBool(_ value: Bool, for key: KeychainKey) {
        set(value ? "1" : "0", for: key)
    }

    static func getBool(_ key: KeychainKey) -> Bool {
        get(key) == "1"
    }
}
