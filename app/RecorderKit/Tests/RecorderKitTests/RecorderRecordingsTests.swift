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
    /// recordings need not be read again, nothing having been sent; and a play turned away leaves the offer to
    /// turn the recorder on where it was.
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
        XCTAssertEqual(away.readAgain, [false, false], "known to be away")
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

    // MARK: - the free space as the screens show it

    /// The free space as the screens show it (`RecorderDriver.storage`): what the recorder said is free and what
    /// its disk holds, in bytes. A disk of no size counts as a recorder that has not said, since the screens would
    /// show it as a full disk, and so does a recorder that refuses. Silence alone gets out, for whoever asked to
    /// lose the recorder by.
    func testTheFreeSpaceOfADiskOfNoSizeOrARecorderThatWillNotSayIsNoneAndOnlySilenceGetsOut() async throws {
        func space(total: Int, free: Int) -> HTTPResponse {
            let info = "<RecordDestinationInfo totalCapacity=\"\(total)\" availableCapacity=\"\(free)\"/>"
            return Stub.soap("X_HDLnkGetRecordDestinationInfo",
                             extra: "<RecordDestinationInfo>\(Soap.escape(info))</RecordDestinationInfo>")
        }
        func client(answering response: HTTPResponse) -> RecorderClient {
            RecorderClient(host: Stub.host, transport: StubTransport(always: response))
        }

        let said = try await RecorderDriver.storage(
            of: client(answering: space(total: 4_294_967_296_000, free: 790_273_982_464)))
        XCTAssertEqual(said?.free, 790_273_982_464)
        XCTAssertEqual(said?.total, 4_294_967_296_000)

        let ofNoSize = try await RecorderDriver.storage(of: client(answering: space(total: 0, free: 0)))
        XCTAssertNil(ofNoSize, "a disk of no size was taken for one that has said how full it is")
        let refused = try await RecorderDriver.storage(of: client(answering: Stub.fault("402")))
        XCTAssertNil(refused, "a refusal was read as a size")

        let silent = RecorderClient(host: Stub.host, transport: StubTransport(handler: { _, _ in
            throw RecorderError.transport("The request timed out.")
        }))
        do {
            let space = try await RecorderDriver.storage(of: silent)
            XCTFail("silence was read as an answer: \(String(describing: space))")
        } catch {
            XCTAssertEqual((error as? any DeviceError)?.failure, .silent, "\(error)")
        }
    }

    // MARK: - a run over many recordings

    /// What a run of each kind does, in the letters its job shows while it runs (「削除中 3 / 12」). The app's
    /// tests read the three that change recordings in what a job says once it has stopped; the scan's is shown
    /// by a view alone.
    func testWhatARunOfEachKindDoesInTheLettersItsJobShows() {
        XCTAssertEqual(RecorderDriver.verb(of: .delete), "削除")
        XCTAssertEqual(RecorderDriver.verb(of: .protecting(true)), "保護")
        XCTAssertEqual(RecorderDriver.verb(of: .protecting(false)), "保護解除")
        XCTAssertEqual(RecorderDriver.verb(of: .scanning), "重複の検出")
    }

    /// A run begins only with a recorder's client in hand. With no link, and with a link that has made no
    /// client yet, none begins, whatever its kind: nothing is asked, the line an earlier failure left stays, and
    /// why is that the app is not connected. With a client in hand one begins, and beginning it asks and says
    /// nothing either. And what stopped a run says its sentence when the run was turned away, and nothing for
    /// silence, which what the job says once it has stopped says itself.
    func testARunBeginsOnlyWithARecordersClientInHandAndAStopSaysItsSentenceUnlessItIsSilence() async throws {
        func whyNot(_ begun: Result<Run, RunStop>) -> RunStop? {
            if case .failure(let stop) = begun { stop } else { nil }
        }
        let kinds = [RunKind.delete, .protecting(true), .protecting(false), .scanning]

        let alone = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        XCTAssertEqual(kinds.map { whyNot(alone.beginRun($0)) },
                       Array(repeating: .said(RecorderDriver.notConnected), count: 4))

        let (world, driver, link) = try Self.linked()
        XCTAssertEqual(kinds.map { whyNot(driver.beginRun($0)) },
                       Array(repeating: .said(RecorderDriver.notConnected), count: 4), "with no client")
        XCTAssertEqual(world.events, [], "something was asked, sent or told with no client")
        XCTAssertEqual(world.problem, Self.left, "something was said on the line with no client")

        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        world.events = []
        world.problem = Self.left
        XCTAssertEqual(kinds.map { whyNot(driver.beginRun($0)) }, Array(repeating: nil, count: 4),
                       "no run began with a client in hand")
        XCTAssertEqual(world.events, [], "beginning a run asked, sent or told something")
        XCTAssertEqual(world.problem, Self.left, "beginning a run said something on the line")

        XCTAssertEqual(RunStop.said(Self.left).said, Self.left)
        XCTAssertNil(RunStop.silent(afterSending: true).said)
        XCTAssertNil(RunStop.silent(afterSending: false).said)
    }

    /// A run that deletes or protects does not begin with the recorder known to be away, as a single protect is
    /// turned away at its door: nothing is asked, no line goes up, the line an earlier failure left stays, and
    /// why is that the app is not connected. A scan begins all the same, on the client still in hand: one that
    /// has every text in the cache asks the recorder nothing.
    func testARunThatDeletesOrProtectsDoesNotBeginWithTheRecorderKnownToBeAwayAndAScanDoes() async throws {
        func whyNot(_ begun: Result<Run, RunStop>) -> RunStop? {
            if case .failure(let stop) = begun { stop } else { nil }
        }
        let (world, driver, recorder) = try await Self.playing([:])
        driver.link?.lost()
        world.events = []
        let putUp = world.begun.count

        XCTAssertEqual([RunKind.delete, .protecting(true), .protecting(false)].map { whyNot(driver.beginRun($0)) },
                       Array(repeating: .said(RecorderDriver.notConnected), count: 3))
        XCTAssertNil(whyNot(driver.beginRun(.scanning)), "a scan was turned away for a recorder known to be away")
        expectEqual(await recorder.actions, [], "something was asked of a recorder known to be away")
        XCTAssertEqual(world.events, [], "something was sent or told as a run was begun")
        XCTAssertEqual(world.begun.count, putUp, "a line went up as a run was begun")
        XCTAssertEqual(world.problem, Self.left, "something was said on the line as a run was begun")
        XCTAssertTrue(driver.link?.client != nil, "the client went with the recorder: not that door alone")
    }

    /// What a run stopped before a recording hands back, for its job to show as why: whatever stands on the line
    /// of what went wrong, and that the app is not connected where nothing stands there. Before a recording after
    /// the first, with the recorder known to be away and no check out, the run writes nothing on the line and asks
    /// nothing: so what it hands back is what a check that met silence said there, when that is what lost the
    /// recorder -- and what an earlier operation left there, when the recorder was lost by something that said
    /// nothing, which need not be about the run at all. Before its first recording the run makes sure of the
    /// recorder itself, and of one known to be away that check says that the app is not connected, on the line
    /// and so in what is handed back.
    func testARunStoppedBeforeARecordingHandsBackWhatStandsOnTheLine() async throws {
        // Lost by something that said nothing, the line as an earlier failure left it.
        let (world, driver, recorder) = try await Self.playing([:])
        let run = try driver.beginRun(.delete).get()
        driver.link?.lost()
        world.events = []
        expectEqual(await driver.mayGoOn(run, .next), .said(Self.left))
        XCTAssertEqual(world.problem, Self.left, "the run wrote on the line before a later recording")
        world.problem = nil
        expectEqual(await driver.mayGoOn(run, .next), .said(RecorderDriver.notConnected))
        XCTAssertNil(world.problem, "the run wrote on the line before a later recording")
        expectEqual(await recorder.actions, [], "a recorder known to be away was asked")

        // Before the first recording: the run's own check, of a recorder known to be away.
        expectEqual(await driver.mayGoOn(run, .first), .said(LinkWorld.notConnected))
        XCTAssertEqual(world.problem, LinkWorld.notConnected)
        expectEqual(await recorder.actions, [], "a recorder known to be away was asked")
        XCTAssertEqual(world.events, [], "something was sent or told for a recorder known to be away")

        // Lost by a check that met silence, which said so.
        let (dark, ofTheSilent, silent) = try await Self.playing([:])
        let stopped = try ofTheSilent.beginRun(.delete).get()
        await silent.sayNothingOfWhoItIs()
        let there = await ofTheSilent.link?.ensureUp(evenIfRecent: true)
        XCTAssertEqual(there, false, "the check was meant to meet silence")
        XCTAssertEqual(dark.problem, ofTheSilent.noAnswerLine, "the check was meant to say that nothing answered")
        await silent.forget()
        expectEqual(await ofTheSilent.mayGoOn(stopped, .next), .said(ofTheSilent.noAnswerLine))
        XCTAssertEqual(dark.problem, ofTheSilent.noAnswerLine)
        expectEqual(await silent.actions, [], "a recorder known to be away was asked")
    }

    // MARK: - one recording of a run

    // The decisions a run makes about each recording. The recorder's traps are the point: it refuses a protected
    // recording, it refuses one it is still writing to, and it answers success for one it no longer has.

    /// A recording in progress: the recorder answers a bare HTTP 500, so nothing is sent at all.
    func testARecordingInProgressIsPassedOverWithoutAskingTheRecorder() async throws {
        let (run, driver, recorder) = try await Self.running(.delete, ["X_DeleteTitle": [Stub.soap("X_DeleteTitle")]])

        let came = await driver.delete(try await Self.title(recording: true), in: run)

        XCTAssertEqual(came, .passedOver("録画中のため削除できません。番組が終わるまでお待ちください。"))
        let sent = await recorder.actions.count
        XCTAssertEqual(sent, 0, "a recording in progress should not be sent to the recorder at all")
    }

    func testAProtectedRecordingIsPassedOverWithoutAskingTheRecorder() async throws {
        let (run, driver, recorder) = try await Self.running(.delete, ["X_DeleteTitle": [Stub.soap("X_DeleteTitle")]])

        let came = await driver.delete(try await Self.title(protected: true), in: run)

        let sent = await recorder.actions.count
        XCTAssertEqual(came, .passedOver("保護されているため削除できません。先に保護を解除してください。"))
        XCTAssertEqual(sent, 0, "nothing should have been sent")
    }

    /// Whether a recording can be deleted is asked of one rule, wherever it is asked: over the four kinds of row
    /// -- neither flag, protected, still being recorded, both -- the sets of copies offer a recording for
    /// deleting exactly where a delete's door has nothing to say against it, and a run passes over each of the
    /// other three with that door's sentence, nothing asked. One both protected and being recorded is passed
    /// over as being recorded, which the door looks at first.
    func testTheSetsOfCopiesAndARunAskTheDeletesOwnDoorWhetherARecordingCanBeDeleted() async throws {
        let titles = try await Self.titles()
        let rows = [titles.idle, titles.protected, titles.recording, titles.protectedAndRecording]
        XCTAssertEqual(rows.map { Duplicates.deletable($0) }, [true, false, false, false])
        XCTAssertEqual(rows.map { Duplicates.deletable($0) }, rows.map { RecorderDriver.whyNot(deleting: $0) == nil })

        let (run, driver, recorder) = try await Self.running(.delete, ["X_DeleteTitle": [Stub.soap("X_DeleteTitle")]])
        var came: [ItemCame] = []
        for title in rows.dropFirst() { came.append(await driver.delete(title, in: run)) }
        XCTAssertEqual(came, rows.dropFirst().map { .passedOver(RecorderDriver.whyNot(deleting: $0) ?? "") })
        XCTAssertEqual(came.last, .passedOver("録画中のため削除できません。番組が終わるまでお待ちください。"))
        expectEqual(await recorder.actions, [], "a recording the door turns away was asked about, or sent")
    }

    func testARecordingTheRecorderNoLongerHasIsNotAnError() async throws {
        let (run, driver, recorder) = try await Self.running(.delete, [
            "X_GetTitleDetail": [Stub.fault("820")], "X_DeleteTitle": [Stub.fault("820")],
        ])

        let came = await driver.delete(try await Self.title(), in: run)

        XCTAssertEqual(came, .gone)
        XCTAssertEqual(came.reason, "すでに削除されています", "the run's list of what was passed over says why")
        let bodies = await recorder.bodies
        guard bodies.count == 1 else {
            return XCTFail("it asked, and then knew better than to delete: \(bodies.count) requests")
        }
        XCTAssertTrue(bodies[0].contains("X_GetTitleDetail"), bodies[0])
    }

    func testDeletingAsksFirstAndThenDeletes() async throws {
        let (run, driver, recorder) = try await Self.running(.delete, [
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")],
            "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        ])

        let came = await driver.delete(try await Self.title(id: "0x0000010000034d78"), in: run)

        XCTAssertEqual(came, .done)
        let bodies = await recorder.bodies
        guard bodies.count == 2 else { return XCTFail("the question and the delete: \(bodies.count) requests") }
        XCTAssertTrue(bodies[1].contains("<TitleID>0x0000010000034d78</TitleID>"), bodies[1])
    }

    /// The delete is sent only once the question asked first has been answered. Turned down otherwise than as a
    /// recording the recorder no longer has -- with a fault, or busy with somebody else through every try the
    /// client makes -- nothing is known of whether the recording is still there, and the recorder would answer
    /// its delete as done either way: the recording is passed over with what the recorder said, and no delete
    /// is sent.
    func testARecordingThatCouldNotBeAskedAboutIsPassedOverAndNotSentToBeDeleted() async throws {
        let faulting = try await Self.running(.delete, [
            "X_GetTitleDetail": [Stub.fault("402")], "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        ])
        let faulted = await faulting.driver.delete(try await Self.title(), in: faulting.run)
        XCTAssertEqual(faulted, .passedOver(RecorderError.soap(action: "X_GetTitleDetail", status: 500, code: "402",
                                                               body: "").explanation))
        expectEqual(await faulting.recorder.actions, ["X_GetTitleDetail"], "the delete was sent all the same")

        let busy = try await Self.running(.delete, [
            "X_GetTitleDetail": [HTTPResponse(statusCode: 503)], "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        ])
        let turnedDown = await busy.driver.delete(try await Self.title(), in: busy.run)
        XCTAssertEqual(turnedDown, .passedOver(RecorderError.busy(action: "X_GetTitleDetail").explanation))
        expectEqual(await busy.recorder.actions, Array(repeating: "X_GetTitleDetail", count: 3),
                    "the delete was sent all the same, or the question not asked through its tries")
    }

    func testARefusedDeleteSaysWhyRatherThanStoppingTheRun() async throws {
        let (run, driver, _) = try await Self.running(.delete, [
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail/>")],
            "X_DeleteTitle": [Stub.fault("402")],
        ])

        let came = await driver.delete(try await Self.title(), in: run)

        XCTAssertEqual(came.reason?.contains("402"), true, came.reason ?? "-")
    }

    func testProtectingSendsOnlyWhenItWouldChangeSomething() async throws {
        let (run, driver, recorder) = try await Self.running(.protecting(true),
                                                             ["X_UpdateTitle": [Stub.soap("X_UpdateTitle")]])

        let already = await driver.protect(try await Self.title(protected: true), true, in: run)
        XCTAssertEqual(already, .passedOver("すでに保護されています"))
        let notProtected = await driver.protect(try await Self.title(protected: false), false, in: run)
        XCTAssertEqual(notProtected, .passedOver("保護されていません"))
        expectEqual(await recorder.actions.count, 0)

        expectEqual(await driver.protect(try await Self.title(id: "0x2", protected: false), true, in: run), .done)
        let bodies = await recorder.bodies
        guard bodies.count == 1 else { return XCTFail("the one protect: \(bodies.count) requests") }
        // the payload travels as a SOAP argument, so it arrives escaped
        XCTAssertTrue(bodies[0].contains("&lt;item id=&quot;0x2&quot;&gt;&lt;titleProtectFlag&gt;1&lt;"), bodies[0])
    }

    /// A recorder that has gone to sleep says nothing to the question asked first, and the delete is then
    /// not sent at all: it would only wait out the same silence, and the run has to stop rather than pass the
    /// recording over.
    func testSilenceBeforeTheDeleteStopsTheRunWithoutDeleting() async throws {
        let (run, driver, recorder) = try await Self.running(.delete, [:],
                                                             silentTo: ["X_GetTitleDetail", "X_DeleteTitle"])

        let came = await driver.delete(try await Self.title(), in: run)

        guard case .stopped(let stop) = came else {
            return XCTFail("silence should stop the run, not be turned into a recording passed over")
        }
        XCTAssertEqual(stop, .silent(afterSending: false))
        let bodies = await recorder.bodies
        guard bodies.count == 1 else { return XCTFail("the question alone: \(bodies.count) requests") }
        XCTAssertTrue(bodies[0].contains("X_GetTitleDetail"), bodies[0])
    }

    /// Silence on the delete itself stops the run too. Whether it arrived is unknown, which is why it must not
    /// come back as a recording passed over that the caller could take for "not deleted" -- or send again.
    func testSilenceOnTheDeleteStopsTheRunRatherThanPassingTheRecordingOver() async throws {
        let (run, driver, recorder) = try await Self.running(.delete, [
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail/>")],
        ], silentTo: ["X_DeleteTitle"])

        let came = await driver.delete(try await Self.title(), in: run)

        guard case .stopped(let stop) = came else {
            return XCTFail("silence should stop the run, not be turned into a recording passed over")
        }
        XCTAssertEqual(stop, .silent(afterSending: true))
        let sent = await recorder.actions.count
        XCTAssertEqual(sent, 2, "asked once and deleted once, and nothing sent again")
    }

    /// The duplicate scan keeps what it reads for good, so only an answer counts as read -- an empty text
    /// included, since some recordings come with none.
    func testTheTextIsReadAndAnEmptyOneIsAnAnswer() async throws {
        let described = try await Self.running(.scanning, [
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")],
        ])
        expectEqual(await described.driver.text(of: try await Self.title(), in: described.run), .read("あらすじ"))

        let bare = try await Self.running(.scanning, [
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail/>")],
        ])
        expectEqual(await bare.driver.text(of: try await Self.title(), in: bare.run), .read(""))
    }

    func testARecordingTheRecorderNoLongerHasIsGoneRatherThanRead() async throws {
        let (run, driver, _) = try await Self.running(.scanning, ["X_GetTitleDetail": [Stub.fault("820")]])
        expectEqual(await driver.text(of: try await Self.title(), in: run), .gone)
    }

    /// A refusal is not a text. Kept as an empty one, it would be the same as every other failure's and make
    /// copies of recordings that are nothing alike.
    func testARefusedReadIsAFailureRatherThanAnEmptyText() async throws {
        let (run, driver, _) = try await Self.running(.scanning, ["X_GetTitleDetail": [Stub.fault("402")]])
        let came = await driver.text(of: try await Self.title(), in: run)
        guard case .failed(let reason) = came else { return XCTFail("\(came)") }
        XCTAssertTrue(reason.contains("402"), reason)
    }

    func testSilenceWhileReadingStopsTheScan() async throws {
        let (run, driver, _) = try await Self.running(.scanning, [:], silentTo: ["X_GetTitleDetail"])
        let came = await driver.text(of: try await Self.title(), in: run)
        guard case .stopped(let stop) = came else {
            return XCTFail("silence should stop the scan, not be turned into a failure to read")
        }
        XCTAssertEqual(stop, .silent(afterSending: false))
    }

    func testSilenceOnProtectingStopsTheRun() async throws {
        let (run, driver, recorder) = try await Self.running(.protecting(true), [:], silentTo: ["X_UpdateTitle"])

        let came = await driver.protect(try await Self.title(protected: false), true, in: run)

        guard case .stopped(let stop) = came else {
            return XCTFail("silence should stop the run, not be turned into a recording passed over")
        }
        XCTAssertEqual(stop, .silent(afterSending: true))
        expectEqual(await recorder.actions.count, 1)
    }

    // MARK: - the guide's refresh

    /// What a refresh of the guide hands back, which no screen reads yet. Turned away at its door -- with no
    /// cache in hand; with a cache and no recorder's client, the link not having connected; with both and the
    /// recorder known to be away, each of the three lacking that alone -- it asks nothing, puts up no line,
    /// leaves the line an earlier failure left, and says in what it hands back that the app is not connected.
    /// Asked for two types of a recorder that has built neither file, it goes through: its line goes up and
    /// says each type in turn, nothing is reported stored, both types are handed back as failed with why, and
    /// what it says is what it wrote on the line of what went wrong, a line to a type.
    func testAGuideRefreshHandsBackWhatItCameToAndSaysWhatItWroteOnTheLine() async throws {
        let (world, driver, recorder) = try await Self.playing([:])
        let begun = world.begun.count

        let turnedAway = await driver.refreshGuide(.all) { world.put("stored \($0)") }
        XCTAssertFalse(turnedAway.wentThrough)
        XCTAssertEqual(turnedAway.said, RecorderDriver.notConnected)
        XCTAssertEqual(turnedAway.failed, [])
        expectEqual(await recorder.actions, [], "something was asked with no cache in hand")
        XCTAssertEqual(world.begun.count, begun, "a line went up with no cache in hand")
        XCTAssertEqual(world.problem, Self.left, "something was said on the line with no cache in hand")

        // A cache in hand and the recorder not known to be away, on a link that has not connected: no client.
        let (unconnected, withNoClient, link) = try Self.linked()
        unconnected.cache = try temporaryStore()
        let unasked = await withNoClient.refreshGuide(.all) { unconnected.put("stored \($0)") }
        XCTAssertFalse(unasked.wentThrough, "with no client")
        XCTAssertEqual(unasked.said, RecorderDriver.notConnected, "with no client")
        XCTAssertEqual(unconnected.events, [], "something was asked, sent or told with no client")
        XCTAssertEqual(unconnected.begun, [], "a line went up with no client")
        XCTAssertEqual(unconnected.problem, Self.left, "something was said on the line with no client")
        XCTAssertFalse(link.session.unreachable, "the recorder was known to be away too: not that door alone")

        // A cache and a client in hand, the recorder lost since: known to be away.
        let (dark, ofTheLost, lost) = try await Self.playing([:])
        dark.cache = try temporaryStore()
        ofTheLost.link?.lost()
        dark.events = []
        let putUp = dark.begun.count
        let away = await ofTheLost.refreshGuide(.all) { dark.put("stored \($0)") }
        XCTAssertFalse(away.wentThrough, "known to be away")
        XCTAssertEqual(away.said, RecorderDriver.notConnected, "known to be away")
        expectEqual(await lost.actions, [], "something was asked of a recorder known to be away")
        XCTAssertEqual(dark.events, [], "something was sent or told for a recorder known to be away")
        XCTAssertEqual(dark.begun.count, putUp, "a line went up for a recorder known to be away")
        XCTAssertEqual(dark.problem, Self.left, "something was said on the line for a recorder known to be away")
        XCTAssertTrue(ofTheLost.link?.client != nil, "the client went with the recorder: not that door alone")

        world.cache = try temporaryStore()
        let refreshed = await driver.refreshGuide(.only(["td", "bs"])) { world.put("stored \($0)") }
        func missing(_ file: String) -> String { RecorderError.guideFileMissing(name: file, status: 500).explanation }
        let lines = "地上デジタルの番組表：\(missing("EPG_TRDEPG_FILE.dat"))\nBS の番組表：\(missing("EPG_BSEPG_FILE.dat"))"
        XCTAssertTrue(refreshed.wentThrough, "a file the recorder has not built was taken for the refresh failing")
        XCTAssertEqual(refreshed.stored, 0)
        XCTAssertEqual(refreshed.answered, [])
        XCTAssertEqual(refreshed.failed.map(\.broadcasting), ["td", "bs"])
        XCTAssertEqual(refreshed.said, lines)
        XCTAssertEqual(world.problem, lines)
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), ["番組表を取得中"])
        XCTAssertEqual(world.updated.suffix(2), ["番組表を取得中 (地上デジタル)", "番組表を取得中 (BS)"])
        XCTAssertNil(world.line, "the line was left up")
        XCTAssertFalse(world.events.contains { $0.hasPrefix("stored") }, "a type that failed was reported stored")
        XCTAssertTrue(driver.link?.session.connected == true, "a file not built was taken for the recorder going")
    }

    // MARK: - what the tests start from

    /// A run of `kind` begun on a link of the test's own (`playing`), to a recorder that answers each action as
    /// `answers` says and says nothing at all to those of `silentTo`. The recorder has put down nothing yet.
    private static func running(_ kind: RunKind, _ answers: [String: [HTTPResponse]],
                                silentTo silent: Set<String> = []) async throws
        -> (run: Run, driver: RecorderDriver, recorder: PlayingRecorder) {
        let (_, driver, recorder) = try await playing(answers, silentTo: silent)
        return (try driver.beginRun(kind).get(), driver, recorder)
    }

    /// One recording as a client reads it from what a recorder lists, with its number and its two flags.
    private static func title(id: String = "0x1", protected: Bool = false,
                              recording: Bool = false) async throws -> RecordedTitle {
        let list = "<xsrs>" + listed(id, protected: protected, recording: recording) + "</xsrs>"
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.soap(
            "X_GetTitleList", result: list, totalMatches: 1)))
        guard let title = try await client.allTitles().first else {
            throw RecorderError.unexpectedAnswer(action: "X_GetTitleList")
        }
        return title
    }

    /// A recording as a recorder lists it.
    private static func listed(_ id: String, protected: Bool, recording: Bool) -> String {
        "<item id=\"\(id)\"><title>サンプル</title>"
            + "<scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
            + "<scheduledDuration>1800</scheduledDuration>"
            + "<titleProtectFlag>\(protected ? 1 : 0)</titleProtectFlag>"
            + "<recordingFlag>\(recording ? 1 : 0)</recordingFlag></item>"
    }

    /// A link of the test's own to a recorder at the bench's address that says who it is and answers each
    /// action as `answers` says, and those of `silentTo` not at all (`PlayingRecorder`), connected a moment ago,
    /// with the world it reaches and an earlier failure's line left. The driver asks every `interval` for up to
    /// `limit` while a play waits for the recorder's power. The recorder has put down nothing yet.
    private static func playing(_ answers: [String: [HTTPResponse]], silentTo silent: Set<String> = [],
                                limit: TimeInterval = 30, interval: Duration = .milliseconds(1)) async throws
        -> (LinkWorld, RecorderDriver, PlayingRecorder) {
        let world = LinkWorld()
        let recorder = try PlayingRecorder(answers, silentTo: silent, udn: DeviceLinkTests.udn)
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
        let added = await driver.addRule(request) { _ in }
        let removed = await driver.removeRule(rule) { _ in }
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
        let list = "<xsrs>" + listed("0x1", protected: false, recording: false)
            + listed("0x2", protected: true, recording: false) + listed("0x3", protected: false, recording: true)
            + listed("0x4", protected: true, recording: true) + "</xsrs>"
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
/// test gives for it, in turn and the last again once they run out; an action the test names as met by silence
/// with nothing at all; anything else with a 500, as a recorder that refuses what an attach reads besides its
/// description. It puts down everything it was asked, answered or not: each action with its body, and an ask of
/// who it is by its file's name with an empty body, so that a test that counts what was asked, or finds nothing
/// asked, counts a look at who is there as well.
private actor PlayingRecorder: HTTPTransport {
    private var answers: [String: [HTTPResponse]]
    private let silent: Set<String>
    private let description: String
    private(set) var actions: [String] = []
    private(set) var bodies: [String] = []
    private var saysWhoItIs = true

    init(_ answers: [String: [HTTPResponse]], silentTo silent: Set<String> = [], udn: String) throws {
        self.answers = answers
        self.silent = silent
        description = try Vectors.descriptionXML(udn: udn)
    }

    /// Puts down nothing of what was asked before now: what a connect asked.
    func forget() {
        actions = []
        bodies = []
    }

    /// Says nothing from now on when asked who it is, as a recorder that has left the network.
    func sayNothingOfWhoItIs() {
        saysWhoItIs = false
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.lastPathComponent != "description.xml" else {
            actions.append("description.xml")
            bodies.append("")
            guard saysWhoItIs else { throw RecorderError.transport("timed out") }
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        let action = String((request.headers["SOAPACTION"] ?? "").split(separator: "#").last ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        actions.append(action)
        bodies.append(String(decoding: request.body ?? Data(), as: UTF8.self))
        guard !silent.contains(action) else { throw RecorderError.transport("timed out") }
        guard var given = answers[action], let answer = given.first else { return HTTPResponse(statusCode: 500) }
        if given.count > 1 { given.removeFirst() }
        answers[action] = given
        return answer
    }
}
