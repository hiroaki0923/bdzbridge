import Foundation
import RecBridgeModel
import RecorderKit

/// The token the helper on the television handed out at registration, in the Keychain: one item, readable after
/// the first unlock and on this device only, holding the token sealed with a key of its own kept in a file of the
/// app's own (`SealedKeychainItem`, which says how the item is kept and read). The token lets anything on the LAN
/// read the television's guide and what the helper tells of the television and of itself, and nothing else.
///
/// Readable after the first unlock, so that the overnight run can fetch the television's guide with it while the
/// phone is locked, and kept on this device only, so that it does not travel with a backup to another phone. An
/// item left behind by a deleted app opens for nobody, the next install of the app included, which registers with
/// the helper again by the number the helper shows on the television.
///
/// A key of its own, apart from the television's registration's (`KeychainTVCredentials`), because the two are
/// removed apart: ヘルパーの登録を解除 removes the token alone, and removing either leaves the other as it was.
///
/// Reading never writes and never deletes. A token that does not open with the key -- one sealed with a key that
/// has gone, or the plain token that builds before this one wrote -- reads as none, and stays until a registration
/// writes over it.
final class KeychainTVHelperToken: TVHelperTokenStore {
    private static let account = "helper"

    private let item: SealedKeychainItem
    /// Where the key is kept: `Application Support/television-helper.key` in the app, beside the registration's
    /// and for the same reasons (`KeychainTVCredentials.keyFile`).
    let keyFile: URL

    /// `service`, `keyFile`: the app's own by default; a test's throwaway ones in `BDBridgeTests`.
    init(service: String = "BDBridge.television", keyFile: URL? = nil) {
        self.keyFile = keyFile ?? URL.applicationSupportDirectory.appendingPathComponent("television-helper.key")
        item = SealedKeychainItem(service: service, account: Self.account, keyFile: self.keyFile)
    }

    func load() -> String? {
        guard let data = item.load() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        item.save(Data(token.utf8))
    }

    func remove() {
        item.remove()
    }
}
