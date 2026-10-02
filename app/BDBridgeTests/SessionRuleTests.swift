import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The rules about being connected, one test to a rule: what counts as the recorder being gone, what the app
/// does about it and what it leaves alone, and when it asks again. They are the ones docs/porting.md sets
/// out under 端末側の設計メモ, and each was learnt on a phone beside a recorder. The tests are here so that
/// the model can be taken apart without any of them changing.
///
/// Nothing here wakes anything: no MAC is saved and the model puts nothing on the network by itself
/// (`Surroundings.reachesTheLAN`), so a recorder that is silent is given up on at once.
@MainActor
final class SessionRuleTests: XCTestCase {
    /// A model with a guide in its cache, started, and its first connect over.
    private func started(_ bench: Bench, recorder: any HTTPTransport) async throws -> AppModel {
        try await bench.cacheAGuide()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await until("the first connect never ended", within: 20) {
            !model.connecting && (model.connected || model.gaveUp || model.problem != nil)
        }
        return model
    }

    /// A programme from the cached guide that starts an hour or more from now.
    private func aProgramme(_ model: AppModel) async throws -> GuideProgramRow {
        let later = Date().addingTimeInterval(3600)
        let found = await model.search("サンプル").hits.first { $0.program.start > later }
        return try XCTUnwrap(found?.program, "the cached guide had nothing an hour or more ahead")
    }

    // MARK: - what counts as gone

