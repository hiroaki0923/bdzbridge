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

    // MARK: - playing, and turning the recorder on for it

    /// One tap on 再生 in standby: the 880 turns the recorder on, the status is asked until it says it is on,
    /// and the play goes again. It used to stop at the 880 and take a second button and a second go. The line is
    /// told the seconds waited once for each look at the status, and the play is done.
    func testPlayingInStandbyTurnsTheRecorderOnWaitsForItAndPlays() async throws {
        let (world, driver, recorder) = try await Self.playing([
            "X_PlayControlTitle": [Stub.fault("880"), Stub.soap("X_PlayControlTitle")],
            "X_PowerControl": [Self.poweredOn],
            "X_GetPlayStatus": [Stub.soap("X_GetPlayStatus", result: Self.playStatus("PowerInternalOn")),
                                Stub.soap("X_GetPlayStatus", result: Self.playStatus("PowerOn"))],
        ])
        let title = try await Self.titles().idle

        expectEqual(await driver.play(title, "play"), .done(saying: nil))

        expectEqual(await recorder.actions, ["X_PlayControlTitle", "X_PowerControl", "X_GetPlayStatus",
                                             "X_GetPlayStatus", "X_PlayControlTitle"])
        let bodies = await recorder.bodies
        XCTAssertTrue(bodies[1].contains("<Operation>on</Operation>"), bodies[1])
        XCTAssertTrue(bodies[4].contains("<TitleID>0x1</TitleID>"), bodies[4])
        XCTAssertTrue(bodies[4].contains("<Operation>play</Operation>"), bodies[4])
        XCTAssertEqual(world.updated, Array(repeating: "レコーダーの電源を入れています（0 秒）", count: 2),
                       "the line is told once for each look at the status")
    }

    /// A recorder that is on plays at once, and nothing about power is sent or asked: that is the usual case,
    /// and the demo's recorder does not report its power state at all.
    func testPlayingOnARecorderThatIsOnSendsOnlyThePlay() async throws {
        let (world, driver, recorder) = try await Self.playing([
            "X_PlayControlTitle": [Stub.soap("X_PlayControlTitle")],
        ])
        let title = try await Self.titles().idle

        expectEqual(await driver.play(title, "play"), .done(saying: nil))

        expectEqual(await recorder.actions, ["X_PlayControlTitle"])
        XCTAssertEqual(world.updated, [])
    }

    /// Only standby is worth turning the recorder on for. Anything else it answers -- here a recording it no
    /// longer has -- is the answer, in the recorder's words.
    func testPlayingSomethingTheRecorderRefusesDoesNotTurnItOn() async throws {
        let (world, driver, recorder) = try await Self.playing(["X_PlayControlTitle": [Stub.fault("820")]])
        let title = try await Self.titles().idle

        let came = await driver.play(title, "play")

        guard case .notDone(let why) = came else { return XCTFail("a refusal was taken for a play: \(came)") }
        XCTAssertTrue(why.contains("820"), why)
        XCTAssertEqual(world.problem, why)
        expectEqual(await recorder.actions, ["X_PlayControlTitle"])
    }

    /// The wait is bounded. A recorder that never says it is on is sent the play once more all the same, and
    /// its 880 is the answer, the session keeping it for the sheet to offer to turn the recorder on by hand.
    func testARecorderThatStaysInStandbyIsGivenUpOnAfterTheLimit() async throws {
        let (_, driver, recorder) = try await Self.playing([
            "X_PlayControlTitle": [Stub.fault("880")],
            "X_PowerControl": [Self.poweredOn],
            "X_GetPlayStatus": [Stub.soap("X_GetPlayStatus", result: Self.playStatus("PowerInternalOn"))],
        ], limit: 0.05, interval: .milliseconds(5))
        let title = try await Self.titles().idle

        let came = await driver.play(title, "play")

        guard case .notDone(let why) = came else { return XCTFail("a recorder still in standby played: \(came)") }
        XCTAssertTrue(why.contains("880"), why)
        XCTAssertTrue(driver.link?.session.needsPower == true, "nothing offers to turn the recorder on")
        let actions = await recorder.actions
        XCTAssertEqual(actions.first, "X_PlayControlTitle")
        XCTAssertEqual(actions.last, "X_PlayControlTitle")
        XCTAssertEqual(actions.filter { $0 == "X_PowerControl" }.count, 1, "turned on once, not on every look")
        XCTAssertTrue(actions.contains("X_GetPlayStatus"))
    }

    // MARK: - what the tests start from

    /// A link of the test's own to a recorder at the bench's address that says who it is and answers each
    /// action as `answers` says (`PlayingRecorder`), connected a moment ago, with the world it reaches and an
    /// earlier failure's line left. The driver asks every `interval` for up to `limit` while a play waits for
    /// the recorder's power. The recorder has put down nothing yet.
    private static func playing(_ answers: [String: [HTTPResponse]], limit: TimeInterval = 30,
                                interval: Duration = .milliseconds(1)) async throws
        -> (LinkWorld, RecorderDriver, PlayingRecorder) {
        let world = LinkWorld()
        let recorder = try PlayingRecorder(answers, udn: DeviceLinkTests.udn)
        world.devices[Stub.host] = recorder
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0,
                                    powerOnLimit: limit, powerOnInterval: interval)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        await recorder.forget()
        world.problem = left
        // Held by the driver weakly: kept here for as long as the test runs.
        links.append(link)
        return (world, driver, recorder)
    }

    /// The links the tests above made, kept for as long as the tests run, their drivers holding them weakly.
    private static var links: [DeviceLink] = []

    /// What `X_PowerControl` answers when the recorder takes it.
    private static let poweredOn = Stub.soap("X_PowerControl",
                                             result: "<power><powerstatus>PowerOn</powerstatus></power>")

    /// What `X_GetPlayStatus` says, in the shape the recorder says it (docs/xsrs-api.md).
    private static func playStatus(_ power: String) -> String {
        "<status><powerstatus>\(power)</powerstatus><playstatus>Stopped</playstatus></status>"
    }

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
        return ([protected.altered, deleted.altered, played, poweredOn, added, removed.altered],
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

/// A recorder that says who it is as the vectors' recorder does, and answers each SOAP action with the answers a
/// test gives for it, in turn and the last again once they run out; anything else with a 500, as a recorder that
/// refuses what an attach reads besides its description. It puts down each action it was asked, with its body.
private actor PlayingRecorder: HTTPTransport {
    private var answers: [String: [HTTPResponse]]
    private let description: String
    private(set) var actions: [String] = []
    private(set) var bodies: [String] = []

    init(_ answers: [String: [HTTPResponse]], udn: String) throws {
        self.answers = answers
        description = try Vectors.descriptionXML(udn: udn)
    }

    /// Puts down nothing of what was asked before now: what a connect asked.
    func forget() {
        actions = []
        bodies = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.lastPathComponent != "description.xml" else {
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        let action = String((request.headers["SOAPACTION"] ?? "").split(separator: "#").last ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        actions.append(action)
        bodies.append(String(decoding: request.body ?? Data(), as: UTF8.self))
        guard var given = answers[action], let answer = given.first else { return HTTPResponse(statusCode: 500) }
        if given.count > 1 { given.removeFirst() }
        answers[action] = given
        return answer
    }
}
