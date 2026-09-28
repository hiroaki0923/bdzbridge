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
        let bench = try Bench()
        defer { bench.throwAway() }
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
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let waiting = try await queueOne(on: bench)
        let store = try GuideStore(path: bench.guidePath)

        let sending = await BackgroundWork.sendWaiting(
            client: RecorderClient(host: Bench.host, transport: RecorderAtHome()), store: store, mac: nil)

        guard case .sent(let outcome) = sending else {
            return XCTFail("nothing was sent: \(sending)")
        }
        XCTAssertEqual(outcome.sent.map(\.id), [waiting.id])
        let left = try await store.pendingReservations()
        XCTAssertTrue(left.isEmpty, "what was sent stayed in the queue")
        XCTAssertTrue(SendWaitingIntent.saying(sending).contains("を登録しました"))
    }

    /// Still away, or the recorder not coming up: nothing is lost, and the next chance sends it.
    func testARecorderThatDoesNotAnswerLeavesTheQueueAsItWas() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let waiting = try await queueOne(on: bench)
        let store = try GuideStore(path: bench.guidePath)
        let recorder = RecorderAtHome()
        await recorder.setReachable(false)

        let sending = await BackgroundWork.sendWaiting(
            client: RecorderClient(host: Bench.host, transport: recorder), store: store, mac: nil)

        XCTAssertEqual(sending, .unreachable)
        let left = try await store.pendingReservations()
        XCTAssertEqual(left.map(\.id), [waiting.id])
    }

    /// A reservation queued the way the app queues one away from home.
    private func queueOne(on bench: Bench) async throws -> PendingReservation {
        let model = bench.model(recorder: SilentRecorder())
        await model.start()
        try await until("the first connect never gave up") { model.gaveUp && !model.connecting }
        let later = Date().addingTimeInterval(3600)
        let found = await model.search("サンプル").hits.first { $0.program.start > later }
        let program = try XCTUnwrap(found?.program, "the cached guide had nothing an hour or more ahead")
        let kept = await model.reserve(program, quality: "DR", repeating: "none")
        XCTAssertTrue(kept, "the reservation was not kept: \(model.problem ?? "no reason given")")
        return try XCTUnwrap(model.queued)
    }
}
