import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The phone's queue in a home with a television saved beside the recorder. Nothing is sent to a television
/// yet: what one being saved changes is the words, which then say that it was the recorder the waiting
/// reservations went to.
@MainActor
final class QueueWithATelevisionTests: XCTestCase {
    /// What runs with no screen has no model to ask whether a television is saved, and reads it from what the
    /// screens saved: an address, and not an empty one.
    func testWhetherATelevisionIsSavedIsReadFromWhatTheScreensSaved() throws {
        let defaults = try aBench().defaults
        XCTAssertFalse(BackgroundWork.televisionSaved(in: defaults))
        defaults.set("", forKey: DefaultsKey.tvHost)
        XCTAssertFalse(BackgroundWork.televisionSaved(in: defaults), "an address that is empty is none saved")
        defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        XCTAssertTrue(BackgroundWork.televisionSaved(in: defaults))
    }

    /// With a television saved the reader has two devices, so each sentence about the queue says which one it
    /// is about: on the strip once the screens have sent what waited, and in the Shortcuts action's answer,
    /// which is told that a television is saved. A sentence for each way a reservation went -- sent, dropped
    /// because its programme was over, turned down, passed over -- in the bench's words (`Said`).
    ///
    /// With no television saved the same sentences name no device, as they never have: `QueueGateTests` and
    /// `SendWaitingTests` hold that, and it is not held a second time here.
    func testWithATelevisionSavedWhatBecameOfTheQueueNamesTheRecorder() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        let television = DemoTV()
        let model = bench.model(recorder: recorder, television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let store = try GuideStore(path: bench.guidePath)
        let named = "レコーダー"

        // Read from the queue in the order they start: the one that is over, then the morning's, then noon's.
        // The morning's is taken and noon's turned down: 831, a channel the recorder cannot receive.
        for waiting in [waiting("終わった番組", startingIn: -120, programme: 4320),
                        waiting("朝の番組", startingIn: 120, programme: 4321),
                        waiting("昼の番組", startingIn: 121, programme: 4322)] {
            try await store.queue(waiting)
        }
        await recorder.answer(Self.create, with: .fault(831), after: 1)
        await model.refreshReservations()
        XCTAssertEqual(model.flushReport,
                       [Said.sent("朝の番組", naming: named), Said.expired("終わった番組", naming: named),
                        Said.refused("昼の番組", naming: named)].joined(separator: "。"))

        // With no screen, and the recorder too busy for the evening's. Noon's was turned down before: it is
        // neither sent again nor said again.
        try await store.queue(waiting("夜の番組", startingIn: 122, programme: 4323))
        await recorder.beBusy(with: Self.create)
        let sending = await BackgroundWork.sendWaiting(client: aClient(of: recorder), store: store, mac: nil)
        XCTAssertEqual(SendWaitingIntent.saying(sending, televisionSaved: true),
                       Said.deferred("夜の番組", naming: named))
    }

    /// What the recorder's fake on the bench calls the request that makes a reservation.
    private static let create = "X_CreateRecordSchedule"

    /// A reservation of the test's own making: half an hour on the demo's first channel, in DR and not
    /// repeated, starting so many minutes from now.
    private func waiting(_ title: String, startingIn minutes: Double, programme: Int) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Date().addingTimeInterval(minutes * 60),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ")
    }
}
