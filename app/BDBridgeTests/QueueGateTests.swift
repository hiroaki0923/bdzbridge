import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The reservations that wait on the phone for the recorder to answer: when they are sent and what is read
/// around the sending, what the strip says became of them, what one that could not be kept says, what asking for
/// one again or taking one away does while the recorder is away, and how the ones held for another recorder are
/// counted.
///
/// Gates, as `FunnelGateTests` and `ReservationGateTests` are and for the same move: each pins what the app does
/// today, and where a later change is to rewrite a test it says so, with that change's name in the plan in
/// brackets. A test asks only what a screen asks and reads only what a screen reads. The one that looks at the
/// sentences a sending comes to asks the queue itself (`PendingQueue.flush`), which is what the screens' sending
/// and the two runs with no screen all end in; neither of those runs is called here.
///
/// What is said of a sending is compared with the bench's own words (`Said`). Those sentences are to be
/// reworded on purpose before the queue moves, and the rewording is then one edit, there.
@MainActor
final class QueueGateTests: XCTestCase {
    // MARK: - sending what waits

    /// Pulling the reservations down while connected reads the list and then sends what waits. The list is read
    /// once more only when something was made, which is what puts the new reservation on screen: with nothing
    /// waiting, or nothing but what was turned down before, the recorder is asked for its list and for nothing
    /// else. A sending with nothing to say leaves the strip's last line where it was.
    ///
    /// The sending has a line of its own, and while it is out the recorder in play cannot be changed. A
    /// reservation the recorder turns down keeps the recorder's reason on its row, on screen and on the phone,
    /// and is said on the strip in the queue's words. It is not put on the failure line, which is for what the
    /// reader asked the recorder for and is left as it was. Leaving the app takes the strip's line away: it was
    /// for that visit.
    ///
    /// The strip's two sentences are to name the device (C). The read after something was made has to stay
    /// when the two reads of a connect become one (A10).
    func testPullingDownWhileConnectedReadsThenSendsWhatWaitsUnderALineOfItsOwn() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)
        let (taken, refused) = (programmes[0], programmes[1])

        // Nothing waiting.
        var count = await recorder.heard.count
        await model.refreshReservations()
        expectEqual(await recorder.heard(since: count), [Kind.list], "with nothing waiting, only the list is read")
        XCTAssertNil(model.flushReport, "the strip says something of a queue with nothing in it")

        // One waiting.
        try await store.queue(waiting(for: taken))
        count = await recorder.heard.count
        await model.refreshReservations()
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.create, Kind.list],
                    "the list is read, what waits is sent, and the list is read again for what was made")
        XCTAssertEqual(model.flushReport, Said.sent(taken.title))
        XCTAssertNotNil(model.reservation(for: taken), "the programme is not marked as reserved")
        XCTAssertTrue(model.pending.isEmpty, "what was sent is still shown as waiting")
        expectEqual(reasons(try await store.pendingReservations()), [:], "what was sent stayed in the queue")

        // One the recorder turned down before: not sent again by itself, so nothing was made and nothing new is
        // to be said.
        let reason = "前に断られた理由"
        try await store.queue(waiting(for: refused, problem: reason))
        count = await recorder.heard.count
        await model.refreshReservations()
        expectEqual(await recorder.heard(since: count), [Kind.list],
                    "a reservation turned down before was sent, or the list was read with nothing made")
        XCTAssertEqual(model.flushReport, Said.sent(taken.title), "a sending with nothing to say changed the strip")
        let row = try XCTUnwrap(model.pending(for: refused), "the reservation turned down before is not shown")
        XCTAssertEqual(row.problem, reason)

        // The reader asks for it again, and the recorder turns it down again: 831, a channel it cannot receive.
        leaveALine(on: model)
        count = await recorder.heard.count
        await recorder.answer(Kind.create, with: .fault(831))
        await recorder.hold(only: Kind.create)
        let asking = Task { await model.resend(row) }
        try await until("what waits never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        XCTAssertEqual(model.busy, "送信待ちの予約を登録中")
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with what waits being sent")
        await recorder.letGo()
        await asking.value

        let refusal = Said.fault(831, Kind.create)
        expectEqual(await recorder.heard(since: count), [Kind.create],
                    "it was sent again, or the list was read with nothing made")
        XCTAssertEqual(reasons(model.pending), [row.id: refusal], "the row on screen does not say why")
        expectEqual(reasons(try await store.pendingReservations()), [row.id: refusal],
                    "the reason was not kept, and the reservation would be sent again by itself")
        XCTAssertEqual(model.flushReport, Said.refused(refused.title))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the queue's refusal went on the failure line")
        XCTAssertNil(model.busy)
        XCTAssertTrue(model.connected, "a refusal was taken for the recorder going")

        model.wentToBackground()
        XCTAssertNil(model.flushReport, "the strip's line outlived the visit it was for")
    }

    /// The order of a connect. What waits is sent inside the attach, and the list is read after it for what was
    /// made; then the reservations are read, before a guide that is behind is fetched -- the guide marks what is
    /// already set to record from that list. So a connect that sent something reads the list twice, and nothing
    /// of the guide is asked for before the second.
    ///
    /// The two reads are to become one (A10), and the strip's sentence is to name the device (C).
    func testAConnectSendsWhatWaitsThenReadsTheReservationsThenTheGuide() async throws {
        let bench = try aBench()
        // No guide in the cache, so every type of it is behind; and so the reservation is of the test's making.
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await GuideStore(path: bench.guidePath).queue(morning)
        let recorder = NamedRecorder(1)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)

        // Of everything a connect asks, what this is about: the reservation, the list, and the guide's files.
        let heard = await recorder.heard.filter { $0 == Kind.create || $0 == Kind.list || $0.hasPrefix(Kind.guide) }
        XCTAssertEqual(Array(heard.prefix(3)), [Kind.create, Kind.list, Kind.list],
                       "what waits is sent and read back, and the reservations are read, before the guide")
        let afterwards = heard.dropFirst(3)
        XCTAssertFalse(afterwards.isEmpty, "the guide was meant to be behind, and so to be fetched")
        XCTAssertTrue(afterwards.allSatisfy { $0.hasPrefix(Kind.guide) },
                      "something was sent or read once the guide was being fetched: \(heard)")
        XCTAssertEqual(model.flushReport, Said.sent(morning.request.title))
        XCTAssertTrue(model.pending.isEmpty, "what was sent is still shown as waiting")
        XCTAssertTrue(model.reservations.contains { $0.eventID == morning.request.eventID },
                      "the reservation made is not in the list on screen")
    }

    // MARK: - keeping one, asking for one again, taking one away

    /// A reservation that could not be saved has been made nowhere: the answer is no, the reason is said, and
    /// nothing says it is waiting, on screen or on the phone. That is so when the cache is busy with another
    /// writer for longer than the app waits, and when there is no cache at all -- in which case no connect was
    /// ever set going either. One that is kept asks the recorder nothing.
    ///
    /// As it is today: keeping one takes away what was on the failure line. A later change leaves the device's
    /// line to the device (A9), and gives what is not the device's failure a line of its own. Both sentences
    /// stay as they are.
    func testAReservationThatCannotBeKeptOnThePhoneIsNotSaidToBeWaiting() async throws {
        let bench = try aBench()
        // The lock is held on purpose: what is tested is giving up, not the wait.
        bench.storeBusyTimeoutMilliseconds = 200
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilGivenUp(model)
        let program = try await aProgramme(model)
        let store = try GuideStore(path: bench.guidePath)
        let asked = await recorder.asked
        func reserve(with model: AppModel) async -> Bool {
            await model.reserve(program, quality: "DR", repeating: "none")
        }

        let writer = Writer(to: bench.guidePath)
        expectFalse(await reserve(with: model), "a reservation that could not be saved is said to have been kept")
        let said = model.problem(for: .recorder) ?? "nothing"
        XCTAssertTrue(said.hasPrefix("予約を端末に保存できませんでした: "), "what is said instead: \(said)")
        XCTAssertNil(model.queued, "a reservation that was not saved is said to be waiting")
        XCTAssertNil(model.pending(for: program))
        expectEqual(reasons(try await store.pendingReservations()), [:])

        writer.letGo()
        expectTrue(await reserve(with: model), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertEqual(model.queued?.request.eventID, program.eventID)
        XCTAssertNotNil(model.pending(for: program), "the reservation kept is not shown as waiting")
        expectEqual(try await store.pendingReservations().map(\.request.eventID), [program.eventID])
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked")

        // No cache: a folder stands where the database would be, so it cannot be opened.
        let other = try aBench()
        try FileManager.default.createDirectory(atPath: other.guidePath, withIntermediateDirectories: true)
        let without = other.model(recorder: SilentRecorder())
        expectFalse(await reserve(with: without), "a reservation with nowhere to be saved is said to have been kept")
        XCTAssertEqual(without.problem(for: .recorder),
                       "予約を端末に保存できませんでした（端末内のデータベースを開けませんでした）")
        XCTAssertNil(without.queued)
        XCTAssertTrue(without.pending.isEmpty)
        XCTAssertEqual(other.clientsMade, 0, "a connect was set going with no cache to connect over")
    }

    /// With the recorder known to be away. Asking for a waiting reservation to be sent again takes the reason
    /// off its row, on the phone and on screen, so that it goes with the rest the next time the recorder
    /// answers -- and does nothing more: nothing is asked, and nothing is said on the failure line or the strip.
    /// Taking one away removes it from the phone, and asks the recorder nothing either.
    func testAwayFromTheRecorderAWaitingReservationIsAskedForAgainOrTakenAwayWithNothingAsked() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilGivenUp(model)
        let store = try GuideStore(path: bench.guidePath)
        let reason = "前に断られた理由"
        let again = try waiting(for: try await aProgramme(model), problem: reason)
        let unwanted = try waiting(for: try await aProgramme(model, skipping: 1), problem: reason)
        try await store.queue(again)
        try await store.queue(unwanted)
        await model.loadPending()
        XCTAssertEqual(reasons(model.pending), [again.id: reason, unwanted.id: reason])
        let asked = await recorder.asked
        leaveALine(on: model)

        await model.resend(again)
        XCTAssertEqual(reasons(model.pending), [again.id: "", unwanted.id: reason],
                       "the row on screen still says it was turned down, or the other no longer does")
        expectEqual(reasons(try await store.pendingReservations()), [again.id: "", unwanted.id: reason],
                    "the reason is still on the phone, and the reservation would not go with the rest")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "asking for one again said something")
        XCTAssertNil(model.flushReport)

        await model.removePending(unwanted)
        XCTAssertEqual(reasons(model.pending), [again.id: ""], "the reservation taken away is still shown")
        expectEqual(reasons(try await store.pendingReservations()), [again.id: ""])
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked")
        XCTAssertTrue(model.gaveUp)
    }

    // MARK: - what the strip says

    /// How many reservations the strip says are held for another recorder is the number of waiting rows whose
    /// reason is one sentence, letter for letter -- and that sentence is in the phone's database, where a build
    /// that words it otherwise would no longer find what an earlier one wrote. So it is written here as it
    /// reads: a row an earlier launch left in those words is counted at the first connect, and a row with any
    /// other reason is not; they are the words another recorder's arrival writes on every row; the strip's own
    /// sentence carries the count, comes first, and is joined to what was sent with a full stop; and one the
    /// reader asks for again goes to the recorder in play.
    ///
    /// The sentence on the rows is never to change. The strip's own may be reworded (C).
    func testWhatIsHeldForAnotherRecorderIsCountedByTheSentenceWrittenOnIt() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let store = try GuideStore(path: bench.guidePath)
        let recorder = NamedRecorder(1)
        let model = bench.model(recorders: [Bench.host: recorder])
        // Held until the reservations are in the queue, so that the first connect finds them waiting.
        await recorder.hold()
        await model.start()
        let written = [Said.heldForAnotherRecorder, Said.heldForAnotherRecorder, "受信できないチャンネルです"]
        for (skipping, reason) in written.enumerated() {
            try await store.queue(waiting(for: aProgramme(model, skipping: skipping), problem: reason))
        }
        await recorder.letGo()
        try await untilConnected(model)

        XCTAssertEqual(model.pending.count, written.count)
        XCTAssertEqual(model.flushReport, Said.heldBack(2),
                       "what an earlier launch left held is not counted, or what was turned down is counted too")
        expectEqual(await recorder.asked(Kind.create), 0, "a reservation with a reason on it was sent")

        await recorder.become(2)
        await model.connect()
        try await untilIdle(model)
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(try await store.pendingReservations().map(\.problem),
                    Array(repeating: Said.heldForAnotherRecorder, count: written.count),
                    "another recorder's arrival did not write the sentence on every row")
        XCTAssertEqual(model.flushReport, Said.heldBack(3))
        expectEqual(await recorder.asked(Kind.create), 0, "what waited for the first recorder went to the second")

        let first = try XCTUnwrap(model.pending.first)
        await model.resend(first)
        XCTAssertEqual(model.flushReport, Said.heldBack(2) + "。" + Said.sent(first.request.title))
        expectEqual(await recorder.asked(Kind.create), 1, "the one asked for again did not go to the recorder in play")
        XCTAssertEqual(model.pending.count, 2)
    }

    /// What became of the queue, as a sending says it: the other half of the strip's line, and the whole of the
    /// overnight notification and of the Shortcuts action's answer. A sentence each for what was sent, what was
    /// dropped because its programme was over, what the recorder turned down and what could not be sent this
    /// time, in that order and joined with a full stop; the first by its title and the others by their number;
    /// the recorder going silent part way said only after something else, since by itself it is the app going
    /// offline, which the strip says already; and nothing at all when there is nothing to say.
    ///
    /// Each sending is the queue's own (`PendingQueue.flush`) to a recorder of its own, with no model and no
    /// connect: what a sending came to cannot be made by hand. The queue is emptied before each, so that what one
    /// left behind is not what the next one finds.
    ///
    /// The sentences are to be reworded on purpose (C), and to move beside the queue.
    func testWhatBecameOfTheQueueIsSaidInTheseWords() async throws {
        let store = try GuideStore(path: try aBench().guidePath)
        // Read from the queue in the order they start: the one that is over, then the morning's, then noon's.
        let over = waiting("終わった番組", startingIn: -120, programme: 4320)
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        let noon = waiting("昼の番組", startingIn: 121, programme: 4322)
        let sendings = [
            Sending("one sent", [morning], says: Said.sent("朝の番組")),
            Sending("two sent", [morning, noon], says: Said.sent("朝の番組", andOthers: 1)),
            Sending("one that is over", [over], says: Said.expired("終わった番組")),
            Sending("one turned down", [morning], says: Said.refused("朝の番組")) {
                await $0.answer(Kind.create, with: .fault(831))
            },
            Sending("one the recorder was too busy for", [morning], says: Said.deferred("朝の番組")) {
                await $0.beBusy(with: Kind.create)
            },
            // The morning's is taken and noon's turned down.
            Sending("one over, one sent, one turned down", [over, morning, noon],
                    says: [Said.sent("朝の番組"), Said.expired("終わった番組"), Said.refused("昼の番組")]
                        .joined(separator: "。")) {
                await $0.answer(Kind.create, with: .fault(831), after: 1)
            },
            Sending("one sent, then silence", [morning, noon], says: Said.sent("朝の番組") + "。" + Said.interrupted) {
                await $0.goQuiet(for: 1, after: 1)
            },
            Sending("silence at the first", [morning], says: nil) { await $0.goQuiet(for: 1) },
        ]

        for sending in sendings {
            for left in try await store.pendingReservations() { try await store.removePending(left.id) }
            for waiting in sending.waits { try await store.queue(waiting) }
            let recorder = NamedRecorder(1)
            await sending.told(recorder)

            let outcome = await PendingQueue.flush(client: aClient(of: recorder), store: store)
            XCTAssertEqual(outcome.summary, sending.says, sending.name)
        }
    }

    // MARK: - what the tests put in the queue

    /// A reservation of `program` as the app queues one, turned down before when `problem` is given.
    private func waiting(for program: GuideProgramRow, problem: String? = nil) throws -> PendingReservation {
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        return PendingReservation(request: request, serviceName: program.serviceName, problem: problem)
    }

    /// One of the test's own making, for where there is no guide to take a programme from: half an hour on the
    /// demo's first channel, in DR and not repeated, starting so many minutes from now.
    private func waiting(_ title: String, startingIn minutes: Double, programme: Int) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Date().addingTimeInterval(minutes * 60),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ")
    }

    /// What is written on each of the rows waiting, by the row: its reason, and nothing where it has none. Which
    /// rows there are and what each says, in one comparison and whatever order they come in.
    private func reasons(_ rows: [PendingReservation]) -> [String: String] {
        Dictionary(rows.map { ($0.id, $0.problem ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - what the tests ask for

/// What the recorder is asked, as its fake on the bench names a kind of request. Named once: a name misspelt in
/// a test that looks for nothing having been asked would pass.
private enum Kind {
    /// The reservations' list, read when asked for, by a connect, and after something waiting was made.
    static let list = "X_GetRecordScheduleList"
    static let create = "X_CreateRecordSchedule"
    /// What the name of each of the guide's files begins with.
    static let guide = "EPG_"
}

/// One sending of the queue: what waits, what the recorder is told beforehand, and what is said of it afterwards.
@MainActor
private struct Sending {
    let name: String
    let waits: [PendingReservation]
    /// What became of the queue, in words; nil when nothing is to be said.
    let says: String?
    let told: @MainActor (NamedRecorder) async -> Void

    init(_ name: String, _ waits: [PendingReservation], says: String?,
         told: @escaping @MainActor (NamedRecorder) async -> Void = { _ in }) {
        (self.name, self.waits, self.says, self.told) = (name, waits, says, told)
    }
}
