import CryptoKit
import Foundation
import Security

/// One Keychain item, readable after the first unlock and on this device only, holding data sealed (AES-GCM,
/// CryptoKit) with a key kept in a file of the app's own. The file goes when the app is deleted, and with it the
/// only way to open what the Keychain may keep. What becomes of a Keychain item when its app is deleted Apple
/// documents neither way; the key file is the app's data, which goes with it, so an item left behind opens for
/// nobody, the next install of the app included. The television's registration and the helper's token are each
/// kept in one, with a key file of its own (`KeychainTVCredentials`, `KeychainTVHelperToken`).
///
/// Reading never writes and never deletes. Before the first unlock neither the item nor the key can be read, and
/// that reads as nothing with nothing touched. An item that does not open with the key -- one sealed with a key
/// that has gone, or one written in plain -- reads as nothing as well, and stays until a save writes over it.
struct SealedKeychainItem: Sendable {
    private static let keyBytes = 32

    let service: String
    let account: String
    let keyFile: URL

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> Data? {
        guard case .key(let key) = readKey() else { return nil }
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let sealed = found as? Data,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return data
    }

    /// With no key, a key is made and written first, and the item only once it is on disk: an item that no key
    /// on disk opens has lost what it held. A key that cannot be written leaves the item as it was. A key file
    /// that cannot be read holds everything as it is.
    func save(_ data: Data) {
        let key: SymmetricKey
        switch readKey() {
        case .key(let kept):
            key = kept
        case .unreadable:
            return
        case .none:
            let made = SymmetricKey(size: .bits256)
            guard write(made) else { return }
            key = made
        }
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        let update: [String: Any] = [kSecValueData as String: sealed,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            item.merge(update) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    /// Deletes the item and the key file.
    func remove() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: keyFile)
    }

    /// What the key file holds. No file, or one read whole that is not a key's length -- a write cut short,
    /// which nothing was sealed with -- is no key, and the next save writes one. A file that cannot be read,
    /// before the first unlock or for its permissions, is not the same: what it holds may be what opens the item.
    private enum Key {
        case key(SymmetricKey)
        case none
        case unreadable
    }

    private func readKey() -> Key {
        let data: Data
        do {
            data = try Data(contentsOf: keyFile)
        } catch CocoaError.fileReadNoSuchFile {
            return .none
        } catch {
            return .unreadable
        }
        return data.count == Self.keyBytes ? .key(SymmetricKey(data: data)) : .none
    }

    /// Atomically, so that a key is on disk whole or not at all, and with the protection files have by default
    /// made explicit: readable once the phone has been unlocked after a restart, as the item is.
    private func write(_ key: SymmetricKey) -> Bool {
        let bytes = key.withUnsafeBytes { Data($0) }
        do {
            try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: keyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}
