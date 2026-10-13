import Foundation
import RecorderKit
import XCTest

/// A reason written on a waiting row while its create is out -- another recorder's arrival, holding every row for
/// the one before -- stands, whatever the create is answered with. And a round acts on a row only as it read it:
/// one given a reason, or gone, while the round was out is not sent in that round, nor taken out of the queue
/// as found on the device.
final class ReasonWrittenMeanwhileTests: XCTestCase {
    /// One row waits for a device of the test's own, which turns its create down with a reason of its own: a row
    /// with no reason, and one sent with the reader's consent to the reason it carries, as a row held after
    /// silence and sent again is. Each has the device's reason written on it, as ever. The same rows again,
    /// held for another recorder while their create is out, as that recorder's arrival writes it: the refusal
    /// is not written over that, which stands. The round says the row was refused all the same: so it was.
    func testARefusalIsNotWrittenOverAReasonWrittenWhileTheCreateWasOut() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for (name, consented, meanwhile) in [("a row with no reason", false, false),
                                             ("a row sent with the reader's consent", true, false),
                                             ("a row with no reason, held meanwhile", false, true),
                                             ("a row sent with the reader's consent, held meanwhile", true, true)] {
            let store = try temporaryStore()
            let row = pending("断られる番組", eventID: 1, start: now.addingTimeInterval(3600),
                              problem: consented ? RecorderDriver.heldAfterSilence : nil)
            try await store.queue(row)
            let device = TurnsTheCreateDown(store, holdingItMeanwhile: meanwhile)

            let outcome = await PendingQueue.flush(
                client: device, store: store,
                consenting: consented ? [row.id: RecorderDriver.heldAfterSilence] : [:], now: now)

            expectEqual(await device.creates, 1, name)
            XCTAssertEqual(outcome.refused.map(\.id), [row.id], name)
            let refusal = try XCTUnwrap(outcome.refused.first?.problem, name)
            XCTAssertNotEqual(refusal, RecorderDriver.heldForAnotherRecorder, name)
            expectEqual(try await store.pendingReservations().map(\.problem),
                        [meanwhile ? RecorderDriver.heldForAnotherRecorder : refusal], name)
        }
    }

    /// Three rows wait for a device of the test's own, which makes whatever it is sent, and the queue is
    /// written by somebody else while the first row's create is out. With nothing written, each row is sent,
    /// in the order they start. The second held meanwhile, with the reason another recorder's arrival writes:
    /// it is not sent, it waits with that reason, and the round counts it as held, as it stands now; the round
    /// goes on, and the third is sent. Every row held meanwhile, as that arrival holds them: the first, whose
    /// create was out, has gone and leaves the queue, and neither of the others is sent. The second gone
    /// meanwhile, as when the reader deletes it: it is not sent, and the round counts it nowhere.
    ///
    /// So for the rows of either device, the round being one for both; it reads no sentence, and a
    /// television's rows are written here with the recorder's.
    func testARowGivenAReasonOrGoneWhileTheRowAheadOfItWasBeingMadeIsNotSentInThatRound() async throws {
        try await rowsWrittenWhileTheFirstIsBeingMade(for: Recorders.self)
        try await rowsWrittenWhileTheFirstIsBeingMade(for: Televisions.self)
    }

    private func rowsWrittenWhileTheFirstIsBeingMade<Slot: Named>(for _: Slot.Type) async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reason = RecorderDriver.heldForAnotherRecorder
        let (one, two, three) = ("送信待ちだった「朝の番組」を登録しました", "送信待ちだった「朝の番組」ほか 1 件を登録しました",
                                 "送信待ちだった「朝の番組」ほか 2 件を登録しました")
        let cases: [(name: String, held: [Int], gone: [Int], sent: [Int], says: String)] = [
            ("nothing written", [], [], [0, 1, 2], three),
            ("the second held", [1], [], [0, 2], two),
            ("every row held", [0, 1, 2], [], [0], one),
            ("the second gone", [], [1], [0, 2], two),
        ]
        for (name, held, gone, sent, says) in cases {
            let name = "\(name), waiting for \(Slot.slot.rawValue)"
            let store = try temporaryStore()
            let rows = ["朝の番組", "昼の番組", "夜の番組"].enumerated().map { index, title in
                pending(title, eventID: index + 1, start: now.addingTimeInterval(Double(index + 1) * 3600),
                        target: Slot.slot)
            }
            for row in rows { try await store.queue(row) }
            let device = WritesMeanwhile<Slot>(.whileTheFirstRowIsBeingMade) {
                for index in held { try await store.setPendingProblem(rows[index].id, reason) }
                for index in gone { try await store.removePending(rows[index].id) }
            }

            let outcome = await PendingQueue.flush(client: device, store: store, now: now)

            expectEqual(await device.sent, sent.map { rows[$0].request.title }, name)
            XCTAssertEqual(outcome.sent, sent.map { rows[$0] }, name)
            // The first was sent, whatever was written on it since: it is in none of these.
            let stillHeld = held.filter { $0 > 0 }.map { index in
                var row = rows[index]
                row.problem = reason
                return row
            }
            XCTAssertEqual(outcome.held, stillHeld, "\(name): what the round counts as held, as it stands now")
            expectEqual(try await store.pendingReservations(), stillHeld, "\(name): what still waits")
            XCTAssertEqual(outcome.deferred + outcome.refused + outcome.expired + outcome.alreadyThere, [], name)
            XCTAssertNil(outcome.stopped, name)
            XCTAssertEqual(outcome.says(naming: nil), says, name)
        }
    }

    /// A row sent again with the reader's consent to the reason it carries, as one held after silence at its
    /// create is, in a round for that row alone. It is sent, and the device is told of the consent. Its reason
    /// rewritten once the round has read the queue, as another recorder's arrival rewrites it while the device
    /// is read for the round: the consent was given to the sentence it had, the row is not sent, it waits with
    /// the reason it has now, and the round counts it as held so.
    func testARowSentWithTheReadersConsentIsNotSentOnceItsReasonIsAnotherThanTheRoundReadItWith() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for rewritten in [false, true] {
            let name = rewritten ? "its reason rewritten as the round opened" : "its reason as it was"
            let store = try temporaryStore()
            let row = pending("朝の番組", eventID: 1, start: now.addingTimeInterval(3600),
                              problem: RecorderDriver.heldAfterSilence)
            try await store.queue(row)
            let device = WritesMeanwhile<Recorders>(.asTheRoundOpens) {
                if rewritten { try await store.setPendingProblem(row.id, RecorderDriver.heldForAnotherRecorder) }
            }

            let outcome = await PendingQueue.flush(client: device, store: store,
                                                   consenting: [row.id: RecorderDriver.heldAfterSilence],
                                                   only: row.id, now: now)

            var held = row
            held.problem = RecorderDriver.heldForAnotherRecorder
            expectEqual(await device.sent, rewritten ? [] : ["朝の番組"], name)
            expectEqual(await device.consentedTo, rewritten ? [] : ["朝の番組"], name)
            XCTAssertEqual(outcome.sent, rewritten ? [] : [row], name)
            XCTAssertEqual(outcome.held, rewritten ? [held] : [], name)
            expectEqual(try await store.pendingReservations(), rewritten ? [held] : [], name)
        }
    }

    /// Two rows wait for a device of the test's own, which holds the second already and says so as the round
    /// opens, and the queue is written by somebody else while the first row is being made. With nothing
    /// written the second leaves the queue as found there, unsent -- also when it was read with a reason on it,
    /// a refusal from before. Both held meanwhile, with the reason another recorder's arrival writes: the first,
    /// whose create was out, has gone; the second is not taken out. It waits with that reason, and the round
    /// counts it as held, as it stands now, and not as found there: said to be reserved already and gone from
    /// the queue, it would be a row the reader had just been shown as left for them. So when the reason it was
    /// read with is written over. The second gone meanwhile, as when the reader deletes it: the round counts it
    /// nowhere, and does not say that it was found.
    ///
    /// So for the rows of either device, the round being one for both.
    func testARowFoundOnTheDeviceIsTakenOutOnlyAsItsRoundReadIt() async throws {
        try await rowsFoundThereAndWrittenWhileTheFirstIsBeingMade(for: Recorders.self)
        try await rowsFoundThereAndWrittenWhileTheFirstIsBeingMade(for: Televisions.self)
    }

    private func rowsFoundThereAndWrittenWhileTheFirstIsBeingMade<Slot: Named>(for _: Slot.Type) async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (reason, refusal) = (RecorderDriver.heldForAnotherRecorder, "前に断られた理由")
        let sent = "送信待ちだった「朝の番組」を登録しました", found = "「昼の番組」はすでに予約されていました"
        let cases: [(name: String, readWith: String?, held: Bool, gone: Bool)] = [
            ("nothing written", nil, false, false),
            ("nothing written, the row read with a reason", refusal, false, false),
            ("both held", nil, true, false),
            ("both held, the row read with a reason", refusal, true, false),
            ("the second gone", nil, false, true),
        ]
        for (name, readWith, held, gone) in cases {
            let name = "\(name), waiting for \(Slot.slot.rawValue)"
            let store = try temporaryStore()
            let first = pending("朝の番組", eventID: 1, start: now.addingTimeInterval(3600), target: Slot.slot)
            let second = pending("昼の番組", eventID: 2, start: now.addingTimeInterval(7200), problem: readWith,
                                 target: Slot.slot)
            for row in [first, second] { try await store.queue(row) }
            let device = WritesMeanwhile<Slot>(.whileTheFirstRowIsBeingMade, finding: ["昼の番組"]) {
                if held { for row in [first, second] { try await store.setPendingProblem(row.id, reason) } }
                if gone { try await store.removePending(second.id) }
            }

            let outcome = await PendingQueue.flush(client: device, store: store, now: now)

            var left = second
            left.problem = reason
            expectEqual(await device.sent, ["朝の番組"], name)
            XCTAssertEqual(outcome.sent, [first], name)
            XCTAssertEqual(outcome.alreadyThere, held || gone ? [] : [second],
                           "\(name): what the round counts as found there")
            XCTAssertEqual(outcome.held, held ? [left] : [], "\(name): what the round counts as held, as it stands now")
            expectEqual(try await store.pendingReservations(), held ? [left] : [], "\(name): what still waits")
            XCTAssertEqual(outcome.deferred + outcome.refused + outcome.expired, [], name)
            XCTAssertNil(outcome.stopped, name)
            XCTAssertEqual(outcome.says(naming: nil), held || gone ? sent : sent + "。" + found, name)
        }
    }

    /// The same of a row with a reason on it that the round passed on its way to the row that opened it: such a
    /// row is looked up once the device has been read for the round, and was read before that request went. Two
    /// rows wait: the first refused before, which the device holds already and says so as the round opens; the
    /// second to go. With nothing written the first leaves the queue as found there. Its reason written over
    /// while the device is read for the round, as another recorder's arrival writes it: it is not taken out,
    /// waits with the reason it has now, and is counted as held so. Gone meanwhile: counted nowhere. And one the
    /// device does not hold stays as it was read, held. The second is made each time.
    func testARowPassedOverAndFoundOnTheDeviceAsTheRoundOpensIsTakenOutOnlyAsItsRoundReadIt() async throws {
        try await aRowPassedOverAndWrittenAsTheRoundOpens(for: Recorders.self)
        try await aRowPassedOverAndWrittenAsTheRoundOpens(for: Televisions.self)
    }

    private func aRowPassedOverAndWrittenAsTheRoundOpens<Slot: Named>(for _: Slot.Type) async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (reason, refusal) = (RecorderDriver.heldForAnotherRecorder, "前に断られた理由")
        let cases: [(name: String, there: Bool, rewritten: Bool, gone: Bool)] = [
            ("nothing written", true, false, false),
            ("its reason written over", true, true, false),
            ("gone", true, false, true),
            ("not on the device, nothing written", false, false, false),
        ]
        for (name, there, rewritten, gone) in cases {
            let name = "\(name), waiting for \(Slot.slot.rawValue)"
            let store = try temporaryStore()
            let passed = pending("朝の番組", eventID: 1, start: now.addingTimeInterval(3600), problem: refusal,
                                 target: Slot.slot)
            let toGo = pending("昼の番組", eventID: 2, start: now.addingTimeInterval(7200), target: Slot.slot)
            for row in [passed, toGo] { try await store.queue(row) }
            let device = WritesMeanwhile<Slot>(.asTheRoundOpens, finding: there ? ["朝の番組"] : []) {
                if rewritten { try await store.setPendingProblem(passed.id, reason) }
                if gone { try await store.removePending(passed.id) }
            }

            let outcome = await PendingQueue.flush(client: device, store: store, now: now)

            var left = passed
            if rewritten { left.problem = reason }
            let waits = rewritten || !there ? [left] : []
            expectEqual(await device.sent, ["昼の番組"], name)
            XCTAssertEqual(outcome.sent, [toGo], name)
            XCTAssertEqual(outcome.alreadyThere, there && !rewritten && !gone ? [passed] : [],
                           "\(name): what the round counts as found there")
            XCTAssertEqual(outcome.held, waits, "\(name): what the round counts as held, as it stands now")
            expectEqual(try await store.pendingReservations(), waits, "\(name): what still waits")
            XCTAssertEqual(outcome.deferred + outcome.refused + outcome.expired, [], name)
            XCTAssertNil(outcome.stopped, name)
        }
    }
}

