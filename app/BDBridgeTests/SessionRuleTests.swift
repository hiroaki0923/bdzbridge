import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The rules about being connected, one test to a rule: what counts as the recorder being gone, what the app
/// does about it and what it leaves alone, what goes when another recorder is chosen, and when it asks
/// again. They are the ones docs/porting.md sets out under 端末側の設計メモ. Most were learnt on a phone
/// beside a recorder; the list read once the recorder has answered, and the ones about another recorder, were
/// found by reading the code. The tests are here so that the model can be taken apart without any of them
/// changing.
///
/// Nothing here wakes anything: no MAC is saved, the recorders here keep theirs to themselves, and the model
/// puts nothing on the network by itself (`Surroundings.reachesTheLAN`), so a recorder that is silent is given
/// up on at once. The tests that enter the demo do save its MAC, which is nobody's, and the demo sends no
/// packet.
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
        let bench = try aBench()
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
        let bench = try aBench()
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
        let bench = try aBench()
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
        expectEqual(await recorder.asked, asked, "a screen asked a recorder the app knew was not answering")
    }

    /// A recorder that has just described itself is connected, and stays marked silent from before until the
    /// rest of the attach has been read. A list asked for in between finds nothing to ask and is not asked
    /// for again, so a screen that loads when `connected` turns true was left empty after the recorder had
    /// been woken with that screen open. The screens load on connected and not offline together; the second
    /// is what the load itself checks.
    func testAListIsReadOnceTheRecorderHasAnsweredAndNotTheMomentItDescribesItself() async throws {
        let bench = try aBench()
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
        let bench = try aBench()
        let recorder = RecorderAtHome()
        let model = try await started(bench, recorder: recorder)
        let program = try await aProgramme(model)
        XCTAssertTrue(model.connected)

        await recorder.setReachable(false)
        let asked = await recorder.asked
        let made = await model.reserve(program, quality: "DR", repeating: "none")

        XCTAssertFalse(made)
        expectEqual(await recorder.asked, asked + 1, "the reservation was sent more than once, or not at all")
        XCTAssertNil(model.pending(for: program), "a reservation that may have arrived was queued")
        expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty)
        XCTAssertTrue(model.gaveUp)
        XCTAssertTrue(model.problem?.contains("送信待ちにはしていません") ?? false, model.problem ?? "no reason given")
    }

    /// While the recorder is being made sure of, whatever else is asked waits for that answer rather than
    /// sending a probe, or a request, of its own. When the answer is silence nothing of the reservation has
    /// been sent, so the queue is the place for it.
    func testAReservationAskedForDuringACheckThatMeetsSilenceIsQueuedUnsent() async throws {
        let bench = try aBench()
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
        expectEqual(await recorder.asked, asked + 1, "something besides the one check was sent")
        XCTAssertTrue(model.offline)
    }

    /// What waits in the queue is sent whenever the recorder answers, by the connect itself.
    func testTheQueueIsSentWhenTheRecorderAnswersAgain() async throws {
        let bench = try aBench()
        let recorder = RecorderAtHome()
        await recorder.setReachable(false)
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.gaveUp)
        let program = try await aProgramme(model)
        expectTrue(await model.reserve(program, quality: "DR", repeating: "none"))
        XCTAssertNotNil(model.pending(for: program))

        await recorder.setReachable(true)
        await model.connect()

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertNil(model.pending(for: program), "the reservation is still waiting")
        XCTAssertNotNil(model.reservation(for: program), "the recorder does not hold the reservation")
        XCTAssertNotNil(model.flushReport, "nothing on screen says the waiting reservation was sent")
        expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty)
    }

    // MARK: - another recorder

    /// A model connected to a recorder that has one broadcast twice on its disk, with everything the screens
    /// would have read from it by now: its recordings, its keyword conditions, the set of copies with one
    /// ticked for deletion, and the scan that found them finished. `others` is what answers elsewhere.
    private func settledIn(_ bench: Bench, others: [String: any HTTPTransport] = [:]) async throws -> AppModel {
        try await bench.cacheAGuide()
        var recorders = others
        recorders[Bench.host] = RecorderWithACopy()
        let model = bench.model(recorders: recorders)
        await model.start()
        try await until("the first connect never finished", within: 20) { model.connected && !model.connecting }
        await model.loadTitles()
        await model.loadRecorderRules()
        model.startDuplicateScan()
        try await until("the scan never finished", within: 20) { model.job?.finished == true }
        XCTAssertFalse(model.reservations.isEmpty)
        XCTAssertFalse(model.titles.isEmpty)
        XCTAssertFalse(model.recorderRules.isEmpty)
        XCTAssertFalse(model.duplicates.isEmpty, "the two copies were not found")
        XCTAssertFalse(model.duplicatePicks.isEmpty, "neither copy came up ticked")
        XCTAssertNotNil(model.storage)
        XCTAssertTrue(model.canChangeRecorder)
        return model
    }

    /// Choosing another address is choosing another recorder, for all the app can tell before anything
    /// answers there, and what the last one said goes at the choice: its description and free space, its
    /// reservations, recordings and keyword conditions, the sets of copies with their ticks, and the job that
    /// last ran on it. They used to stay. The client pointed at the new address from that moment, so a delete
    /// tapped in the old list went to the new recorder under the old one's id, and the recordings were never
    /// read again, since the app had them down as read.
    func testChoosingAnotherAddressForgetsTheLastRecorderBeforeTheNewOneIsAsked() async throws {
        let bench = try aBench()
        let other = SilentRecorder(holding: true)
        let model = try await settledIn(bench, others: [Bench.otherHost: other])
        // The lists narrowed, as the reader may have left them.
        model.titleGenre = 3
        model.titleState = .unwatched
        model.reservationKind = .automatic

        let choosing = Task { await model.adopt(host: Bench.otherHost) }
        try await until("the address chosen was never asked") { await other.asked > 0 }

        XCTAssertEqual(model.host, Bench.otherHost)
        XCTAssertFalse(model.connected, "the app looks connected to the recorder it has left")
        XCTAssertNil(model.storage, "the last recorder's free space is still shown")
        XCTAssertEqual(model.firmware, "")
        XCTAssertTrue(model.reservations.isEmpty, "the last recorder's reservations still mark the guide")
        XCTAssertTrue(model.titles.isEmpty, "the last recorder's recordings are still listed")
        XCTAssertFalse(model.titlesLoaded, "the recordings would not be read from the recorder chosen")
        XCTAssertTrue(model.recorderRules.isEmpty)
        XCTAssertFalse(model.recorderRulesLoaded)
        XCTAssertTrue(model.duplicates.isEmpty)
        XCTAssertTrue(model.duplicatePicks.isEmpty, "a copy on the last recorder is still ticked for deletion")
        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertNil(model.job, "a scan of the last recorder would pass for a scan of this one")
        XCTAssertNil(model.titleGenre, "the next recorder's recordings would open narrowed to a genre")
        XCTAssertNil(model.titleState)
        XCTAssertEqual(model.reservationKind, .all)

        await other.letGo()
        await choosing.value
        XCTAssertTrue(model.gaveUp)
        XCTAssertTrue(model.titles.isEmpty)
    }

    /// The recorder chosen is then read as any recorder is: its reservations by the connect, and its
    /// recordings when a screen asks for them, which is what did not happen while the last recorder's stood.
    func testTheRecorderChosenIsReadForItself() async throws {
        let bench = try aBench()
        let model = try await settledIn(bench, others: [Bench.otherHost: RecorderAtHome()])
        // One recording fewer on the first recorder than on the second, which tells their lists apart. Not
        // one of the copies: deleting the one ticked would take the set, and its tick, away before the choice.
        let copies = Set(model.duplicates.flatMap { $0.items.map(\.id) })
        let gone = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected && !copies.contains($0.id) })
        expectTrue(await model.delete(gone), model.problem ?? "no reason given")
        XCTAssertFalse(model.duplicatePicks.isEmpty)
        let attached = model.timesAttached

        await model.adopt(host: Bench.otherHost)

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertEqual(model.info?.host, Bench.otherHost)
        XCTAssertEqual(model.timesAttached, attached + 1, "the tutorial would not close on this answer")
        XCTAssertFalse(model.reservations.isEmpty, "the connect did not read the reservations")
        XCTAssertFalse(model.titlesLoaded)
        await model.loadTitles()   // what the recordings tab does when it is shown
        XCTAssertTrue(model.titles.contains { $0.id == gone.id }, "the recordings are not the chosen recorder's")
        XCTAssertTrue(model.duplicatePicks.isEmpty)
    }

    /// What answers at the address chosen need not be a recorder, and a recorder there may be busy with
    /// somebody else. The last recorder's description stood through either answer -- something had answered,
    /// so what was known stood -- and the app looked connected to the recorder it had left, with its lists up,
    /// while every request went to the new address.
    func testAnAddressThatAnswersWithoutDescribingItselfIsNotTakenForTheLastRecorder() async throws {
        let answering: [any HTTPTransport] = [NotARecorder(), BusyRecorder()]
        for other in answering {
            let bench = try aBench()
            let model = try await settledIn(bench, others: [Bench.otherHost: other])

            await model.adopt(host: Bench.otherHost)

            XCTAssertEqual(model.host, Bench.otherHost)
            XCTAssertFalse(model.connected, "the app looks connected to the recorder it has left")
            XCTAssertFalse(model.gaveUp, "an answer was taken for silence")
            XCTAssertFalse(model.unreachable)
            XCTAssertNotNil(model.problem, "nothing on screen says why the app is not connected")
            XCTAssertTrue(model.titles.isEmpty, "the last recorder's recordings are still listed")
            XCTAssertTrue(model.reservations.isEmpty)
            XCTAssertTrue(model.duplicatePicks.isEmpty)
        }
    }

    /// The address already in use, chosen again -- its own row in a scan's list, or typed once more -- is the
    /// recorder the app has, and connects again as 再接続 does. Nothing it said is thrown away: well over a
    /// thousand recordings would be read a second time, and the reader's ticks would go.
    func testChoosingTheAddressInUseAgainForgetsNothing() async throws {
        let bench = try aBench()
        let model = try await settledIn(bench)
        let recordings = model.titles.map(\.id), ticked = model.duplicatePicks
        let attached = model.timesAttached

        await model.adopt(host: Bench.host)

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertEqual(model.timesAttached, attached + 1, "the address in use, chosen again, did not connect again")
        XCTAssertTrue(model.titlesLoaded, "the recordings would be read again")
        XCTAssertEqual(model.titles.map(\.id), recordings)
        XCTAssertEqual(model.duplicatePicks, ticked, "the reader's ticks went")
        XCTAssertTrue(model.recorderRulesLoaded)
        XCTAssertNotNil(model.job)
    }

    /// An address is the one in use however it is spelled (`RecorderAddress.same`). What a screen hands over
    /// has been tidied already, so the one difference that gets this far is a name's case.
    func testTheAddressInUseSpelledInAnotherCaseForgetsNothing() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = RecorderAtHome()
        let model = bench.model(recorders: ["bdz.local": recorder, "BDZ.local": recorder])
        await model.start()
        try await untilGivenUp(model)
        await model.adopt(host: "bdz.local")
        await model.loadTitles()
        XCTAssertTrue(model.titlesLoaded, model.problem ?? "no reason given")

        await model.adopt(host: "BDZ.local")

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertTrue(model.titlesLoaded, "the recordings would be read again for a name spelled another way")
    }

    /// What is waiting to be sent is the reader's and not something a recorder said: it stays on screen and
    /// on disk through the choice, where the lists read from the last recorder go.
    func testReservationsWaitingToBeSentStayWhenAnotherAddressIsChosen() async throws {
        let bench = try aBench()
        let recorder = RecorderAtHome()
        await recorder.setReachable(false)
        try await bench.cacheAGuide()
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilGivenUp(model)
        let program = try await aProgramme(model)
        expectTrue(await model.reserve(program, quality: "DR", repeating: "none"), model.problem ?? "no reason given")

        await model.adopt(host: Bench.otherHost)

        XCTAssertNotNil(model.pending(for: program), "the reservation waiting is no longer shown")
        let onDisk = try await GuideStore(path: bench.guidePath).pendingReservations()
        XCTAssertEqual(onDisk.map(\.request.eventID), [program.eventID])
    }

    /// What waits goes to a recorder that has said who it is, and to nothing else, whoever asks for it to be
    /// sent. A recorder that answered the choice with a 503 -- busy with somebody else as it was asked -- has
    /// not, and the app is not connected to it. It answered, though, so the screens do not take it for gone,
    /// and pulling the reservations down read its list and then sent the queue: that handed what was waiting
    /// for the last recorder to whatever was at the address. Pulling down connects instead now
    /// (`refreshReservations`), and the rule is held where the queue is sent.
    func testTheQueueIsNotSentToARecorderThatHasNotSaidWhoItIs() async throws {
        let bench = try aBench()
        let recorder = RecorderAtHome(), other = RecorderBusyAtTheDoor()
        await recorder.setReachable(false)
        try await bench.cacheAGuide()
        let model = bench.model(recorders: [Bench.host: recorder, Bench.otherHost: other])
        await model.start()
        try await untilGivenUp(model)
        let program = try await aProgramme(model)
        expectTrue(await model.reserve(program, quality: "DR", repeating: "none"), model.problem ?? "no reason given")

        await model.adopt(host: Bench.otherHost)
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.offline, "it answered, so the screens do not take it for gone")
        // What pulling the reservations down did while the app was not offline.
        await model.loadReservations()
        await model.flushPending()

        expectEqual(await other.made, 0, "what was waiting was sent to a recorder that never said which it is")
        XCTAssertNotNil(model.pending(for: program), "the reservation waiting is no longer shown")
        let onDisk = try await GuideStore(path: bench.guidePath).pendingReservations()
        XCTAssertEqual(onDisk.map(\.request.eventID), [program.eventID])
        XCTAssertEqual(onDisk.map(\.problem), [nil], "the reservation was held back, with a reason, by nobody")
    }

    /// While the recorder is being made sure of, with nothing on the strip to say so, another cannot be
    /// chosen. The check carries on with the client it began with, and what it finds lands on whichever
    /// recorder is in play by then: the one just left, woken and attached again under the new address.
    func testAnotherRecorderCannotBeChosenWhileTheLastIsBeingMadeSureOf() async throws {
        let bench = try aBench()
        let recorder = RecorderAtHome()
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.connected)
        try await until("the first connect's work never finished") { model.busy == nil }

        bench.network = "away"
        await recorder.setReachable(false, holding: true)
        let asked = await recorder.asked
        let check = Task { await model.networkChangedWhileOpen() }
        try await until("the recorder was never made sure of") { await recorder.asked > asked }

        XCTAssertFalse(model.canChangeRecorder)
        // In a task of its own: let through, the choice would wait on the same held recorder as the check.
        let choosing = Task { await model.adopt(host: Bench.otherHost) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.host, Bench.host, "the recorder was changed under a check still asking the last one")

        await recorder.letGo()
        _ = await check.value
        await choosing.value
    }

    /// The demo is another recorder as well, and the way into it forgets the same things. The job that last
    /// ran on the real recorder used to stay: its line on the recordings screen, and a finished scan read as
    /// a scan of the demo's recordings.
    func testEnteringTheDemoForgetsTheJobThatLastRanOnTheRecorder() async throws {
        let bench = try aBench()
        let model = try await settledIn(bench)
        XCTAssertNotNil(model.job)

        await model.enterDemo()

        XCTAssertTrue(model.demo)
        XCTAssertTrue(model.connected, "the demo did not start: \(model.problem ?? "no reason given")")
        XCTAssertNil(model.job, "the last recorder's job is shown over the demo")
        XCTAssertTrue(model.duplicatePicks.isEmpty)
    }

    /// Leaving the demo with no recorder to go back to connects to nothing, so nothing replaces the client the
    /// demo made: it goes with what its recorder said. Left standing it answers, the app is not offline, and
    /// the next list a screen reads is the invented recorder's, in an app that says no recorder is set.
    func testLeavingTheDemoWithNoRecorderToGoBackToLeavesNobodyToAsk() async throws {
        let bench = try aBench()
        let model = bench.modelWithNoRecorder()
        await model.start()
        await model.enterDemo()
        XCTAssertTrue(model.connected, "the demo did not start: \(model.problem ?? "no reason given")")
        XCTAssertFalse(model.reservations.isEmpty)

        await model.leaveDemo()

        XCTAssertFalse(model.demo)
        XCTAssertEqual(model.host, "")
        XCTAssertTrue(model.offline, "the demo's recorder is still there to be asked")
        await model.loadReservations()   // what the reservations tab does when it is shown
        XCTAssertTrue(model.reservations.isEmpty, "the demo's reservations were read after it had ended")
    }

    /// What the screens were saying about the last recorder goes with it too: the failure on screen, the line
    /// on the strip about the queue sent to it, and why its keyword conditions could not be read. Each stayed
    /// over the recorder chosen, which had said none of it.
    func testWhatTheScreensSaidOfTheLastRecorderGoesWithIt() async throws {
        let bench = try aBench()
        let recorder = RecorderAtHome(refusing: ["X_GetPrefRecSettingList"]), other = SilentRecorder(holding: true)
        await recorder.setReachable(false)
        try await bench.cacheAGuide()
        let model = bench.model(recorders: [Bench.host: recorder, Bench.otherHost: other])
        await model.start()
        try await untilGivenUp(model)
        let program = try await aProgramme(model)
        expectTrue(await model.reserve(program, quality: "DR", repeating: "none"), model.problem ?? "no reason given")
        await recorder.setReachable(true)
        await model.connect()
        XCTAssertNotNil(model.flushReport, "nothing on the strip says the waiting reservation was sent")
        await model.loadRecorderRules()
        XCTAssertNotNil(model.recorderRulesFailure, "the keyword conditions were read after all")
        XCTAssertNotNil(model.problem)

        let choosing = Task { await model.adopt(host: Bench.otherHost) }
        try await until("the address chosen was never asked") { await other.asked > 0 }

        XCTAssertNil(model.problem, "the last recorder's failure is said of the recorder chosen")
        XCTAssertNil(model.flushReport, "the strip says the queue went to a recorder the app has left")
        XCTAssertNil(model.recorderRulesFailure, "the last recorder's refusal is given for the one chosen")

        await other.letGo()
        await choosing.value
    }

    /// A request still out to the recorder left, when another is chosen, ends in its own time, and its silence
    /// is the old recorder's. Taken for the new one's, it left the app given up on a recorder that had just
    /// answered. Only what has no line on the strip can be out at the choice: a recording's details, and the
    /// check for clashes, which is tried on the way back.
    func testSilenceFromTheRecorderLeftIsNotTakenForTheOneChosen() async throws {
        let bench = try aBench()
        let first = RecorderAtHome(), second = RecorderAtHome()
        try await bench.cacheAGuide()
        let model = bench.model(recorders: [Bench.host: first, Bench.otherHost: second])
        await model.start()
        try await until("the first connect never finished", within: 20) { model.connected && !model.connecting }
        await model.loadTitles()
        let title = try XCTUnwrap(model.titles.first)
        let program = try await aProgramme(model)

        // The first recorder goes quiet with a recording's details asked of it, and the second is chosen.
        await first.setReachable(false, holding: true)
        var asked = await first.asked
        let reading = Task { await model.detail(of: title) }
        try await until("the recording's details were never asked for") { await first.asked > asked }
        XCTAssertTrue(model.canChangeRecorder, "something on the strip says a request is out")
        await model.adopt(host: Bench.otherHost)
        XCTAssertEqual(model.info?.host, Bench.otherHost, model.problem ?? "no reason given")
        await first.letGo()
        _ = await reading.value
        XCTAssertTrue(model.connected, "silence from the recorder left was taken for the one chosen")
        XCTAssertFalse(model.gaveUp)

        // And back, with the check for clashes out to the second.
        await first.setReachable(true)
        await second.setReachable(false, holding: true)
        asked = await second.asked
        let checking = Task { await model.conflicts(for: program, quality: "DR", repeating: "none") }
        try await until("the clashes were never asked for") { await second.asked > asked }
        XCTAssertTrue(model.canChangeRecorder, "something on the strip says a request is out")
        await model.adopt(host: Bench.host)
        XCTAssertEqual(model.info?.host, Bench.host, model.problem ?? "no reason given")
        await second.letGo()
        _ = await checking.value
        XCTAssertTrue(model.connected, "silence from the recorder left was taken for the one chosen")
        XCTAssertFalse(model.gaveUp)
        XCTAssertNil(model.problem, "what the recorder left ran into is said of the one chosen")
    }

    /// A model whose recorder was busy with somebody else when the first connect asked who it is: there, not
    /// connected to, and not given up on. No other recorder has been chosen: an ordinary launch can end here.
    /// One reservation waits on disk, turned down before when `refused` gives the reason.
    private func leftAtTheDoor(_ bench: Bench, refused reason: String? = nil) async throws
        -> (model: AppModel, recorder: RecorderBusyAtTheDoor, waiting: PendingReservation, program: GuideProgramRow) {
        let recorder = RecorderBusyAtTheDoor()
        try await bench.cacheAGuide()
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await until("the first connect never ended") { !model.connecting && model.problem != nil }
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.offline, "it answered, so the screens do not take it for gone")
        XCTAssertFalse(model.gaveUp)
        let program = try await aProgramme(model)
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        let waiting = PendingReservation(request: request, serviceName: program.serviceName, problem: reason)
        try await GuideStore(path: bench.guidePath).queue(waiting)
        await model.loadPending()
        XCTAssertNotNil(model.pending(for: program))
        return (model, recorder, waiting, program)
    }

    /// Pulling the reservations down is the reader asking, and when the app is not connected it connects:
    /// given up, or with a recorder there that has not said which it is. Only the first counted before. The
    /// second had its list read and the queue sent after it; and with the queue going only to a recorder that
    /// has said which it is, that would have read the list and left what waits, with nothing on that screen
    /// to say why. Asked again, a recorder that is free by now describes itself, and the connect sends it.
    func testPullingTheReservationsDownConnectsWhenTheAppIsNotConnected() async throws {
        let bench = try aBench()
        let (model, recorder, _, program) = try await leftAtTheDoor(bench)

        await model.refreshReservations()
        var made = await recorder.made
        XCTAssertEqual(made, 0, "what waits was sent to a recorder that has not said which it is")
        XCTAssertFalse(model.connected)
        XCTAssertNotNil(model.pending(for: program), "the reservation waiting is no longer shown")

        await recorder.comeFree()
        await model.refreshReservations()
        made = await recorder.made
        XCTAssertEqual(made, 1, "the recorder was not asked again, or what waits was not sent once it answered")
        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertNil(model.pending(for: program), "the reservation is still waiting")
        XCTAssertNotNil(model.reservation(for: program), "the recorder's list was not read")
    }

    /// The reader asking for a waiting reservation to be sent again does the same. Stopping where the queue
    /// stops left the reason gone from the row and nothing sent, without a word.
    func testAskingForOneToBeSentAgainConnectsWhenTheAppIsNotConnected() async throws {
        let bench = try aBench()
        let (model, recorder, waiting, program) = try await leftAtTheDoor(bench, refused: "refused")

        await model.resend(waiting)
        var made = await recorder.made
        XCTAssertEqual(made, 0, "what waits was sent to a recorder that has not said which it is")
        XCTAssertFalse(model.connected)
        XCTAssertNotNil(model.problem, "nothing on screen says why it was not sent")

        await recorder.comeFree()
        await model.resend(waiting)
        made = await recorder.made
        XCTAssertEqual(made, 1, "the recorder was not asked again, or what waits was not sent once it answered")
        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertNil(model.pending(for: program), "the reservation is still waiting")
    }

    // MARK: - when it asks again

    /// Given up stays given up until the network changes or the reader asks. 再接続 and pulling down are the
    /// reader asking, and they do ask, on the same network.
    func testTheReaderAskingTriesAgainOnTheSameNetwork() async throws {
        let bench = try aBench()
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
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = SilentRecorder(holding: true)
        let model = bench.model(recorder: recorder)
        await model.start()
        try await until("the first connect never asked the recorder") { await recorder.asked > 0 }

        bench.network = "the Wi-Fi at home, joined on the way in"
        await recorder.letGo()
        try await until("the connect never ended") { !model.connecting }

        expectEqual(await recorder.asked, 2, "one try on the network that went and one on the network that came")
        XCTAssertTrue(model.gaveUp)
        XCTAssertFalse(model.networkChanged, "the app gave up on a network it had not tried")
    }

    /// A connect whose network stayed where it was tries once.
    func testAConnectOnOneNetworkTriesOnce() async throws {
        let bench = try aBench()
        let recorder = SilentRecorder()
        let model = try await started(bench, recorder: recorder)

        expectEqual(await recorder.asked, 1)
        XCTAssertTrue(model.gaveUp)
    }

    /// Becoming active is not coming back. Control Centre, a notification pulled down and a system alert
    /// take the app out of being active without it going anywhere, and connecting after each sent a magic
    /// packet for a glance at the time. Only a real trip to the background counts.
    func testBecomingActiveWithoutHavingBeenAwayDoesNotConnect() async throws {
        let bench = try aBench()
        let recorder = SilentRecorder()
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.gaveUp)
        // On another network, where coming back from the background would ask again.
        bench.network = "away"
        let asked = await recorder.asked

        await model.returnedToForeground()
        expectEqual(await recorder.asked, asked, "the app connected after a moment that went nowhere")

        model.wentToBackground()
        await model.returnedToForeground()
        let askedAfterLeaving = await recorder.asked
        XCTAssertGreaterThan(askedAfterLeaving, asked, "a real return to the app did not ask")
    }

    /// Nor on every flick between apps: a recorder that answered within the last minute is not asked again
    /// for the app having been away for a moment.
    func testComingBackWithinAMinuteOfAnAnswerDoesNotConnectAgain() async throws {
        let bench = try aBench()
        let recorder = RecorderAtHome()
        let model = try await started(bench, recorder: recorder)
        XCTAssertTrue(model.connected)
        try await until("the first connect's work never finished") { model.busy == nil }
        let asked = await recorder.asked

        model.wentToBackground()
        await model.returnedToForeground()

        expectEqual(await recorder.asked, asked, "the recorder was asked again a moment after it had answered")
        XCTAssertTrue(model.connected)
    }
}
