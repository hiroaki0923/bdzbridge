import Foundation
import RecorderKit
import XCTest

/// A reason written on a waiting row while its create is out -- another recorder's arrival, holding every row for
/// the one before -- stands, whatever the create is answered with.
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