/// Whose rows a device of the test's own is sent.
private protocol Named {
    static var slot: DeviceSlot { get }
}

private enum Recorders: Named {
    static let slot = DeviceSlot.recorder
}

private enum Televisions: Named {
    static let slot = DeviceSlot.tv
}

/// A device of the test's own that is read for nothing before a round and makes every row it is sent, saying
/// nothing of it. Once, while the round is out, it does what the test handed it -- as somebody else writing the
/// queue meanwhile would: as it is asked to open the round, or while the first row it is sent is being made.
/// The rows it is said to hold already, by their titles, it says it holds as the round opens.
private actor WritesMeanwhile<Slot: Named>: QueueTarget {
    enum When {
        case asTheRoundOpens, whileTheFirstRowIsBeingMade
    }

    static var slot: DeviceSlot { Slot.slot }

    private let when: When
    private let finding: Set<String>
    private var meanwhile: (@Sendable () async throws -> Void)?
    /// The rows it was sent, by their titles, in order, and those of them it was told the reader consented to.
    private(set) var sent: [String] = []
    private(set) var consentedTo: [String] = []

    init(_ when: When, finding: Set<String> = [], _ meanwhile: @escaping @Sendable () async throws -> Void) {
        self.when = when
        self.finding = finding
        self.meanwhile = meanwhile
    }

    func probe(timeout: TimeInterval) async throws {}

    func openRound(for waiting: [PendingReservation]) async -> RoundOpened<NoRound> {
        if when == .asTheRoundOpens { await writeOnce() }
        return .open(NoRound(), alreadyThere: Set(waiting.filter { finding.contains($0.request.title) }.map(\.id)))
    }

    func send(_ waiting: PendingReservation, consented: Bool,
              in round: NoRound) async -> (sent: RowSent, round: NoRound) {
        sent.append(waiting.request.title)
        if consented { consentedTo.append(waiting.request.title) }
        if when == .whileTheFirstRowIsBeingMade { await writeOnce() }
        return (.made(saying: nil), round)
    }

    private func writeOnce() async {
        guard let write = meanwhile else { return }
        meanwhile = nil
        do {
            try await write()
        } catch {
            XCTFail("the queue could not be written meanwhile: \(error)")
        }
    }
}

/// A device of the test's own that turns every create down with a reason of its own (831, a channel it cannot
/// record), having first written on the waiting row, when told to, that it is held for another recorder -- as
/// that recorder's arrival writes it while the create is out.
private actor TurnsTheCreateDown: ReservationTarget {
    static let slot = DeviceSlot.recorder

    private let store: GuideStore
    private let holding: Bool
    private(set) var creates = 0

    init(_ store: GuideStore, holdingItMeanwhile holding: Bool) {
        self.store = store
        self.holding = holding
    }

    func probe(timeout: TimeInterval) async throws {}

    func create(_ request: ReservationRequest) async throws {
        creates += 1
        if holding {
            for row in try await store.pendingReservations() {
                try await store.setPendingProblem(row.id, RecorderDriver.heldForAnotherRecorder)
            }
        }
        throw RecorderError.soap(action: "X_CreateRecordSchedule", status: 500, code: "831", body: "")
    }
}
