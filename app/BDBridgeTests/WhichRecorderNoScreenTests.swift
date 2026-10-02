import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The paths with no screen -- the Shortcuts action, the overnight run -- and a recorder the cache is not of.
extension WhichRecorderTests {
    /// With no screen the recorder the phone knows is sent the queue as before: when the cache has no owner
    /// written yet -- the app not opened since this was kept -- and when it has.
    ///
    /// No MAC is handed to these, here or below. The paths with no screen send their packet themselves, not
    /// through the model, and a MAC would put one on the network this is run on.
    func testWithNoScreenTheRecorderThePhoneKnowsIsSentTheQueue() async throws {
        for ownerWritten in [false, true] {
            let bench = try aBench()
            let recorder = NamedRecorder(1)
            let model: AppModel
            if ownerWritten {
                model = try await connected(bench, at: [Bench.host: recorder])
            } else {
                // A cache nobody has answered for since the owner was kept: the app's own connect met silence.
                try await bench.cacheAGuide()
                model = bench.model(recorders: [:])
                await model.start()
                try await untilGivenUp(model)
            }
            let cache = try store(bench)
            let owner = try await cache.owner()
            XCTAssertEqual(owner, ownerWritten ? NamedRecorder.udn(1) : nil)
            try await queueAReservation(bench, model)

            let sending = await BackgroundWork.sendWaiting(client: client(recorder), store: cache, mac: nil)

            guard case .sent(let outcome) = sending else {
                XCTFail("not sent, with the owner \(ownerWritten ? "written" : "not written"): \(sending)")
                continue
            }
            XCTAssertEqual(outcome.sent.count, 1)
            expectTrue(try await cache.pendingReservations().isEmpty)
        }
    }

    /// The Shortcuts action knocks at the saved address with no screen to say who answered. A recorder the
    /// cache is not of is left alone: the queue was made for the other one.
    func testWithNoScreenARecorderTheCacheIsNotOfIsSentNothing() async throws {
        let bench = try aBench()
        let model = try await connected(bench, at: [Bench.host: NamedRecorder(1)])
        let cache = try store(bench)
        try await queueAReservation(bench, model)
        let stranger = NamedRecorder(2)

        let sending = await BackgroundWork.sendWaiting(client: client(stranger), store: cache, mac: nil)

        XCTAssertEqual(sending, .anotherRecorder)
        XCTAssertEqual(SendWaitingIntent.saying(sending), Notify.anotherRecorderAnswered)
        expectEqual(await stranger.asked("X_CreateRecordSchedule"), 0)
        let left = try await cache.pendingReservations()
        XCTAssertEqual(left.map(\.problem), [nil], "left as it was, for the recorder it was made for")
        try await expect(bench, keeps: .all(of: 1), "nothing is taken up without a screen")
    }

    /// What an overnight run told the reader and kept for the screens, in the order it did.
    private actor Told {
        private(set) var said: [String] = []
        func say(_ what: String) { said.append(what) }
    }

    private func telling(_ told: Told) -> BackgroundWork.Telling {
        BackgroundWork.Telling(heldBack: { await told.say("held back") },
                               flushed: { await told.say("sent \($0.sent.count)") },
                               freeSpace: { _, _ in await told.say("free space") },
                               fetched: { _ in Task { await told.say("fetched") } })
    }

    /// The overnight run, with the recorder the cache is of: what waits is sent, the reader is told, the free
    /// space is looked at and the guide asked for, as before any of this.
    func testTheOvernightRunDoesItsWorkWithTheRecorderThePhoneKnows() async throws {
        let (bench, recorder, model) = try await atHome(waiting: true)
        let before = await recorder.asked
        let told = Told()

        _ = await BackgroundWork.refresh(client: client(recorder), store: try store(bench), mac: nil,
                                         telling: telling(told))

        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 1)
        expectTrue(await recorder.asked("EPG_TRDEPG_FILE.dat", since: before) >= 1, "the guide was not asked for")
        expectEqual(Array(await told.said.prefix(2)), ["sent 1", "free space"])
    }

    /// The overnight run, answered by a recorder the cache is not of: nothing is sent to it, nothing is read
    /// from it into a cache that is the other's, and the reader is told -- when something was waiting to go,
    /// which is what they would otherwise miss, and not on every night after that.
    func testTheOvernightRunLeavesARecorderTheCacheIsNotOfAlone() async throws {
        for somethingWaits in [true, false] {
            let bench = try aBench()
            let model = try await connected(bench, at: [Bench.host: NamedRecorder(1)])
            let cache = try store(bench)
            if somethingWaits { try await queueAReservation(bench, model) }
            let stranger = NamedRecorder(2)
            let told = Told()

            let refreshed = await BackgroundWork.refresh(client: client(stranger), store: cache, mac: nil,
                                                         telling: telling(told))

            XCTAssertFalse(refreshed)
            expectEqual(await stranger.asked("X_CreateRecordSchedule"), 0)
            expectEqual(await stranger.asked("EPG_TRDEPG_FILE.dat"), 0,
                        "the stranger's guide would be stored in the other's cache")
            expectEqual(await stranger.asked("X_HDLnkGetRecordDestinationInfo"), 0)
            expectEqual(await told.said, somethingWaits ? ["held back"] : [])
            expectEqual(try await cache.pendingReservations().map(\.problem), somethingWaits ? [nil] : [])
            try await expect(bench, keeps: .all(of: 1))
        }
    }
}
