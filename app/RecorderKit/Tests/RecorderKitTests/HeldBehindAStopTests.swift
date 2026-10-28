import Foundation
import RecorderKit
import XCTest

/// A round that stops counts the rows it did not come to, where they carry a reason, as passed over with it, as
/// it counts the ones it did come to (`PendingQueue.flush`, `PendingQueue.Outcome.held`): so that what a round
/// with no screen tells of the reservations still held after silence at an earlier create
/// (`RecorderDriver.tells`) is counted over the whole of what the round read, each row as it stands as the round
/// breaks. Through the queue's flush, with a device of the test's own that stops where the test says.
///
/// On the main actor, as the app's tests are: a failure recorded off it by the last assertion of an async test
/// has been seen to go unrecorded, the test ending with one failure fewer than it had.
@MainActor
final class HeldBehindAStopTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let clause = "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります"
    private static let dropped = "「終わった番組」は放送が終わっていたため、送らずに削除しました"
    private static let sent = "送信待ちだった「朝の番組」を予約しました"
    private static func still(_ count: Int) -> String {
        "レコーダーに届いたか確かめていない予約が \(count) 件あります。予約一覧で確かめてください"
    }

    /// A row an hour long that starts `hours` after the moment the rounds here are run at.
    private func row<Slot: Named>(_ title: String, _ programme: Int, in hours: Double, reason: String? = nil,
                                  for _: Slot.Type) -> PendingReservation {
        pending(title, eventID: programme, start: Self.now + hours * 3600, problem: reason, target: Slot.slot)
    }

    /// The round of `rows` on a device that stops as it is told, with `consenting` handed in.
    private func round<Slot: Named>(_ rows: [PendingReservation], on device: Stops<Slot>,
                                    consenting: [String: String] = [:]) async throws
        -> (outcome: PendingQueue.Outcome, waits: [PendingReservation]) {
        try await round(rows, consenting: consenting) { _ in device }
    }

    /// The same on a device made once the queue is there, for one that writes the queue before it stops.
    private func round<Slot: Named>(_ rows: [PendingReservation], consenting: [String: String] = [:],
                                    on device: (GuideStore) -> Stops<Slot>) async throws
        -> (outcome: PendingQueue.Outcome, waits: [PendingReservation]) {
        let store = try temporaryStore()
        for row in rows { try await store.queue(row) }
        let outcome = await PendingQueue.flush(client: device(store), store: store, consenting: consenting,
                                               now: Self.now)
        return (outcome, try await store.pendingReservations())
    }

    /// A round of the recorder's rows cut short at the read that opens it, one whose programme is over having
    /// been dropped ahead of it, which is news. Behind the row that was to go waits one held after silence at
    /// an earlier create: the round never came to it, counts it as held all the same, and what it tells ends,
    /// after the queue's clause for a round cut short, by saying that one reservation is held still. With such
    /// a row on either side of the stop, the one passed over and the one not come to: two. A row behind the
    /// stop that is held for another reason -- refused before, held for another recorder -- is counted as held
    /// and is not said: the line is of the reservations held after silence. A row behind it with no reason is
    /// not held, nor is one whose programme is over, which the round would have dropped, nor one the reader
    /// consented to, which it would have sent. A consent handed in for a row that carries no reason changes
    /// nothing of that row: it waits to go, and is not held.
    ///
    /// Cut short by silence at a row -- as the recorder's round is at its USB slot's settling -- after one that
    /// was made: the same, of the row behind. A round that stopped at silence at a create says that a
    /// reservation is held, in the sentence written on the row, and not how many, also with such a row behind
    /// the stop. And with no news -- nothing over, nothing sent -- nothing is told, the row behind counted or
    /// not.
    func testARoundThatStopsCountsTheRowsBehindTheStopThatCarryAReasonAsHeld() async throws {
        typealias R = Recorders
        let after = RecorderDriver.heldAfterSilence
        let over = row("終わった番組", 1, in: -2, for: R.self), toGo = row("朝の番組", 2, in: 1, for: R.self)
        let behind = row("夜の番組", 3, in: 3, reason: after, for: R.self)
        let ahead = row("早朝の番組", 4, in: 0.5, reason: after, for: R.self)
        let refused = row("夕方の番組", 5, in: 2, reason: "前に断られた理由", for: R.self)
        let forAnother = row("深夜の番組", 6, in: 4, reason: RecorderDriver.heldForAnotherRecorder, for: R.self)
        let plain = row("昼の番組", 7, in: 2, for: R.self)
        // One over that began first of all; one on air since three hours ago; and one behind that, which began
        // after it and is over.
        let overFirst = row("終わった番組", 10, in: -4, for: R.self)
        var onAir = row("長い番組", 8, in: -3, for: R.self)
        onAir.request.durationSec = 4 * 3600
        var overBehind = row("短い番組", 9, in: -2.5, reason: after, for: R.self)
        overBehind.request.durationSec = 1800
        let atARead = SendingStop.silent(afterSending: false)
        let cutShort = Self.dropped + "。" + Self.clause

        var came = try await round([over, toGo, behind], on: Stops<R>(opening: atARead))
        XCTAssertEqual(came.outcome.stopped, atARead)
        XCTAssertEqual(came.outcome.expired, [over])
        XCTAssertEqual(came.outcome.held, [behind], "the row behind the stop is not counted as held")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort + "。" + Self.still(1),
                       "cut short at the read that opens it, one held behind")
        XCTAssertEqual(came.waits, [toGo, behind], "a row was written or taken out by a round that stopped")

        came = try await round([over, ahead, toGo, behind], on: Stops<R>(opening: atARead))
        XCTAssertEqual(came.outcome.held, [ahead, behind])
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort + "。" + Self.still(2),
                       "one held either side of the stop")

        came = try await round([over, toGo, refused, forAnother], on: Stops<R>(opening: atARead))
        XCTAssertEqual(came.outcome.held, [refused, forAnother])
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort,
                       "rows held for other reasons behind the stop")

        came = try await round([over, toGo, plain], on: Stops<R>(opening: atARead))
        XCTAssertEqual(came.outcome.held, [], "a row with no reason behind the stop")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort, "a row with no reason behind")

        came = try await round([overFirst, onAir, overBehind], on: Stops<R>(opening: atARead))
        XCTAssertEqual(came.outcome.expired, [overFirst])
        XCTAssertEqual(came.outcome.held, [], "a row behind the stop whose programme is over")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort, "a row over behind the stop")

        came = try await round([over, toGo, behind], on: Stops<R>(opening: atARead), consenting: [behind.id: after])
        XCTAssertEqual(came.outcome.held, [], "a row behind the stop that the reader consented to")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort, "a row consented to behind")

        came = try await round([over, toGo, plain], on: Stops<R>(opening: atARead), consenting: [plain.id: after])
        XCTAssertEqual(came.outcome.held, [], "a row with no reason behind the stop, a consent handed in for it")

        let atARow = Stops<R>(at: ["昼の番組": .stopped(atARead, passedOver: false)])
        came = try await round([toGo, plain, behind], on: atARow)
        XCTAssertEqual(came.outcome.sent, [toGo])
        XCTAssertEqual(came.outcome.held, [behind], "the row behind a stop at a row is not counted as held")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil),
                       Self.sent + "。" + Self.clause + "。" + Self.still(1), "cut short at a row, one held behind")

        let atACreate = Stops<R>(at: ["朝の番組": .stopped(.silent(afterSending: true), passedOver: false)])
        came = try await round([toGo, behind], on: atACreate)
        XCTAssertEqual(came.outcome.held, [behind])
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), after, "silence at a create, one behind")

        came = try await round([toGo, behind], on: Stops<R>(opening: atARead))
        XCTAssertEqual(came.outcome.held, [behind])
        XCTAssertNil(RecorderDriver.tells(came.outcome, naming: nil), "no news, one held behind the stop")

        came = try await round([toGo, behind], on: Stops<R>())
        XCTAssertEqual(came.outcome.held, [behind])
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), Self.sent + "。" + Self.still(1),
                       "a round that went through")
    }

    /// The rows behind a stop are counted as they stand as the round breaks, and not as the round read them as
    /// it began: it can be out for as long as the device takes, and the queue need not stand as it was read by
    /// then. Written here by the device itself, just before it stops, as somebody else writing the queue while
    /// the round is out would. Of two reservations held after silence behind the row that was to go, one gone
    /// from the queue by the time the round is cut short at the read that opens it: the other is counted as
    /// held, and what the round tells ends by saying that one reservation is held still, not two. One whose
    /// reason has been taken off meanwhile waits to go, is not held, and nothing is said of it. And behind a
    /// stop at a row, after one that was made: the same of a reservation gone meanwhile.
    func testTheRowsBehindAStopAreCountedAsTheyStandAsTheRoundBreaks() async throws {
        typealias R = Recorders
        let after = RecorderDriver.heldAfterSilence
        let over = row("終わった番組", 1, in: -2, for: R.self), toGo = row("朝の番組", 2, in: 1, for: R.self)
        let behind = row("夜の番組", 3, in: 3, reason: after, for: R.self)
        let later = row("深夜の番組", 6, in: 4, reason: after, for: R.self)
        let plain = row("昼の番組", 7, in: 2, for: R.self)
        let atARead = SendingStop.silent(afterSending: false)
        let cutShort = Self.dropped + "。" + Self.clause

        var came = try await round([over, toGo, behind, later]) { queue in
            Stops<R>(opening: atARead, first: { try await queue.removePending(later.id) })
        }
        XCTAssertEqual(came.outcome.stopped, atARead)
        XCTAssertEqual(came.outcome.held, [behind], "a row behind the stop is counted as the round read it")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort + "。" + Self.still(1),
                       "one of two held behind the stop gone meanwhile")
        XCTAssertEqual(came.waits, [toGo, behind])

        var toGoNow = behind
        toGoNow.problem = nil
        came = try await round([over, toGo, behind]) { queue in
            Stops<R>(opening: atARead, first: { try await queue.setPendingProblem(behind.id, nil) })
        }
        XCTAssertEqual(came.outcome.held, [], "a row behind the stop whose reason was taken off meanwhile")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), cutShort,
                       "the reason taken off meanwhile, behind the stop")
        XCTAssertEqual(came.waits, [toGo, toGoNow])

        came = try await round([toGo, plain, behind]) { queue in
            Stops<R>(at: ["昼の番組": .stopped(atARead, passedOver: false)],
                     first: { try await queue.removePending(behind.id) })
        }
        XCTAssertEqual(came.outcome.sent, [toGo])
        XCTAssertEqual(came.outcome.held, [], "a row behind a stop at a row that has gone meanwhile")
        XCTAssertEqual(RecorderDriver.tells(came.outcome, naming: nil), Self.sent + "。" + Self.clause,
                       "gone meanwhile, behind a stop at a row")
        XCTAssertEqual(came.waits, [plain])
    }

    /// A television's round that stops counts the rows behind the stop that carry a reason as held too, the
    /// round being one for both devices, and nothing it says changes by it: neither the Shortcuts action's
    /// answer nor what its runs tell once reads what a round held. Here a round stopped as it opened, for want
    /// of a registration, after a row whose programme was over, with a row refused before behind the one to go.
    func testATelevisionsRoundThatStopsCountsThemTooAndSaysNothingMoreForIt() async throws {
        typealias T = Televisions
        let over = row("終わった番組", 1, in: -2, for: T.self), toGo = row("朝の番組", 2, in: 1, for: T.self)
        let behind = row("夜の番組", 3, in: 3, reason: "前に断られた理由", for: T.self)

        let came = try await round([over, toGo, behind], on: Stops<T>(opening: .needsPairing))
        XCTAssertEqual(came.outcome.held, [behind], "the row behind the stop is not counted as held")
        XCTAssertEqual(came.outcome.expired, [over])
        XCTAssertEqual(came.waits, [toGo, behind])

        var withNoneHeld = came.outcome
        withNoneHeld.held = []
        let said = TVDriver.says(.sent(came.outcome), naming: "テレビ")
        XCTAssertEqual(said, TVDriver.says(.sent(withNoneHeld), naming: "テレビ"), "the action's answer")
        XCTAssertEqual(said?.hasPrefix("テレビ宛の「終わった番組」は放送が終わっていたため、送らずに削除しました。"), true,
                       "the round was meant to have news: \(said ?? "nothing said")")
        let nextRun = Self.now + 6 * 3600
        let told = ToldOnce().after(.sent(came.outcome), waiting: came.waits, before: nextRun, now: Self.now,
                                  naming: "テレビ")
        let toldWithNoneHeld = ToldOnce().after(.sent(withNoneHeld), waiting: came.waits, before: nextRun,
                                              now: Self.now, naming: "テレビ")
        XCTAssertEqual(told.notices, toldWithNoneHeld.notices, "what the television's runs tell once")
        XCTAssertEqual(told.told, toldWithNoneHeld.told)
        XCTAssertNotNil(told.notices.queue, "the round was meant to have news")
    }
}

