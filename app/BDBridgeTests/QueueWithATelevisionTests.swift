import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The phone's queue in a home with a television saved beside the recorder. Each sentence about the queue then
/// says which device it is about. What waits for the television is sent when the app connects to it and when
/// its list is pulled down, as the television's work and none of the recorder's, and the strip says what
/// became of it beside what the recorder's sending said. That line of the strip is held here for the home
/// with no television as well, where it is the recorder's report as it stands. How a sending to a
/// television goes, step by step, and what each way it can stop leaves and says, is RecorderKit's to hold
/// (`TVDriverTests`).
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

    // MARK: - what waits for the television

    /// A reservation waiting for the television as the app is opened is sent by the connect to the
    /// television, and is the television's work alone: in a home whose recorder never answers it goes just
    /// the same, since it needs the phone's cache opened and nothing of the recorder's (`sentAtLaunch`). A
    /// recorder that answers is never asked to make it.
    ///
    /// What a sending came to goes with the host that kept it, and a host the app has let go of sends
    /// nothing. Registered again over the one saved, the television is on a host of its own, and the strip
    /// has nothing left of what the last one's sending came to. The host before, told to send what waits
    /// with its link still standing -- as it does while something asked earlier is carried through -- and
    /// with a registration the television still takes, asks the television nothing: the reservation waits.
    /// (Taken away, a television leaves no registration to send anything with, whatever its host did.)
    func testALaunchSendsWhatWaitsForTheTelevisionAsItsOwnWork() async throws {
        let recorder = NamedRecorder(1)
        let home = try await sentAtLaunch(with: recorder, "a recorder that answers")
        expectEqual(await recorder.asked(Self.create), 0, "the television's reservation went to the recorder")
        _ = try await sentAtLaunch(with: SilentRecorder(), "a recorder that never answers")

        let (model, television) = (home.model, home.television)
        let first = try XCTUnwrap(model.tvHost), firstLink = try XCTUnwrap(model.tv)
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .registered)
        XCTAssertFalse(model.tvHost === first, "the host of the last registration was kept")
        XCTAssertNil(model.queueReport, "the strip still says what the last host's sending came to")
        let left = forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402))
        try await home.store.queue(left)
        let calls = await television.calls

        await first.sendWhatWaits()

        expectEqual(await television.calls, calls, "a host the app let go of sent what waits")
        XCTAssertTrue(firstLink.session.connected, "the first link is not one the television would still answer")
        expectEqual(try await home.store.pendingReservations().map(\.id), [left.id])
    }

    /// Opens the app in a home with `recorder` and a television, a reservation waiting for the television,
    /// and looks at the app twice: with the television held at the request that makes the reservation, and
    /// once it has answered. `name` says which home, where something fails.
    ///
    /// While the request is out the strip reads the television's line for it, the television's buttons are
    /// held back, and the recorder is neither busy nor kept from being changed. Afterwards the reservation
    /// is on the television once and gone from the queue, on the phone and on screen; the television's list
    /// on screen has it, being read after the sending; and the strip says so, naming the television, with
    /// nothing in the recorder's half of that line.
    private func sentAtLaunch(with recorder: any HTTPTransport, _ name: String) async throws -> Home {
        let title = "サンプル劇場"
        let row = forTheTelevision(waiting(title, startingIn: 120, programme: 4401))
        let home = try await launch(with: recorder, waiting: [row], holding: Self.tvCreate)
        let (model, television, door) = (home.model, home.television, home.door)
        try await until("the television was never asked to make the reservation, with \(name)") {
            await door.isHolding
        }
        // Not `untilConnected`, which waits for no line at all: the television's is up for as long as it is held.
        try await until("the recorder's side never came to rest, with \(name)") {
            !isConnecting(model) && !model.isBusy && (model.connected || model.gaveUp)
        }

        XCTAssertEqual(model.busy, TVDriver.sendingLine, name)
        XCTAssertTrue(model.isBusy(for: .tv), "the television's sending holds no button of its own back, \(name)")
        XCTAssertFalse(model.isBusy(for: .recorder), "it holds a button of the recorder's back, \(name)")
        XCTAssertTrue(model.canChangeRecorder, "it held the recorder's choice back, \(name)")
        // As the reservations tab reads the queue when it appears.
        await model.loadPending()
        XCTAssertEqual(model.pending.map(\.request.title), [title], name)

        await door.letGo()
        try await untilTheTelevisionIsConnected(model, "the connect to the television never ended, with \(name)")

        expectEqual(await television.schedules.map(\.eventId), [4401], name)
        expectEqual(try await home.store.pendingReservations(), [], name)
        XCTAssertTrue(model.pending.isEmpty, "what was sent is still shown as waiting, \(name)")
        XCTAssertEqual(model.tvHost?.reservations.map(\.eventID), [4401],
                       "the television's list on screen was read before the reservation was made, \(name)")
        XCTAssertEqual(model.queueReport, Said.sent(title, naming: "テレビ"), name)
        XCTAssertNil(model.flushReport, "what the television was sent is said as the recorder's, \(name)")
        XCTAssertNil(model.problem(for: .tv), name)
        XCTAssertNil(model.busy, "a line was left up, \(name)")
        return home
    }

    /// With a reservation waiting for each device as the app is opened, each is made once, on its own device
    /// and not on the other, and the strip says both in one line: what became of the recorder's and then
    /// what became of the television's, each naming its device, joined with a full stop.
    ///
    /// Neither device's sending writes over what the other's said. The recorder's next one changes its own
    /// half alone. A sending to the television that has nothing to say changes neither: here its disk is
    /// away, so nothing is made, nothing is put on the television's line, and the reservation waits as it
    /// was, to go by itself once the disk is back. Closing the line takes both halves; and with both said
    /// again, so does leaving the app.
    func testTheStripSaysWhatBecameOfEachDevicesAndOneCloseTakesBoth() async throws {
        let recorder = NamedRecorder(1)
        let home = try await launch(with: recorder, waiting: [
            waiting("朝の番組", startingIn: 120, programme: 4321),
            forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)),
        ])
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        let (recorders, televisions) = ("レコーダー", "テレビ")
        let onTheTelevision = Said.sent("サンプル劇場", naming: televisions)

        expectEqual(await recorder.asked(Self.create), 1, "the recorder was sent the television's too, or nothing")
        expectEqual(await television.schedules.map(\.eventId), [4401], "the television holds the recorder's too")
        XCTAssertEqual(model.queueReport, Said.sent("朝の番組", naming: recorders) + "。" + onTheTelevision)

        try await store.queue(waiting("昼の番組", startingIn: 121, programme: 4322))
        await model.refreshReservations()
        let both = Said.sent("昼の番組", naming: recorders) + "。" + onTheTelevision
        XCTAssertEqual(model.queueReport, both, "the recorder's sending took what the television's said")

        await television.unmount()
        try await store.queue(forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402)))
        await host.refreshReservations()
        XCTAssertEqual(model.queueReport, both, "a sending with nothing to say changed the strip")
        XCTAssertNil(model.problem(for: .tv), "a disk that is away went on the television's line")
        expectEqual(try await store.pendingReservations().map(\.problem), [nil], "a reason was written, or it went")

        model.closeQueueReport()
        XCTAssertNil(model.flushReport, "closing the line left the recorder's half")
        XCTAssertNil(host.report, "closing the line left the television's half")
        XCTAssertNil(model.queueReport)

        await television.unmount(false)
        try await store.queue(waiting("夜の番組", startingIn: 122, programme: 4323))
        await host.refreshReservations()
        await model.refreshReservations()
        XCTAssertEqual(model.queueReport,
                       Said.sent("夜の番組", naming: recorders) + "。" + Said.sent("サンプル紀行", naming: televisions))

        model.wentToBackground()
        XCTAssertNil(model.flushReport, "the recorder's half outlived the visit it was for")
        XCTAssertNil(host.report, "the television's half outlived the visit it was for")
        XCTAssertNil(model.queueReport)
    }

    /// The strip reads both devices' reports as one line, and in a home with no television saved that line
    /// is the recorder's report and nothing else: what its sending said, letter for letter, in the sentence
    /// such a home has always read, which names no device. Closing the line takes it. The gates of the
    /// recorder's queue read what the sending wrote down (`QueueGateTests`); this reads what the strip does.
    func testWithNoTelevisionSavedTheStripReadsTheRecordersReportAndNothingElse() async throws {
        let (bench, _, model) = try await connectedHome()
        XCTAssertNil(model.tvHost, "a television is saved in this home")
        try await GuideStore(path: bench.guidePath).queue(waiting("朝の番組", startingIn: 120, programme: 4321))

        await model.refreshReservations()

        XCTAssertEqual(model.queueReport, Said.sent("朝の番組"))
        XCTAssertEqual(model.queueReport, model.flushReport, "the strip reads more, or less, than the recorder said")
        model.closeQueueReport()
        XCTAssertNil(model.flushReport, "closing the line left what the recorder's sending said")
        XCTAssertNil(model.queueReport)
    }

    /// With nothing but a television's reservation waiting, the recorder's sending has nothing to send, so
    /// it puts up no line and does not take its turn behind the television's -- sendings go one at a time,
    /// whichever device they are for. While the television is held at the request that makes its
    /// reservation, pulling the recorder's list down comes back: the recorder is asked for its list and
    /// nothing else, the line on the strip is still the television's, and nothing is said of the recorder's
    /// queue. The television's own pull-down, let go, has made the reservation and then read the list.
    func testWithOnlyTheTelevisionsWaitingTheRecordersPullDownDoesNotWaitForItsSending() async throws {
        let recorder = NamedRecorder(1)
        let home = try await launch(with: recorder)
        let (model, door) = (home.model, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        try await home.store.queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        await door.hold(only: Self.tvCreate)
        let television = Task { await host.refreshReservations() }
        try await until("the television was never asked to make the reservation") { await door.isHolding }
        let heard = await recorder.heard.count

        try await within(5, "the recorder's pull-down waited for the television's sending") {
            await model.refreshReservations()
        }

        expectTrue(await door.isHolding, "the television's sending was over before the recorder's list came back")
        expectEqual(await recorder.heard(since: heard), [Self.list], "the recorder was asked for more than its list")
        XCTAssertEqual(model.busy, TVDriver.sendingLine, "the recorder's sending put a line of its own up")
        XCTAssertNil(model.flushReport)
        await door.letGo()
        await television.value
        XCTAssertEqual(host.reservations.map(\.eventID), [4401], "the list was read before the reservation was made")
        XCTAssertEqual(model.queueReport, Said.sent("サンプル劇場", naming: "テレビ"))
    }

    // MARK: - what the tests set up

    /// A home with a recorder and a television the app is registered with, and what a test reaches of it
    /// beside the model: the phone's queue, through a connection of its own, and what stands between the app
    /// and the television, for a test that holds one of its answers.
    private struct Home {
        let model: AppModel
        let store: GuideStore
        let television: DemoTV
        let door: HeldTelevision
    }

    /// Opens the app in such a home and waits for nothing. `rows` are in the phone's queue from before, so
    /// that the first connect to each device finds them. The guide is cached, so a connect has none to
    /// fetch. The television receives the station the waiting reservations are on, and holds every request
    /// for `method` when one is named.
    private func launch(with recorder: any HTTPTransport, waiting rows: [PendingReservation] = [],
                        holding method: String? = nil) async throws -> Home {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let store = try GuideStore(path: bench.guidePath)
        for row in rows { try await store.queue(row) }
        let television = DemoTV()
        await television.receives([DemoTV.Station()])
        let door = HeldTelevision(television, holding: false)
        // Whatever a test held is let go as it ends, however it ends. Sendings go one at a time in the whole
        // process: one left held by a test that failed would keep every later test's from its turn.
        addTeardownBlock { await door.letGo() }
        if let method { await door.hold(only: method) }
        let model = bench.model(recorder: recorder, television: door,
                                credentials: await registered(with: television))
        await model.start()
        return Home(model: model, store: store, television: television, door: door)
    }

    /// What the recorder's fake on the bench calls the request that makes a reservation.
    private static let create = "X_CreateRecordSchedule"
    /// What it calls the one that reads its list, and what the television's calls the one that makes a
    /// reservation.
    private static let list = "X_GetRecordScheduleList"
    private static let tvCreate = "addSchedule"

    /// A reservation of the test's own making: half an hour on the demo's first channel, in DR and not
    /// repeated, starting so many minutes from now.
    private func waiting(_ title: String, startingIn minutes: Double, programme: Int) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Date().addingTimeInterval(minutes * 60),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ")
    }

    /// The same reservation waiting for the television: the channel is the station the invented television
    /// is told it receives (`launch`), under the same name.
    private func forTheTelevision(_ row: PendingReservation) -> PendingReservation {
        var row = row
        row.target = .tv
        return row
    }
}
