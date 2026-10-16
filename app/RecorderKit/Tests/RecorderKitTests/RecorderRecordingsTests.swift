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

    /// A keyword condition's delete goes only from the list read just before it: a read refused, or met by
    /// silence, ends it there with nothing sent, the result saying what the read left -- the recorder's words,
    /// or the read's silence, which loses the recorder.
    func testAConditionsDeleteSendsNothingWhenTheListBeforeItCannotBeRead() async throws {
        let rule = try await Self.rule()
        let refusal = RecorderError.soap(action: "X_GetPrefRecSettingList", status: 500, code: "402", body: "")

        let (refusedWorld, refusing, refusedRecorder) = try await Self.playing([
            "X_GetPrefRecSettingList": [Stub.fault("402")],
            "X_DeletePrefRecSetting": [Stub.soap("X_DeletePrefRecSetting")],
        ])
        let refused = await refusing.removeRule(rule) { _ in }
        expectEqual(await refusedRecorder.actions, ["X_GetPrefRecSettingList"],
                    "a condition was deleted with no list read before it")
        XCTAssertEqual(refused, .notDone(refusal.explanation))
        XCTAssertEqual(refusedWorld.problem, refusal.explanation)

        let (silentWorld, silent, silentRecorder) = try await Self.playing(
            ["X_DeletePrefRecSetting": [Stub.soap("X_DeletePrefRecSetting")]], silentTo: ["X_GetPrefRecSettingList"])
        let unanswered = await silent.removeRule(rule) { _ in }
        expectEqual(await silentRecorder.actions, ["X_GetPrefRecSettingList"],
                    "a condition was deleted after silence on the list before it")
        XCTAssertEqual(unanswered, .notDone(silent.noAnswerLine))
        XCTAssertEqual(silentWorld.problem, silent.noAnswerLine)
        XCTAssertTrue(silent.link?.session.unreachable == true, "silence on the list did not lose the recorder")
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

    /// Silence on a play is silence on something sent: it may have arrived. Asked of the recorder in play and
    /// answered by silence once another has described itself at the address, it is still said, on the line and
    /// in the result, and loses nobody: the recorder now in play has not been asked anything.
    func testSilenceOnAPlayAcrossALetGoIsStillSaidAndLosesNobody() async throws {
        let (world, driver, first) = try await Self.playing([:], silentTo: ["X_PlayControlTitle"])
        let link = try XCTUnwrap(driver.link)
        let title = try await Self.title()
        await first.holdTheNext("X_PlayControlTitle")
        let playing = Task { await driver.play(title, "play") }
        addTeardownBlock { await first.letGo() }
        try await first.whenHeld()
        world.devices[Stub.host] = try PlayingRecorder([:], udn: Self.anotherUDN)
        await link.connect()
        XCTAssertTrue(link.session.connected && link.clientIsAttached, world.problem ?? "no reason given")
        world.problem = Self.left
        await first.letGo()
        let came = await playing.value

        XCTAssertNotEqual(world.problem, Self.left, "silence on a play across a let-go was not said")
        XCTAssertEqual(world.problem, RecorderDriver.instructionMayHaveArrived)
        XCTAssertEqual(came, .notDone(RecorderDriver.instructionMayHaveArrived))
        XCTAssertTrue(link.session.connected, "silence met across a let-go lost the newcomer")
    }

    /// What silence on a play wrote on the line stays there through what is met on the way back: a connect whose
    /// attach meets silence too, and a waking that comes to nothing. It is all the reader has to go by.
    func testWhatSilenceOnAPlaySaidIsNotWrittenOverByAConnectOrAWaking() async throws {
        let world = LinkWorld()
        let recorder = try PlayingRecorder([:], silentTo: ["X_PlayControlTitle"], udn: DeviceLinkTests.udn)
        world.devices[Stub.host] = recorder
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: "F8-4E-17-00-00-00"), driver: driver,
                              environment: world.environment)
        link.owner = world
        Self.links.append(link)
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        world.problem = Self.left

        let came = await driver.play(try await Self.title(), "play")
        XCTAssertNotEqual(came, .notDone(driver.noAnswerLine), "silence on a play was said as a read's")
        XCTAssertTrue(link.session.unreachable, "silence on a play did not lose the recorder")
        let said = try XCTUnwrap(world.problem)
        XCTAssertNotEqual(said, driver.noAnswerLine, "silence on a play was said as a read's")

        await recorder.sayNothingOfWhoItIs()
        world.events = []
        await link.connect()
        XCTAssertTrue(world.events.contains { $0.hasPrefix("packet") }, "the recorder was meant to be woken")
        XCTAssertFalse(link.session.connected, "the recorder was meant to stay silent")
        XCTAssertEqual(world.problem, said, "what met the connect or the waking wrote over the play's silence")
        XCTAssertEqual(said, RecorderDriver.instructionMayHaveArrived)
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

    /// A run that deletes or protects begins only on a client that has heard which recorder answers it. After a
    /// reconnect the recorder answered busy with somebody else as it was asked who it is, the app is connected
    /// from the attach before, beside a client that never heard: no such run begins, nothing is asked, the line
    /// an earlier failure left stays, and why is that the app is not connected. A scan begins all the same, as
    /// with the recorder known to be away.
    ///
    /// And a run holds no client of its own. Ended once the link has let go of the recorder, and with it of the
    /// client, a run that deleted something reads no free space: there is nobody in hand to ask, and whoever
    /// answers at the address now is not the recorder the run was about.
    func testARunBeginsOnlyOnAClientThatHasHeardWhichRecorderAnswersAndHoldsNoneOfItsOwn() async throws {
        func whyNot(_ begun: Result<Run, RunStop>) -> RunStop? {
            if case .failure(let stop) = begun { stop } else { nil }
        }
        let (world, driver, recorder) = try await Self.playing([:])
        let link = try XCTUnwrap(driver.link)
        let begun = try driver.beginRun(.delete).get()

        await recorder.beBusyWhenAskedWhoItIs()
        await link.connect()
        XCTAssertTrue(link.session.connected, "the attach before was meant to stand")
        XCTAssertFalse(link.clientIsAttached, "the reconnect's client was meant not to have heard who answers")
        await recorder.forget()
        world.events = []
        world.problem = Self.left
        let putUp = world.begun.count
        XCTAssertEqual([RunKind.delete, .protecting(true), .protecting(false)].map { whyNot(driver.beginRun($0)) },
                       Array(repeating: .said(RecorderDriver.notConnected), count: 3))
        XCTAssertNil(whyNot(driver.beginRun(.scanning)), "a scan was turned away at a door of a write")
        expectEqual(await recorder.actions, [], "something was asked as a run was begun")
        XCTAssertEqual(world.events, [], "something was sent or told as a run was begun")
        XCTAssertEqual(world.begun.count, putUp, "a line went up as a run was begun")
        XCTAssertEqual(world.problem, Self.left, "something was said on the line as a run was begun")

        link.forgetTheDevice()
        await driver.end(begun, deleted: 1, stopped: nil)
        expectEqual(await recorder.actions, [], "the free space was asked for a run whose recorder was let go of")
    }

    /// What a run stopped before a recording hands back, for its job to show as why, nothing having been asked
    /// about any recording.
    ///
    /// At a door the line of what went wrong is left as it was, and why is that the app is not connected. So it
    /// is with the recorder known to be away, whatever lost it and whatever stands on the line -- what an earlier
    /// operation left there, or what a check that met silence said -- and on a client that has not heard which
    /// recorder answers, after a reconnect the recorder answered busy, for a scan as for a run that writes. Nothing
    /// is asked at a door, not even who answers.
    ///
    /// Past the doors the run makes sure of the recorder itself. After a check that heard the recorder busy with
    /// somebody else as it was asked who it is, it asks again however lately the recorder answered: still busy,
    /// the run stops with what it heard, which goes on the line as well; saying which it is, the run goes on, and
    /// the next time asks nothing; silent, the run stops with what the check said of that silence on the line.
    func testARunTurnedAwayAtADoorLeavesTheLineAndOneStoppedByItsCheckSaysWhatThatCheckHeard() async throws {
        let notConnected = RunStop.said(RecorderDriver.notConnected)

        // Known to be away, lost by something that said nothing: the line as an earlier failure left it.
        let (world, driver, recorder) = try await Self.playing([:])
        let run = try driver.beginRun(.delete).get()
        driver.link?.lost()
        world.events = []
        expectEqual(await driver.mayGoOn(run), notConnected)
        XCTAssertEqual(world.problem, Self.left, "a run turned away at a door wrote on the line")
        expectEqual(await recorder.actions, [], "a recorder known to be away was asked")
        XCTAssertEqual(world.events, [], "something was sent or told for a recorder known to be away")

        // Known to be away, lost by a check that met silence and said so.
        let (dark, ofTheSilent, silent) = try await Self.playing([:])
        let stopped = try ofTheSilent.beginRun(.delete).get()
        await silent.sayNothingOfWhoItIs()
        let there = await ofTheSilent.link?.ensureUp(evenIfRecent: true)
        XCTAssertEqual(there, false, "the check was meant to meet silence")
        XCTAssertEqual(dark.problem, ofTheSilent.noAnswerLine, "the check was meant to say that nothing answered")
        await silent.forget()
        expectEqual(await ofTheSilent.mayGoOn(stopped), notConnected)
        XCTAssertEqual(dark.problem, ofTheSilent.noAnswerLine, "a run turned away at a door wrote on the line")
        expectEqual(await silent.actions, [], "a recorder known to be away was asked")

        // On a client that has not heard which recorder answers: a scan, which began before the reconnect.
        let (apart, ofTheUnheard, unheard) = try await Self.playing([:])
        let scan = try ofTheUnheard.beginRun(.scanning).get()
        await unheard.beBusyWhenAskedWhoItIs()
        await ofTheUnheard.link?.connect()
        XCTAssertTrue(ofTheUnheard.link?.session.connected == true, "the attach before was meant to stand")
        XCTAssertTrue(ofTheUnheard.link?.clientIsAttached == false,
                      "the reconnect was meant not to have heard who answers")
        await unheard.forget()
        apart.problem = Self.left
        expectEqual(await ofTheUnheard.mayGoOn(scan), notConnected)
        XCTAssertEqual(apart.problem, Self.left, "a run turned away at a door wrote on the line")
        expectEqual(await unheard.actions, [], "a client that never heard who answers was asked through")

        // After a check that heard the recorder busy: asked again, and still busy.
        let busy = RecorderError.busy(action: "description.xml").explanation
        let (heard, ofTheBusy, busyOne) = try await Self.playing([:])
        let held = try ofTheBusy.beginRun(.delete).get()
        await busyOne.beBusyWhenAskedWhoItIs()
        var up = await ofTheBusy.link?.ensureUp(evenIfRecent: true)
        XCTAssertEqual(up, true, "a recorder that answered busy was taken for gone")
        XCTAssertEqual(heard.problem, Self.left, "the recorder's check was meant to write nothing on the line")
        await busyOne.forget()
        expectEqual(await ofTheBusy.mayGoOn(held), .said(busy))
        XCTAssertEqual(heard.problem, busy, "what the check heard is not on the line")
        expectEqual(await busyOne.actions, Array(repeating: "description.xml", count: 3),
                    "the run did not ask again who answers, through the client's tries")

        // Free again: asked once more, and then no more.
        await busyOne.sayWhoItIs()
        await busyOne.forget()
        expectEqual(await ofTheBusy.mayGoOn(held), nil)
        expectEqual(await busyOne.actions, ["description.xml"], "the run after a busy check did not ask again")
        expectEqual(await ofTheBusy.mayGoOn(held), nil)
        expectEqual(await busyOne.actions, ["description.xml"],
                    "the run asked who answers though the recorder had just said")

        // Busy to a check once more, and then silent to the run's own ask.
        await busyOne.beBusyWhenAskedWhoItIs()
        up = await ofTheBusy.link?.ensureUp(evenIfRecent: true)
        XCTAssertEqual(up, true, "a recorder that answered busy was taken for gone")
        await busyOne.sayNothingOfWhoItIs()
        await busyOne.forget()
        expectEqual(await ofTheBusy.mayGoOn(held), .said(ofTheBusy.noAnswerLine))
        XCTAssertEqual(heard.problem, ofTheBusy.noAnswerLine)
        expectEqual(await busyOne.actions, ["description.xml"], "the run's own check asked more than who answers")
        XCTAssertTrue(ofTheBusy.link?.session.unreachable == true,
                      "silence to the run's check did not lose the recorder")
    }

    /// A recording of a run is asked for as a single write is. After a check that heard the recorder busy with
    /// somebody else as it was asked who it is, the run asks who answers again before anything of the recording
    /// is sent, hears the same, and stops with what it heard, which goes on the line: not the delete, and not the
    /// question a delete asks first either, on whose answer the delete rests; not a protect; and not a scan's
    /// text, which is kept for good. Nothing is asked but who answers, through the client's tries. And with the
    /// recorder known to be away nothing is asked at all: the run stops with what the check before the request
    /// said on the line.
    ///
    /// Each is asked for here with nothing having asked first whether the run may go on, as no caller does:
    /// what stops the run is what the recording's own request came to, read as a stop and not as a recording
    /// passed over.
    func testNothingOfARecordingOfARunIsSentAfterACheckThatHeardTheRecorderBusy() async throws {
        let (world, driver, recorder) = try await Self.playing([
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail/>")],
            "X_DeleteTitle": [Stub.soap("X_DeleteTitle")], "X_UpdateTitle": [Stub.soap("X_UpdateTitle")],
        ])
        let title = try await Self.title()
        let deleting = try driver.beginRun(.delete).get()
        let protecting = try driver.beginRun(.protecting(true)).get()
        let scanning = try driver.beginRun(.scanning).get()
        await recorder.beBusyWhenAskedWhoItIs()
        let up = await driver.link?.ensureUp(evenIfRecent: true)
        XCTAssertEqual(up, true, "a recorder that answered busy was taken for gone")

        let busy = RecorderError.busy(action: "description.xml").explanation
        let asksWhoAnswers = Array(repeating: "description.xml", count: 3)
        await recorder.forget()
        expectEqual(await driver.delete(title, in: deleting), .stopped(.said(busy)))
        expectEqual(await recorder.actions, asksWhoAnswers,
                    "a recording was asked about after a check that heard the recorder busy, or the run did not ask")
        XCTAssertEqual(world.problem, busy, "what the check heard is not on the line")

        await recorder.forget()
        world.problem = Self.left
        expectEqual(await driver.protect(title, true, in: protecting), .stopped(.said(busy)))
        expectEqual(await recorder.actions, asksWhoAnswers,
                    "a protect was sent after a check that heard the recorder busy")
        XCTAssertEqual(world.problem, busy, "what the check heard is not on the line")

        await recorder.forget()
        world.problem = Self.left
        expectEqual(await driver.text(of: title, in: scanning), .stopped(.said(busy)))
        expectEqual(await recorder.actions, asksWhoAnswers,
                    "a text was read after a check that heard the recorder busy")
        XCTAssertEqual(world.problem, busy, "what the check heard is not on the line")

        // The recorder known to be away: the check before the request says no, and why.
        driver.link?.lost()
        await recorder.forget()
        world.problem = Self.left
        expectEqual(await driver.delete(title, in: deleting), .stopped(.said(RecorderDriver.notConnected)))
        expectEqual(await driver.text(of: title, in: scanning), .stopped(.said(RecorderDriver.notConnected)))
        expectEqual(await recorder.actions, [], "a recorder known to be away was asked")
        XCTAssertEqual(world.problem, RecorderDriver.notConnected)
    }

    /// Between the question a delete asks first and the delete itself, a check of the recorder that came in
    /// behind the question is heard out before the delete is handed over. The question is held at the recorder
    /// while a check is asked for, which waits its turn behind it; the question is then answered, and the check
    /// hears the recorder busy with somebody else as it asks who it is. The run stops with what was heard, which
    /// is on the line: the delete is not sent, and nothing is asked after the question but who answers.
    ///
    /// Two things stop it there, each of which would alone: the run asks again whether it may go on before
    /// the delete, and the delete is itself asked as a single write is, which waits for a check that is out and
    /// is not sent after one that heard something else. So how often the recorder is asked who answers is not
    /// looked at here.
    func testARunHearsOutACheckThatCameInBehindTheQuestionBeforeItSendsTheDelete() async throws {
        let (world, driver, recorder) = try await Self.playing([
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail/>")],
            "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        ])
        let link = try XCTUnwrap(driver.link)
        let title = try await Self.title()
        let run = try driver.beginRun(.delete).get()
        await recorder.holdTheNext("X_GetTitleDetail")
        let deleting = Task { await driver.delete(title, in: run) }
        try await recorder.whenHeld()
        await recorder.beBusyWhenAskedWhoItIs()
        let check = Task { await link.ensureUp(evenIfRecent: true) }
        for _ in 0..<100_000 where link.wakeCheck == nil { await Task.yield() }
        XCTAssertNotNil(link.wakeCheck, "the check was meant to be out behind the question")
        await recorder.letGo()

        let busy = RecorderError.busy(action: "description.xml").explanation
        expectEqual(await deleting.value, .stopped(.said(busy)))
        expectEqual(await check.value, true, "a recorder that answered busy was taken for gone")
        let asked = await recorder.actions
        XCTAssertEqual(asked.first, "X_GetTitleDetail")
        XCTAssertEqual(Set(asked.dropFirst()), ["description.xml"],
                       "the delete was sent after a check that heard the recorder busy: \(asked)")
        XCTAssertEqual(world.problem, busy, "what the check heard is not on the line")
    }

    /// A run that has heard a check out asks who answers for itself, as it does after any check that heard
    /// something in the recorder's place: however lately the recorder answered. A check is out, its ask of who
    /// answers held at the recorder, as a run of each kind is asked whether it may go on, so that the run is
    /// waiting for that check as it ends; and the check then hears the recorder busy with somebody else,
    /// through the client's tries. The run is not handed that check's answer again in place of its own ask.
    /// With the recorder free by then, it hears the recorder say which it is and goes on, nothing written on
    /// the line; with the recorder busy still, it hears so itself, through its own tries, and stops with what
    /// it heard, which goes on the line.
    func testARunThatHeardACheckOutAsksAgainWhoAnswersAfterOneThatHeardTheRecorderBusy() async throws {
        let busy = RecorderError.busy(action: "description.xml").explanation
        for kind in [RunKind.delete, .protecting(true), .scanning] {
            for freeAgain in [true, false] {
                let what = "\(kind), the recorder \(freeAgain ? "free again" : "busy still")"
                let (world, driver, link) = try Self.linked()
                let recorder = try XCTUnwrap(world.devices[Stub.host] as? ScriptedRecorder)
                Self.links.append(link)
                await link.connect()
                XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
                let run = try driver.beginRun(kind).get()
                world.problem = Self.left
                world.events = []

                await recorder.hold()
                addTeardownBlock { await recorder.letGo() }
                let check = Task { await link.ensureUp(evenIfRecent: true) }
                try await Self.whenHeld(recorder)
                XCTAssertNotNil(link.wakeCheck, "the check was meant to be out: \(what)")
                let noted = Noted()
                let asking = Task {
                    noted.begun = true
                    return await driver.mayGoOn(run)
                }
                for _ in 0..<100_000 where !noted.begun { await Task.yield() }
                XCTAssertTrue(noted.begun, "the run was meant to be waiting for the check: \(what)")
                // Busy to the check, through both tries after the first; and then free, or busy still.
                if freeAgain {
                    await recorder.answerNext(.busy, .busy, .busy)
                } else {
                    await recorder.answer(.busy)
                }
                await recorder.letGo()

                expectEqual(await check.value, true, "a recorder that answered busy was taken for gone: \(what)")
                expectEqual(await asking.value, freeAgain ? nil : .said(busy), what)
                XCTAssertEqual(world.count("ask description.xml"), freeAgain ? 4 : 6,
                               "the run was meant to ask who answers itself, after the check's three: \(what)")
                XCTAssertEqual(world.problem, freeAgain ? Self.left : busy, what)
                XCTAssertEqual(link.checksAgain, !freeAgain, what)
            }
        }
    }

    /// A run is for the recorder it began with. Once another recorder has described itself at the address and
    /// been taken up -- the link asks through a client that has heard the newcomer, and is connected to it --
    /// nothing of a run begun before goes to it: asked whether it may go on, a bulk delete, a bulk protect and a
    /// scan each stop, saying that another recorder answered; a recording handed to the run all the same is
    /// neither asked about nor sent; and the free space is not read as the run ends. Nothing is asked of either
    /// recorder, nothing is written on the line, which is the newcomer's, and the newcomer is not lost. A run
    /// begun with the newcomer goes.
    ///
    /// With no recorder in hand since -- the app let go of the one the run began with and has taken up no other
    /// -- the run stops the same way, and says what whatever let go of the recorder left on the line, or that
    /// another recorder answered where the line holds nothing.
    func testNothingOfARunGoesToARecorderThatTookThePlaceOfTheOneItBeganWith() async throws {
        let answers = [
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")],
            "X_DeleteTitle": [Stub.soap("X_DeleteTitle")], "X_UpdateTitle": [Stub.soap("X_UpdateTitle")],
        ]
        let (world, driver, first) = try await Self.playing(answers)
        let link = try XCTUnwrap(driver.link)
        let title = try await Self.title()
        let deleting = try driver.beginRun(.delete).get()
        let protecting = try driver.beginRun(.protecting(true)).get()
        let scanning = try driver.beginRun(.scanning).get()

        let newcomer = try PlayingRecorder(answers, udn: Self.anotherUDN)
        world.devices[Stub.host] = newcomer
        await link.connect()
        XCTAssertTrue(link.session.connected && link.clientIsAttached, world.problem ?? "no reason given")
        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, "the newcomer was meant to be taken up")
        await newcomer.forget()
        world.events = []
        world.problem = Self.left

        let another = RunStop.said(RecorderDriver.anotherAnswered)
        for run in [deleting, protecting, scanning] {
            expectEqual(await driver.mayGoOn(run), another)
        }
        expectEqual(await driver.delete(title, in: deleting), .stopped(another))
        expectEqual(await driver.protect(title, true, in: protecting), .stopped(another))
        expectEqual(await driver.text(of: title, in: scanning), .stopped(another))
        await driver.end(deleting, deleted: 1, stopped: nil)
        expectEqual(await newcomer.actions, [], "something of a run went to a recorder it did not begin with")
        expectEqual(await first.actions, [], "something of a run went to the recorder let go of")
        XCTAssertEqual(world.problem, Self.left, "a run stopped for its recorder wrote on the newcomer's line")
        XCTAssertEqual(world.events, [], "something was sent or told for a run stopped for its recorder")
        XCTAssertTrue(link.session.connected, "a run stopped for its recorder lost the newcomer")

        let begunSince = try driver.beginRun(.delete).get()
        expectEqual(await driver.mayGoOn(begunSince), nil)
        expectEqual(await driver.delete(title, in: begunSince), .done)
        expectEqual(await newcomer.actions, ["X_GetTitleDetail", "X_DeleteTitle"])

        // No recorder in hand since.
        link.forgetTheDevice()
        await newcomer.forget()
        world.problem = "why the app let go of the recorder"
        expectEqual(await driver.mayGoOn(begunSince), .said("why the app let go of the recorder"))
        expectEqual(await driver.delete(title, in: begunSince), .stopped(.said("why the app let go of the recorder")))
        XCTAssertEqual(world.problem, "why the app let go of the recorder")
        world.problem = nil
        expectEqual(await driver.mayGoOn(begunSince), another)
        XCTAssertNil(world.problem, "a run stopped for its recorder wrote on the line")
        expectEqual(await newcomer.actions, [], "something of a run went to an address the app had let go of")
    }

    /// What comes back for a run once its recorder has been let go of is not the run's. A request is held at the
    /// recorder the run began with while another describes itself at the address on a connect, whose client is
    /// another one; then the held request is answered. The run stops there, saying that another recorder
    /// answered, whatever the answer: a scan's text is not handed back to be kept, a delete taken is not handed
    /// back as done, a delete refused not as a recording passed over, and a question answered "no such
    /// recording" not as a recording gone, which would take a row out of a list that is the newcomer's by then.
    /// Nothing is written on the newcomer's line.
    ///
    /// Silence across the let-go still stops the run as silence and loses nobody. And the free space read as a
    /// run ends, answered across the let-go, is not kept: what the session shows is the newcomer's.
    ///
    /// Silence on a protect is said on the line all the same, as a single protect's is: what was sent may have
    /// arrived, whatever became of the recorder. On the question a delete asks first, which changes nothing, it
    /// is not said: the line is the newcomer's.
    func testWhatComesBackForARunOnceItsRecorderWasLetGoOfIsNotTheRuns() async throws {
        let read = Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")
        let another = RunStop.said(RecorderDriver.anotherAnswered)
        let title = try await Self.title()
        let unprotected = try await Self.title(protected: false)

        /// Asks `something` of a run of `kind` on a recorder that answers as `answers` say, holds the request for
        /// `held` there, has another recorder taken up at the address meanwhile, and lets the request go.
        func acrossALetGo<T: Sendable>(
            _ kind: RunKind, _ answers: [String: [HTTPResponse]], silentTo silent: Set<String> = [],
            holding held: String, _ something: @escaping @MainActor (RecorderDriver, Run) async -> T
        ) async throws -> (came: T, world: LinkWorld, link: DeviceLink) {
            let (world, driver, first) = try await Self.playing(answers, silentTo: silent)
            let link = try XCTUnwrap(driver.link)
            let run = try driver.beginRun(kind).get()
            await first.holdTheNext(held)
            let asking = Task { await something(driver, run) }
            try await first.whenHeld()
            world.devices[Stub.host] = try PlayingRecorder(["X_HDLnkGetRecordDestinationInfo": [Self.space(free: 20)]],
                                                           udn: Self.anotherUDN)
            await link.connect()
            XCTAssertTrue(link.session.connected && link.clientIsAttached, world.problem ?? "no reason given")
            world.problem = Self.left
            await first.letGo()
            return (await asking.value, world, link)
        }

        let text = try await acrossALetGo(.scanning, ["X_GetTitleDetail": [read]], holding: "X_GetTitleDetail") {
            await $0.text(of: title, in: $1)
        }
        XCTAssertEqual(text.came, .stopped(another), "a text read for the recorder let go of was handed back")
        XCTAssertEqual(text.world.problem, Self.left, "an answer across a let-go wrote on the newcomer's line")

        let deleted = Stub.soap("X_DeleteTitle")
        let taken = try await acrossALetGo(.delete, ["X_GetTitleDetail": [read], "X_DeleteTitle": [deleted]],
                                           holding: "X_DeleteTitle") { await $0.delete(title, in: $1) }
        XCTAssertEqual(taken.came, .stopped(another), "a delete answered across a let-go was handed back as done")

        let fault = Stub.fault("402")
        let refused = try await acrossALetGo(.delete, ["X_GetTitleDetail": [read], "X_DeleteTitle": [fault]],
                                             holding: "X_DeleteTitle") { await $0.delete(title, in: $1) }
        XCTAssertEqual(refused.came, .stopped(another), "a refusal across a let-go passed the recording over")

        let gone = try await acrossALetGo(.delete, ["X_GetTitleDetail": [Stub.fault("820")]],
                                          holding: "X_GetTitleDetail") { await $0.delete(title, in: $1) }
        XCTAssertEqual(gone.came, .stopped(another), "a recording was taken for gone on an answer across a let-go")

        let silent = try await acrossALetGo(.protecting(true), [:], silentTo: ["X_UpdateTitle"],
                                            holding: "X_UpdateTitle") { await $0.protect(unprotected, true, in: $1) }
        XCTAssertEqual(silent.came, .stopped(.silent(afterSending: true)))
        XCTAssertTrue(silent.link.session.connected, "silence met across a let-go lost the newcomer")
        XCTAssertEqual(silent.world.problem, RecorderDriver.mayHaveArrived,
                       "silence on a protect across a let-go is not said: it may have arrived")

        let unasked = try await acrossALetGo(.delete, [:], silentTo: ["X_GetTitleDetail"],
                                             holding: "X_GetTitleDetail") { await $0.delete(title, in: $1) }
        XCTAssertEqual(unasked.came, .stopped(.silent(afterSending: false)))
        XCTAssertTrue(unasked.link.session.connected, "silence met across a let-go lost the newcomer")
        XCTAssertEqual(unasked.world.problem, Self.left,
                       "silence on a question across a let-go wrote on the newcomer's line")

        let ended = try await acrossALetGo(.delete, ["X_HDLnkGetRecordDestinationInfo": [Self.space(free: 10)]],
                                           holding: "X_HDLnkGetRecordDestinationInfo") {
            await $0.end($1, deleted: 1, stopped: nil)
        }
        XCTAssertEqual(ended.link.session.storage?.free, 20,
                       "the free space of the recorder let go of is shown as the newcomer's")
    }

    /// The free space is read as a run ends only after a bulk delete that deleted something and that nothing
    /// stopped on the recorder's account, as it is read after a single delete: what the recorder says is kept
    /// for the screens, and the line of what went wrong is left as it was. Nothing is asked after a run that
    /// deleted nothing; after one that was stopped, whatever it had deleted, turned away or by silence; after a
    /// bulk protect or a scan; or of a recorder known to be away.
    ///
    /// A recorder that will not say leaves the free space unknown and is not lost for it. Silence is said on the
    /// line as any read's is, and loses the recorder.
    func testTheFreeSpaceIsReadAsARunEndsOnlyAfterADeleteThatNothingStopped() async throws {
        let space = "X_HDLnkGetRecordDestinationInfo"
        let (world, driver, recorder) = try await Self.playing([
            space: [Self.space(free: 10), Self.space(free: 30), Stub.fault("402")],
        ])
        let link = try XCTUnwrap(driver.link)
        XCTAssertEqual(link.session.storage?.free, 10, "the connect was meant to read the free space")
        let deleting = try driver.beginRun(.delete).get()

        await driver.end(deleting, deleted: 0, stopped: nil)
        await driver.end(deleting, deleted: 2, stopped: .said(RecorderDriver.notConnected))
        await driver.end(deleting, deleted: 2, stopped: .silent(afterSending: true))
        await driver.end(deleting, deleted: 2, stopped: .silent(afterSending: false))
        await driver.end(try driver.beginRun(.protecting(true)).get(), deleted: 2, stopped: nil)
        await driver.end(try driver.beginRun(.scanning).get(), deleted: 2, stopped: nil)
        expectEqual(await recorder.actions, [],
                    "the free space was read after a run that deleted nothing, was stopped, or is no delete")
        XCTAssertEqual(link.session.storage?.free, 10)

        await driver.end(deleting, deleted: 1, stopped: nil)
        expectEqual(await recorder.actions, [space], "the free space was not read once, after a run that deleted")
        XCTAssertEqual(link.session.storage?.free, 30, "what the recorder said is not kept for the screens")
        XCTAssertEqual(world.problem, Self.left, "the free space read as a run ends wrote on the line, or cleared it")

        // A recorder that will not say.
        await driver.end(deleting, deleted: 1, stopped: nil)
        XCTAssertNil(link.session.storage, "the free space the recorder would not say is still shown as it was")
        XCTAssertTrue(link.session.connected, "a recorder that would not say its free space was lost")
        XCTAssertEqual(world.problem, Self.left, "a refusal to say the free space is said on the line")

        // Silence.
        await recorder.sayNothing(to: space)
        await recorder.forget()
        await driver.end(deleting, deleted: 1, stopped: nil)
        expectEqual(await recorder.actions, [space])
        XCTAssertEqual(world.problem, RecorderError.transport("").explanation,
                       "silence on the free space as a run ends is not said on the line")
        XCTAssertTrue(link.session.unreachable, "silence on the free space did not lose the recorder")

        // Known to be away.
        await recorder.forget()
        await driver.end(deleting, deleted: 1, stopped: nil)
        expectEqual(await recorder.actions, [], "the free space was asked of a recorder known to be away")
    }

    /// The free space is read only where a check of the recorder made then would have nothing to ask, whoever
    /// asks for it -- the end of a run, a single delete, the list of recordings -- since that read makes no
    /// check of its own. Beside a check that is out, here waiting its turn behind a question held at the
    /// recorder, nothing is asked: the read would have waited behind the check's ask and gone whatever that
    /// heard. After a check that heard the recorder busy with somebody else nothing is asked, and the line is
    /// left as it was. What the session holds stays as it was last read, and once the recorder has said which it
    /// is again, the next that asks reads it.
    ///
    /// A single delete, and the list, with a check behind its request that hears the recorder busy, goes
    /// through all the same -- the row taken out, the list handed over -- and no free space is asked for after
    /// it. And on a client the recorder has not answered yet, put in hand here as a connect puts its own in
    /// hand before its first ask, nothing is asked: there is no answer to go by.
    func testTheFreeSpaceIsReadOnlyWhereACheckWouldHaveNothingToAsk() async throws {
        let space = "X_HDLnkGetRecordDestinationInfo"
        let listed = "<xsrs>" + Self.listed("0x1", protected: false, recording: false) + "</xsrs>"
        let (world, driver, recorder) = try await Self.playing([
            space: [Self.space(free: 10), Self.space(free: 30)],
            "X_GetTitleDetail": [Stub.soap("X_GetTitleDetail", result: "<detail/>")],
            "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
            "X_GetTitleList": [Stub.soap("X_GetTitleList", result: listed, totalMatches: 1)],
        ])
        let link = try XCTUnwrap(driver.link)
        let title = try await Self.title()
        let run = try driver.beginRun(.delete).get()
        let noted = Noted()
        XCTAssertEqual(link.session.storage?.free, 10, "the connect was meant to read the free space")

        // Beside a check that is out, its ask waiting its turn behind a question held at the recorder.
        await recorder.holdTheNext("X_GetTitleDetail")
        let asking = Task { await driver.detail(of: title) }
        try await recorder.whenHeld()
        let check = Task { await link.ensureUp(evenIfRecent: true) }
        for _ in 0..<100_000 where link.wakeCheck == nil { await Task.yield() }
        XCTAssertNotNil(link.wakeCheck, "the check was meant to be out behind the question")
        let ending = Task {
            await driver.end(run, deleted: 1, stopped: nil)
            noted.back = true
        }
        for _ in 0..<100_000 where !noted.back { await Task.yield() }
        await recorder.letGo()
        _ = await asking.value
        await ending.value
        expectEqual(await check.value, true, "the recorder was meant to say which it is")
        expectEqual(await recorder.actions, ["X_GetTitleDetail", "description.xml"],
                    "the free space was asked for beside a check that was out")
        XCTAssertEqual(link.session.storage?.free, 10, "the free space kept is not as it was last read")

        // After a check that heard the recorder busy with somebody else.
        await recorder.beBusyWhenAskedWhoItIs()
        var up = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(up, "a recorder that answered busy was taken for gone")
        await recorder.forget()
        await driver.end(run, deleted: 1, stopped: nil)
        expectEqual(await recorder.actions, [],
                    "the free space was asked for after a check that heard the recorder busy")
        XCTAssertEqual(link.session.storage?.free, 10, "the free space kept is not as it was last read")
        XCTAssertEqual(world.problem, Self.left, "a free space not asked for wrote on the line")

        // The recorder says which it is again: read, and kept.
        await recorder.sayWhoItIs()
        up = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(up, "the recorder was meant to say which it is again")
        await recorder.forget()
        await driver.end(run, deleted: 1, stopped: nil)
        expectEqual(await recorder.actions, [space], "the free space was not read once nothing was in the way")
        XCTAssertEqual(link.session.storage?.free, 30)

        // A single delete, with a check behind it that hears the recorder busy.
        await recorder.forget()
        await recorder.holdTheNext("X_DeleteTitle")
        let deleting = Task { await driver.delete(title) { noted.rowsTakenOut += 1 } }
        try await recorder.whenHeld()
        await recorder.beBusyWhenAskedWhoItIs()
        var behind = Task { await link.ensureUp(evenIfRecent: true) }
        for _ in 0..<100_000 where link.wakeCheck == nil { await Task.yield() }
        XCTAssertNotNil(link.wakeCheck, "the check was meant to be out behind the delete")
        await recorder.letGo()
        let deleted = await deleting.value
        expectEqual(await behind.value, true, "a recorder that answered busy was taken for gone")
        XCTAssertEqual(deleted.altered, .done(saying: nil), "a check that came in behind a delete failed it")
        XCTAssertEqual(noted.rowsTakenOut, 1, "the row of a delete that went through was not taken out")
        var asked = await recorder.actions
        XCTAssertEqual(Array(asked.prefix(2)), ["X_GetTitleDetail", "X_DeleteTitle"],
                       "a single delete asks whether the recording is still there first")
        XCTAssertEqual(Set(asked.dropFirst(2)), ["description.xml"],
                       "the free space was asked for after a delete, behind a check that heard busy: \(asked)")
        XCTAssertEqual(link.session.storage?.free, 30, "the free space kept is not as it was last read")

        // The list, the same.
        await recorder.sayWhoItIs()
        up = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(up, "the recorder was meant to say which it is again")
        await recorder.forget()
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { await driver.titles { noted.list = $0.map(\.id) } }
        try await recorder.whenHeld()
        await recorder.beBusyWhenAskedWhoItIs()
        behind = Task { await link.ensureUp(evenIfRecent: true) }
        for _ in 0..<100_000 where link.wakeCheck == nil { await Task.yield() }
        XCTAssertNotNil(link.wakeCheck, "the check was meant to be out behind the list")
        await recorder.letGo()
        expectEqual(await reading.value, true, "a check that came in behind the list failed its read")
        expectEqual(await behind.value, true, "a recorder that answered busy was taken for gone")
        XCTAssertEqual(noted.list, ["0x1"], "the list read was not handed over")
        asked = await recorder.actions
        XCTAssertEqual(asked.first, "X_GetTitleList")
        XCTAssertEqual(Set(asked.dropFirst()), ["description.xml"],
                       "the free space was asked for with the list, behind a check that heard busy: \(asked)")
        XCTAssertEqual(link.session.storage?.free, 30, "the free space kept is not as it was last read")

        // On a client the recorder has not answered yet.
        await recorder.sayWhoItIs()
        up = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(up, "the recorder was meant to say which it is again")
        link.client = RecorderClient(host: Stub.host, transport: recorder)
        await recorder.forget()
        await driver.end(run, deleted: 1, stopped: nil)
        expectEqual(await recorder.actions, [],
                    "the free space was asked for on a client the recorder has not answered")
        XCTAssertEqual(link.session.storage?.free, 30)
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

    /// A single delete asks whether the recording is still there first, as a run's does: the recorder answers
    /// success for an id it no longer has. Answered that it has no such recording (820), nothing is sent, the
    /// row is taken out of the list, and the result says it was deleted already, the question having gone
    /// through and cleared the line the request before left. Refused otherwise, or met by silence, nothing is
    /// sent, and the question's failure is said as a read's, on the line and in the result; the recordings are
    /// not to be read again, nothing having changed. Answered, the delete goes after it, once.
    func testASingleDeleteAsksWhetherTheRecordingIsStillThereFirst() async throws {
        let detail = Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")
        let title = try await Self.title()
        var kept = 0

        let (goneWorld, gone, goneRecorder) = try await Self.playing([
            "X_GetTitleDetail": [Stub.fault("820")], "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        ])
        let wentAlready = await gone.delete(title) { kept += 1 }
        expectEqual(await goneRecorder.actions.filter { $0 == "X_DeleteTitle" }.count, 0,
                    "a recording the recorder no longer has was sent to be deleted")
        XCTAssertEqual(wentAlready.altered, .done(saying: ItemCame.gone.reason))
        XCTAssertEqual(wentAlready.altered, .done(saying: "すでに削除されています"))
        XCTAssertFalse(wentAlready.readAgain)
        XCTAssertEqual(kept, 1, "the row of a recording the recorder no longer has stayed in the list")
        XCTAssertNil(goneWorld.problem, "the question went through and left the line of the request before")
        expectEqual(await goneRecorder.actions, ["X_GetTitleDetail"])

        kept = 0
        let (faultWorld, faulting, faultRecorder) = try await Self.playing([
            "X_GetTitleDetail": [Stub.fault("402")], "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        ])
        let refused = await faulting.delete(title) { kept += 1 }
        expectEqual(await faultRecorder.actions, ["X_GetTitleDetail"], "deleted without an answer to the question")
        let faulted = RecorderError.soap(action: "X_GetTitleDetail", status: 500, code: "402", body: "").explanation
        XCTAssertEqual(refused.altered, .notDone(faulted))
        XCTAssertEqual(faultWorld.problem, faulted)
        XCTAssertFalse(refused.readAgain)
        XCTAssertEqual(kept, 0)

        let (silentWorld, silent, silentRecorder) = try await Self.playing(
            ["X_DeleteTitle": [Stub.soap("X_DeleteTitle")]], silentTo: ["X_GetTitleDetail"])
        let unanswered = await silent.delete(title) { kept += 1 }
        expectEqual(await silentRecorder.actions, ["X_GetTitleDetail"], "deleted after silence on the question")
        XCTAssertEqual(unanswered.altered, .notDone(silent.noAnswerLine), "silence on the question is a read's")
        XCTAssertEqual(silentWorld.problem, silent.noAnswerLine)
        XCTAssertFalse(unanswered.readAgain, "nothing was sent, and the recordings are to be read again")
        XCTAssertTrue(silent.link?.session.unreachable == true, "silence on the question did not lose the recorder")
        XCTAssertEqual(kept, 0)

        let (answeredWorld, answered, answeredRecorder) = try await Self.playing([
            "X_GetTitleDetail": [detail], "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        ])
        let deleted = await answered.delete(title) { kept += 1 }
        XCTAssertEqual(deleted.altered, .done(saying: nil))
        XCTAssertEqual(kept, 1)
        XCTAssertNil(answeredWorld.problem)
        expectEqual(Array(await answeredRecorder.actions.prefix(2)), ["X_GetTitleDetail", "X_DeleteTitle"])
        expectEqual(await answeredRecorder.actions.filter { $0 == "X_DeleteTitle" }.count, 1)
    }

    /// A single delete whose question is out as the recorder is let go of sends nothing, whatever the question is
    /// answered -- that the recording is there, a refusal, or nothing: the result says why (`whyLetGo`), the list
    /// is not touched, and nothing is said on the line, which is the newcomer's.
    func testASingleDeleteLetGoOfWhileItsQuestionIsOutSendsNothing() async throws {
        let detail = Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")
        for answer in ["answered", "refused", "silent"] {
            let (world, driver, recorder) = try await Self.playing([
                "X_GetTitleDetail": [answer == "refused" ? Stub.fault("402") : detail],
                "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
            ])
            let link = try XCTUnwrap(driver.link)
            let title = try await Self.title()
            var kept = 0
            await recorder.holdTheNext("X_GetTitleDetail")
            let deleting = Task { await driver.delete(title) { kept += 1 } }
            addTeardownBlock { await recorder.letGo() }
            try await recorder.whenHeld()
            link.forgetTheDevice()
            world.problem = nil
            if answer == "silent" { await recorder.sayNothing(to: "X_GetTitleDetail") }
            await recorder.letGo()
            let came = await deleting.value

            expectEqual(await recorder.actions.filter { $0 == "X_DeleteTitle" }.count, 0,
                        "a recording was deleted on a recorder let go of, the question \(answer)")
            XCTAssertEqual(came.altered, .notDone(RecorderDriver.anotherAnswered), "the question \(answer)")
            XCTAssertFalse(came.readAgain, "the question \(answer)")
            XCTAssertEqual(kept, 0, "the list was edited for a recorder let go of, the question \(answer)")
            XCTAssertNil(world.problem, "something was said on the newcomer's line, the question \(answer)")
        }
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

    /// A recording of a run comes and goes under whatever the line of what went wrong holds: done, passed over
    /// with what the recorder said, gone, or a text read, it neither clears the line nor writes on it -- a
    /// refusal is the run's to list beside that recording, and what an earlier operation left on the line is
    /// not a run's to take away.
    ///
    /// Silence is what stops the run, and is said there, once, through the link, as a single write's is, the
    /// recorder lost: after a delete or a protect, that it may have arrived; after the question a delete asks
    /// first and after a scan's text, which change nothing, what a read's silence says. The request that met it
    /// is not sent again, and nothing is asked after it.
    func testSilenceAtARecordingOfARunIsSaidOnTheLineAndAnAnswerLeavesTheLine() async throws {
        let read = Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")
        let title = try await Self.title()

        // Answered, whatever the answer.
        let (world, driver, _) = try await Self.playing([
            "X_GetTitleDetail": [read, Stub.fault("402"), Stub.fault("820"), read],
            "X_DeleteTitle": [Stub.soap("X_DeleteTitle"), Stub.fault("402")],
            "X_UpdateTitle": [Stub.soap("X_UpdateTitle"), Stub.fault("402")],
        ])
        let deleting = try driver.beginRun(.delete).get()
        let protecting = try driver.beginRun(.protecting(true)).get()
        let refusedToDelete = RecorderError.soap(action: "X_DeleteTitle", status: 500, code: "402", body: "")
        let refusedToSay = RecorderError.soap(action: "X_GetTitleDetail", status: 500, code: "402", body: "")
        let refusedToProtect = RecorderError.soap(action: "X_UpdateTitle", status: 500, code: "402", body: "")
        var lines: [String?] = []
        var came: [ItemCame] = []
        for _ in 0..<4 {
            came.append(await driver.delete(title, in: deleting))
            lines.append(world.problem)
        }
        for _ in 0..<2 {
            came.append(await driver.protect(title, true, in: protecting))
            lines.append(world.problem)
        }
        XCTAssertEqual(came, [.done, .passedOver(refusedToSay.explanation), .gone,
                              .passedOver(refusedToDelete.explanation), .done,
                              .passedOver(refusedToProtect.explanation)])
        expectEqual(await driver.text(of: title, in: try driver.beginRun(.scanning).get()), .read("あらすじ"))
        lines.append(world.problem)
        XCTAssertEqual(lines, Array(repeating: Self.left, count: 7),
                       "a recording of a run cleared the line, or wrote what the recorder said on it")
        XCTAssertTrue(driver.link?.session.connected == true)

        // Silence.
        let noAnswer = RecorderError.transport("").explanation
        let rows: [(what: String, kind: RunKind, silent: String, sent: [String], stop: RunStop, said: String)] = [
            ("the question a delete asks first", .delete, "X_GetTitleDetail", ["X_GetTitleDetail"],
             .silent(afterSending: false), noAnswer),
            ("a delete", .delete, "X_DeleteTitle", ["X_GetTitleDetail", "X_DeleteTitle"],
             .silent(afterSending: true), RecorderDriver.mayHaveArrived),
            ("a protect", .protecting(true), "X_UpdateTitle", ["X_UpdateTitle"],
             .silent(afterSending: true), RecorderDriver.mayHaveArrived),
            ("a scan's text", .scanning, "X_GetTitleDetail", ["X_GetTitleDetail"],
             .silent(afterSending: false), noAnswer),
        ]
        for row in rows {
            let (dark, driver, recorder) = try await Self.playing(["X_GetTitleDetail": [read]], silentTo: [row.silent])
            let run = try driver.beginRun(row.kind).get()
            var stop: RunStop?
            switch row.kind {
            case .delete:
                if case .stopped(let why) = await driver.delete(title, in: run) { stop = why }
            case .protecting(let on):
                if case .stopped(let why) = await driver.protect(title, on, in: run) { stop = why }
            case .scanning:
                if case .stopped(let why) = await driver.text(of: title, in: run) { stop = why }
            }
            XCTAssertEqual(stop, row.stop, "silence at \(row.what)")
            XCTAssertEqual(dark.problem, row.said, "silence at \(row.what) is not said on the line")
            XCTAssertTrue(driver.link?.session.unreachable == true, "silence at \(row.what) did not lose the recorder")
            expectEqual(await recorder.actions, row.sent,
                        "silence at \(row.what): sent again, or something asked after")
        }
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

    /// The guide is fetched only from a recorder that has said which it is. After a reconnect the recorder
    /// answered busy with somebody else, the app is connected from the attach before, beside a client that has
    /// not heard which recorder answers it. A refresh as a connect asks for it is turned away there: nothing is
    /// asked, no line goes up, the line an earlier failure left stays, and it says that the app is not
    /// connected.
    ///
    /// 番組表を更新 pressed there connects first. With the recorder busy still, that connect comes to no
    /// recorder that can be asked, and nothing is fetched after it: the press says what the connect left on
    /// the line of what went wrong, that the recorder is busy, as after a check that said no. With the recorder
    /// free, who answers is asked once, and then each file once. Pressed again, the recorder to be asked, it
    /// fetches with no connect. Pressed with the recorder known to be away, it is turned away as a refresh is,
    /// and makes no connect.
    ///
    /// And where the press's connect is answered by another recorder, which is taken up, the press fetches
    /// nothing: the guide is the newcomer's connect's to fetch, and the press says that another recorder
    /// answered.
    ///
    /// Where the press's connect left nothing on the line, the press says that the app is not connected: here
    /// a connect is under way as it is pressed, its ask of who answers held at the recorder, so that the press's
    /// own does nothing beside it, nothing is asked, and the press is back before that connect is.
    func testAGuideIsFetchedOnlyFromARecorderThatHasSaidWhichItIsAndAPressConnectsFirst() async throws {
        func files(_ recorder: PlayingRecorder) async -> Int { await recorder.actions.filter(\.isEmpty).count }
        func asksOfWhoAnswers(_ recorder: PlayingRecorder) async -> Int {
            await recorder.actions.filter { $0 == "description.xml" }.count
        }
        /// Connected, and then a reconnect answered busy, the recorder busy still: with a cache in hand, an
        /// earlier failure's line left and nothing put down.
        func afterABusyReconnect() async throws -> (LinkWorld, RecorderDriver, PlayingRecorder, DeviceLink) {
            let (world, driver, recorder) = try await Self.playing([:])
            let link = try XCTUnwrap(driver.link)
            world.cache = try temporaryStore()
            await recorder.beBusyWhenAskedWhoItIs()
            await link.connect()
            XCTAssertTrue(link.session.connected, "the attach before was meant to stand")
            XCTAssertFalse(link.clientIsAttached, "the client in hand was meant not to have heard who answers")
            XCTAssertFalse(driver.canBeAsked)
            await recorder.forget()
            world.problem = Self.left
            return (world, driver, recorder, link)
        }

        let (world, driver, recorder, link) = try await afterABusyReconnect()
        let begun = world.begun.count
        let turnedAway = await driver.refreshGuide(.all) { world.put("stored \($0)") }
        XCTAssertFalse(turnedAway.wentThrough)
        XCTAssertEqual(turnedAway.said, RecorderDriver.notConnected)
        expectEqual(await recorder.actions, [], "something was asked of a recorder that has not said which it is")
        XCTAssertEqual(world.begun.count, begun, "a line went up for a refresh turned away at its door")
        XCTAssertEqual(world.problem, Self.left, "a refresh turned away at its door wrote on the line")

        let stillBusy = await driver.refreshGuideByHand { world.put("stored \($0)") }
        let busy = RecorderError.busy(action: "description.xml").explanation
        XCTAssertFalse(stillBusy.wentThrough)
        XCTAssertEqual(world.problem, busy, "the press's connect was meant to say what it heard on the line")
        XCTAssertEqual(stillBusy.said, busy, "the press does not say what its connect left on the line")
        expectEqual(await asksOfWhoAnswers(recorder), 3, "the press was meant to connect, busy through its tries")
        expectEqual(await files(recorder), 0, "a file was asked for after a connect the recorder answered busy")
        XCTAssertTrue(link.session.connected, "the attach before was meant to stand")

        await recorder.sayWhoItIs()
        await recorder.forget()
        let pressed = await driver.refreshGuideByHand { world.put("stored \($0)") }
        XCTAssertTrue(pressed.wentThrough, pressed.said ?? "nothing said")
        XCTAssertEqual(pressed.failed.map(\.broadcasting), GuideRefresh.broadcastingTypes)
        expectEqual(await asksOfWhoAnswers(recorder), 1, "the press was meant to connect once")
        expectEqual(await files(recorder), 4, "each file was meant to be asked for once")
        expectEqual(await recorder.actions.first, "description.xml", "something was asked before who answers")
        XCTAssertTrue(driver.canBeAsked)

        await recorder.forget()
        let again = await driver.refreshGuideByHand { world.put("stored \($0)") }
        XCTAssertTrue(again.wentThrough)
        expectEqual(await asksOfWhoAnswers(recorder), 0, "a press connected for a recorder that can be asked")
        expectEqual(await files(recorder), 4)

        link.lost()
        await recorder.forget()
        world.problem = Self.left
        let away = await driver.refreshGuideByHand { world.put("stored \($0)") }
        XCTAssertFalse(away.wentThrough)
        XCTAssertEqual(away.said, RecorderDriver.notConnected)
        expectEqual(await recorder.actions, [], "a press connected, or fetched, for a recorder known to be away")
        XCTAssertEqual(world.problem, Self.left)

        // Another recorder answers the press's connect.
        let (home, ofTheFirst, first, toTheFirst) = try await afterABusyReconnect()
        let newcomer = try PlayingRecorder([:], udn: Self.anotherUDN)
        home.devices[Stub.host] = newcomer
        let answeredByAnother = await ofTheFirst.refreshGuideByHand { home.put("stored \($0)") }
        XCTAssertEqual(toTheFirst.session.info?.udn, Self.anotherUDN, "the newcomer was meant to be taken up")
        XCTAssertFalse(answeredByAnother.wentThrough)
        XCTAssertEqual(answeredByAnother.said, RecorderDriver.anotherAnswered)
        expectEqual(await files(newcomer), 0, "the press fetched from a recorder it was not pressed for")
        expectEqual(await files(first), 0)

        // Pressed while a connect is under way, which leaves nothing on the line for the press to say.
        let (waiting, ofTheWaiting, toTheWaiting) = try Self.linked()
        let scripted = try XCTUnwrap(waiting.devices[Stub.host] as? ScriptedRecorder)
        Self.links.append(toTheWaiting)
        waiting.cache = try temporaryStore()
        await toTheWaiting.connect()
        XCTAssertTrue(toTheWaiting.session.connected, waiting.problem ?? "no reason given")
        await scripted.hold()
        let connecting = Task { await toTheWaiting.connect() }
        try await Self.whenHeld(scripted)
        waiting.problem = nil
        waiting.events = []
        let noted = Noted()
        let pressing = Task {
            let came = await ofTheWaiting.refreshGuideByHand { waiting.put("stored \($0)") }
            noted.back = true
            return came
        }
        for _ in 0..<100_000 where !noted.back { await Task.yield() }
        XCTAssertTrue(noted.back, "the press waits for the connect that is under way")
        XCTAssertEqual(waiting.events.filter { $0.hasPrefix("ask") }, [], "something was asked beside a connect")
        await scripted.letGo()
        await connecting.value
        let beside = await pressing.value
        XCTAssertFalse(beside.wentThrough)
        XCTAssertEqual(beside.said, RecorderDriver.notConnected, "with nothing on the line")
    }

    /// A refresh that comes to fetch and finds nothing to -- every type answered for since the moment it was
    /// asked with -- asks the recorder for no file. It went through, has nothing to say, and leaves the line of
    /// what went wrong as it stands: nothing was asked that could have put right what the line says. With one
    /// type's mark older than the moment, that type alone is asked for, and going through clears the line.
    ///
    /// The marks are the test's own, a day ahead of now and two days back.
    func testAGuideRefreshThatFindsNothingToFetchLeavesTheLineAsItStands() async throws {
        let (world, driver, recorder) = try await Self.serving(["td": true])
        let cache = try temporaryStore()
        world.cache = cache
        let ahead = Date().addingTimeInterval(86_400), longAgo = Date().addingTimeInterval(-2 * 86_400)
        for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: ahead) }
        let asked = await recorder.requests.count

        let nothing = await driver.refreshGuide(.notAnsweredSince(Date())) { world.put("stored \($0)") }
        XCTAssertTrue(nothing.wentThrough, "a refresh with nothing left to fetch was said not to have gone through")
        XCTAssertNil(nothing.said)
        XCTAssertEqual(nothing.answered, [])
        XCTAssertEqual(nothing.failed, [])
        expectEqual(await recorder.requests.count, asked, "the recorder was asked, with nothing to fetch")
        XCTAssertEqual(world.problem, Self.left, "a refresh that asked the recorder for nothing cleared the line")
        XCTAssertNil(world.line, "the line was left up")

        try await cache.noteNoGuide(broadcasting: "td", at: longAgo)
        let one = await driver.refreshGuide(.notAnsweredSince(Date())) { world.put("stored \($0)") }
        XCTAssertTrue(one.wentThrough, one.said ?? "nothing said")
        XCTAssertEqual(one.answered, ["td"])
        expectEqual(await Self.guideFiles(asked: recorder), ["td"], "the one type behind was meant to be asked for")
        XCTAssertNil(world.problem, "a refresh that fetched a type and went through left the line up")
    }

    /// What a refresh of the guide says when the check before it said no, nothing having been asked for:
    /// whatever stands on the line of what went wrong once that check has ended, and that the app is not
    /// connected where nothing stands there. That is all that is promised of it (`GuideRefreshed.said`), and it
    /// is what a screen then shows. Each refresh here is asked beside a check that is out, its ask of who answers
    /// held at the recorder, and each check then meets silence.
    ///
    /// With nothing to wake the recorder with, the check writes that it did not answer, and the refresh says
    /// that. With the local network permission in the way, the check empties the line, and the refresh says
    /// that access to the local network is not allowed. Those are the two ends a check's no decides. A check
    /// that ends on a recorder let go of meanwhile is not held here: what a refresh says of a recorder let go
    /// of is a rule of its own, held where a refresh is kept to the recorder it began with.
    func testWhatAGuideRefreshSaysAfterACheckThatSaidNoIsWhatStandsOnTheLine() async throws {
        /// A refresh asked while a check is out, the check's ask held at the recorder: `meanwhile` is done once
        /// the refresh waits for that check, and the check then meets silence. What the refresh came to, with
        /// its world and its driver.
        func refreshedBesideASilentCheck(_ meanwhile: @MainActor (LinkWorld) -> Void = { _ in })
            async throws -> (GuideRefreshed, LinkWorld, RecorderDriver) {
            let (world, driver, link) = try Self.linked()
            let recorder = try XCTUnwrap(world.devices[Stub.host] as? ScriptedRecorder)
            // Held by the driver weakly: kept for as long as the tests run.
            Self.links.append(link)
            await link.connect()
            XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
            world.cache = try temporaryStore()
            world.problem = Self.left
            world.events = []
            await recorder.hold()
            let check = Task { await link.ensureUp(evenIfRecent: true) }
            try await Self.whenHeld(recorder)
            let refreshing = Task { await driver.refreshGuide(.all) { world.put("stored \($0)") } }
            for _ in 0..<100_000 where world.line != "番組表を取得中" { await Task.yield() }
            XCTAssertEqual(world.line, "番組表を取得中", "the refresh was meant to be waiting for the check")
            meanwhile(world)
            await recorder.answer(.silence)
            await recorder.letGo()
            expectEqual(await check.value, false, "the check was meant to meet silence")
            let refreshed = await refreshing.value
            XCTAssertFalse(refreshed.wentThrough)
            XCTAssertEqual(world.events.filter { $0.hasPrefix("ask") }, ["ask description.xml at \(Stub.host)"],
                           "a file was asked for after a check that said no")
            XCTAssertNil(world.line, "the line was left up")
            return (refreshed, world, driver)
        }

        var (refreshed, world, driver) = try await refreshedBesideASilentCheck()
        XCTAssertEqual(world.problem, driver.noAnswerLine, "the check was meant to say that nothing answered")
        XCTAssertEqual(refreshed.said, driver.noAnswerLine)

        (refreshed, world, driver) = try await refreshedBesideASilentCheck { $0.blocked = true }
        XCTAssertNil(world.problem, "a check that ended waiting for the permission was meant to empty the line")
        XCTAssertEqual(refreshed.said, LocalNetwork.accessNotAllowed)
        XCTAssertEqual(driver.whyNotConnected, LocalNetwork.accessNotAllowed)
    }

    /// A refresh of the guide that silence stops hands back what came before the silence: the type that
    /// failed, the type that was stored and reported so, and what was stored of it. It did not go through. What
    /// it says is a line for the type that failed and then that the recorder did not answer, while the line of
    /// what went wrong holds the silence alone, said as a read's is, with the recorder lost. Nothing is asked
    /// for after the type that met it.
    ///
    /// Where the silence is not said -- the recorder known to be away by then, something else having met its
    /// silence first, while the file was out -- the line stays as it was: a refresh that silence stopped does
    /// not clear it.
    func testAGuideRefreshStoppedBySilenceHandsBackWhatCameBeforeItAndSaysItOnce() async throws {
        func missing(_ file: String) -> String { RecorderError.guideFileMissing(name: file, status: 500).explanation }
        let (world, driver, recorder) = try await Self.serving(["bs": true, "cs": false])
        world.cache = try temporaryStore()
        let begun = world.begun.count

        let stopped = await driver.refreshGuide(.all) { world.put("stored \($0)") }

        XCTAssertFalse(stopped.wentThrough, "a refresh that silence stopped was said to have gone through")
        XCTAssertEqual(stopped.failed.map(\.broadcasting), ["td"], "the type that failed before the silence")
        XCTAssertEqual(stopped.answered, ["bs"], "the type that answered before the silence")
        XCTAssertEqual(stopped.stored, 5, "what was stored before the silence")
        XCTAssertEqual(stopped.said, "地上デジタルの番組表：\(missing("EPG_TRDEPG_FILE.dat"))\n\(driver.noAnswerLine)")
        XCTAssertEqual(world.problem, driver.noAnswerLine, "the line was meant to hold the silence alone")
        XCTAssertTrue(driver.link?.session.unreachable == true, "silence in the guide did not lose the recorder")
        XCTAssertEqual(world.events.filter { $0.hasPrefix("stored") }, ["stored bs"])
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), ["番組表を取得中"])
        XCTAssertNil(world.line, "the line was left up")
        expectEqual(await Self.guideFiles(asked: recorder), ["td", "bs", "cs"], "a silent recorder was asked for more")
        expectEqual(try await world.cache?.counts()["bs"]?.programs, 4, "the type stored before the silence stays")

        // Lost by something else as the second type's file is asked for, with its own sentence left on the line.
        let (dark, ofTheLost, quiet) = try await Self.serving(["td": true, "bs": false]) { type, link in
            if type == "bs" { link.lost() }
        }
        dark.cache = try temporaryStore()
        let unsaid = await ofTheLost.refreshGuide(.all) { dark.put("stored \($0)") }
        XCTAssertFalse(unsaid.wentThrough)
        XCTAssertEqual(unsaid.answered, ["td"])
        XCTAssertEqual(unsaid.said, ofTheLost.noAnswerLine)
        XCTAssertEqual(dark.problem, Self.left, "a refresh whose silence was not said cleared the line, or wrote on it")
        expectEqual(await Self.guideFiles(asked: quiet), ["td", "bs"])
    }

    /// No guide is fetched after a check that heard something in place of the recorder saying which it is. The
    /// recorder answers busy with somebody else as a check asks who it is: it is there, and connected to still.
    /// A refresh asked then puts its line up, asks again who answers, however lately the recorder answered,
    /// hears busy through its tries, and asks for no file: it did not go through, and what it says is what was
    /// heard, in the recorder's words, which is on the line of what went wrong as well. With the recorder
    /// saying who it is again, the next refresh asks once who answers and then for each file.
    func testNoGuideIsFetchedAfterACheckThatHeardTheRecorderBusyAndTheNextAsksAgainWhoAnswers() async throws {
        let (world, driver, recorder) = try await Self.playing([:])
        let link = try XCTUnwrap(driver.link)
        world.cache = try temporaryStore()
        await recorder.beBusyWhenAskedWhoItIs()
        expectTrue(await link.ensureUp(evenIfRecent: true), "a recorder that answered busy was taken for gone")
        XCTAssertTrue(link.checksAgain, "the check was meant to have heard the recorder busy")
        await recorder.forget()
        world.problem = Self.left
        let begun = world.begun.count
        let busy = RecorderError.busy(action: "description.xml").explanation

        let refreshed = await driver.refreshGuide(.all) { world.put("stored \($0)") }

        XCTAssertFalse(refreshed.wentThrough, "a guide went through after a check that heard busy")
        XCTAssertEqual(refreshed.said, busy)
        XCTAssertEqual(world.problem, busy, "what the check heard was not said on the line")
        expectEqual(await recorder.actions, ["description.xml", "description.xml", "description.xml"],
                    "who answers was meant to be asked again, through the tries, and no file")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), ["番組表を取得中"])
        XCTAssertNil(world.line, "the line was left up")
        XCTAssertTrue(link.session.connected, "a recorder that answered busy was given up on")

        await recorder.sayWhoItIs()
        await recorder.forget()
        let again = await driver.refreshGuide(.all) { world.put("stored \($0)") }
        XCTAssertTrue(again.wentThrough, again.said ?? "nothing said")
        expectEqual(await recorder.actions.first, "description.xml", "who answers was not asked again first")
        expectEqual(await recorder.actions.filter { $0 == "description.xml" }.count, 1)
        expectEqual(await recorder.actions.filter(\.isEmpty).count, 4, "each file was meant to be asked for once")
        XCTAssertFalse(link.checksAgain)
    }

    /// A refresh of the guide is for the recorder in play at its door, and nothing of it goes on once that
    /// recorder has been let go of. Each refresh here has its first file out, held at the recorder, as the
    /// recorder is let go of.
    ///
    /// Let go of by the host, nobody taken up in its place, and the file then answered as one not built: the
    /// next type is not asked for, the line of what went wrong is neither cleared nor written with the type
    /// that failed, and the refresh did not go through; what it says is what a write says then, which with no
    /// recorder in hand is what the line holds. So it is where the file out was the last one asked for, and
    /// the refresh came to its end across the let-go. The file answered with nothing at all instead: the
    /// silence is not the recorder in play's, and is neither said nor taken -- nobody is lost.
    ///
    /// Another recorder taken up at the address by a connect, which makes the cache over to it, and the file
    /// then answered with a guide: nothing of it is in the newcomer's cache and no type is marked, nothing more
    /// is asked for, of either recorder, the line is as the newcomer's connect left it, and the refresh says
    /// that another recorder answered.
    ///
    /// And let go of while the check before the refresh is out, nobody taken up in its place: no file is asked
    /// for, and the refresh says what a write says then, not what a check's no says. It repeats the line, which
    /// the link has written as another recorder answering once the check heard none of the recorder in play,
    /// over a line left by whatever let go of the recorder and over an empty one alike; after a check's no it
    /// would say that the app is not connected.
    func testAGuideRefreshIsForTheRecorderInPlayAtItsDoorAndNothingOfItGoesOnAcrossALetGo() async throws {
        func missing(_ file: String) -> String { RecorderError.guideFileMissing(name: file, status: 500).explanation }
        /// A refresh begun on `driver`, of every type unless told which, its first file held at `recorder`.
        func refreshing(_ driver: RecorderDriver, _ world: LinkWorld, _ which: GuideAsked = .all,
                        heldAt recorder: HoldingAFile) async -> Task<GuideRefreshed, Never> {
            let refresh = Task { await driver.refreshGuide(which) { world.put("stored \($0)") } }
            var turns = 0
            while await !recorder.isHolding, turns < 100_000 {
                turns += 1
                await Task.yield()
            }
            expectTrue(await recorder.isHolding, "the refresh was meant to have its first file out")
            return refresh
        }

        var (world, driver, link, recorder) = try await holdingAFile()
        var refresh = await refreshing(driver, world, heldAt: recorder)
        link.forgetTheDevice()
        await recorder.letGo(with: .success(HTTPResponse(statusCode: 500)))
        var refreshed = await refresh.value
        XCTAssertFalse(refreshed.wentThrough, "a refresh went through for a recorder let go of")
        XCTAssertEqual(refreshed.failed.map(\.broadcasting), ["td"])
        XCTAssertEqual(refreshed.said, Self.left, "what a write says with no recorder in hand: the line")
        XCTAssertEqual(world.problem, Self.left, "the line was cleared, or written, across a let-go")
        expectEqual(await recorder.files, ["EPG_TRDEPG_FILE.dat"], "a file was asked for after the let-go")
        XCTAssertNil(world.line, "the line was left up")

        (world, driver, link, recorder) = try await holdingAFile()
        refresh = await refreshing(driver, world, .only(["td"]), heldAt: recorder)
        link.forgetTheDevice()
        await recorder.letGo(with: .success(HTTPResponse(statusCode: 500)))
        refreshed = await refresh.value
        XCTAssertFalse(refreshed.wentThrough, "a refresh that ended across a let-go was said to have gone through")
        XCTAssertEqual(refreshed.said, Self.left)
        XCTAssertEqual(world.problem, Self.left, "the line was cleared, or written, across a let-go")

        (world, driver, link, recorder) = try await holdingAFile()
        refresh = await refreshing(driver, world, heldAt: recorder)
        link.forgetTheDevice()
        await recorder.letGo(with: .failure(.transport("timed out")))
        refreshed = await refresh.value
        XCTAssertFalse(refreshed.wentThrough)
        XCTAssertEqual(refreshed.said, Self.left)
        XCTAssertEqual(world.problem, Self.left, "the silence of a recorder let go of was said")
        XCTAssertFalse(link.session.unreachable, "the silence of a recorder let go of was taken for the one in play's")
        expectEqual(await recorder.files, ["EPG_TRDEPG_FILE.dat"])

        // Another recorder at the address, taken up by a connect while the file is out.
        (world, driver, link, recorder) = try await holdingAFile()
        let cache = try XCTUnwrap(world.cache)
        refresh = await refreshing(driver, world, heldAt: recorder)
        let newcomer = try PlayingRecorder([:], udn: Self.anotherUDN)
        world.devices[Stub.host] = newcomer
        await link.connect()
        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, "the newcomer was meant to be taken up")
        expectEqual(try await cache.owner(), Self.anotherUDN, "the cache was meant to be made over to it")
        let lineOfTheNewcomer = world.problem
        let sample = try Vectors.load("epg-sample.json").string("file")
        let guide = try Data(contentsOf: Vectors.directory.appendingPathComponent(sample))
        await recorder.letGo(with: .success(HTTPResponse(statusCode: 200, body: guide)))
        refreshed = await refresh.value
        XCTAssertFalse(refreshed.wentThrough)
        XCTAssertEqual(refreshed.said, RecorderDriver.anotherAnswered)
        XCTAssertEqual(refreshed.stored, 0)
        XCTAssertEqual(world.problem, lineOfTheNewcomer, "the newcomer's line was cleared or written")
        let counts = try await cache.counts()
        for type in GuideRefresh.broadcastingTypes {
            XCTAssertEqual(counts[type]?.programs, 0, "\(type): the last recorder's programmes are in the cache")
            XCTAssertNil(counts[type]?.lastAnswered, "\(type) is marked as answered for")
        }
        XCTAssertFalse(world.events.contains { $0.hasPrefix("stored") }, "a type was reported stored")
        expectEqual(await recorder.files, ["EPG_TRDEPG_FILE.dat"], "more was asked of the recorder let go of")
        expectEqual(await newcomer.actions.filter(\.isEmpty).count, 0, "a file was asked of the newcomer")

        // Let go of while the check before the refresh is out: with a line left, and with the line empty.
        for (left, said) in [(Self.left as String?, RecorderDriver.anotherAnswered),
                             (nil, RecorderDriver.anotherAnswered)] {
            let what = left == nil ? "the line empty" : "a line left"
            let (checked, ofTheChecked, toTheChecked) = try Self.linked()
            let scripted = try XCTUnwrap(checked.devices[Stub.host] as? ScriptedRecorder)
            Self.links.append(toTheChecked)
            checked.cache = try temporaryStore()
            await toTheChecked.connect()
            XCTAssertTrue(toTheChecked.session.connected, checked.problem ?? "no reason given")
            checked.events = []
            await scripted.hold()
            let check = Task { await toTheChecked.ensureUp(evenIfRecent: true) }
            try await Self.whenHeld(scripted)
            let besideTheCheck = Task { await ofTheChecked.refreshGuide(.all) { checked.put("stored \($0)") } }
            for _ in 0..<100_000 where checked.line != "番組表を取得中" { await Task.yield() }
            XCTAssertEqual(checked.line, "番組表を取得中", "the refresh was meant to be waiting for the check")
            toTheChecked.forgetTheDevice()
            checked.problem = left
            await scripted.letGo()
            _ = await check.value
            refreshed = await besideTheCheck.value
            XCTAssertFalse(refreshed.wentThrough, what)
            XCTAssertEqual(refreshed.said, said,
                           "\(what): a check that ended across a let-go was said as a check that said no")
            XCTAssertEqual(checked.events.filter { $0.hasPrefix("ask") }, ["ask description.xml at \(Stub.host)"],
                           "\(what): a file was asked for across a let-go")
            XCTAssertEqual(checked.problem, said, "\(what): the line was written, or cleared, across a let-go")
        }
    }

    /// A refresh that waited its turn asks nothing at all for a recorder let go of meanwhile: no file, and not
    /// who answers either. The turn is another refresh's here, of the test's own, its first file held; a
    /// refresh is asked for and waits under its line; and another recorder is then taken up at the address by
    /// a connect, which lets go of the first. A check has since heard the newcomer busy with somebody else, so
    /// that whatever makes sure of it next asks who answers, however lately it answered. Once the turn comes,
    /// nothing is asked of the newcomer, and nothing of the recorder let go of: the refresh did not go
    /// through, says that another recorder answered, and leaves the newcomer's line as it was.
    func testAGuideWhoseRecorderWasLetGoOfWhileItWaitedItsTurnAsksNothingOfTheOneInItsPlace() async throws {
        let (world, driver, first) = try await Self.playing([:])
        let link = try XCTUnwrap(driver.link)
        world.cache = try temporaryStore()
        let turn = try await holdingTheTurn()
        let refreshing = Task { await driver.refreshGuide(.all) { world.put("stored \($0)") } }
        try await Self.whenWaitingUnderItsLine(world)

        let newcomer = try PlayingRecorder([:], udn: Self.anotherUDN)
        world.devices[Stub.host] = newcomer
        await link.connect()
        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, "the newcomer was meant to be taken up")
        await newcomer.beBusyWhenAskedWhoItIs()
        expectTrue(await link.ensureUp(evenIfRecent: true), "a recorder that answered busy was taken for gone")
        XCTAssertTrue(link.checksAgain, "the check was meant to have heard the newcomer busy")
        await newcomer.sayWhoItIs()
        await newcomer.forget()
        await first.forget()
        let lineOfTheNewcomer = world.problem

        await turn.giveBack()
        let refreshed = await refreshing.value
        XCTAssertFalse(refreshed.wentThrough, "a refresh went through for a recorder let go of as it waited its turn")
        XCTAssertEqual(refreshed.said, RecorderDriver.anotherAnswered)
        expectEqual(await newcomer.actions, [], "the newcomer was asked, for a refresh that is not for it")
        expectEqual(await first.actions, [], "the recorder let go of was asked")
        XCTAssertEqual(world.problem, lineOfTheNewcomer, "the newcomer's line was cleared or written")
        XCTAssertFalse(world.events.contains { $0.hasPrefix("stored") }, "a type was reported stored")
        XCTAssertNil(world.line, "the line was left up")
    }

    /// A refresh whose turn comes while the recorder is being woken hears the waking out, as a run does, and
    /// goes by what it found: a recorder being woken counts as away until the waking is over, and a door asked
    /// first would turn the refresh away over a recorder that is about to answer. The turn is another
    /// refresh's here, of the test's own; a refresh is asked for and waits under its line; the recorder then
    /// says nothing as something else makes sure of it, and is being woken when the turn is given back.
    ///
    /// The recorder answers again: until then the refresh has not come back and no file is asked for; then it
    /// asks for each file, and goes through. With a waking that gets no answer, nothing is asked for: the
    /// refresh did not go through, and says what the waking left on the line.
    func testAGuideWhoseTurnComesWhileTheRecorderIsBeingWokenHearsTheWakingOut() async throws {
        func files(_ recorder: PlayingRecorder) async -> Int { await recorder.actions.filter(\.isEmpty).count }
        /// A refresh waiting its turn on a link that can wake its recorder, the recorder then silent to a check
        /// that wakes it: what is needed to give the turn back and to look at what came of it. The waking is
        /// waited for a bounded while, and whether it is under way is for the row to say: one that gives up
        /// after a twentieth of a second can be over before it is seen.
        func refreshingBesideAWaking(givingUpAfter limit: TimeInterval) async throws
            -> (world: LinkWorld, link: DeviceLink, recorder: PlayingRecorder, turn: TurnHeld, back: Noted,
                refresh: Task<GuideRefreshed, Never>, check: Task<Bool, Never>) {
            let (world, driver, link, recorder) = try await wakeable(givingUpAfter: limit)
            let turn = try await holdingTheTurn()
            let noted = Noted()
            let refresh = Task {
                let came = await driver.refreshGuide(.all) { world.put("stored \($0)") }
                noted.back = true
                return came
            }
            try await Self.whenWaitingUnderItsLine(world)
            await recorder.sayNothingOfWhoItIs()
            let check = Task { await link.ensureUp(evenIfRecent: true) }
            for _ in 0..<100_000 where !link.session.waking { await Task.yield() }
            return (world, link, recorder, turn, noted, refresh, check)
        }

        var beside = try await refreshingBesideAWaking(givingUpAfter: 30)
        XCTAssertTrue(beside.link.session.waking, "the recorder was meant to be being woken")
        await beside.turn.giveBack()
        // The turn is the refresh's from here on. A refresh turned away at a door would be back by now.
        for _ in 0..<100_000 where !beside.back.back { await Task.yield() }
        XCTAssertFalse(beside.back.back, "a refresh whose turn came during a waking did not hear the waking out")
        expectEqual(await files(beside.recorder), 0, "a file was asked for of a recorder being woken")
        await beside.recorder.sayWhoItIs()
        expectTrue(await beside.check.value, "the recorder was meant to have been woken")
        var refreshed = await beside.refresh.value
        XCTAssertTrue(refreshed.wentThrough, refreshed.said ?? "nothing said")
        XCTAssertEqual(refreshed.failed.map(\.broadcasting), GuideRefresh.broadcastingTypes)
        expectEqual(await files(beside.recorder), 4, "each file was meant to be asked for once the recorder answered")

        beside = try await refreshingBesideAWaking(givingUpAfter: 0.05)
        await beside.turn.giveBack()
        expectFalse(await beside.check.value, "a recorder that said nothing was taken for one to ask")
        refreshed = await beside.refresh.value
        XCTAssertFalse(refreshed.wentThrough, "a refresh went through for a recorder that was not woken")
        XCTAssertEqual(refreshed.said, DeviceLinkTests.noAnswer, "the refresh does not say what the waking left")
        XCTAssertEqual(beside.world.problem, DeviceLinkTests.noAnswer)
        expectEqual(await files(beside.recorder), 0, "a file was asked for of a recorder that was not woken")
        XCTAssertNil(beside.world.line, "the line was left up")
    }

    /// The files of a refresh are asked of the client in hand once its turn has come, and not of the one in
    /// hand as it was asked for. The turn is another refresh's here, of the test's own; a refresh is asked for
    /// and waits under its line. Meanwhile the recorder moves: it says nothing where it was, a connect finds
    /// it at another address by its MAC and attaches there with a client of its own, and nobody is let go of,
    /// since it is the same recorder. Once the turn comes, each file is asked for at the address the recorder
    /// is at now and none where it was; the refresh goes through, and the recorder is kept.
    func testAGuideThatWaitedItsTurnIsFetchedThroughTheClientInHandOnceTheTurnHasCome() async throws {
        let world = LinkWorld()
        let recorder = DeviceLinkTests.Recorder(at: Stub.host, udn: DeviceLinkTests.udn, world: world)
        world.devices[Stub.host] = recorder
        world.cache = try temporaryStore()
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: DeviceLinkTests.mac), driver: driver,
                              environment: world.environment)
        link.owner = world
        Self.links.append(link)
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        let turn = try await holdingTheTurn()
        let refreshing = Task { await driver.refreshGuide(.all) { world.put("stored \($0)") } }
        try await Self.whenWaitingUnderItsLine(world)

        let moved = DeviceLinkTests.moved
        let began = link.generation
        await recorder.goSilent()
        let there = DeviceLinkTests.Recorder(at: moved, udn: DeviceLinkTests.udn, world: world)
        world.devices[moved] = there
        world.near = [moved]
        // As a search of the subnet finds it: what it says of itself where it is now.
        world.found = try await RecorderClient(host: moved, transport: there).describe()
        await link.connect()
        XCTAssertEqual(link.client?.host, moved, world.problem ?? "the recorder was meant to be found where it moved")
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        XCTAssertFalse(link.letGo(since: began), "a recorder that moved was meant not to be let go of")
        world.events = []

        await turn.giveBack()
        let refreshed = await refreshing.value
        let files = GuideRefresh.broadcastingTypes.compactMap { Codes.epgFiles[$0] }
        XCTAssertEqual(world.events.filter { $0.hasPrefix("ask EPG_") }, files.map { "ask \($0) at \(moved)" },
                       "the files were not asked for where the recorder is, or were asked for where it was")
        XCTAssertTrue(refreshed.wentThrough, refreshed.said ?? "nothing said")
        XCTAssertTrue(link.session.connected, "the recorder was lost over a file asked for where it no longer is")
        XCTAssertNil(world.line, "the line was left up")
    }

    /// Each file of the guide after the first is asked for only of a recorder made sure of, as each request of
    /// a run is: a refresh is as many requests as it has files, a type's guide and then its logos. Each refresh
    /// here has its first type's file out, held at the recorder, while something happens beside it; the file
    /// then comes, and the refresh comes to its next.
    ///
    /// A check asked for beside the file hears the recorder busy with somebody else as it asks who it is, and
    /// the recorder is busy still. The file comes with a guide, which is stored: the refresh asks again who
    /// answers, through its tries, hears busy, and asks for nothing more -- not the logos of the type it has
    /// just stored, and no further type. It did not go through; the type is reported as stored, with the logos
    /// it had, and handed back with what was stored of it; and what the refresh says is what was heard, in the
    /// recorder's words, which is on the line of what went wrong as well. It is not said as a recorder let go
    /// of. With the first type's file not built instead, there are no logos to ask for and the refresh stops
    /// before its second type: what it says is the first type's line and then what was heard, the line of what
    /// went wrong holding what was heard alone.
    ///
    /// The recorder free again by the time the refresh asks: it hears the recorder say which it is, having
    /// asked once more, asks for the logos, and goes on through every type to its end.
    ///
    /// Each of those three is staged in both orders the check and the refresh can come in. The check's ask of
    /// who answers waits its turn behind the file on the one client, so as a rule the check has ended by the
    /// time the refresh, with the file's programmes to store first, asks before its next file; nothing here
    /// can make that order certain, and nothing rests on it. In the other, the check's ask is held at the
    /// recorder once the file has been answered, until the refresh has stored the type and has had its turns
    /// to come to its asking, so that the refresh is waiting for the check as it ends. The refresh asks who
    /// answers itself either way, the same number of times, and comes to the same end: a check that has
    /// ended is joined by nobody.
    ///
    /// The recorder lost meanwhile, by something else that met its silence: nothing more is asked, of who
    /// answers or for a file, the line of what went wrong is left as it was, and the refresh says what stands
    /// on it, where whatever lost the recorder has said why -- and that the app is not connected only over a
    /// line that holds nothing.
    ///
    /// The recorder found at another address meanwhile, by a connect that attaches there with a client of its
    /// own and lets go of nobody: nothing more is asked for, through the client the file went out on or
    /// through the one in hand now, and the refresh ends there with nothing of a door said. It did not go
    /// through, and what it hands back says nothing of what stands on the line of what went wrong, which is
    /// left as it stands: nothing is wrong with a recorder just connected to. The type that came is stored
    /// and reported so; one that failed before the stop is handed back and said, in its line and no more; and
    /// the recorder is kept. So it is where a check has since heard the recorder busy with somebody else at
    /// its new address, after which whatever makes sure of it asks who answers: the refresh ends at its door
    /// all the same, ahead of any check of its own, and asks nothing there either.
    ///
    /// And the file that was out then meeting silence where the recorder no longer is, in place of an answer:
    /// that silence is not the recorder in play's. The recorder just connected to is kept, nothing is said
    /// and nothing written on the line, and nothing more is asked at either address.
    ///
    /// A connect that is under way still as the file comes, its ask of who answers held at the recorder: the
    /// client in hand is that connect's own by then, and has not heard which recorder answers it. The
    /// refresh ends there as well with nothing said, the line an earlier failure left neither said nor
    /// touched, the type that came stored and reported, and nothing more asked for; the connect is under way
    /// still as the refresh comes back, and then goes through.
    ///
    /// A recorder let go of meanwhile is held where a refresh is kept to the recorder it began with
    /// (`testAGuideRefreshIsForTheRecorderInPlayAtItsDoorAndNothingOfItGoesOnAcrossALetGo`), and says what it
    /// said.
    func testAFileOfTheGuideAfterTheFirstIsAskedForOnlyOfARecorderMadeSureOfAsARunsRequestIs() async throws {
        func missing(_ file: String) -> String { RecorderError.guideFileMissing(name: file, status: 500).explanation }
        let sample = try Vectors.load("epg-sample.json").string("file")
        let guide = HTTPResponse(statusCode: 200,
                                 body: try Data(contentsOf: Vectors.directory.appendingPathComponent(sample)))
        let busy = RecorderError.busy(action: "description.xml").explanation
        let first = ["EPG_TRDEPG_FILE.dat", "EPG_TRDLOGO_FILE.dat"]
        /// A refresh of every type begun on a link of its own, its first file held at the recorder.
        func refreshing(wakeable: Bool = false) async throws
            -> (world: LinkWorld, link: DeviceLink, recorder: HoldingAFile, refresh: Task<GuideRefreshed, Never>) {
            let (world, driver, link, recorder) = try await holdingAFile(wakeable: wakeable)
            let refresh = Task { await driver.refreshGuide(.all) { world.put("stored \($0)") } }
            var turns = 0
            while await !recorder.isHolding, turns < 100_000 {
                turns += 1
                await Task.yield()
            }
            guard await recorder.isHolding else {
                XCTFail("the refresh was meant to have its first file out")
                throw NothingHeld()
            }
            return (world, link, recorder, refresh)
        }
        /// The same with a check asked for beside the file, which hears the recorder busy for `times` asks.
        /// `waitedFor` has that check's own ask held at the recorder when it comes, which is once the file
        /// has been answered (`comeToItsAsking`).
        func refreshingBesideABusyCheck(times: Int = .max, waitedFor: Bool) async throws
            -> (world: LinkWorld, link: DeviceLink, recorder: HoldingAFile, refresh: Task<GuideRefreshed, Never>,
                check: Task<Bool, Never>, asked: Int) {
            let (world, link, recorder, refresh) = try await refreshing()
            let asked = await recorder.asksOfWhoItIs
            await recorder.beBusyWhenAskedWhoItIs(times: times)
            if waitedFor { await recorder.holdTheNextAskOfWhoItIs() }
            let check = Task { await link.ensureUp(evenIfRecent: true) }
            for _ in 0..<100_000 where link.wakeCheck == nil { await Task.yield() }
            XCTAssertNotNil(link.wakeCheck, "the check was meant to be out beside the file")
            return (world, link, recorder, refresh, check, asked)
        }
        /// The file having been let go, with the check's ask held behind it: waits until that ask is held and,
        /// where the file gave a guide, until its programmes are in the cache; gives the refresh its turns to
        /// come to its asking, where it finds the check out and waits for it; and lets the ask go. Each wait a
        /// counted loop of turns that ends in a failure, thrown on.
        func comeToItsAsking(_ world: LinkWorld, _ recorder: HoldingAFile, stored: Bool) async throws {
            var turns = 0
            while await !recorder.isHoldingAnAsk, turns < 100_000 {
                turns += 1
                await Task.yield()
            }
            turns = 0
            while stored, try await world.cache?.counts()["td"]?.programs != 4, turns < 100_000 {
                turns += 1
                await Task.yield()
            }
            guard await recorder.isHoldingAnAsk, turns < 100_000 else {
                XCTFail("the check's ask was never held, or the type never stored")
                throw NothingHeld()
            }
            for _ in 0..<10_000 { await Task.yield() }
            await recorder.letTheAskGo()
        }

        for waitedFor in [false, true] {
            let order = waitedFor ? "the refresh waiting for the check as it ends" : "the check asked for and left to end"

            // Busy with somebody else, and busy still as the refresh comes to the logos of the type it has stored.
            var beside = try await refreshingBesideABusyCheck(waitedFor: waitedFor)
            await beside.recorder.letGo(with: .success(guide))
            if waitedFor { try await comeToItsAsking(beside.world, beside.recorder, stored: true) }
            expectTrue(await beside.check.value, "a recorder that answered busy was taken for gone")
            var refreshed = await beside.refresh.value
            XCTAssertFalse(refreshed.wentThrough, "a refresh went on after a check that heard the recorder busy")
            XCTAssertEqual(refreshed.answered, ["td"], "what came before the stop was not handed back")
            XCTAssertEqual(refreshed.stored, 5)
            XCTAssertEqual(refreshed.failed, [])
            XCTAssertEqual(refreshed.said, busy, "the stop was not said as what was heard: \(order)")
            XCTAssertEqual(beside.world.problem, busy, "what was heard is not on the line")
            expectEqual(await beside.recorder.files, [first[0]],
                        "the logos, or a further type, were asked for after a check that heard busy: \(order)")
            expectEqual(await beside.recorder.asksOfWhoItIs - beside.asked, 6,
                        "who answers was meant to be asked by the check and again before the logos, each thrice: \(order)")
            XCTAssertTrue(beside.world.events.contains("stored td"), "the type stored before the stop was not reported")
            expectEqual(try await beside.world.cache?.counts()["td"]?.programs, 4,
                        "the type that came is not in the cache")
            XCTAssertTrue(beside.link.session.connected, "a recorder that answered busy was given up on")
            XCTAssertNil(beside.world.line, "the line was left up")

            // The same with the first type's file not built: stopped before the second type.
            beside = try await refreshingBesideABusyCheck(waitedFor: waitedFor)
            await beside.recorder.letGo(with: .success(HTTPResponse(statusCode: 500)))
            if waitedFor { try await comeToItsAsking(beside.world, beside.recorder, stored: false) }
            _ = await beside.check.value
            refreshed = await beside.refresh.value
            XCTAssertFalse(refreshed.wentThrough)
            XCTAssertEqual(refreshed.failed.map(\.broadcasting), ["td"])
            XCTAssertEqual(refreshed.said, "地上デジタルの番組表：\(missing(first[0]))\n\(busy)")
            XCTAssertEqual(beside.world.problem, busy, "the type that failed before the stop was written on the line")
            expectEqual(await beside.recorder.files, [first[0]],
                        "a further type was asked for after a check that heard busy: \(order)")
            expectEqual(await beside.recorder.asksOfWhoItIs - beside.asked, 6,
                        "who answers was meant to be asked by the check and again before the next type: \(order)")

            // Busy as the check asks, through its tries, and free again by the time the refresh asks.
            beside = try await refreshingBesideABusyCheck(times: 3, waitedFor: waitedFor)
            await beside.recorder.letGo(with: .success(guide))
            if waitedFor { try await comeToItsAsking(beside.world, beside.recorder, stored: true) }
            expectTrue(await beside.check.value)
            refreshed = await beside.refresh.value
            XCTAssertTrue(refreshed.wentThrough, "\(order): \(refreshed.said ?? "nothing said")")
            XCTAssertEqual(refreshed.answered, ["td"])
            XCTAssertEqual(refreshed.failed.map(\.broadcasting), ["bs", "cs", "bs4k"])
            expectEqual(await beside.recorder.files,
                        first + ["EPG_BSEPG_FILE.dat", "EPG_CSEPG_FILE.dat", "EPG_ADVBSDEPG_FILE.dat"],
                        "the refresh was meant to go on through every file once the recorder said which it is: \(order)")
            expectEqual(await beside.recorder.asksOfWhoItIs - beside.asked, 4,
                        "who answers was meant to be asked once more: \(order)")
            XCTAssertFalse(beside.link.checksAgain)
        }
        var refreshed: GuideRefreshed

        // Lost meanwhile, by something else: with a line left, and with the line empty.
        for (left, said) in [(Self.left as String?, Self.left), (nil, RecorderDriver.notConnected)] {
            let what = left == nil ? "the line empty" : "a line left"
            let (world, link, recorder, refresh) = try await refreshing()
            let asked = await recorder.asksOfWhoItIs
            link.lost()
            world.problem = left
            await recorder.letGo(with: .success(guide))
            refreshed = await refresh.value
            XCTAssertFalse(refreshed.wentThrough, "\(what): a refresh went on for a recorder known to be away")
            XCTAssertEqual(refreshed.answered, ["td"], what)
            XCTAssertEqual(refreshed.stored, 5, what)
            XCTAssertEqual(refreshed.said, said, "\(what): the refresh does not say what stands on the line")
            XCTAssertEqual(world.problem, left, "\(what): a refresh turned away at a door wrote on the line")
            expectEqual(await recorder.files, [first[0]], "\(what): a file was asked of a recorder known to be away")
            expectEqual(await recorder.asksOfWhoItIs, asked,
                        "\(what): a recorder known to be away was asked who answers")
            XCTAssertTrue(world.events.contains("stored td"), "\(what): the type that came was not reported")
        }

        // Found at another address meanwhile, by a connect: a client of its own, and nobody let go of. With the
        // file that was out a guide and a line left since; with it not built and nothing on the line; with the
        // recorder heard busy by a check since, where it is now; and with the file that was out meeting silence
        // where the recorder was.
        let cameAs: [Came: Result<HTTPResponse, RecorderError>] = [
            .guide: .success(guide), .notBuilt: .success(HTTPResponse(statusCode: 500)),
            .nothing: .failure(.transport("timed out")),
        ]
        for (came, left, heardBusy) in [(Came.guide, Self.left as String?, false), (.notBuilt, nil, false),
                                        (.guide, Self.left, true), (.nothing, nil, false)] {
            let what = "\(came.rawValue), \(left == nil ? "the line empty" : "a line left")"
                + (heardBusy ? ", heard busy since" : "")
            let (world, link, recorder, refresh) = try await refreshing(wakeable: true)
            let moved = DeviceLinkTests.moved
            let began = link.generation
            await recorder.sayNothingOfWhoItIs()
            let there = DeviceLinkTests.Recorder(at: moved, udn: DeviceLinkTests.udn, world: world)
            world.devices[moved] = there
            world.near = [moved]
            world.found = try await RecorderClient(host: moved, transport: there).describe()
            await link.connect()
            XCTAssertEqual(link.client?.host, moved, world.problem ?? "the recorder was meant to be found where it moved")
            XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
            XCTAssertFalse(link.letGo(since: began), "a recorder that moved was meant not to be let go of")
            XCTAssertNil(world.problem, "the connect was meant to leave nothing on the line")
            if heardBusy {
                await there.goBusy()
                expectTrue(await link.ensureUp(evenIfRecent: true), "a recorder that answered busy was taken for gone")
                XCTAssertTrue(link.checksAgain, "the check was meant to have heard the recorder busy")
            }
            world.problem = left
            world.events = []
            await recorder.letGo(with: try XCTUnwrap(cameAs[came]))
            refreshed = await refresh.value
            XCTAssertFalse(refreshed.wentThrough, "\(what): a refresh went on through a client that is in hand no longer")
            XCTAssertEqual(refreshed.answered, came == .guide ? ["td"] : [], what)
            XCTAssertEqual(refreshed.failed.map(\.broadcasting), came == .notBuilt ? ["td"] : [], what)
            XCTAssertEqual(refreshed.said, came == .notBuilt ? "地上デジタルの番組表：\(missing(first[0]))" : nil,
                           "\(what): a refresh ended for another client in hand says the types that failed, and no more")
            expectEqual(await recorder.files, [first[0]], "\(what): a file was asked for where the recorder no longer is")
            XCTAssertEqual(world.events.filter { $0.hasPrefix("ask") }, [],
                           "\(what): something was asked where the recorder is now")
            XCTAssertEqual(world.events.contains("stored td"), came == .guide,
                           "\(what): the type that came was not reported")
            XCTAssertEqual(world.problem, left, "\(what): a refresh ended for another client in hand wrote on the line")
            XCTAssertTrue(link.session.connected, "\(what): the recorder just connected to was given up on")
            XCTAssertFalse(link.session.unreachable, "\(what): the recorder just connected to was lost")
            XCTAssertNil(world.line, "\(what): the line was left up")
        }

        // A connect under way as the file comes, its ask of who answers held at the recorder: its own client
        // in hand, which has not heard which recorder answers it.
        let (world, link, recorder, refresh) = try await refreshing()
        await recorder.holdTheNextAskOfWhoItIs()
        let connecting = Task { await link.connect() }
        var turns = 0
        while await !recorder.isHoldingAnAsk, turns < 100_000 {
            turns += 1
            await Task.yield()
        }
        expectTrue(await recorder.isHoldingAnAsk, "the connect's ask of who answers was meant to be held")
        XCTAssertFalse(link.clientIsAttached, "the connect's own client was meant to be in hand, unheard")
        world.events = []
        await recorder.letGo(with: .success(guide))
        refreshed = await refresh.value
        XCTAssertTrue(link.session.connecting, "the connect was meant to be under way still as the refresh ended")
        XCTAssertFalse(refreshed.wentThrough, "a refresh went on beside a connect with a client of its own in hand")
        XCTAssertEqual(refreshed.answered, ["td"])
        XCTAssertNil(refreshed.said, "a refresh ended for the client of a connect under way said something")
        XCTAssertEqual(world.problem, Self.left, "a refresh ended for the client of a connect under way wrote on the line")
        XCTAssertTrue(world.events.contains("stored td"), "the type that came was not reported")
        expectEqual(await recorder.files, [first[0]], "a file was asked for beside a connect under way")
        await recorder.letTheAskGo()
        await connecting.value
        XCTAssertTrue(link.clientIsAttached, world.problem ?? "the connect was meant to go through")
        XCTAssertNil(world.line, "a line was left up")
    }

    /// What the file a refresh has out comes to, once it is let go.
    private enum Came: String {
        case guide = "a guide"
        case notBuilt = "not built"
        case nothing = "nothing at all"
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

    /// A link as `playing` makes one, connected a moment ago with an earlier failure's line left, to a recorder
    /// that says who it is and gives the guide's files as `files` says, by the type each is of: the sample
    /// guide for a type listed as true, nothing at all for one listed as false, and for the rest, as for
    /// everything else it is asked, a 500, as for a file it has not built. `asEachIsAsked` is done on the main
    /// actor as the guide of a type listed is asked for, before it is answered, with that type and the link:
    /// for a test in which something else happens to the link while a file is out.
    private static func serving(_ files: [String: Bool],
                                asEachIsAsked: (@MainActor @Sendable (String, DeviceLink) -> Void)? = nil)
        async throws -> (LinkWorld, RecorderDriver, StubTransport) {
        let description = try Vectors.descriptionXML(udn: DeviceLinkTests.udn)
        let sample = try Vectors.load("epg-sample.json").string("file")
        let guide = try Data(contentsOf: Vectors.directory.appendingPathComponent(sample))
        let world = LinkWorld()
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                              environment: world.environment)
        let recorder = StubTransport { request, _ in
            let name = request.url.lastPathComponent
            if name == "description.xml" { return HTTPResponse(statusCode: 200, body: Data(description.utf8)) }
            guard let type = Codes.epgFiles.first(where: { $0.value == name })?.key, let gives = files[type] else {
                return HTTPResponse(statusCode: 500)
            }
            if let asEachIsAsked { await asEachIsAsked(type, link) }
            guard gives else { throw RecorderError.transport("timed out") }
            return HTTPResponse(statusCode: 200, body: guide)
        }
        world.devices[Stub.host] = recorder
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        world.problem = left
        links.append(link)
        return (world, driver, recorder)
    }

    /// A link as `playing` makes one, connected a moment ago to a recorder that says who it is and holds the
    /// first file of the guide asked of it (`HoldingAFile`), with a cache in hand that the connect has put that
    /// recorder down as the owner of, and an earlier failure's line left. `wakeable` has a MAC known for the
    /// recorder, so that a connect which finds it silent wakes it and then looks for it elsewhere. What the
    /// recorder still holds as the test is torn down is let go then.
    private func holdingAFile(wakeable: Bool = false) async throws
        -> (LinkWorld, RecorderDriver, DeviceLink, HoldingAFile) {
        let world = LinkWorld()
        let recorder = try HoldingAFile(udn: DeviceLinkTests.udn)
        world.devices[Stub.host] = recorder
        world.cache = try temporaryStore()
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: wakeable ? DeviceLinkTests.mac : nil),
                              driver: driver, environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        expectEqual(try await world.cache?.owner(), DeviceLinkTests.udn, "the cache was meant to be this recorder's")
        world.problem = Self.left
        Self.links.append(link)
        // The guide's turn is the whole process's: a file, or an ask of who answers, left held by a test that
        // failed part-way would keep its refresh in the turn, and every later refresh waiting.
        addTeardownBlock {
            await recorder.letTheAskGo()
            await recorder.letGo(with: .success(HTTPResponse(statusCode: 500)))
        }
        return (world, driver, link, recorder)
    }

    /// A link as `playing` makes one, to a recorder that can be woken: a MAC is known for it, and a check that
    /// meets silence wakes it, asking every hundredth of a second and giving up after `limit` seconds. With a
    /// cache in hand and an earlier failure's line left; the recorder has put down nothing yet.
    private func wakeable(givingUpAfter limit: TimeInterval) async throws
        -> (LinkWorld, RecorderDriver, DeviceLink, PlayingRecorder) {
        let world = LinkWorld()
        let recorder = try PlayingRecorder([:], udn: DeviceLinkTests.udn)
        world.devices[Stub.host] = recorder
        world.cache = try temporaryStore()
        let driver = RecorderDriver(wakingLimit: limit, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: DeviceLinkTests.mac), driver: driver,
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        await recorder.forget()
        world.problem = Self.left
        Self.links.append(link)
        return (world, driver, link, recorder)
    }

    /// The guide's one turn, taken by a refresh of the test's own: on a client and into a cache of its own, its
    /// first file held at a recorder of its own (`HoldingAFile`) until the test gives the turn back
    /// (`TurnHeld.giveBack`). The turn is the whole process's, so the file is let go as the test is torn down
    /// as well: left held by a test that failed part-way, it would keep every later refresh waiting.
    private func holdingTheTurn() async throws -> TurnHeld {
        let recorder = try HoldingAFile(udn: DeviceLinkTests.udn)
        let client = RecorderClient(host: Stub.host, transport: recorder, streamPort: 60151, busyRetryDelay: 0...0)
        let store = try temporaryStore()
        addTeardownBlock { await recorder.letGo(with: .success(HTTPResponse(statusCode: 500))) }
        let refresh = Task { await GuideRefresh.run(client: client, store: store) }
        var turns = 0
        while await !recorder.isHolding, turns < 100_000 {
            turns += 1
            await Task.yield()
        }
        guard await recorder.isHolding else {
            XCTFail("the refresh that was to have the turn never asked for its first file")
            throw NothingHeld()
        }
        return TurnHeld(recorder: recorder, refresh: refresh)
    }

    /// Waits, a bounded while, for a refresh asked for on `world`'s link to have put its line up, which it
    /// does before it waits its turn: a counted loop of turns, and a failure, thrown on, when it has not by
    /// then.
    private static func whenWaitingUnderItsLine(_ world: LinkWorld) async throws {
        for _ in 0..<100_000 where world.line != RecorderDriver.guideLine { await Task.yield() }
        guard world.line == RecorderDriver.guideLine else {
            XCTFail("the refresh that was to wait its turn never put its line up")
            throw NothingHeld()
        }
    }

    /// The types whose guide `recorder` was asked for, in the order it was asked.
    private static func guideFiles(asked recorder: StubTransport) async -> [String] {
        await recorder.requests.compactMap { request in
            Codes.epgFiles.first { $0.value == request.url.lastPathComponent }?.key
        }
    }

    /// Waits, a bounded while, for `recorder` to be holding an ask of who it is: a counted loop of turns, and a
    /// failure, thrown on, when none has come by then. The recorder's own wait for it has no bound.
    private static func whenHeld(_ recorder: ScriptedRecorder) async throws {
        let noted = Noted()
        Task {
            await recorder.whenHeld()
            noted.back = true
        }
        for _ in 0..<100_000 where !noted.back { await Task.yield() }
        guard noted.back else {
            XCTFail("the ask that was to be held never came")
            throw NothingHeld()
        }
    }

    /// The links the tests above made, kept for as long as the tests run, their drivers holding them weakly.
    private static var links: [DeviceLink] = []

    /// Another recorder than the one `playing` makes: Sony's OUI and the rest zeroed, with a last digit of its own.
    private static let anotherUDN = "uuid:00000000-0000-0000-0000-f84e17000002"

    /// What a recorder answers when asked how much room its disk has: `free` bytes of a hundred.
    private static func space(free: Int) -> HTTPResponse {
        let info = "<RecordDestinationInfo totalCapacity=\"100\" availableCapacity=\"\(free)\"/>"
        return Stub.soap("X_HDLnkGetRecordDestinationInfo",
                         extra: "<RecordDestinationInfo>\(Soap.escape(info))</RecordDestinationInfo>")
    }

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

