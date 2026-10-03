import Foundation
import RecorderKit
import SQLite3
import XCTest
@testable import BDBridge

/// Another recorder taking the place of the one the phone knows: it gets nothing that was the first's.
extension WhichRecorderTests {
    /// Another recorder answering takes the app over whole. Its own lists are read; the other's programme
    /// texts go, and so do the marks that said the guide need not be fetched, and that a low-space warning
    /// had been given; a reservation that was waiting is held with a reason, not sent to a recorder it was
    /// not made for, until the reader asks.
    func testAnotherRecorderGetsNothingThatWasTheFirsts() async throws {
        let bench = try aBench()
        let first = NamedRecorder(1), second = NamedRecorder(2)
        let model = try await connected(bench, at: [Bench.host: first, Bench.otherHost: second])
        try await queueAReservation(bench, model)

        await model.adopt(host: Bench.otherHost)
        try await untilIdle(model)

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        XCTAssertFalse(model.reservations.isEmpty, "the new recorder's reservations were not read")
        try await expect(bench, keeps: .nothing(nowOf: 2),
                         "the first one's text would confirm a duplicate on the second; the warning was of its disk")
        expectTrue(await second.asked("EPG_TRDEPG_FILE.dat") >= 1,
                   "the marks left by the first kept the second from being asked for its guide")
        expectEqual(await second.asked("X_CreateRecordSchedule"), 0,
                    "what was waiting for the first recorder was made on the second")
        expectHeld(model, 1, "the reservation waits with nothing to say why")
        XCTAssertNotNil(model.flushReport, "nothing on screen says the reservation was held back")
        XCTAssertFalse(model.anotherTookOver, "the strip tells the reader of a recorder they chose themselves")

        // The reader asks: it goes to the recorder in play now.
        await model.resend(try XCTUnwrap(model.pending.first))
        expectEqual(await second.asked("X_CreateRecordSchedule"), 1)
        XCTAssertTrue(model.pending.isEmpty)
    }

