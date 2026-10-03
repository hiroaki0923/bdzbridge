import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The Shortcuts action that sends the queue, as an automation runs it when the phone joins the home Wi-Fi:
/// with nothing on screen, at every arrival home, and mostly with nothing to send.
@MainActor
final class SendWaitingTests: XCTestCase {
    /// Most arrivals home have nothing waiting, and each would otherwise wake the recorder -- half a minute of
    /// a box starting up in the living room -- to be told nothing.
    func testNothingWaitingLeavesTheRecorderAlone() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = RecorderAtHome()

        let sending = await BackgroundWork.sendWaiting(
            client: RecorderClient(host: Bench.host, transport: recorder),
            store: try GuideStore(path: bench.guidePath), mac: nil)

        XCTAssertEqual(sending, .nothingWaiting)
        let asked = await recorder.asked
        XCTAssertEqual(asked, 0, "the recorder was asked with nothing to send it")
        XCTAssertEqual(SendWaitingIntent.saying(sending), "送信待ちの予約はありません。")
    }

    /// A reservation queued away from home goes to the recorder once it answers, and leaves the queue.
    func testWhatIsWaitingGoesToARecorderThatAnswers() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let waiting = try await queueOne(on: bench)
        let store = try GuideStore(path: bench.guidePath)

        let sending = await BackgroundWork.sendWaiting(
            client: RecorderClient(host: Bench.host, transport: RecorderAtHome()), store: store, mac: nil)

        guard case .sent(let outcome) = sending else {
            return XCTFail("nothing was sent: \(sending)")
        }
        XCTAssertEqual(outcome.sent.map(\.id), [waiting.id])
        expectTrue(try await store.pendingReservations().isEmpty, "what was sent stayed in the queue")
        XCTAssertTrue(SendWaitingIntent.saying(sending).contains("を登録しました"))
    }

    /// Still away, or the recorder not coming up: nothing is lost, and the next chance sends it.
    func testARecorderThatDoesNotAnswerLeavesTheQueueAsItWas() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let waiting = try await queueOne(on: bench)
        let store = try GuideStore(path: bench.guidePath)
        let recorder = RecorderAtHome()
        await recorder.setReachable(false)

        let sending = await BackgroundWork.sendWaiting(
            client: RecorderClient(host: Bench.host, transport: recorder), store: store, mac: nil)

        XCTAssertEqual(sending, .unreachable)
        expectEqual(try await store.pendingReservations().map(\.id), [waiting.id])
    }

    /// The app open as the phone joins the home Wi-Fi: the screens' connect sends the queue, and the automation
    /// runs the action at the same moment, with a client of its own and a connection of its own to the cache.
    /// One waits for the other and reads the queue after it (`PendingQueue.flush`), so the recorder is asked
    /// for the reservation once. Asked by each, it would hold the reservation twice.
    func testTheScreensAndTheActionAtOnceSendAReservationOnce() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        // Queued once the model is connected: its first connect would have sent it by itself.
        let store = try GuideStore(path: bench.guidePath)
        let program = try await aProgramme(model)
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        try await store.queue(PendingReservation(request: request, serviceName: program.serviceName))
        // The recorder takes its time over a reservation, so that whichever sends first is still at it when
        // the other comes to the queue.
        await recorder.hold(only: "X_CreateRecordSchedule")
        let before = await recorder.asked

        async let screens: Void = model.connect()
        async let action = BackgroundWork.sendWaiting(
            client: RecorderClient(host: Bench.host, transport: recorder), store: store, mac: nil)
        // Both have got as far as the recorder, and one of them as far as the reservation.
        try await until("the two did not both reach the recorder") {
            await recorder.asked("description.xml", since: before) >= 2
        }
        try await until("neither sent the reservation") { await recorder.asked("X_CreateRecordSchedule") > 0 }
        // Long enough for the other to have sent it too, were it not waiting its turn.
        try await Task.sleep(for: .milliseconds(300))
        await recorder.letGo()
        _ = await (screens, action)

        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 1, "the reservation was sent by each")
        expectTrue(try await store.pendingReservations().isEmpty, "what was sent stayed in the queue")
    }

    /// A reservation queued the way the app queues one away from home.
    private func queueOne(on bench: Bench) async throws -> PendingReservation {
        let model = bench.model(recorder: SilentRecorder())
        await model.start()
        try await untilGivenUp(model)
        let program = try await aProgramme(model)
        let kept = await model.reserve(program, quality: "DR", repeating: "none")
        XCTAssertTrue(kept, "the reservation was not kept: \(model.problem ?? "no reason given")")
        return try XCTUnwrap(model.queued)
    }
}
