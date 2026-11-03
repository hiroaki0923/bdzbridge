import Foundation
import RecorderKit
import Security

/// The token the helper on the television handed out at registration, in the Keychain: one item, readable after
/// the first unlock and on this device only, so that it neither travels with a backup to another phone nor is
/// read before the phone has been unlocked. It lets anything on the LAN read the television's guide, and nothing
/// else; the television's own registration is kept apart from it, sealed (`KeychainTVCredentials`).
final class KeychainTVHelperToken: TVHelperTokenStore {
    private let service: String
    private static let account = "helper"

    /// `service`: the app's own by default; a test's throwaway one in `BDBridgeTests`.
    init(service: String = "BDBridge.television") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    func load() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        let update: [String: Any] = [kSecValueData as String: Data(token.utf8),
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
