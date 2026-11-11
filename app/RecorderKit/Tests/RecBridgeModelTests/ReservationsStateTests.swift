import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The reservations' screen as the reader works it (`ReservationsState`): the delete a row's swipe asks for and
/// its question, what the one alert says and in which order, a waiting row deleted and sent again, and what the
/// screen says over its list. The deletes and the sendings themselves are the model's and its drivers', held
/// elsewhere; here is what the screen makes of them.
@MainActor
final class ReservationsStateTests: XCTestCase {
    /// A home whose recorder answers and holds one reservation made just now.
    private func withAReservation() async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel, row: Reservation) {
        let (bench, recorder, model) = try await connectedHome()
        let programmes = try await programmesNotReserved(model, 1)
        let program = try XCTUnwrap(programmes.first)
        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none"), .made(saying: nil))
        let row = try XCTUnwrap(model.reservations(for: program).first { $0.device == .recorder })
        return (bench, recorder, model, row)
    }

    /// A reservation of `program` as the app queues one, turned down before when `problem` is given.
    private func waiting(for program: GuideProgramRow, problem: String? = nil) throws -> PendingReservation {
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        return PendingReservation(request: request, serviceName: program.serviceName, problem: problem)
    }

    /// What the alert is up for, in a word.
    private func shown(_ state: ReservationsState) -> String {
        switch state.ask {
        case .confirm: "confirm"
        case .confirmPending: "confirm pending"
        case .failed: "failed"
        case .said: "said"
        case nil: "nothing"
        }
    }

    /// The button under the question, pressed as the screen presses it: the action with the value the alert was
    /// put up with, and then the alert's closing, which is what lets go of the question.
    private func press(_ state: ReservationsState, acting: Bool, file: StaticString = #filePath,
                       line: UInt = #line) throws {
        let asked = try XCTUnwrap(state.ask, "nothing was asked", file: file, line: line)
        if acting { state.act(on: asked) }
        state.askClosed()
    }

    /// A swipe's 削除 asks first, in the list's words; キャンセル leaves the reservation, and 削除する deletes it,
    /// saying nothing more.
    func testADeleteIsAskedFirstAndTheYesDeletes() async throws {
        let (_, _, model, row) = try await withAReservation()
        let state = ReservationsState(model: model)
        XCTAssertEqual(shown(state), "nothing")
        XCTAssertFalse(state.holdsDeleting(row), "a row was held with nothing under way")

        state.delete(row)
        XCTAssertEqual(shown(state), "confirm")
        XCTAssertEqual(state.askTitle, "この予約を削除しますか？")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertEqual(state.message(for: asked), "\(Format.dateTime.string(from: row.start)) \(row.title)\n"
                       + "レコーダーから削除されます。")
        XCTAssertEqual(state.actionLabel(for: asked)?.label, "削除する")
        XCTAssertEqual(state.actionLabel(for: asked)?.destructive, true)
        XCTAssertEqual(state.closingLabel(for: asked), "キャンセル")

        try press(state, acting: false)
        XCTAssertEqual(shown(state), "nothing")
        XCTAssertNotNil(model.reservation(listKey: row.listKey), "キャンセル deleted the reservation")

        state.delete(row)
        try press(state, acting: true)
        XCTAssertEqual(shown(state), "nothing", "the question stayed up after its button")
        try await until("the reservation was never deleted") { model.reservation(listKey: row.listKey) == nil }
        XCTAssertEqual(shown(state), "nothing", "a delete that went through said something")
    }

    /// A delete the recorder turns down is said in the same alert once the question has closed, under エラー with
    /// only OK; closing that leaves nothing up.
    func testADeleteTurnedDownIsSaidOnceTheQuestionHasClosed() async throws {
        let (_, recorder, model, row) = try await withAReservation()
        let state = ReservationsState(model: model)
        await recorder.answer(ReservationWrite.delete.rawValue, with: .fault(402))
        state.delete(row)
        try press(state, acting: true)
        try await until("the refusal was never said") { self.shown(state) == "failed" }
        XCTAssertEqual(state.askTitle, "エラー")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertNil(state.actionLabel(for: asked))
        XCTAssertEqual(state.closingLabel(for: asked), "OK")
        XCTAssertTrue(state.message(for: asked).hasSuffix("。"), "the reason is not said as a body")
        XCTAssertNotNil(model.reservation(listKey: row.listKey), "the reservation turned down went all the same")

        // A failure wins over a question put up since: it is the answer to what was just asked.
        state.delete(row)
        XCTAssertEqual(shown(state), "failed")
        state.askClosed()
        XCTAssertEqual(shown(state), "nothing", "closing the report left the question behind it")
    }

    /// The row picked is read back out of the list, so a question about a row that has gone comes down by itself;
    /// and it is let go of with its own device's lists, not with the other's.
    func testThePickGoesWithItsRowAndWithItsOwnDevicesLists() async throws {
        let (_, _, model, row) = try await withAReservation()
        let state = ReservationsState(model: model)

        state.delete(row)
        state.televisionsListsLetGo()
        XCTAssertEqual(shown(state), "confirm", "the television's lists going took a recorder's row with them")
        state.recordersListsLetGo()
        XCTAssertEqual(shown(state), "nothing", "the recorder's lists went and its row stayed picked")

        state.delete(row)
        expectEqual(await model.cancel(row), .done(saying: nil))
        XCTAssertNil(model.reservation(listKey: row.listKey))
        XCTAssertEqual(shown(state), "nothing", "a question stayed up about a row the list no longer holds")
    }

    /// A waiting row: もう一度送る is offered only on one a device refused; its delete is asked first, in its own
    /// words, and deletes it from this device; and neither device's lists going lets go of that pick, which is
    /// the reader's and no recorder's.
    func testAWaitingRowsDeleteIsAskedFirstAndStaysThroughALetGo() async throws {
        let (bench, _, model, _) = try await withAReservation()
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)
        let (plain, refused) = (try waiting(for: programmes[0]), try waiting(for: programmes[1], problem: "断られた理由"))
        try await store.queue(plain)
        try await store.queue(refused)
        await model.loadPending()
        let state = ReservationsState(model: model)
        XCTAssertFalse(state.offersSendingAgain(plain), "a row with no reason was offered to be sent again")
        XCTAssertTrue(state.offersSendingAgain(refused))
        XCTAssertFalse(state.holds(refused), "a waiting row was held with nothing under way")

        state.deleteWaiting(refused)
        XCTAssertEqual(shown(state), "confirm pending")
        XCTAssertEqual(state.askTitle, "送信待ちの予約を削除しますか？")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertEqual(state.message(for: asked),
                       "\(Format.dateTime.string(from: refused.request.start)) \(refused.request.title)\n"
                       + "この端末から削除し、レコーダーには送りません。")
        XCTAssertEqual(state.actionLabel(for: asked)?.destructive, true)
        state.recordersListsLetGo()
        state.televisionsListsLetGo()
        XCTAssertEqual(shown(state), "confirm pending", "a let-go took the reader's own row out of the question")

        try press(state, acting: true)
        try await until("the waiting row was never deleted") { !model.pending.contains { $0.id == refused.id } }
        XCTAssertEqual(shown(state), "nothing", "a waiting row deleted said something")
    }

    /// A waiting row a sending made first is not deleted: that is said once the question has closed, under
    /// 送信待ちの予約. A row sent again with nothing to add does not take that down before it is read.
    func testWhatASendingMadeOfARowIsSaidAndNotTakenDownByNothing() async throws {
        let (bench, recorder, model, reserved) = try await withAReservation()
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)
        let made = try waiting(for: programmes[0], problem: Said.heldAfterSilence)
        let other = try waiting(for: programmes[1], problem: "断られた理由")
        try await store.queue(made)
        try await store.queue(other)
        try await aClient(of: recorder).create(made.request)
        await model.loadPending()
        let state = ReservationsState(model: model)

        state.deleteWaiting(made)
        try press(state, acting: true)
        try await until("what the sending made was never said") { self.shown(state) == "said" }
        XCTAssertEqual(state.askTitle, "送信待ちの予約")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertEqual(state.message(for: asked), Said.madeBeforeItsDelete(made.request.title).asABody)
        XCTAssertNil(state.actionLabel(for: asked))
        XCTAssertEqual(state.closingLabel(for: asked), "OK")

        // What a sending came to wins over a question put up since, of a reservation or of a waiting row.
        state.delete(reserved)
        state.deleteWaiting(other)
        XCTAssertEqual(shown(state), "said", "a question went over what a sending came to")

        // The other row sent again is made, with nothing to say beside its row: what is up stays up. The list read
        // after the sending is the last thing the sending does before it answers.
        state.sendAgain(other)
        try await until("the row sent again was never made") { model.reservation(for: programmes[1]) != nil }
        XCTAssertEqual(shown(state), "said", "a sending with nothing to say took down what was being said")

        // And a failure wins over that: a delete turned down while it is up.
        await recorder.answer(ReservationWrite.delete.rawValue, with: .fault(402))
        state.act(on: .confirm(reserved))
        try await until("the refusal was never said") { self.shown(state) == "failed" }
        state.askClosed()
        XCTAssertEqual(shown(state), "nothing")
    }

    /// もう一度送る says what it came to where the row does not say it: a row held after silence, sent again when
    /// the recorder's list cannot be read, is not sent, and the alert says why and what to do.
    func testARowSentAgainSaysWhatItsRowDoesNot() async throws {
        let (bench, recorder, model, _) = try await withAReservation()
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 1)
        let row = try waiting(for: programmes[0], problem: Said.heldAfterSilence)
        try await store.queue(row)
        await model.loadPending()
        let state = ReservationsState(model: model)

        await recorder.answer("X_GetRecordScheduleList", with: .fault(501))
        state.sendAgain(row)
        try await until("what the sending came to was never said") { self.shown(state) == "said" }
        XCTAssertEqual(state.askTitle, "送信待ちの予約")
        XCTAssertEqual(state.message(for: try XCTUnwrap(state.ask)), Said.notKnownThereUnread.asABody)
        XCTAssertTrue(model.pending.contains { $0.id == row.id }, "a row not sent left the queue")
    }

    /// A row's delete and a waiting row's swipes are held while the row's own device works: here the recorder,
    /// with a delete of its own out.
    func testTheSwipesAreHeldWhileTheRowsDeviceWorks() async throws {
        let (bench, recorder, model, row) = try await withAReservation()
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 1)
        let waits = try waiting(for: programmes[0], problem: "断られた理由")
        try await store.queue(waits)
        await model.loadPending()
        var forTheTelevision = waits
        forTheTelevision.target = .tv
        let state = ReservationsState(model: model)
        XCTAssertFalse(state.holdsDeleting(row))
        XCTAssertFalse(state.holds(waits))

        await recorder.hold(only: ReservationWrite.delete.rawValue)
        state.delete(row)
        try press(state, acting: true)
        try await until("the delete was never out") { model.isBusy(for: .recorder) }
        XCTAssertTrue(state.holdsDeleting(row), "a second delete was offered with the first still out")
        XCTAssertTrue(state.holds(waits), "a waiting row was live with its recorder at work")
        // With no television in play its rows are held as well: there is nothing to send them to.
        XCTAssertTrue(state.holds(forTheTelevision))

        await recorder.letGo()
        try await until("the delete never came back") { !model.isBusy(for: .recorder) }
        XCTAssertFalse(state.holdsDeleting(row))
        XCTAssertFalse(state.holds(waits))
    }

    /// A television's row picked is let go of with the television's lists, and not with the recorder's.
    func testATelevisionsPickGoesWithTheTelevisionsLists() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoLineUp.television()
        let credentials = await registered(with: television)
        let model = bench.model(recorder: NamedRecorder(1), television: HeldTelevision(television, holding: false),
                                credentials: credentials)
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let programmes = try await programmesNotReserved(model, 1)
        _ = await model.reserve(programmes[0], on: .tv, quality: TVDriver.recordsIn, repeating: "none")
        let row = try XCTUnwrap(model.reservations(for: programmes[0]).first { $0.device == .tv },
                                "the television did not take the reservation")
        let state = ReservationsState(model: model)
        XCTAssertFalse(state.holdsDeleting(row))

        state.delete(row)
        XCTAssertEqual(shown(state), "confirm")
        XCTAssertTrue(state.message(for: try XCTUnwrap(state.ask)).hasSuffix("テレビから削除されます。"))
        state.recordersListsLetGo()
        XCTAssertEqual(shown(state), "confirm", "the recorder's lists going took a television's row with them")
        state.televisionsListsLetGo()
        XCTAssertEqual(shown(state), "nothing", "the television's lists went and its row stayed picked")
    }

    /// Under the title: how many, with the kind when it is not all of them, and how many record now or clash; the
    /// menu's icon marks a list narrowed or sorted otherwise than by time.
    func testTheSubtitleCountsWhatIsShown() async throws {
        let (_, _, model, _) = try await withAReservation()
        let state = ReservationsState(model: model)
        let all = model.allReservations
        XCTAssertTrue(state.subtitle.hasPrefix("\(all.count) 件"), state.subtitle)
        let recording = all.filter(\.recording).count, clashing = all.filter(\.conflict).count
        XCTAssertEqual(state.subtitle.contains(" · 録画中 \(recording)"), recording > 0, state.subtitle)
        XCTAssertEqual(state.subtitle.contains(" · 重複 \(clashing)"), clashing > 0, state.subtitle)
        XCTAssertFalse(state.narrowedOrSorted)

        model.reservationKind = .mine
        let mine = all.filter { !$0.createdByRecorder }
        XCTAssertGreaterThan(mine.count, 0)
        XCTAssertTrue(state.subtitle.hasPrefix("通常の予約 · \(mine.count) 件"), state.subtitle)
        XCTAssertTrue(state.narrowedOrSorted)
        model.reservationKind = .all
        model.reservationSort = .channel
        XCTAssertTrue(state.subtitle.hasPrefix("\(all.count) 件"), "the sort is not said: \(state.subtitle)")
        XCTAssertTrue(state.narrowedOrSorted)
        model.reservationSort = .time
        XCTAssertFalse(state.narrowedOrSorted)
    }

    /// A recorder given up on leaves its list up, and the screen says how old it is above its rows: in minutes,
    /// never less than one, and not while the kind shown leaves its rows out.
    func testAnOldListSaysHowOldItIsAboveItsRows() async throws {
        let (_, recorder, model) = try await connectedHome()
        // One reservation, made from an app: none of the recorder's own making.
        let request = ReservationRequest(title: "手で入れた予約", start: Date().addingTimeInterval(86_400),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: 0xe000)
        await recorder.answer("X_GetRecordScheduleList",
                              with: .result(XsrsElements.update(id: "0x000000000000e000", request)), times: 10)
        await model.pullDownReservations()
        XCTAssertEqual(model.reservations.count, 1)
        XCTAssertEqual(model.reservations.filter(\.createdByRecorder).count, 0)
        let state = ReservationsState(model: model)
        XCTAssertTrue(state.stale.isEmpty, "a list of a recorder that can be asked was said to be old")

        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model), "a recorder that said nothing was taken for one to ask")
        let stale = try XCTUnwrap(state.stale.first)
        XCTAssertEqual(state.stale.count, 1)
        XCTAssertEqual(stale.device, .recorder)
        XCTAssertEqual(stale.since, model.staleSince(for: .recorder))

        let justNow = state.staleLine(stale, at: Date())
        XCTAssertTrue(justNow.hasPrefix("レコーダーの予約は") && justNow.hasSuffix("に読んだものです"), justNow)
        XCTAssertTrue(justNow.contains("1") && justNow.contains("分前"), "a list read just now is not a minute old: \(justNow)")
        XCTAssertFalse(justNow.contains("秒"), justNow)

        model.reservationKind = .automatic
        XCTAssertTrue(state.stale.isEmpty, "the heading stayed with none of its rows shown")
        model.reservationKind = .all
        XCTAssertEqual(state.stale.count, 1)
    }
}