/// Whose rows a device of the test's own is sent, and whether it holds a row whose create met silence.
private protocol Named {
    static var slot: DeviceSlot { get }
    static var heldAfterSilence: String? { get }
}

private enum Recorders: Named {
    static let slot = DeviceSlot.recorder
    static var heldAfterSilence: String? { RecorderDriver.heldAfterSilence }
}

private enum Televisions: Named {
    static let slot = DeviceSlot.tv
    static var heldAfterSilence: String? { nil }
}

/// A device of the test's own that makes every row it is sent, but for where it is told to stop: as the round
/// opens (`opening`), or at the rows named by their titles, each answered as said (`at`). Just before it stops
/// it does what the test handed it (`first`), as somebody else writing the queue while the round is out would.
private actor Stops<Slot: Named>: QueueTarget {
    static var slot: DeviceSlot { Slot.slot }
    static var heldAfterSilence: String? { Slot.heldAfterSilence }

    private let opening: SendingStop?
    private let at: [String: RowSent]
    private let first: @Sendable () async throws -> Void

    init(opening: SendingStop? = nil, at: [String: RowSent] = [:],
         first: @escaping @Sendable () async throws -> Void = {}) {
        self.opening = opening
        self.at = at
        self.first = first
    }

    func probe(timeout: TimeInterval) async throws {}

    func openRound(for waiting: [PendingReservation]) async -> RoundOpened<NoRound> {
        guard let opening else { return .open(NoRound(), alreadyThere: []) }
        await write()
        return .stopped(opening)
    }

    func send(_ waiting: PendingReservation, consented: Bool,
              in round: NoRound) async -> (sent: RowSent, round: NoRound) {
        let came = at[waiting.request.title] ?? .made(saying: nil)
        if case .stopped = came { await write() }
        return (came, round)
    }

    private func write() async {
        do {
            try await first()
        } catch {
            XCTFail("the queue could not be written before the stop: \(error)")
        }
    }
}
