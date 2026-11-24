import Foundation
import RecBridgeModel
import RecorderKit

/// The television's registration in the Keychain: one item, readable after the first unlock and on this device
/// only, holding the credentials' JSON sealed with a key kept in a file of the app's own (`SealedKeychainItem`,
/// which says how the item is kept and read). The file goes when the app is deleted, and with it the only way to
/// open what the Keychain may keep. The helper's token is kept apart from it, with a key of its own
/// (`KeychainTVHelperToken`).
///
/// Readable after the first unlock, so that the overnight run and the Shortcuts action can send with it while the
/// phone is locked, and kept on this device only: the client id lets anything on the LAN get a cookie from the
/// television without a PIN, so it does not travel with a backup to another phone. A phone restored from one
/// registers again, with the PIN once.
///
/// Reading never writes and never deletes. An item that does not open with the key -- one sealed with a key that
/// has gone, or the plain JSON that builds before this one wrote -- reads as no registration, so its client id is
/// never used again, and stays until a registration writes over it.
final class KeychainTVCredentials: TVCredentialStore {
    private static let account = "registration"

    private let item: SealedKeychainItem
    /// Where the key is kept: `Application Support/television.key` in the app. Backed up with the app's data, so
    /// that a restore to the same phone, which brings the item back, can open it; on another phone there is no
    /// item for it to open. Not in the guide's folder, which is left out of backups, nor in Caches or tmp, which
    /// the system empties.
    let keyFile: URL

    /// `service`, `keyFile`: the app's own by default; a test's throwaway ones in `BDBridgeTests`.
    init(service: String = "BDBridge.television", keyFile: URL? = nil) {
        self.keyFile = keyFile ?? URL.applicationSupportDirectory.appendingPathComponent("television.key")
        item = SealedKeychainItem(service: service, account: Self.account, keyFile: self.keyFile)
    }

    func load() -> TVCredentials? {
        guard let json = item.load() else { return nil }
        return try? JSONDecoder().decode(TVCredentials.self, from: json)
    }

    func save(_ credentials: TVCredentials) {
        guard let json = try? JSONEncoder().encode(credentials) else { return }
        item.save(json)
    }

    func remove() {
        item.remove()
    }
}
