import Foundation
import Security

// The access token goes in the Keychain, not UserDefaults. UserDefaults is a
// plist in the app container: readable from an unencrypted backup and from
// anything that can reach the filesystem. A Jellyfin token is a bearer
// credential for the whole account, so it gets the same treatment a password
// would.

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.chaosinc.cascade",
            kSecAttrAccount as String: account,
        ]
    }

    static func set(_ value: String, for account: String) {
        // Delete first rather than trying update-then-add: SecItemUpdate needs a
        // different query shape and this is one call either way.
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        // Only readable once the device has been unlocked at least once since
        // boot, and never migrated to a new device by a backup.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
