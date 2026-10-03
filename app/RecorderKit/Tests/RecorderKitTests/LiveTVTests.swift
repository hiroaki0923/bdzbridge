import XCTest
@testable import RecorderKit

/// Checks against a real television, sent by the client and the transport the app sends with, and skipped
/// unless `TV_HOST` names one on the LAN:
///
///     TV_HOST=192.0.2.20 swift test --filter LiveTVTests/testWhatIsAtTheAddress
///
/// What is measured of a television with another tool is worth what that tool's way of sending is worth, and
/// no more: a registration sent by a script left the PIN on the screen, and the same one sent by the app did
/// not, because `URLSession` sent it twice (`URLSessionTransportTests`). So what the app relies on is tried
/// from here.
///
/// The first reads what is at the address, needs no registration and changes nothing. Registering takes two
/// runs, since somebody has to read the PIN off the screen in between -- the television on, and showing a
/// broadcast:
///
///     TV_HOST=… TV_JAR=<a file kept out of the repository> swift test --filter LiveTVTests/testRegistering
///     TV_HOST=… TV_JAR=… TV_PIN=<the four digits> swift test --filter LiveTVTests/testRegistering
///
/// The first run puts the PIN on the screen, where it is to stay until it is typed or runs out. The second
/// registers, and keeps the client id and the cookie in the jar; neither is printed. With that jar,
/// `testReadingWhatNeedsTheRegistration` reads the disk and the reservations and says how many there are, not
/// what they are. The television then lists this client under `TV_NICKNAME` (BD Bridge (test) unless set), to
/// be taken off its list by hand afterwards.
final class LiveTVTests: XCTestCase {
    func testWhatIsAtTheAddress() async throws {
        let client = try liveClient(MemoryTVCredentials())
        let presence = await client.presence()
        print("at the address: \(presence)")
        XCTAssertNotEqual(presence, .nothing)
        XCTAssertNotEqual(presence, .notATelevision)
        print("gives a MAC to wake it by: \(try await client.wakeOnLANAddress(timeout: 5) != nil)")
    }

    func testRegistering() async throws {
        let jar = try liveJar()
        let client = try liveClient(jar)
        let clientID = jar.load()?.clientID ?? "BDBridge:\(UUID().uuidString)"
        // Kept before anything is sent: the PIN goes with the client id that asked for it.
        if jar.load() == nil { jar.save(TVCredentials(clientID: clientID)) }
        let pin = ProcessInfo.processInfo.environment["TV_PIN"].flatMap { $0.isEmpty ? nil : $0 }
        let nickname = ProcessInfo.processInfo.environment["TV_NICKNAME"] ?? "BD Bridge (test)"

        switch await client.enrol(clientID: clientID, nickname: nickname, pin: pin) {
        case .pinNeeded:
            print("the television asked for its PIN: it is on the screen now, and is to stay there")
            XCTAssertNil(pin, "the PIN given was not taken")
        case .registered:
            print("registered: the cookie is in the jar")
            XCTAssertNotNil(jar.load()?.cookie)
        case .failed(let why):
            XCTFail(why)
        }
    }

    func testReadingWhatNeedsTheRegistration() async throws {
        let jar = try liveJar()
        guard jar.load()?.cookie != nil else { throw XCTSkip("Nothing is registered in the jar yet.") }
        let client = try liveClient(jar)
        let storage = try await client.storage()
        print("disk to record to: mounted \(storage.mounted)")
        let rows = try await client.schedules()
        print("schedules: \(rows.count), of which recordings \(rows.filter { $0.type == "recording" }.count)")
    }

    private func liveClient(_ credentials: any TVCredentialStore) throws -> ScalarClient {
        guard let host = ProcessInfo.processInfo.environment["TV_HOST"], !host.isEmpty else {
            throw XCTSkip("Set TV_HOST to a television's address to run this.")
        }
        return ScalarClient(host: host, transport: URLSessionTransport.withoutCookies(), credentials: credentials)
    }

    private func liveJar() throws -> FileTVCredentials {
        guard let path = ProcessInfo.processInfo.environment["TV_JAR"], !path.isEmpty else {
            throw XCTSkip("Set TV_JAR to a file to keep the registration in, outside what the repository tracks.")
        }
        return FileTVCredentials(URL(fileURLWithPath: path))
    }
}

/// A registration kept in a file between two runs, readable by its owner alone. For the checks above only:
/// the app keeps its own in the Keychain.
private final class FileTVCredentials: TVCredentialStore, @unchecked Sendable {
    private let file: URL

    init(_ file: URL) { self.file = file }

    func load() -> TVCredentials? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TVCredentials.self, from: $0) }
    }

    func save(_ credentials: TVCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}
