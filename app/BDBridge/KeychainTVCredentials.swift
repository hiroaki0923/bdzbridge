import Foundation
import RecorderKit
import Security

/// The television's registration in the Keychain: one item, the credentials as JSON.
///
/// Readable after the first unlock, so that the overnight run can send with it while the phone is locked, and
/// kept on this device only: the client id lets anything on the LAN get a cookie from the television without a
/// PIN, so it does not travel with a backup to another phone. A phone restored from one registers again, with
/// the PIN once.
final class KeychainTVCredentials: TVCredentialStore {
    private static let service = "BDBridge.television"
    private static let account = "registration"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() -> TVCredentials? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(TVCredentials.self, from: data)
    }

    func save(_ credentials: TVCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            item.merge(update) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
