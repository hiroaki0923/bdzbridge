import Foundation
import RecorderKit
import Security
import XCTest
@testable import BDBridge

/// Where the app keeps the television's registration (`KeychainTVCredentials`): sealed in the Keychain with a key
/// kept in a file of the app's own, so that deleting the app, which deletes the file, leaves nothing anybody can
/// use. These are the one place a test reaches the simulator's own: its Keychain, under a service of the test's
/// own, and a key file in a folder of the test's own, both removed when the test ends. Deleting that file is what
/// deleting the app does to the key. The app's own item and key file are never read or written.
///
/// What a simulator cannot show is left to a phone: the key file's protection, and a read before the first unlock
/// after a restart, which it and the Keychain both refuse there; the app deleted and installed again; a restore.
final class TVCredentialStoreTests: XCTestCase {
    /// What the app keeps the registration under, as builds before the seal wrote it, for planting one.
    private static let account = "registration"

    private static let registration = TVCredentials(clientID: "BDBridge:test-registration", cookie: "kept-cookie",
                                                    cookieReceived: Date(timeIntervalSince1970: 1_790_000_000),
                                                    cookieMaxAge: 1_209_600)
    private static let another = TVCredentials(clientID: "BDBridge:test-another", cookie: "another-cookie",
                                               cookieReceived: Date(timeIntervalSince1970: 1_790_100_000),
                                               cookieMaxAge: 1_209_600)

    /// Saved, it loads back as it was; what the Keychain holds is neither its JSON nor anything that names its
    /// client id or its cookie.
    func testWhatIsSavedLoadsBackAndIsNotKeptAsItsJSON() throws {
        let kept = try aKeychain()

        kept.store.save(Self.registration)

        XCTAssertEqual(kept.store.load(), Self.registration)
        let item = try XCTUnwrap(kept.item(), "nothing was saved")
        XCTAssertNil(try? JSONDecoder().decode(TVCredentials.self, from: item), "the item is the JSON")
        XCTAssertNil(item.range(of: Data(Self.registration.clientID.utf8)), "the client id is in the item")
        XCTAssertNil(item.range(of: Data("kept-cookie".utf8)), "the cookie is in the item")
        XCTAssertEqual(try kept.key()?.count, 32)
    }

    /// The key file gone, as deleting the app takes it: the item left behind loads as nothing, and is left as it
    /// was, though the same store opened it a moment before. A registration then makes a new key and writes over
    /// that item, and a store made afresh opens it.
    func testWithTheKeyGoneTheItemLeftBehindOpensForNobodyAndASaveStartsAfresh() throws {
        let kept = try aKeychain()
        kept.store.save(Self.registration)
        XCTAssertEqual(kept.store.load(), Self.registration)
        let leftBehind = try XCTUnwrap(kept.item())
        let goneKey = try XCTUnwrap(kept.key())

        try FileManager.default.removeItem(at: kept.keyFile)

        XCTAssertNil(kept.store.load(), "an item opened with its key gone")
        XCTAssertEqual(kept.item(), leftBehind, "a read changed the item")
        XCTAssertFalse(kept.keyIsThere, "a read wrote a key")

        kept.store.save(Self.another)

        let newKey = try XCTUnwrap(kept.key(), "the save wrote no key")
        XCTAssertEqual(newKey.count, 32)
        XCTAssertNotEqual(newKey, goneKey)
        XCTAssertNotEqual(kept.item(), leftBehind, "the item left behind was not written over")
        XCTAssertEqual(kept.store.load(), Self.another)
        XCTAssertEqual(KeychainTVCredentials(service: kept.service, keyFile: kept.keyFile).load(), Self.another)
    }

    /// The item builds before the seal wrote -- the credentials' JSON, as a TestFlight build kept them -- reads as
    /// no registration, with no key and with one, and a read changes nothing: no key is written and the item stays
    /// as it is. A registration then writes over it, sealed, and that loads back.
    func testThePlainItemEarlierBuildsWroteReadsAsNoneAndIsLeftForTheNextRegistration() throws {
        let kept = try aKeychain()
        try kept.plantThePlainItem(Self.registration)
        let planted = try XCTUnwrap(kept.item())

        XCTAssertNil(kept.store.load(), "the plain item was read")
        XCTAssertEqual(kept.item(), planted, "a read changed the item")
        XCTAssertFalse(kept.keyIsThere, "a read wrote a key")

        kept.store.save(Self.another)

        XCTAssertEqual(try kept.key()?.count, 32)
        let sealed = try XCTUnwrap(kept.item())
        XCTAssertNotEqual(sealed, planted)
        XCTAssertNil(sealed.range(of: Data(Self.another.clientID.utf8)), "the item was written in plain")
        XCTAssertEqual(kept.store.load(), Self.another)

        // An earlier build's registration again, over the sealed item, with the key on disk.
        try kept.plantThePlainItem(Self.registration)
        let plantedAgain = try XCTUnwrap(kept.item())
        XCTAssertNil(kept.store.load(), "the plain item was read with a key on disk")
        XCTAssertEqual(kept.item(), plantedAgain, "a read with a key on disk changed the item")
    }

