import Foundation
import XCTest
import RecorderKit

/// What the recorder's driver turns away at the doors of a recording's and a keyword condition's writes, on a
/// link of its own in a world that puts down what it was asked (`LinkWorld`). The steps past the doors are held
/// by the app's tests, which ask them through the screens' entries; here, what needs no screen: that each door
/// sends nothing, puts up no line and leaves the line an earlier failure left, and says why in its result, by
/// the rule the reservations' doors keep (`Reserved`). The recordings and the condition are read through a
/// client of their own from what a recorder answers, as the app has them.
@MainActor
final class RecorderRecordingsTests: XCTestCase {
    /// A line an earlier failure left on the screen.
    static let left = "left by the request before"

    /// Which recordings can be deleted, in the letters the screens show: one still being recorded is not, by its
    /// own flag and protected or not, and then one protected is not; any other is.
    func testWhichRecordingsCanBeDeleted() async throws {
        let recording = "録画中のため削除できません。番組が終わるまでお待ちください。"
        let protected = "保護されているため削除できません。先に保護を解除してください。"
        XCTAssertEqual(RecorderDriver.protectedCannotBeDeleted, protected)
        let titles = try await Self.titles()

        XCTAssertNil(RecorderDriver.whyNot(deleting: titles.idle))
        XCTAssertEqual(RecorderDriver.whyNot(deleting: titles.protected), protected)
        XCTAssertEqual(RecorderDriver.whyNot(deleting: titles.recording), recording)
        XCTAssertEqual(RecorderDriver.whyNot(deleting: titles.protectedAndRecording), recording)
    }

    /// With no link, with a link that holds no recorder's client, and with the recorder known to be away, each
    /// write is turned away at its door: nothing is asked, no line goes up, the line an earlier failure left
    /// stays, and the result says that the app is not connected. The protect and the delete hand back that the
    /// recordings are to be read again only for the recorder known to be away, as a write that failed there
    /// always marked them; and a play turned away leaves the offer to turn the recorder on where it was.
    func testEachWriteTurnedAwayAtItsDoorSendsNothingAndSaysWhy() async throws {
        let titles = try await Self.titles()
        let rule = try await Self.rule()
        let request = RecorderRuleRequest(keywords: ["サンプル"], qualityCode: 220)

        let alone = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let unlinked = await Self.writes(through: alone, titles.idle, rule, request)
        XCTAssertEqual(unlinked.altered, Array(repeating: .notDone(RecorderDriver.notConnected), count: 6))
        XCTAssertEqual(unlinked.readAgain, [false, false])

        let (world, driver, link) = try Self.linked()
        let unasked = await Self.writes(through: driver, titles.idle, rule, request)
        XCTAssertEqual(unasked.altered, Array(repeating: .notDone(RecorderDriver.notConnected), count: 6),
                       "with no client")
        XCTAssertEqual(unasked.readAgain, [false, false], "with no client")
        XCTAssertEqual(world.events, [], "something was asked, sent or told with no client")
        XCTAssertEqual(world.begun, [], "a line went up with no client")
        XCTAssertEqual(world.problem, Self.left, "something was said on the line with no client")

        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        link.lost()
        link.session.powerNeeded(true)
        world.events = []
        world.problem = Self.left
        let begun = world.begun.count
        let away = await Self.writes(through: driver, titles.idle, rule, request)
        XCTAssertEqual(away.altered, Array(repeating: .notDone(RecorderDriver.notConnected), count: 6),
                       "known to be away")
        XCTAssertEqual(away.readAgain, [true, true], "known to be away")
        XCTAssertEqual(world.events, [], "something was asked, sent or told of a recorder known to be away")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for a recorder known to be away")
        XCTAssertEqual(world.problem, Self.left, "something was said on the line for a recorder known to be away")
        XCTAssertTrue(link.session.needsPower, "a play turned away at its door took the offer to turn it on away")
    }

