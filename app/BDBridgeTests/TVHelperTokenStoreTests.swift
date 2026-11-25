import Foundation
import RecBridgeModel
import RecorderKit
import Security
import XCTest
@testable import BDBridge

/// Where the app keeps the helper's token (`KeychainTVHelperToken`): sealed in the Keychain with a key of its own,
/// kept in a file of the app's own, so that deleting the app, which deletes the file, leaves nothing anybody can
/// use, and apart from the television's registration, so that either goes without the other. Like
/// `TVCredentialStoreTests`, these reach the simulator's own Keychain, under a service of the test's own, and key
/// files in a folder of the test's own, all removed when the test ends. Deleting the key file is what deleting the
/// app does to the key. The app's own items and key files are never read or written.
///
/// How the seal itself reads and writes the key -- a key file that cannot be read, one of another length, one
/// that cannot be written -- is `SealedKeychainItem`'s, held by `TVCredentialStoreTests`; these hold what is the
/// token's own. What a simulator cannot show is left to a phone, as there.
final class TVHelperTokenStoreTests: XCTestCase {
    /// What the app keeps the token under, as builds before the seal wrote it, for planting one.
    private static let account = "helper"

    private static let token = "test-helper-token-0123456789abcdef"
    private static let another = "test-helper-token-fedcba9876543210"

    private static let registration = TVCredentials(clientID: "BDBridge:test-registration", cookie: "kept-cookie",
                                                    cookieReceived: Date(timeIntervalSince1970: 1_790_000_000),
                                                    cookieMaxAge: 1_209_600)

    /// Saved, it loads back as it was; what the Keychain holds is neither the token's bytes nor anything that
    /// contains them.
    func testATokenSavedLoadsBackAndIsNotKeptAsItsBytes() throws {
        let kept = try aKeychain()

        kept.store.save(Self.token)

        XCTAssertEqual(kept.store.load(), Self.token)
        let item = try XCTUnwrap(kept.item(), "nothing was saved")
        XCTAssertNotEqual(item, Data(Self.token.utf8), "the item is the token")
        XCTAssertNil(item.range(of: Data(Self.token.utf8)), "the token is in the item")
        XCTAssertEqual(try kept.key()?.count, 32)
    }

    /// The key file gone, as deleting the app takes it: the item left behind is still there and loads as
    /// nothing, and a registration with the helper then makes a new key and writes over it.
    func testWithTheKeyGoneTheItemLeftBehindOpensForNobody() throws {
        let kept = try aKeychain()
        kept.store.save(Self.token)
        let leftBehind = try XCTUnwrap(kept.item())
        let goneKey = try XCTUnwrap(kept.key(), "the save wrote no key")

        try FileManager.default.removeItem(at: kept.keyFile)

        XCTAssertNil(kept.store.load(), "an item opened with its key gone")
        XCTAssertEqual(kept.item(), leftBehind, "a read changed the item")
        XCTAssertFalse(kept.keyIsThere, "a read wrote a key")

        kept.store.save(Self.another)

        let newKey = try XCTUnwrap(kept.key(), "the save wrote no key")
        XCTAssertEqual(newKey.count, 32)
        XCTAssertNotEqual(newKey, goneKey)
        XCTAssertNotEqual(kept.item(), leftBehind, "the item left behind was not written over")
        XCTAssertEqual(KeychainTVHelperToken(service: kept.service, keyFile: kept.keyFile).load(), Self.another)
    }

    /// The plain token builds before the seal wrote reads as none, with no key and with one, and a read changes
    /// nothing; a registration then writes over it, sealed, and that loads back.
    func testThePlainTokenEarlierBuildsWroteReadsAsNoneAndIsLeftForTheNextRegistration() throws {
        let kept = try aKeychain()
        try kept.plantThePlainToken(Self.token)
        let planted = try XCTUnwrap(kept.item())

        XCTAssertNil(kept.store.load(), "the plain token was read")
        XCTAssertEqual(kept.item(), planted, "a read changed the item")
        XCTAssertFalse(kept.keyIsThere, "a read wrote a key")

        kept.store.save(Self.another)

        XCTAssertEqual(try kept.key()?.count, 32)
        let sealed = try XCTUnwrap(kept.item())
        XCTAssertNotEqual(sealed, planted)
        XCTAssertNil(sealed.range(of: Data(Self.another.utf8)), "the token was written in plain")
        XCTAssertEqual(kept.store.load(), Self.another)

        // A plain token again, over the sealed item, with the key on disk.
        try kept.plantThePlainToken(Self.token)
        let plantedAgain = try XCTUnwrap(kept.item())
        XCTAssertNil(kept.store.load(), "the plain token was read with a key on disk")
        XCTAssertEqual(kept.item(), plantedAgain, "a read with a key on disk changed the item")
    }

