import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// Another recorder heard by the check before an operation: what the reader asked of the first is not sent.
extension WhichRecorderTests {
    /// The check before an operation hears who is there as well. Another recorder answering it gets nothing
    /// the reader asked of the first: the lists go, the check says no, and the newcomer is taken up by a
    /// connect of its own.
    func testAnotherRecorderAnsweringTheCheckIsSentNothing() async throws {
        let (bench, recorder, model) = try await atHome()

        await recorder.become(2)
        let answering = await makeSure(model)

        XCTAssertFalse(answering, "what the reader asked of the first recorder would have gone to the second")
        XCTAssertTrue(model.titles.isEmpty)
        XCTAssertEqual(model.problem, Said.anotherAnswered, "nothing says why what was asked for was not sent")
        try await untilTakenUp(model, 2)
        // The connect has taken the failure line away, and a sheet the reader asked from was closed with
        // its alert: the strip is what still says it.
        XCTAssertNil(model.problem)
        XCTAssertTrue(model.anotherTookOver, "nothing is left saying why what was asked for was not done")
    }

    /// The same when the check has to wake what is there first. The waking's attach turns the app to whoever
    /// answers, which reads neither its reservations nor its guide; the check still says no, and the connect
    /// that follows reads them. The MAC that woke it was the first recorder's, and is not kept for the second.
    func testAnotherRecorderAnsweringAfterAWakingIsSentNothingEither() async throws {
        let (bench, recorder, model) = try await atHome(wakeable: true)
        XCTAssertNotNil(model.mac)
        try await queueAReservation(bench, model)

        // Silent to the check's probe, and another recorder by the time the waking asks again.
        await recorder.become(2)
        await recorder.goQuiet(for: 1)
        let answering = await makeSure(model)

        XCTAssertFalse(answering, "what the reader asked of the first recorder would have gone to the second")
        XCTAssertTrue(model.titles.isEmpty)
        XCTAssertEqual(model.problem, Said.anotherAnswered, "nothing says why what was asked for was not sent")
        try await untilTakenUp(model, 2)
        XCTAssertTrue(model.anotherTookOver, "nothing is left saying why what was asked for was not done")
        XCTAssertFalse(model.reservations.isEmpty, "the newcomer's reservations were never read")
        // Not the first one's, here or where the overnight run reads it. (None at all, as it happens: this
        // newcomer keeps its own to itself.)
        XCTAssertNotEqual(model.mac, Self.firstsMAC, "the packet would go on waking the first recorder")
        XCTAssertNotEqual(bench.defaults.string(forKey: DefaultsKey.recorderMac), Self.firstsMAC)
        XCTAssertNil(bench.defaults.string(forKey: DefaultsKey.recorderMacHost))
        try await expect(bench, keeps: .nothing(nowOf: 2))
        // Held by the waking's attach, and said by the connect after it: the line is read from the rows.
        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 0,
                    "what was waiting for the first recorder was made on the second")
        expectHeld(model, 1)
        expectTheStripSaysWhatIsHeld(model)
    }

    /// Something asked of a recording while the check is out, which then hears another recorder. The
    /// recording's number is the first recorder's, and the second, which numbers its own from the same start,
    /// has one under it: nothing is sent, and the reader is told why. A delete only waits for what the check
    /// found, however the check ended, so the probe's way is enough here; the waking's way is the
    /// reservation's below, which had a fault of its own on each.
    func testADeleteAskedOfWhatTurnsOutToBeAnotherRecorderIsNotSent() async throws {
        let (bench, recorder, model) = try await atHome(wakeable: true)
        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })

        let deleted = try await asking(model, on: bench, of: recorder, heard: .onTheProbe) { await model.delete(title) }

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.problem, Said.anotherAnswered, "nothing says why it was not deleted")
        try await untilTakenUp(model, 2, "the newcomer was never taken up")
        expectEqual(await recorder.asked("X_DeleteTitle"), 0,
                    "the second recorder was asked to delete its recording of that number")
    }

    /// A reservation asked for while the check is out, which then hears another recorder -- answering its
    /// probe, or answering after a waking: it is not sent, and not queued either. Queued after the probe, it
    /// was held as one made for the recorder before the moment the newcomer was taken up, under a sheet that
    /// had just said it would go at the next connect. Queued after the waking, which had held the queue
    /// already, it was the one row not held, and the connect that followed sent it to the newcomer.
    func testAReservationAskedOfWhatTurnsOutToBeAnotherRecorderIsNeitherSentNorQueued() async throws {
        for heard in Heard.allCases {
            let (bench, recorder, model) = try await atHome(wakeable: true)
            let program = try await aProgramme(model)

            let reserved = try await asking(model, on: bench, of: recorder, heard: heard) {
                await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none")
            }

            let exit = heard.rawValue
            XCTAssertFalse(reserved, "the sheet would close as though the programme were reserved, \(exit)")
            try await untilTakenUp(model, 2, "the newcomer was never taken up, \(exit)")
            XCTAssertNil(model.pending(for: program), "queued for a recorder that had turned out another, \(exit)")
            expectTrue(try await store(bench).pendingReservations().isEmpty, exit)
            expectEqual(await recorder.asked("X_CreateRecordSchedule"), 0,
                        "the reservation went to the newcomer, \(exit)")
        }
    }

    /// A reservation asked for while the check is out, whose waking finds another recorder and cannot make the
    /// cache over to it: another writer holds the cache for longer than the app waits. The app lets go of the
    /// recorder it had, and the reservation is neither sent nor kept -- kept, it would wait as one made for the
    /// recorder before, and go to whichever answers the next connect. The line says why the app is not
    /// connected, and the strip that another recorder answered.
    ///
    /// The writer lets go once the line says so, while the reservation is still deciding: a reservation kept
    /// from then on is saved, and found on the phone, rather than failing to be saved under a sentence of its
    /// own. The line is still the one look that tells a reservation kept from one that was not.
    ///
    /// As it is today: the check answers the same for a recorder that turned the waking away and for one the
    /// app let go of over its cache, and the reservation tells the two apart by whether the recorder it began
    /// with is still the one in hand. A later change gives the check an answer of its own for this, and what
    /// is looked at here stands.
    func testAReservationAskedOfARecorderLetGoOfForItsCacheIsNeitherSentNorQueued() async throws {
        let bench = try aBench()
        // The lock is held on purpose: what is tested is giving up, not the wait.
        bench.storeBusyTimeoutMilliseconds = 200
        bench.keep(mac: Self.firstsMAC)
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        let program = try await aProgramme(model)

        let writer = Writer(to: bench.guidePath)
        let freed = Task {
            try await until("the cache was never said not to have been made over") {
                model.problem == Said.cacheNotMadeOver
            }
            writer.letGo()
        }
        let reserved = try await asking(model, on: bench, of: recorder, heard: .afterAWaking) {
            await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none")
        }
        try await freed.value

        XCTAssertEqual(model.problem, Said.cacheNotMadeOver,
                       "not what the cache left to say: the one look that tells a reservation kept here from none, "
                           + "so it is not to be loosened")
        XCTAssertFalse(reserved, "the sheet would close as though the programme were reserved")
        XCTAssertNil(model.pending(for: program), "kept for a recorder the app had let go of")
        expectTrue(try await store(bench).pendingReservations().isEmpty, "kept on the phone")
        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 0, "the reservation went to the newcomer")
        XCTAssertTrue(model.anotherTookOver, "nothing on the strip says another recorder answered")
        XCTAssertFalse(model.connected, "connected over a cache that is still the first recorder's")
    }

    /// A change or a delete of a reservation asked for while the check is out, which then hears another
    /// recorder. The second holds a reservation under the same number, as it holds a recording under the
    /// first's: nothing is sent to it, and the answer is no.
    ///
    /// What is said is not looked at. Each of the two looks again at whether the app is offline once the read
    /// of the list has come back, and the connect that takes the newcomer up may have made its client by then:
    /// the line then says that the reservation has gone from the recorder, and not that another recorder
    /// answered. The list is empty in that turn either way, so nothing is found in it to send. (A gate, as
    /// `ReservationGateTests` are: a later change makes the guard the link's, and says why, and what
    /// is looked at here stands.)
    func testAChangeOrADeleteAskedOfWhatTurnsOutToBeAnotherRecorderIsNotSent() async throws {
        for write in ReservationWrite.allCases {
            let (bench, recorder, model) = try await atHome()
            let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]

            let done = try await asking(model, on: bench, of: recorder, heard: .onTheProbe) {
                await write.ask(model, row)
            }

            XCTAssertFalse(done, "\(write.name) is said to have been done")
            try await untilTakenUp(model, 2, "the newcomer was never taken up, after \(write.name)")
            expectEqual(await recorder.asked(write.rawValue), 0,
                        "\(write.name) was sent to the second recorder, for its reservation of that number")
            XCTAssertTrue(model.reservations.contains { $0.id == row.id },
                          "the newcomer was meant to hold a reservation under the same number")
        }
    }

    /// Another recorder heard by the check while a bulk job is under way -- parked, here, with the app in the
    /// background, which is when an address has the time to change hands. The job is stopped and nothing of
    /// it is sent; the connect that takes the newcomer up waits for it to end, since a connect does not start
    /// beside a job, and set going at once it left the app connected to nothing under a line saying the lists
    /// would be read again. What the job came to goes with the recorder it was about.
    func testAnotherRecorderHeardWhileAJobIsUnderWayIsTakenUpOnceItHasEnded() async throws {
        let (bench, recorder, model) = try await atHome()
        let id = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected }).id

        model.wentToBackground()
        model.startBulk(.delete, ids: [id])
        try await until("the job never waited for the app to come back") { model.backInFront != nil }
        await recorder.become(2)
        bench.network = "another"
        await lookAtTheNetwork(model)
        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.titles.isEmpty)
        // Stopped by the check, as 中止 stops one: a scan under way in front goes by this alone, since it
        // asks by the numbers it began with and not from the list that has just gone.
        XCTAssertEqual(model.job?.cancelled, true)

        await model.returnedToForeground()
        try await until("the newcomer was never taken up", within: 20) {
            model.info?.udn == NamedRecorder.udn(2) && !isConnecting(model) && !model.jobRunning
        }

        expectEqual(await recorder.asked("X_DeleteTitle"), 0,
                    "the job went on, on the newcomer, by the last recorder's numbers")
        XCTAssertNil(model.job, "what the job came to is shown over a recorder it was not about")
        XCTAssertFalse(model.titlesLoaded)
        await model.loadTitles()
        XCTAssertFalse(model.titles.isEmpty)
    }

    /// A job under way in front, the last request of one step out, when the network changes and the recorder
    /// is asked whether it is still there: the ask waits its turn behind that request, whose answer comes
    /// back first. The job hears the check out before its next step. Going straight on, that step reached
    /// the recorder ahead of the check's verdict -- another recorder, here, with a recording of its own under
    /// the same number.
    func testAJobInFrontHearsTheCheckOutBeforeItsNextStep() async throws {
        let (bench, recorder, model) = try await atHome()
        let ids = model.titles.filter { !$0.recording && !$0.protected }.prefix(2).map(\.id)
        XCTAssertEqual(ids.count, 2, "the recorder was meant to have two recordings that can be deleted")

        await recorder.hold(only: "X_DeleteTitle")
        model.startBulk(.delete, ids: Array(ids))
        try await until("the job never came to its first delete") { await recorder.asked("X_DeleteTitle") == 1 }
        bench.network = "away"
        let check = Task { await lookAtTheNetwork(model) }
        try await until("the recorder was never made sure of") { isMakingSure(model) }
        await recorder.become(2)
        await recorder.letGo()
        _ = await check.value
        try await until("the job never ended") { !model.jobRunning }

        // The step that was out when the ask was made is not called back; the next one is not sent.
        expectEqual(await recorder.asked("X_DeleteTitle"), 1,
                    "the job went on to its next step on the recorder that had just answered")
        try await untilTakenUp(model, 2)
        XCTAssertNil(model.job)
    }

    // MARK: - how the check comes to hear it

    /// How the check before an operation comes to hear another recorder: answering its probe, or answering
    /// after the waking that a silent probe sets off.
    private enum Heard: String, CaseIterable {
        case onTheProbe = "on the probe"
        case afterAWaking = "after a waking"
    }

    /// Asks `something` of the model while the check before it is out, and has that check hear the second
    /// recorder. The network changes, the recorder is asked whether it is still there, and the ask is held;
    /// `something` is asked meanwhile and waits for the check; then the second recorder is at the address when
    /// the ask is let go -- answering it, or silent to it and found by the waking. Returns what `something` did.
    private func asking<T: Sendable>(_ model: AppModel, on bench: Bench, of recorder: NamedRecorder, heard: Heard,
                                     _ something: @escaping @MainActor () async -> T) async throws -> T {
        bench.network = "away"
        await recorder.hold()
        let asked = await recorder.asked("description.xml")
        let check = Task { await lookAtTheNetwork(model) }
        try await until("the recorder was never made sure of") { await recorder.asked("description.xml") > asked }
        let answer = Task { await something() }
        try await until("what was asked for was never begun") { model.busy != nil }
        await recorder.become(2)
        if heard == .afterAWaking { await recorder.goQuiet(for: 1) }
        await recorder.letGo()
        _ = await check.value
        return await answer.value
    }
}