    /// A recording still being recorded, and one protected, asked to be deleted of a recorder that is there and
    /// connected: nothing is asked, no line goes up, the list is not touched (`keep`), the line an earlier
    /// failure left stays, and the result says why. The recordings are not to be read again for either.
    func testADeleteOfARecordingThatCannotBeDeletedSendsNothing() async throws {
        let titles = try await Self.titles()
        let (world, driver, link) = try Self.linked()
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        world.events = []
        world.problem = Self.left
        let begun = world.begun.count
        var kept = 0

        let recording = "録画中のため削除できません。番組が終わるまでお待ちください。"
        for (name, title, why) in [("being recorded", titles.recording, recording),
                                   ("protected", titles.protected, RecorderDriver.protectedCannotBeDeleted)] {
            let came = await driver.delete(title) { kept += 1 }
            XCTAssertEqual(came.altered, .notDone(why), name)
            XCTAssertFalse(came.readAgain, name)
        }
        XCTAssertEqual(kept, 0, "the list was edited for a delete turned away")
        XCTAssertEqual(world.events, [], "something was asked, sent or told for a delete turned away")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for a delete turned away")
        XCTAssertEqual(world.problem, Self.left)
        XCTAssertTrue(link.session.connected)
    }

    // MARK: - what the tests start from

    /// The six writes, asked in turn: a protect, a delete, a play, the power, a condition added and one removed.
    /// What each came to, and the protect's and the delete's word on reading the recordings again.
    private static func writes(through driver: RecorderDriver, _ title: RecordedTitle, _ rule: RecorderRule,
                               _ request: RecorderRuleRequest) async -> (altered: [Altered], readAgain: [Bool]) {
        let protected = await driver.protect(title, true) {}
        let deleted = await driver.delete(title) {}
        let played = await driver.play(title, "play")
        let poweredOn = await driver.powerOn()
        let added = await driver.addRule(request) {}
        let removed = await driver.removeRule(rule)
        return ([protected.altered, deleted.altered, played, poweredOn, added, removed],
                [protected.readAgain, deleted.readAgain])
    }

    /// A link of the test's own to a recorder at the bench's address, not yet connected, and the world it
    /// reaches, with nothing put down and an earlier failure's line left. The link is handed back with the
    /// driver, which holds it weakly.
    private static func linked() throws -> (LinkWorld, RecorderDriver, DeviceLink) {
        let world = LinkWorld()
        world.devices[Stub.host] = try ScriptedRecorder(at: Stub.host, udn: DeviceLinkTests.udn, world: world)
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                              environment: world.environment)
        link.owner = world
        world.problem = left
        return (world, driver, link)
    }

    /// Four recordings, as a client reads them from what a recorder lists: one that can be deleted, one
    /// protected, one still being recorded, and one both.
    private static func titles() async throws
        -> (idle: RecordedTitle, protected: RecordedTitle, recording: RecordedTitle,
            protectedAndRecording: RecordedTitle) {
        func item(_ id: String, protected: Bool, recording: Bool) -> String {
            "<item id=\"\(id)\"><title>サンプル</title>"
                + "<scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
                + "<scheduledDuration>1800</scheduledDuration>"
                + "<titleProtectFlag>\(protected ? 1 : 0)</titleProtectFlag>"
                + "<recordingFlag>\(recording ? 1 : 0)</recordingFlag></item>"
        }
        let list = "<xsrs>" + item("0x1", protected: false, recording: false)
            + item("0x2", protected: true, recording: false) + item("0x3", protected: false, recording: true)
            + item("0x4", protected: true, recording: true) + "</xsrs>"
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.soap(
            "X_GetTitleList", result: list, totalMatches: 4)))
        let titles = try await client.allTitles()
        XCTAssertEqual(titles.map(\.id), ["0x1", "0x2", "0x3", "0x4"])
        XCTAssertEqual(titles.map(\.protected), [false, true, false, true], "the flags were not read as listed")
        XCTAssertEqual(titles.map(\.recording), [false, false, true, true], "the flags were not read as listed")
        return (titles[0], titles[1], titles[2], titles[3])
    }

    /// A keyword condition as a client reads it from the recorder's list of the vectors.
    private static func rule() async throws -> RecorderRule {
        let list = try Vectors.load("xsrs.json").dictionary("recorder_rules").string("list_result")
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.soap(
            "X_GetPrefRecSettingList", result: list)))
        let rules = try await client.recorderRules()
        return try XCTUnwrap(rules.first, "the vectors list no condition")
    }
}
