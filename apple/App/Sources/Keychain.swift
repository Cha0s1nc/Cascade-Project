import Foundation
import Security

// The access token goes in the Keychain, not UserDefaults. UserDefaults is a
// plist in the app container: readable from an unencrypted backup and from
// anything that can reach the filesystem. A Jellyfin token is a bearer
// credential for the whole account, so it gets the same treatment a password
// would.

#if os(macOS)
/// On the Mac the token is a 0600 file in Application Support, not a Keychain
/// item. The app is ad-hoc signed and the signature changes with every update,
/// so the legacy file keychain would prompt after each one, and the
/// data-protection keychain needs a team-signed build. Electron keeps the
/// token in config.json today, so this is no weaker than what it replaces.
enum Keychain {
    private static func file(_ account: String) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "xyz.chaosinc.cascade", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appending(path: "\(account).secret")
    }

    static func set(_ value: String, for account: String) {
        let url = file(account)
        // Created 0600 before the secret is written, so it is never readable by others.
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? Data(value.utf8).write(to: url)
    }

    static func get(_ account: String) -> String? {
        (try? Data(contentsOf: file(account))).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func remove(_ account: String) {
        try? FileManager.default.removeItem(at: file(account))
    }
}
#else
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
#endif