    /// A save with a key on disk seals with that key and writes no other, so that a registration made again is
    /// opened by the key already there.
    func testASaveWithAKeyOnDiskKeepsThatKey() throws {
        let kept = try aKeychain()
        kept.store.save(Self.token)
        let key = try XCTUnwrap(kept.key())

        kept.store.save(Self.another)

        XCTAssertEqual(try kept.key(), key, "a save with a key on disk wrote another")
        XCTAssertEqual(kept.store.load(), Self.another)
    }

    /// ヘルパーの登録を解除 leaves neither the item nor the key.
    func testRemoveLeavesNeitherTheItemNorTheKey() throws {
        let kept = try aKeychain()
        kept.store.save(Self.token)

        kept.store.remove()

        XCTAssertNil(kept.item(), "the item is still there")
        XCTAssertFalse(kept.keyIsThere, "the key file is still there")
        XCTAssertNil(kept.store.load())
    }

    /// ヘルパーの登録を解除 takes the token alone: the television's registration, kept under the same service
    /// with a key of its own, still loads, and its key file is still there.
    func testRemovingTheTokenLeavesTheTelevisionsRegistration() throws {
        let kept = try aKeychain()
        let registrations = kept.registrations()
        registrations.save(Self.registration)
        kept.store.save(Self.token)

        kept.store.remove()

        XCTAssertNil(kept.store.load())
        XCTAssertEqual(registrations.load(), Self.registration, "the registration went with the token")
        XCTAssertTrue(FileManager.default.fileExists(atPath: registrations.keyFile.path),
                      "the registration's key went with the token's")
    }

    /// The television's registration removed, the token kept under the same service with a key of its own still
    /// loads, and its key file is still there.
    func testRemovingTheTelevisionsRegistrationLeavesTheToken() throws {
        let kept = try aKeychain()
        let registrations = kept.registrations()
        registrations.save(Self.registration)
        kept.store.save(Self.token)

        registrations.remove()

        XCTAssertNil(registrations.load())
        XCTAssertEqual(kept.store.load(), Self.token, "the token went with the registration")
        XCTAssertTrue(kept.keyIsThere, "the token's key went with the registration's")
    }

    /// The item is readable after the first unlock and stays on this device; the app's key file is in
    /// Application Support itself, as the registration's is, and is not the registration's.
    func testTheItemStaysOnThisPhoneAndTheKeyIsTheTokensOwn() throws {
        let kept = try aKeychain()
        kept.store.save(Self.token)

        let attributes = try XCTUnwrap(kept.itemAttributes())
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        let appsKey = KeychainTVHelperToken().keyFile
        XCTAssertEqual(appsKey.lastPathComponent, "television-helper.key")
        XCTAssertEqual(appsKey.deletingLastPathComponent().standardizedFileURL.path,
                       URL.applicationSupportDirectory.standardizedFileURL.path)
        XCTAssertNotEqual(appsKey.standardizedFileURL.path,
                          KeychainTVCredentials().keyFile.standardizedFileURL.path)
    }

    // MARK: - the test's own Keychain service and key files

    /// A store on a Keychain service and a key file of this test's own, both removed when it ends.
    private func aKeychain() throws -> ThrowawayKeychain {
        let kept = try ThrowawayKeychain()
        addTeardownBlock { kept.throwAway() }
        return kept
    }

    private struct ThrowawayKeychain {
        let service = "BDBridgeTests.television-\(UUID().uuidString)"
        let folder: URL
        let keyFile: URL
        let store: KeychainTVHelperToken

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("BDBridgeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            keyFile = folder.appendingPathComponent("television-helper.key")
            store = KeychainTVHelperToken(service: service, keyFile: keyFile)
        }

        /// The television's registration, under the same service and with a key file of its own in the same
        /// folder, as the app keeps the two.
        func registrations() -> KeychainTVCredentials {
            KeychainTVCredentials(service: service, keyFile: folder.appendingPathComponent("television.key"))
        }

        private var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: TVHelperTokenStoreTests.account]
        }

        /// The item's data as the Keychain holds it.
        func item() -> Data? {
            var search = query
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess else { return nil }
            return found as? Data
        }

        func itemAttributes() -> [String: Any]? {
            var search = query
            search[kSecReturnAttributes as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess else { return nil }
            return found as? [String: Any]
        }

        /// The token's UTF-8 bytes as the item, written as builds before the seal wrote it.
        func plantThePlainToken(_ token: String) throws {
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainFailed(status: status) }
        }

        func key() throws -> Data? {
            keyIsThere ? try Data(contentsOf: keyFile) : nil
        }

        var keyIsThere: Bool {
            FileManager.default.fileExists(atPath: keyFile.path)
        }

        /// Every item under the test's service, the registration's among them, and the folder with both keys.
        func throwAway() {
            try? FileManager.default.removeItem(at: folder)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
    }

    private struct KeychainFailed: Error {
        let status: OSStatus
    }
}