    /// テレビを外す leaves neither the item nor the key.
    func testRemoveLeavesNeitherTheItemNorTheKey() throws {
        let kept = try aKeychain()
        kept.store.save(Self.registration)

        kept.store.remove()

        XCTAssertNil(kept.item(), "the item is still there")
        XCTAssertFalse(kept.keyIsThere, "the key file is still there")
        XCTAssertNil(kept.store.load())
    }

    /// The item is readable after the first unlock and stays on this device; the app's key file is in
    /// Application Support itself -- not in the guide's folder, which is left out of backups, nor in Caches or
    /// tmp -- and a key file is not marked to be left out of backups. Its protection is not held here: the
    /// simulator enforces none, and reports the default whatever protection the file was written with.
    func testTheItemStaysOnThisPhoneAndTheKeyIsKeptWithTheAppsData() throws {
        let kept = try aKeychain()
        kept.store.save(Self.registration)

        let attributes = try XCTUnwrap(kept.itemAttributes())
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        let appsKey = KeychainTVCredentials().keyFile
        XCTAssertEqual(appsKey.lastPathComponent, "television.key")
        XCTAssertEqual(appsKey.deletingLastPathComponent().standardizedFileURL.path,
                       URL.applicationSupportDirectory.standardizedFileURL.path)
        for purged in [URL.cachesDirectory, URL.temporaryDirectory] {
            XCTAssertFalse(appsKey.standardizedFileURL.path.hasPrefix(purged.standardizedFileURL.path))
        }

        let values = try kept.keyFile.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, false)
    }

    /// A key file that cannot be read -- as before the first unlock -- is not a key that has gone: a read finds
    /// nothing and a save writes nothing, and the item and the key are both there as they were once it can be read
    /// again.
    func testAKeyThatCannotBeReadHoldsTheItemAndTheKeyAsTheyAre() throws {
        let kept = try aKeychain()
        kept.store.save(Self.registration)
        let item = try XCTUnwrap(kept.item())
        let key = try XCTUnwrap(kept.key())

        try kept.setPermissions(0o000, of: kept.keyFile)
        XCTAssertThrowsError(try Data(contentsOf: kept.keyFile), "the key file can still be read")

        XCTAssertNil(kept.store.load())
        kept.store.save(Self.another)

        XCTAssertEqual(kept.item(), item, "the item was changed")
        try kept.setPermissions(0o600, of: kept.keyFile)
        XCTAssertEqual(try kept.key(), key, "the key was written over")
        XCTAssertEqual(kept.store.load(), Self.registration)
    }

    /// A key file read whole that is not a key's length, as a write cut short would leave, is no key: nothing
    /// loads, and a save writes a whole key and loads back.
    func testAKeyFileOfAnotherLengthIsNoKeyAndASaveWritesAWholeOne() throws {
        let kept = try aKeychain()
        kept.store.save(Self.registration)
        try Data([1, 2, 3, 4, 5]).write(to: kept.keyFile)

        XCTAssertNil(kept.store.load())
        XCTAssertEqual(try kept.key()?.count, 5, "a read changed the key file")

        kept.store.save(Self.another)

        XCTAssertEqual(try kept.key()?.count, 32)
        XCTAssertEqual(kept.store.load(), Self.another)
    }

    /// A key that cannot be written leaves the item as it was: an item sealed with a key that never reached the
    /// disk would open for nobody.
    func testAKeyThatCannotBeWrittenLeavesTheItemAsItWas() throws {
        let kept = try aKeychain()
        kept.store.save(Self.registration)
        let item = try XCTUnwrap(kept.item())
        try FileManager.default.removeItem(at: kept.keyFile)

        try kept.setPermissions(0o555, of: kept.folder)
        XCTAssertThrowsError(try Data().write(to: kept.folder.appendingPathComponent("probe")),
                             "the key's folder can still be written")

        kept.store.save(Self.another)

        XCTAssertEqual(kept.item(), item, "the item was written before its key")
        XCTAssertFalse(kept.keyIsThere)
    }

    // MARK: - the test's own Keychain service and key file

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
        let store: KeychainTVCredentials

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("BDBridgeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            keyFile = folder.appendingPathComponent("television.key")
            store = KeychainTVCredentials(service: service, keyFile: keyFile)
        }

        private var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: TVCredentialStoreTests.account]
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

        /// The credentials' JSON as the item, written as builds before the seal wrote it.
        func plantThePlainItem(_ credentials: TVCredentials) throws {
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = try JSONEncoder().encode(credentials)
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

        func setPermissions(_ permissions: Int, of url: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }

        func throwAway() {
            try? setPermissions(0o755, of: folder)
            try? setPermissions(0o600, of: keyFile)
            try? FileManager.default.removeItem(at: folder)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
    }

    private struct KeychainFailed: Error {
        let status: OSStatus
    }
}