    /// Only silence is given up on. A recorder that answers, if only to say it is busy, is there, and has
    /// said what is wrong: giving up on it put 接続していません beside a recorder that was answering and kept
    /// the next return to the app from asking again.
    func testARecorderThatAnswersBusyIsNotGivenUpOn() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = BusyRecorder()
        let model = try await started(bench, recorder: recorder)

        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.gaveUp, "an answer was taken for silence")
        XCTAssertFalse(model.unreachable)
        XCTAssertNotNil(model.problem, "nothing on screen says why the app is not connected")

        let asked = await recorder.asked
        model.wentToBackground()
        await model.returnedToForeground()
        let askedAgain = await recorder.asked
        XCTAssertGreaterThan(askedAgain, asked, "coming back to the app did not ask a recorder that is there")
    }

    /// Whether the app is connected is decided by the description alone. The firmware, the MAC and the free
    /// space are only shown, or kept for later, and another model of the series may refuse them: failing on
    /// that failed the whole connect with the recorder answering, and nothing after it was read.
    func testARecorderThatRefusesWhatIsOnlyShownIsStillConnected() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = PickyRecorder(refusing: ["X_GetFirmwareVersion", "X_GetPrivateIp",
                                                "X_HDLnkGetRecordDestinationInfo"])
        let model = try await started(bench, recorder: recorder)

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertFalse(model.gaveUp)
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.firmware, "")
        XCTAssertNil(model.storage)
        XCTAssertNil(model.mac)
        XCTAssertFalse(model.reservations.isEmpty, "the connect stopped before the reservations")
    }

    /// Silence is taken in one place, whatever was being asked: the app is left where a connect that got no
    /// answer leaves it, and nothing asks again by itself. Before, the app went on looking connected and
    /// each screen waited out the same timeout in turn.
    func testSilenceOnAnyRequestLeavesTheAppOffline() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = RecorderAtHome()
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.connected)

        await recorder.setReachable(false)
        await model.loadTitles(force: true)

        XCTAssertTrue(model.offline)
        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.gaveUp, "a request that met silence did not leave the app given up")
        let asked = await recorder.asked
        await model.loadReservations()
        await model.loadTitles(force: true)
        await model.loadRecorderRules()
        let askedAfter = await recorder.asked
        XCTAssertEqual(askedAfter, asked, "a screen asked a recorder the app knew was not answering")
    }

    /// A recorder that has just described itself is connected, and stays marked silent from before until the
    /// rest of the attach has been read. A list asked for in between finds nothing to ask and is not asked
    /// for again, so a screen that loads when `connected` turns true was left empty after the recorder had
    /// been woken with that screen open. The screens load on connected and not offline together; the second
    /// is what the load itself checks.
    func testAListIsReadOnceTheRecorderHasAnsweredAndNotTheMomentItDescribesItself() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = RecorderPartWayThroughAnAttach()
        await recorder.setReachable(false)
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.gaveUp)
        XCTAssertTrue(model.unreachable)

        await recorder.setReachable(true)
        await recorder.holdAfterTheDescription()
        let connecting = Task { await model.connect() }
        try await until("the recorder never described itself") { model.connected }
        XCTAssertTrue(model.offline, "the mark of the earlier silence went before the attach had read the rest")
        // Not awaited bare: with the mark gone too soon the list is asked for, behind the read that is held,
        // and would wait here for a `letGo()` that is on the next line.
        try await within(5, "a list asked for while the recorder was still marked silent did not return") {
            await model.loadTitles()
        }
        XCTAssertFalse(model.titlesLoaded, "a list was read from a recorder still marked silent")

        await recorder.letGo()
        try await until("the attach never finished") { model.connected && !model.offline }
        await model.loadTitles()
        XCTAssertTrue(model.titlesLoaded, "the list was not read once the recorder had answered")
        XCTAssertFalse(model.titles.isEmpty)
        await connecting.value
    }

    // MARK: - writes

    /// A reservation that went out and met silence may have been made all the same. It is not sent again and
    /// not queued, which would make it a second time once the recorder is back, and the reader is told to
    /// look.
    func testAReservationThatMetSilenceAfterItWasSentIsNotQueued() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = RecorderAtHome()
        let model = try await started(bench, recorder: recorder)
        let program = try await aProgramme(model)
        XCTAssertTrue(model.connected)

        await recorder.setReachable(false)
        let asked = await recorder.asked
        let made = await model.reserve(program, quality: "DR", repeating: "none")

        XCTAssertFalse(made)
        let askedAfter = await recorder.asked
        XCTAssertEqual(askedAfter, asked + 1, "the reservation was sent more than once, or not at all")
        XCTAssertNil(model.pending(for: program), "a reservation that may have arrived was queued")
        let onDisk = try await GuideStore(path: bench.guidePath).pendingReservations()
        XCTAssertTrue(onDisk.isEmpty)
        XCTAssertTrue(model.gaveUp)
        XCTAssertTrue(model.problem?.contains("送信待ちにはしていません") ?? false, model.problem ?? "no reason given")
    }

    /// While the recorder is being made sure of, whatever else is asked waits for that answer rather than
    /// sending a probe, or a request, of its own. When the answer is silence nothing of the reservation has
    /// been sent, so the queue is the place for it.
    func testAReservationAskedForDuringACheckThatMeetsSilenceIsQueuedUnsent() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = RecorderAtHome()
        let model = try await started(bench, recorder: recorder)
        let program = try await aProgramme(model)
        XCTAssertTrue(model.connected)

        // Leaving home with the app open: the network changes, and the recorder is asked whether it is
        // still there. The ask is held, so that the reservation arrives while it is out.
        bench.network = "away"
        await recorder.setReachable(false, holding: true)
        let asked = await recorder.asked
        let check = Task { await model.networkChangedWhileOpen() }
        try await until("the recorder was never made sure of") { await recorder.asked > asked }
        let reserving = Task { await model.reserve(program, quality: "DR", repeating: "none") }
        try await Task.sleep(for: .milliseconds(200))
        await recorder.letGo()
        _ = await check.value
        let kept = await reserving.value

        XCTAssertTrue(kept, "the reservation was not kept: \(model.problem ?? "no reason given")")
        XCTAssertNotNil(model.pending(for: program))
        let askedAfter = await recorder.asked
        XCTAssertEqual(askedAfter, asked + 1, "something besides the one check was sent")
        XCTAssertTrue(model.offline)
    }

    /// What waits in the queue is sent whenever the recorder answers, by the connect itself.
    func testTheQueueIsSentWhenTheRecorderAnswersAgain() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = RecorderAtHome()
        await recorder.setReachable(false)
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.gaveUp)
        let program = try await aProgramme(model)
        let kept = await model.reserve(program, quality: "DR", repeating: "none")
        XCTAssertTrue(kept)
        XCTAssertNotNil(model.pending(for: program))

        await recorder.setReachable(true)
        await model.connect()

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertNil(model.pending(for: program), "the reservation is still waiting")
        XCTAssertNotNil(model.reservation(for: program), "the recorder does not hold the reservation")
        XCTAssertNotNil(model.flushReport, "nothing on screen says the waiting reservation was sent")
        let onDisk = try await GuideStore(path: bench.guidePath).pendingReservations()
        XCTAssertTrue(onDisk.isEmpty)
    }

    // MARK: - when it asks again

    /// Given up stays given up until the network changes or the reader asks. 再接続 and pulling down are the
    /// reader asking, and they do ask, on the same network.
    func testTheReaderAskingTriesAgainOnTheSameNetwork() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = SilentRecorder()
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.gaveUp)
        let asked = await recorder.asked

        await model.connect()

        let askedAfter = await recorder.asked
        XCTAssertGreaterThan(askedAfter, asked, "再接続 did not ask the recorder")
        XCTAssertTrue(model.gaveUp)
    }

    /// The network under the phone can change while a connect is under way, and the watcher keeps out of a
    /// connect's way. So a connect that got nowhere tries once more, itself, when the network it started on
    /// is no longer the one under it -- once, and then gives up as usual.
    func testAConnectTriesOnceMoreWhenTheNetworkChangedUnderIt() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let recorder = SilentRecorder(holding: true)
        let model = bench.model(recorder: recorder)
        await model.start()
        try await until("the first connect never asked the recorder") { await recorder.asked > 0 }

        bench.network = "the Wi-Fi at home, joined on the way in"
        await recorder.letGo()
        try await until("the connect never ended") { !model.connecting }

        let asked = await recorder.asked
        XCTAssertEqual(asked, 2, "one try on the network that went and one on the network that came")
        XCTAssertTrue(model.gaveUp)
        XCTAssertFalse(model.networkChanged, "the app gave up on a network it had not tried")
    }

    /// A connect whose network stayed where it was tries once.
    func testAConnectOnOneNetworkTriesOnce() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = SilentRecorder()
        let model = try await started(bench, recorder: recorder)

        let asked = await recorder.asked
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(model.gaveUp)
    }

    /// Becoming active is not coming back. Control Centre, a notification pulled down and a system alert
    /// take the app out of being active without it going anywhere, and connecting after each sent a magic
    /// packet for a glance at the time. Only a real trip to the background counts.
    func testBecomingActiveWithoutHavingBeenAwayDoesNotConnect() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = SilentRecorder()
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.gaveUp)
        // On another network, where coming back from the background would ask again.
        bench.network = "away"
        let asked = await recorder.asked

        await model.returnedToForeground()
        let askedWithoutLeaving = await recorder.asked
        XCTAssertEqual(askedWithoutLeaving, asked, "the app connected after a moment that went nowhere")

        model.wentToBackground()
        await model.returnedToForeground()
        let askedAfterLeaving = await recorder.asked
        XCTAssertGreaterThan(askedAfterLeaving, asked, "a real return to the app did not ask")
    }

    /// Nor on every flick between apps: a recorder that answered within the last minute is not asked again
    /// for the app having been away for a moment.
    func testComingBackWithinAMinuteOfAnAnswerDoesNotConnectAgain() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = RecorderAtHome()
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.connected)
        try await until("the first connect's work never finished") { model.busy == nil }
        let asked = await recorder.asked

        model.wentToBackground()
        await model.returnedToForeground()

        let askedAfter = await recorder.asked
        XCTAssertEqual(askedAfter, asked, "the recorder was asked again a moment after it had answered")
        XCTAssertTrue(model.connected)
    }
}