/// What a test's own tasks and closures noted, for a test that sets something going and looks afterwards at
/// what it did.
@MainActor
private final class Noted {
    /// Whether what was set going has begun: it notes that and goes on in the same turn, so by the time the
    /// test sees it, what was set going has got as far as its first wait.
    var begun = false
    /// Whether what was set going has come back.
    var back = false
    var rowsTakenOut = 0
    var list: [String]?
}

/// The guide's one turn as a refresh of a test's own has it, its first file held at a recorder of its own
/// (`holdingTheTurn`).
private struct TurnHeld {
    let recorder: HoldingAFile
    let refresh: Task<GuideRefresh.Outcome, Never>

    /// Lets the file held go, answered as one not built, and waits for that refresh to end: the turn is then
    /// whoever's waited for it.
    func giveBack() async {
        await recorder.letGo(with: .success(HTTPResponse(statusCode: 500)))
        _ = await refresh.value
    }
}

/// A recorder that says who it is as the vectors' recorder does, and holds the first file of the guide it is
/// asked for until the test lets it go, with what that file then gets: an answer, or nothing at all. Every file
/// after it, and everything else it is asked, gets a 500, as from a recorder that has not built its files. It
/// puts down the guide's files it was asked for, by name, and counts how often it was asked who it is; it can
/// be told to be busy with somebody else when asked that, for so many asks or from then on, or to say nothing
/// to it from then on, as a recorder that is no longer at the address; and to hold the next ask of who it is
/// until that is let go, which then gets whatever it would get.
private actor HoldingAFile: HTTPTransport {
    private let description: String
    private var holds = true
    private var held: CheckedContinuation<Result<HTTPResponse, RecorderError>, Never>?
    private(set) var files: [String] = []
    private(set) var asksOfWhoItIs = 0
    private var busyFor = 0
    private var saysWhoItIs = true
    private var holdsTheNextAsk = false
    private var heldAsk: CheckedContinuation<Void, Never>?

    init(udn: String) throws {
        description = try Vectors.descriptionXML(udn: udn)
    }

    /// Whether the file is being held now.
    var isHolding: Bool { held != nil }

    /// The file held gets `answer` now.
    func letGo(with answer: Result<HTTPResponse, RecorderError>) {
        held?.resume(returning: answer)
        held = nil
    }

    /// Busy with somebody else to the next `times` asks of who it is, a 503 to each: from now on, unless told
    /// how many.
    func beBusyWhenAskedWhoItIs(times: Int = .max) {
        busyFor = times
    }

    /// Says nothing from now on when asked who it is. The file held stays held.
    func sayNothingOfWhoItIs() {
        saysWhoItIs = false
    }

    /// The next ask of who it is gets no answer until `letTheAskGo`.
    func holdTheNextAskOfWhoItIs() {
        holdsTheNextAsk = true
    }

    /// Whether an ask of who it is is being held now.
    var isHoldingAnAsk: Bool { heldAsk != nil }

    func letTheAskGo() {
        holdsTheNextAsk = false
        heldAsk?.resume()
        heldAsk = nil
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let name = request.url.lastPathComponent
        if name == "description.xml" {
            asksOfWhoItIs += 1
            if holdsTheNextAsk {
                holdsTheNextAsk = false
                await withCheckedContinuation { heldAsk = $0 }
            }
            guard saysWhoItIs else { throw RecorderError.transport("timed out") }
            guard busyFor == 0 else {
                busyFor -= 1
                return HTTPResponse(statusCode: 503)
            }
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        guard Codes.epgFiles.values.contains(name) || Codes.logoFiles.values.contains(name) else {
            return HTTPResponse(statusCode: 500)
        }
        files.append(name)
        guard holds else { return HTTPResponse(statusCode: 500) }
        holds = false
        return try await withCheckedContinuation { held = $0 }.get()
    }
}

/// Thrown to end a test whose request never came to be held, once the failure is recorded.
private struct NothingHeld: Error {}