    /// Nobody chose anything: the address the recorder had is answered by another, as after the router has
    /// handed it on. The app finds out at the next connect, by what answers, and reads the lists again from
    /// the one that did -- with the app connected throughout, so that no screen is waiting to ask.
    func testAnotherRecorderAtTheSameAddressIsNotTakenForTheFirst() async throws {
        let (bench, recorder, model) = try await atHome()
        let before = await recorder.asked

        await recorder.become(2)
        await model.connect()
        try await untilIdle(model)

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2))
        XCTAssertTrue(model.titlesLoaded, "the recordings tab was left saying there are none")
        expectEqual(await recorder.asked("X_GetTitleList", since: before), 1,
                    "the first recorder's recordings stood for the second's")
        XCTAssertTrue(model.recorderRulesLoaded)
        try await expect(bench, keeps: .nothing(nowOf: 2))
        XCTAssertTrue(model.anotherTookOver, "nothing says why the lists under the reader are other ones")
    }

    /// What was held back is said even when the attach that held it got no further: the newcomer described
    /// itself, the cache was made over and the queue held, and then it said nothing more. The line is read
    /// from the rows by whichever attach does get through.
    func testWhatWasHeldIsSaidByALaterAttachWhenTheOneThatHeldItFailed() async throws {
        let (bench, recorder, model) = try await atHome(waiting: true)

        await recorder.become(2)
        await recorder.goQuiet(for: 1, after: 1)
        await model.connect()
        XCTAssertTrue(model.gaveUp, "the attach was meant to meet silence after the description")
        expectEqual(try await store(bench).pendingReservations().map(\.problem), [AppModel.heldForAnotherRecorder])
        expectHeld(model, 1, "the row on screen still says it goes at the next connect")

        await model.connect()

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        expectHeld(model, 1)
        expectTheStripSaysWhatIsHeld(model)
        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 0)
    }

    /// A sheet open on a recording or a reservation holds a value, and stays up over an emptied list: when the
    /// lists go because another recorder has answered, its buttons would send that value's number to the
    /// newcomer. The screens close what they hold when the model says its lists were let go of, which it
    /// says whenever they are and not when the same recorder answers again.
    func testTheScreensAreToldWhenWhatTheyHoldIsTheLastRecorders() async throws {
        let bench = try aBench()
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder, Bench.otherHost: NamedRecorder(3)])
        var told = model.timesForgotten

        await model.connect()
        _ = await makeSure(model)
        await model.adopt(host: Bench.host)
        XCTAssertEqual(model.timesForgotten, told, "the screens were told to close what is still the recorder's")
        XCTAssertFalse(model.anotherTookOver, "the strip says another recorder answered, of the same one")

        await recorder.become(2)
        await model.connect()
        XCTAssertGreaterThan(model.timesForgotten, told, "another recorder answered the connect")
        told = model.timesForgotten

        try await untilIdle(model)
        await recorder.become(1)
        _ = await makeSure(model)
        XCTAssertGreaterThan(model.timesForgotten, told, "another recorder answered the check")
        try await untilTakenUp(model, 1)
        told = model.timesForgotten

        await model.adopt(host: Bench.otherHost)
        XCTAssertGreaterThan(model.timesForgotten, told, "another address was chosen")
    }

    /// That another recorder answered, which nobody chose, is said for as long as the reader is looking: it
    /// goes when they leave the app, as the line about the queue does, and when they choose a recorder
    /// themselves, which is news of its own.
    func testThatAnotherRecorderAnsweredIsSaidUntilTheReaderLeavesOrChooses() async throws {
        let bench = try aBench()
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder, Bench.otherHost: NamedRecorder(3)])
        XCTAssertFalse(model.anotherTookOver)

        await recorder.become(2)
        await model.connect()
        XCTAssertTrue(model.anotherTookOver)
        // Answering again, it is the recorder the app has by now: said still, and not said a second time.
        await model.connect()
        XCTAssertTrue(model.anotherTookOver, "taken back by the next connect to the same recorder")
        model.wentToBackground()
        XCTAssertFalse(model.anotherTookOver, "still said on coming back to the app")

        await recorder.become(1)
        await model.connect()
        XCTAssertTrue(model.anotherTookOver)
        await model.adopt(host: Bench.otherHost)
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(3), model.problem ?? "no reason given")
        XCTAssertFalse(model.anotherTookOver, "said of a recorder the reader chose")
    }

    /// The cache is another recorder's and cannot be made over to the one that answers: another writer has
    /// held it for longer than the app waits. The app is not connected to that recorder -- it would go on
    /// over the other's guide and the texts of the other's recordings -- and says why; nothing waiting is
    /// sent, and the next connect, with the cache free, takes it over.
    func testACacheThatCannotBeMadeOverIsNotConnectedOver() async throws {
        let bench = try aBench()
        let second = NamedRecorder(2)
        let model = try await connected(bench, at: [Bench.host: NamedRecorder(1), Bench.otherHost: second])
        try await queueAReservation(bench, model)

        let writer = Writer(to: bench.guidePath)
        await model.adopt(host: Bench.otherHost)

        XCTAssertFalse(model.connected, "connected over a cache that is still the first recorder's")
        XCTAssertEqual(model.problem, AppModel.cacheNotMadeOver)
        XCTAssertFalse(model.gaveUp, "it answered: this is not silence")
        expectEqual(await second.asked("X_CreateRecordSchedule"), 0)
        try await expect(bench, keeps: .all(of: 1))

        // The guide on screen is still the first recorder's, and a programme reserved from it is not sent to
        // the one the app has just turned away from: there is nobody to ask, and it waits with the rest.
        writer.letGo()
        XCTAssertTrue(model.offline, "the recorder turned away from is still there to be asked")
        let program = try await aProgramme(model, skipping: 1)
        expectTrue(await model.reserve(program, quality: "DR", repeating: "none"), model.problem ?? "no reason given")
        expectEqual(await second.asked("X_CreateRecordSchedule"), 0,
                    "reserved on the recorder the app would not connect to")

        await model.connect()
        try await untilIdle(model)

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        try await expect(bench, keeps: .nothing(nowOf: 2))
        expectEqual(await second.asked("X_CreateRecordSchedule"), 0)
        expectHeld(model, 2)
    }

    /// Another recorder answers where the first one was, and the cache cannot be made over to it. Both are
    /// said: why the app is not connected, and, on the strip, that another recorder answered, which nobody
    /// chose. Letting go of the first recorder takes the strip's line with it, so it is put back.
    func testAnotherRecorderTurnedAwayForItsCacheIsStillSaidToHaveAnswered() async throws {
        let bench = try aBench()
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])

        let writer = Writer(to: bench.guidePath)
        await recorder.become(2)
        await model.connect()
        writer.letGo()

        XCTAssertFalse(model.connected, "connected over a cache that is still the first recorder's")
        XCTAssertEqual(model.problem, AppModel.cacheNotMadeOver)
        XCTAssertTrue(model.anotherTookOver, "nothing on the strip says another recorder answered")
    }

    /// The first recorder's name could not be put down -- the cache was being written to when it first
    /// answered -- and it is another one that answers next. The app knows that much without the cache: its
    /// lists were read from the first. So the cache is made over all the same, and what waited for the first
    /// is held, not sent to the second as the first answerer of a cache that is nobody's.
    func testAnotherRecorderTakesACacheWhoseOwnerCouldNotBeWrittenDown() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        let writer = Writer(to: bench.guidePath)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        writer.letGo()
        expectNil(try await kept(bench).owner, "the owner was meant not to have been written")
        await model.loadTitles()
        recording = try XCTUnwrap(model.titles.first).id
        try await store(bench).setTitleSummary(recording, "あらすじ")
        try await queueAReservation(bench, model)

        await recorder.become(2)
        await model.connect()
        try await untilIdle(model)

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        try await expect(bench, keeps: .nothing(nowOf: 2),
                         "the first recorder's text was kept under the second one's numbers")
        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 0,
                    "what was waiting for the first recorder was made on the second")
        expectHeld(model, 1)
    }

    // MARK: - a cache that is being written to

    /// Another connection writing to the cache, until it lets go: a write of the app's waits behind it for as
    /// long as the busy timeout, and then fails.
    private final class Writer {
        private var connection: OpaquePointer?

        init(to path: String) {
            XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        }

        func letGo() {
            XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        }

        deinit { sqlite3_close(connection) }
    }
}
