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
///
/// ## The sitting
///
/// The rest are the checks with which the three requests that reserve on a television -- its stations, the
/// question of what a reservation would stop from recording, the create -- meet a real one, sent by the
/// app's own client with the owner at the television. They are `TVSitting`'s, where the rules of a check that
/// writes to somebody's television are written, and `TVSittingTests` rehearses every one of them on the
/// invented television first. They say counts, statuses, error codes, weekdays and times of day, and never a
/// title, a station's name, an id of the television's, an address or a cookie.
///
/// **The evening before**, the programmes the checks choose from are picked from the recorder's guide into a
/// file: what a reservation is made of, with no title and no station's name. This sends the television
/// nothing, and the checks send the recorder nothing:
///
///     RECORDER_HOST=… TV_PICKS=<a file kept out of the repository> \
///         swift test --filter LiveTVTests/testWritingThePicks
///
/// with `TV_PICKS_ALSO=cs:<service id>,bs:<service id>` beside them to name the stations of the last check
/// but one: a CS station, and a station the television lists and does not receive.
///
/// **At the sitting** the television is on and showing a broadcast, its USB disk connected. Before the first
/// check that makes anything the owner looks at the television's own list of reservations, reads two of its
/// settings aloud (remote start; whether a pre-shared key is asked for), and sets one viewing reservation
/// with the remote: for a terrestrial programme that starts on the hour in the evening, a day or more ahead,
/// with nothing else reserved within three hours of it. Every command has `TV_HOST`, `TV_JAR`, `TV_PICKS`
/// and `TV_LEDGER` -- a new file, kept out of the repository, where what is about to be made is written down
/// before it is sent -- and the ones that make something have `TV_WRITE=1` as well. Without it, or while the
/// television says `standby`, such a check is skipped with nothing made. One at a time, in this order:
///
///     TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_WRITE=1 swift test --filter LiveTVTests/<the check>
///
/// 1. `testTheStationsAndAPagePastTheEnd`. Makes nothing. To look at, here and in every check below: that
///    the picture goes on as it was.
/// 2. `testAWholeWriteWithTheTelevisionOn`. The eight requests of one reservation, made and deleted. To look
///    at: whether anything shows on the picture as it is made and as it is deleted.
/// 3. `testARecordingWhereAViewingReservationIs`. A recording of the viewing reservation's programme, made
///    and deleted. To look at afterwards: that the viewing reservation is still on the television's list.
/// 4. `testTheSameProgrammeTwice`. The second is to be refused, and one row deleted.
/// 5. `testTheRepeatsOneAtATime`. Six reservations of one programme, one after another, each left on the
///    television for `TV_LOOK` seconds (thirty unless set). To look at, each time, on the television's own
///    list: how the repeat of the reservation called BD Bridge 確認 is worded, and on which day it stands.
/// 6. `testThreeAtOnce`. Three reservations at one time, twice: the second time beside the viewing
///    reservation. To look at afterwards: the viewing reservation, as it was.
/// 7. `testACreateWithACookieNotTaken`. To look at: that no PIN comes up on the screen.
/// 8. `testTheStationsNamed`. One reservation on each station named with the picks, deleted if it is made.
///    To look at: what the television shows, if anything, for the station it does not receive.
/// 9. `testWhatIsLeftAfterwards`. Makes nothing, and fails unless nothing of the sitting is left. Then the
///    owner deletes the viewing reservation with the remote and looks at the television's own list once
///    more: nothing on it is called BD Bridge 確認.
///
/// A check that stops on the way says what it left in the ledger. The next one then makes nothing until the
/// owner has seen on the television's own list that nothing called BD Bridge 確認 is there, deleting it with
/// the remote if it is, and has set `struck` to `true` on that entry of the ledger by hand.
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

    // MARK: - the sitting

    /// Reads the recorder's guide and sends the television nothing: every terrestrial programme still to
    /// start, and those of the stations named, by what a reservation of each is made of.
    func testWritingThePicks() async throws {
        guard let host = Self.environment("RECORDER_HOST") else {
            throw XCTSkip("Set RECORDER_HOST to the recorder whose guide the picks are taken from.")
        }
        guard let file = Self.environment("TV_PICKS") else {
            throw XCTSkip("Set TV_PICKS to a file to write the picks to, outside what the repository tracks.")
        }
        let named = try (Self.environment("TV_PICKS_ALSO") ?? "").split(separator: ",").map { text in
            try XCTUnwrap(TVPicks.Channel(String(text)), "TV_PICKS_ALSO is <kind>:<service id>, comma separated")
        }
        let recorder = RecorderClient(host: host)
        _ = try await recorder.describe()
        var guide: [String: [GuideService]] = [:]
        for kind in Set(["td"] + named.compactMap { Codes.broadcasting(code: $0.broadcastingType) }).sorted() {
            guide[kind] = try await recorder.guide(kind) ?? []
        }

        let picks = TVPicks(guide: guide, named: named, after: Date())
        try picks.write(to: URL(fileURLWithPath: file))

        print("picks: \(picks.programmes.count) programmes on \(Set(picks.programmes.map(\.channel)).count) channels")
        for (index, channel) in named.enumerated() {
            let programmes = picks.programmes.filter { $0.channel == channel }.count
            print("station \(index + 1) of those named: \(programmes) programmes")
            XCTAssertGreaterThan(programmes, 0, "station \(index + 1) of those named is not in the recorder's guide")
        }
        XCTAssertFalse(picks.programmes.isEmpty, "the guide gave no programme to pick")
    }

    func testTheStationsAndAPagePastTheEnd() async throws {
        try await sitting { try await $0.theStations() }
    }

    func testAWholeWriteWithTheTelevisionOn() async throws {
        try await sitting { try await $0.aWholeWrite() }
    }

    func testARecordingWhereAViewingReservationIs() async throws {
        try await sitting { try await $0.aRecordingWhereAViewingReservationIs() }
    }

    func testTheSameProgrammeTwice() async throws {
        try await sitting { try await $0.theSameProgrammeTwice() }
    }

    func testTheRepeatsOneAtATime() async throws {
        try await sitting { try await $0.theRepeats() }
    }

    func testThreeAtOnce() async throws {
        try await sitting { try await $0.threeAtOnce() }
    }

    func testACreateWithACookieNotTaken() async throws {
        // The registered client id with a cookie the television never gave, in a store of its own: nothing
        // of it reaches the jar, and no cookie this client is answered with would be kept.
        guard let clientID = try liveJar().load()?.clientID else {
            throw XCTSkip("Nothing is registered in the jar yet.")
        }
        let never = TVCredentials(clientID: clientID, cookie: String(repeating: "0", count: 40))
        let stranger = try liveClient(MemoryTVCredentials(never))
        try await sitting { try await $0.aCreateWithACookieNotTaken(sentBy: stranger) }
    }

    func testTheStationsNamed() async throws {
        try await sitting { try await $0.theStationsNamed() }
    }

    func testWhatIsLeftAfterwards() async throws {
        try await sitting { try await $0.whatIsLeft() }
    }

    /// Runs one check of the sitting against the television at `TV_HOST`, with the registration in `TV_JAR`,
    /// the picks in `TV_PICKS` and the ledger in `TV_LEDGER`, and leave to write only for `TV_WRITE=1`. A
    /// check that refuses to run -- no leave, the television in standby, an entry left open in the ledger,
    /// no slot that is empty -- is skipped with its reason: it made nothing.
    private func sitting(_ check: (TVSitting) async throws -> Void) async throws {
        let jar = try liveJar()
        let client = try liveClient(jar)
        guard jar.load()?.cookie != nil else { throw XCTSkip("Nothing is registered in the jar yet.") }
        guard let ledger = Self.environment("TV_LEDGER") else {
            throw XCTSkip("Set TV_LEDGER to a file for the sitting's ledger, outside what the repository tracks.")
        }
        guard let picks = Self.environment("TV_PICKS") else {
            throw XCTSkip("Set TV_PICKS to the file testWritingThePicks wrote.")
        }
        let sitting = TVSitting(client: client, picks: try TVPicks.read(URL(fileURLWithPath: picks)),
                                ledger: URL(fileURLWithPath: ledger), mayWrite: Self.environment("TV_WRITE") == "1",
                                look: Self.environment("TV_LOOK").flatMap { TimeInterval($0) } ?? 30) { print($0) }
        do {
            try await check(sitting)
        } catch let refused as TVSitting.Refused {
            throw XCTSkip(refused.why)
        }
    }

    private static func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
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
