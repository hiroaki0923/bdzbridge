import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The phone's queue in a home with a television saved beside the recorder. Each sentence about the queue then
/// says which device it is about. What waits for the television is sent when the app connects to it and when
/// its list is pulled down, as the television's work and none of the recorder's, and the strip says what
/// became of it beside what the recorder's sending said. That line of the strip is held here for the home
/// with no television as well, where it is the recorder's report as it stands. A programme reserved on the
/// television and a waiting row sent again are held here for the app's side of them: which device is
/// asked, what the television's host keeps of what came back, and what the strip says and does not say.
/// How a reservation or a sending to a television goes, step by step, and what each way it can stop leaves
/// and says, is RecorderKit's to hold (`TVDriverTests`).
///
/// What the reservations tab needs of the model once a row can wait for the television is held here as
/// well: what a row sent again from it came to, the device each waiting row says, what is said under
/// them, and that a television's row is not deleted while the television works. And so is what the
/// settings need: a television is taken away together with what waits for it, and only while that is what
/// its question counted.
///
/// So is what a programme's sheet asks of the model: where a reservation can go, by the devices saved and
/// by what each holds or has waiting; the one entry that reserves on the device named and on no other, the
/// recorder's being the reservation it has always been; and what a yes and a no each do, at the question
/// before a reservation that would stop another from recording.
///
/// Which of its lines the strip shows is held here last, a state at a time: in the home with a recorder
/// alone, where the order is the one it has always had, and with a television saved, whose disk has a line
/// there, and a sentence on the reservations tab, while a reservation waits for it to come back.
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

    // MARK: - a reservation made now, and a row sent again

    /// A programme reserved on the television through its host is the television's work, and what it came
    /// to is what the host hands back. While the request that makes it is out the strip reads the
    /// television's line for a reservation, the television's buttons are held back and the recorder's are
    /// not, and the reservation waits on the phone already: for the television, in DR, with no reason.
    /// Made, it is on the television once and in the host's list, which is the list read back after it;
    /// nothing waits any more, on the phone or on screen; and the strip says nothing of it, since there it
    /// would read as a reservation that had been waiting. The recorder is asked nothing, and what its line
    /// said and what it has waiting are as they were.
    ///
    /// With the television given up on, a reservation is kept and the answer says so, carrying the row as
    /// it waits. The queue on screen has that row, read again though nothing was sent, and the television
    /// is neither asked nor connected to.
    func testAReservationOnTheTelevisionIsItsOwnWorkAndItsHostKeepsWhatCameBack() async throws {
        let recorder = NamedRecorder(1)
        let home = try await launch(with: recorder)
        let (model, television, door) = (home.model, home.television, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost), link = try XCTUnwrap(model.tv)
        let programmes = try await programmesNotReserved(model, 2)
        let (wanted, another) = (programmes[0], programmes[1])
        await television.receives(programmes.map(station(of:)))
        leaveALine(on: model)
        await door.hold(only: Self.tvCreate)
        let heard = await recorder.heard.count

        let asking = Task { await host.reserve(wanted, repeating: "none") }
        try await until("the television was never asked to make the reservation") { await door.isHolding }

        XCTAssertEqual(model.busy, TVDriver.reservingLine)
        XCTAssertTrue(model.isBusy(for: .tv), "a reservation being made holds no button of the television's back")
        XCTAssertFalse(model.isBusy(for: .recorder), "it holds a button of the recorder's back")
        XCTAssertTrue(model.canChangeRecorder, "it held the recorder's choice back")
        // As the reservations tab reads the queue when it appears.
        await model.loadPending()
        XCTAssertEqual(waits(model.pending), ["\(wanted.eventID) for tv in 100, no reason"])

        await door.letGo()
        expectEqual(await asking.value, .made(saying: nil))

        expectEqual(await television.schedules.map(\.eventId), [wanted.eventID])
        XCTAssertEqual(host.reservations.map(\.eventID), [wanted.eventID], "the list read after it was not kept")
        expectEqual(try await home.store.pendingReservations(), [])
        XCTAssertTrue(model.pending.isEmpty, "what was made is still shown as waiting")
        XCTAssertNil(model.queueReport, "a reservation made now is said on the strip as one that had waited")
        expectEqual(await recorder.heard(since: heard), [], "the television's reservation asked the recorder")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        XCTAssertNil(model.pending(for: wanted, on: .recorder),
                     "the television's reservation is said to wait for the recorder")
        XCTAssertNil(model.busy, "a line was left up")

        await television.goSilent()
        _ = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(link.session.gaveUp)
        let calls = await television.calls, tries = link.session.link.tries

        let kept = await host.reserve(another, repeating: "none")

        let onThePhone = try await home.store.pendingReservations()
        let row = try XCTUnwrap(onThePhone.first, "the reservation was not kept")
        XCTAssertEqual(kept, .waiting(row, saying: TVDriver.waitsNotConnected))
        XCTAssertEqual(waits(model.pending), ["\(another.eventID) for tv in 100, no reason"],
                       "the queue on screen was not read again")
        expectEqual(await television.calls, calls, "a television given up on was asked")
        XCTAssertEqual(link.session.link.tries, tries, "a television given up on was connected to")
        XCTAssertEqual(host.reservations.map(\.eventID), [wanted.eventID], "the list it gave went with the answer")
    }

    /// 「もう一度送る」 goes to the device the row waits for. On a row waiting for the television it is the
    /// television's work alone: the recorder is asked nothing -- it is not made sure of, and no sending of
    /// its own is begun -- and its line stays as it was left. The row is made on the television and gone
    /// from the queue, on the phone and on screen; the host's list has it, being the list read back after
    /// it; and the strip says so, naming the television. On a row waiting for the recorder it is what it
    /// was: the recorder is sent the reservation, and the television is asked nothing.
    ///
    /// With the television given up on and still silent, sending its row again takes the reason off, so
    /// that the row goes by itself the next time the television answers, and tries one connect. No round
    /// ran. The queue on screen is read again all the same, and the row there has no reason either. A row
    /// held for what it would stop from recording keeps that reason through the same: it is what the
    /// reader consents to, and nothing of the recorder's sending again, which takes any reason off, is for
    /// a television's row. A sending again with nothing to say leaves the strip as it read.
    func testSendingARowAgainGoesToTheDeviceItWaitsFor() async throws {
        let recorder = NamedRecorder(1)
        let (title, reason) = ("サンプル劇場", "前に断られた理由")
        let first = turnedDown(forTheTelevision(waiting(title, startingIn: 120, programme: 4401)), for: reason)
        let home = try await launch(with: recorder, waiting: [first])
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost), link = try XCTUnwrap(model.tv)
        // As the reservations tab reads the queue when it appears.
        await model.loadPending()
        XCTAssertEqual(waits(model.pending), ["4401 for tv in 100, \(reason)"])
        leaveALine(on: model)
        let heard = await recorder.heard.count

        await model.resend(try XCTUnwrap(model.pending.first))

        expectEqual(await recorder.heard(since: heard), [], "a television's row went by way of the recorder")
        expectEqual(await television.schedules.map(\.eventId), [4401], "the row was not made on the television")
        expectEqual(try await store.pendingReservations(), [])
        XCTAssertTrue(model.pending.isEmpty, "what was sent is still shown as waiting")
        XCTAssertEqual(host.reservations.map(\.eventID), [4401], "the list read after it was not kept")
        XCTAssertEqual(model.queueReport, Said.sent(title, naming: "テレビ"))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)

        let theirs = turnedDown(waiting("朝の番組", startingIn: 120, programme: 4321), for: reason)
        try await store.queue(theirs)
        let asked = await recorder.asked, calls = await television.calls

        await model.resend(theirs)

        expectEqual(await recorder.asked(Self.create, since: asked), 1, "the recorder's row did not go to it once")
        expectEqual(await television.calls, calls, "the recorder's row asked the television")

        await television.goSilent()
        _ = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(link.session.gaveUp)
        let freed = turnedDown(forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402)), for: reason)
        let held = turnedDown(forTheTelevision(waiting("サンプル天気", startingIn: 181, programme: 4403)),
                              for: Self.wouldStop)
        for row in [freed, held] { try await store.queue(row) }
        await model.loadPending()
        XCTAssertEqual(waits(model.pending), ["4402 for tv in 100, \(reason)", "4403 for tv in 100, \(Self.wouldStop)"])
        let tries = link.session.link.tries, said = model.queueReport

        await model.resend(freed)
        await model.resend(held)

        let left = ["4402 for tv in 100, no reason", "4403 for tv in 100, \(Self.wouldStop)"]
        expectEqual(waits(try await store.pendingReservations()), left, "a reason stayed that goes, or went that stays")
        XCTAssertEqual(waits(model.pending), left, "the rows on screen are not as the phone has them")
        XCTAssertEqual(link.session.link.tries, tries + 2, "the television was not tried once for each")
        XCTAssertEqual(model.queueReport, said, "a sending again with nothing to say changed the strip")
    }

    // MARK: - where a reservation can go, and the one entry that makes it

    /// A programme's sheet asks one entry for a reservation, whichever device it is for. In a home with a
    /// recorder alone that is the recorder's reservation as it has always been, and what it came to is read
    /// into the value both devices answer with. Taken: made, sent once and read back, and the recorder is
    /// no longer where a new reservation of the programme can go. Not sent, its mode being one nobody
    /// knows: not done, saying that it cannot be sent to the recorder. Turned
    /// down -- 831, a channel the recorder cannot receive: not done, in the recorder's words, and not kept.
    /// With the recorder known to be away: kept, with the row as the phone has it and the sentence the
    /// sheet has always said of one, the recorder asked nothing, and nothing left set for a screen to say
    /// a second time.
    func testOneEntryReservesOnTheRecorderAsEverAndAnswersInTheValueBothDevicesGive() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let programmes = try await programmesNotReserved(model, 2)
        let (taken, other) = (programmes[0], programmes[1])
        func reserve(_ program: GuideProgramRow, in quality: String = "DR") async -> Reserved {
            await model.reserve(program, on: .recorder, quality: quality, repeating: "none")
        }
        XCTAssertEqual(model.destinations(for: taken), [.recorder])
        var heard = await recorder.heard.count

        expectEqual(await reserve(taken), .made(saying: nil))
        expectEqual(await recorder.heard(since: heard), [Self.create, Self.list])
        XCTAssertEqual(model.destinations(for: taken), [], "the recorder is offered a programme it holds")

        expectEqual(await reserve(other, in: "知らない画質"), .notDone(Said.notInTheTables))
        await recorder.answer(Self.create, with: .fault(831))
        expectEqual(await reserve(other), .notDone(Said.fault(831, Self.create)))
        XCTAssertTrue(model.pending.isEmpty, "a reservation the recorder turned down was kept")

        await recorder.goQuiet(on: Self.list)
        await model.loadReservations()
        XCTAssertTrue(model.gaveUp, "the recorder was meant to be known to be away")
        heard = await recorder.heard.count
        let kept = await reserve(other)
        let onThePhone = try await GuideStore(path: bench.guidePath).pendingReservations()
        let row = try XCTUnwrap(onThePhone.first, "the reservation was not kept")
        XCTAssertEqual(kept, .waiting(row, saying: "レコーダーに届かなかったので、予約を端末に保存しました。"
                                      + "次にレコーダーにつながったときに登録します。予約タブで削除できます。"))
        XCTAssertEqual(model.pending(for: other, on: .recorder), row)
        expectEqual(await recorder.heard(since: heard), [], "a recorder known to be away was asked")
    }

    /// With a television saved the same entry reserves on the device named and on no other. A reservation
    /// on the television is the television's work alone: the recorder is asked nothing, not its check, its
    /// line stays as it was left, nothing is said to wait for it, and the strip says nothing. The same
    /// programme reserved on the recorder then asks the television nothing and is a second reservation:
    /// one on each device, each made once. A device that holds the programme is no longer where a new
    /// reservation of it can go.
    ///
    /// With both devices given up on, the programme is kept for each: two rows, each found by its device,
    /// the television's in DR whatever mode was asked for and the recorder's in that mode. There too the
    /// television's asks the recorder nothing: a recorder known to be away is not made sure of on its
    /// account, which would write over the line left there. The guide's mark goes on finding the first of
    /// the two. Nor is a device the programme waits for where a new reservation of it can go.
    func testOneProgrammeReservedOnBothDevicesIsAReservationOnEachAndOnNoOther() async throws {
        let recorder = NamedRecorder(1)
        let home = try await launch(with: recorder)
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let link = try XCTUnwrap(model.tv)
        let programmes = try await programmesNotReserved(model, 2)
        let (wanted, later) = (programmes[0], programmes[1])
        await television.receives(programmes.map(station(of:)))
        func reserve(_ program: GuideProgramRow, on device: DeviceSlot) async -> Reserved {
            await model.reserve(program, on: device, quality: "ER", repeating: "none")
        }
        XCTAssertEqual(model.destinations(for: wanted), [.recorder, .tv])
        leaveALine(on: model)
        let heard = await recorder.heard.count

        expectEqual(await reserve(wanted, on: .tv), .made(saying: nil))

        expectEqual(await recorder.heard(since: heard), [], "the television's reservation asked the recorder")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        XCTAssertNil(model.pending(for: wanted, on: .recorder),
                     "the television's reservation is said to wait for the recorder")
        XCTAssertNil(model.queueReport, "a reservation made now is said on the strip as one that had waited")
        XCTAssertEqual(model.destinations(for: wanted), [.recorder], "the television is offered what it holds")
        let asked = await recorder.asked, calls = await television.calls

        expectEqual(await reserve(wanted, on: .recorder), .made(saying: nil))

        expectEqual(await recorder.asked(Self.create, since: asked), 1, "the recorder's did not go to it once")
        expectEqual(await television.calls, calls, "the recorder's reservation asked the television")
        expectEqual(await television.schedules.map(\.eventId), [wanted.eventID])
        XCTAssertEqual(model.reservations(for: wanted).map(\.device), [.recorder, .tv])
        XCTAssertEqual(model.destinations(for: wanted), [])

        await television.goSilent()
        _ = await link.ensureUp(evenIfRecent: true)
        await recorder.goQuiet(on: Self.list)
        await model.loadReservations()
        XCTAssertTrue(link.session.gaveUp && model.gaveUp, "the two devices were meant to be given up on")
        leaveALine(on: model)
        let heardSoFar = await recorder.heard.count

        let forTheTelevision = await reserve(later, on: .tv)
        expectEqual(await recorder.heard(since: heardSoFar), [], "it asked a recorder known to be away")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "it wrote on the line of a recorder known to be away")
        XCTAssertEqual(model.destinations(for: later), [.recorder], "the television is offered what waits for it")
        let forTheRecorder = await reserve(later, on: .recorder)

        let rows = try await store.pendingReservations()
        let (its, theirs) = (try XCTUnwrap(rows.first { $0.target == .tv }),
                             try XCTUnwrap(rows.first { $0.target == .recorder }))
        XCTAssertEqual(waits([its, theirs]), ["\(later.eventID) for tv in 100, no reason",
                                              "\(later.eventID) for recorder in 260, no reason"])
        XCTAssertEqual(forTheTelevision, .waiting(its, saying: TVDriver.waitsNotConnected))
        XCTAssertEqual(forTheRecorder, .waiting(theirs, saying: Said.keptForTheRecorder))
        XCTAssertEqual([model.pending(for: later, on: .tv), model.pending(for: later, on: .recorder)], [its, theirs])
        XCTAssertEqual(model.pending(for: later), rows.first, "the guide's mark does not find the first of the two")
        XCTAssertEqual(model.destinations(for: later), [])
    }

    /// Where a reservation can go is the devices saved: the recorder alone in a home with no television,
    /// both with both, and the television alone where a television is saved and no recorder is. Asking
    /// asks the television nothing. A programme that has begun can go to either, the television as the
    /// recorder. One that is over is not offered a television, whose door would turn it away.
    ///
    /// In the demo, entered from the home with both, the invented recorder is alone: the real television
    /// is not offered, and a reservation asked for on it all the same is not done. Nothing is kept, in the
    /// demo's queue or the real one, and the real television is asked nothing.
    ///
    /// With a television and no recorder saved, and a guide cached, a reservation is made on the
    /// television, and no client is ever made for a recorder.
    func testAReservationCanGoToTheDevicesSavedAndInTheDemoToTheInventedRecorderAlone() async throws {
        let alone = try await connectedHome().model
        XCTAssertEqual(alone.destinations, [.recorder])

        let home = try await launch(with: NamedRecorder(1))
        let (model, television) = (home.model, home.television)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let calls = await television.calls
        var begun = try await programmesNotReserved(model, 1)[0]
        XCTAssertEqual(model.destinations, [.recorder, .tv])
        XCTAssertEqual(model.destinations(for: begun), [.recorder, .tv])
        begun.start = Date().addingTimeInterval(-60)
        XCTAssertEqual(model.destinations(for: begun), [.recorder, .tv], "a programme on air is offered no television")
        var over = begun
        over.end = Date().addingTimeInterval(-1)
        XCTAssertEqual(model.destinations(for: over), [.recorder], "a programme that is over is offered a television")
        expectEqual(await television.calls, calls, "asking where a reservation can go asked the television")

        await model.enterDemo()
        try await untilIdle(model)
        XCTAssertTrue(model.connected, "the demo did not start: \(model.problem ?? "no reason given")")
        let invented = try await programmesNotReserved(model, 1)[0]
        XCTAssertEqual(model.destinations, [.recorder], "the real television is offered in the demo")
        XCTAssertEqual(model.destinations(for: invented), [.recorder])
        expectEqual(await model.reserve(invented, on: .tv, quality: "DR", repeating: "none"),
                    .notDone("テレビに接続していません。テレビの電源とネットワーク接続を確認してください。"))
        await model.loadPending()
        XCTAssertTrue(model.pending.isEmpty, "a reservation for the real television was kept in the demo")
        expectEqual(try await home.store.pendingReservations(), [], "it was kept for the real television")
        expectEqual(await television.calls, calls, "the real television was asked something from the demo")

        let bench = try aBench()
        try await bench.cacheAGuide()
        let only = DemoTV()
        let noRecorder = bench.modelWithNoRecorder(television: only, credentials: await registered(with: only))
        await noRecorder.start()
        try await untilTheTelevisionIsConnected(noRecorder)
        let wanted = try await programmesNotReserved(noRecorder, 1)[0]
        await only.receives([station(of: wanted)])
        XCTAssertEqual(noRecorder.destinations, [.tv])
        expectEqual(await noRecorder.reserve(wanted, on: .tv, quality: "DR", repeating: "none"), .made(saying: nil))
        expectEqual(await only.schedules.map(\.eventId), [wanted.eventID])
        XCTAssertEqual(noRecorder.destinations(for: wanted), [], "the television is offered what it holds")
        XCTAssertEqual(bench.clientsMade, 0, "a client was made for a recorder nobody saved")
    }

    /// ［キャンセル］ at the question before a reservation that would stop another from recording makes
    /// nothing, and what becomes of the row goes by where the question came from. The television holds two
    /// recordings at a programme's time, so a reservation of it there comes back as that question, the row
    /// kept and held and nothing made. Declined as a row that was waiting before, it is left as it was,
    /// with its reason. Declined as the reservation just asked for, it is taken off the phone and off the
    /// screen -- with the television busy as well, here reading its list: no sending makes a row that
    /// carries a reason. Neither asks the television anything, which holds what it held; the strip says
    /// nothing; and the television is again where a reservation of the programme can go.
    func testANoAtTheQuestionTakesOffWhatWasJustAskedForAndLeavesARowThatWaitedBefore() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, store, door) = (home.model, home.television, home.store, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        let wanted = try await programmesNotReserved(model, 1)[0]
        await television.receives([station(of: wanted)])
        await television.put([
            DemoTV.Schedule(id: "recording.21", serviceID: 1032, station: "サンプル放送", start: wanted.start),
            DemoTV.Schedule(id: "recording.22", serviceID: 1040, station: "サンプル放送2", start: wanted.start),
        ])
        let holding = await television.schedules

        let asked = await model.reserve(wanted, on: .tv, quality: "DR", repeating: "none")

        let onThePhone = try await store.pendingReservations()
        let held = try XCTUnwrap(onThePhone.first, "the reservation was not kept")
        XCTAssertEqual(asked, .wouldStop(held))
        XCTAssertEqual(model.destinations(for: wanted), [.recorder], "the television is offered what waits for it")
        let calls = await television.calls

        await model.decline(held, askedForJustNow: false)
        expectEqual(try await store.pendingReservations(), [held], "a row that waited before went with a no")
        XCTAssertEqual(model.pending, [held])

        await door.hold(only: "getScheduleList")
        let reading = Task { await host.loadReservations() }
        try await until("the read of the television's list was never out") { await door.isHolding }
        await model.decline(held, askedForJustNow: true)
        expectEqual(await television.calls, calls, "a no asked the television something")
        await door.letGo()
        await reading.value

        expectEqual(try await store.pendingReservations(), [], "a reservation the reader said no to still waits")
        XCTAssertTrue(model.pending.isEmpty, "it is still shown as waiting")
        expectEqual(await television.schedules, holding, "something was made, or marked, after a no")
        XCTAssertNil(model.queueReport, "a reservation the reader said no to is said on the strip")
        XCTAssertEqual(model.destinations(for: wanted), [.recorder, .tv])
    }

    /// ［それでも予約］ at that question is the held row sent again: the reader's consent to what the
    /// question named, and to nothing else. The television holds two recordings at a programme's time, so
    /// a reservation of it there makes nothing and comes back as the question, which is put as the row's
    /// reason without the sentence about a button the question does not have, and names the recording
    /// made first.
    ///
    /// By the time of the yes the television holds another pair, and would stop another recording: the
    /// yes makes nothing, and what comes back is the question again, about the recording named now, on
    /// the row as it waits. A yes to that makes the reservation: it is on the television and in its
    /// host's list, the recording consented to is the one marked, and nothing waits, on the phone or on
    /// screen. The recorder is asked nothing at any of it. And the strip says nothing throughout: the
    /// reservation was asked for a moment ago, and never waited.
    ///
    /// A row that was waiting before says what any row sent again says on the strip: that it was
    /// registered on the television.
    func testAYesAtTheQuestionIsTheConsentToWhatItNamesAndIsAnsweredWhereItWasAsked() async throws {
        let recorder = NamedRecorder(1)
        func clashingHome(with recorder: NamedRecorder) async throws -> (Home, GuideProgramRow, [DemoTV.Schedule]) {
            let home = try await launch(with: recorder)
            try await untilConnected(home.model)
            try await untilTheTelevisionIsConnected(home.model)
            let wanted = try await programmesNotReserved(home.model, 1)[0]
            await home.television.receives([station(of: wanted)])
            let holding = [("サンプル寄席", 1032, "サンプル放送"), ("サンプル音楽館", 1040, "サンプル放送2"),
                           ("サンプル名画座", 1048, "サンプル放送3")].enumerated().map { number, its in
                DemoTV.Schedule(id: "recording.\(21 + number)", serviceID: its.1, station: its.2, title: its.0,
                                start: wanted.start)
            }
            await home.television.put(Array(holding.prefix(2)))
            return (home, wanted, holding)
        }
        func marks(_ television: DemoTV) async -> [String] {
            await television.schedules.map { "\($0.id) \($0.overlapStatus)" }
        }
        let (home, wanted, holding) = try await clashingHome(with: recorder)
        let (model, television, store) = (home.model, home.television, home.store)
        let heard = await recorder.heard.count
        var japan = Calendar(identifier: .gregorian)
        japan.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let at = japan.dateComponents([.month, .day, .hour, .minute], from: wanted.start)
        let start = "\(at.month ?? 0)/\(at.day ?? 0) " + String(format: "%02d:%02d", at.hour ?? 0, at.minute ?? 0)
        let asksOfTheFirst = "この予約を入れると、次の予約は録画されません: 「サンプル寄席」（サンプル放送 \(start)）。"
        let asksOfTheSecond = "この予約を入れると、次の予約は録画されません: 「サンプル音楽館」（サンプル放送2 \(start)）。"
        let tail = "「もう一度送る」を選ぶと、それでも予約します。"

        let asked = await model.reserve(wanted, on: .tv, quality: "DR", repeating: "none")

        var onThePhone = try await store.pendingReservations()
        let held = try XCTUnwrap(onThePhone.first, "the reservation was not kept")
        XCTAssertEqual(asked, .wouldStop(held))
        XCTAssertEqual(held.problem, asksOfTheFirst + tail)
        XCTAssertEqual(TVDriver.asks(of: held), asksOfTheFirst)
        expectEqual(await marks(television), ["recording.21 notOverlapped", "recording.22 notOverlapped"])

        await television.put(Array(holding.suffix(2)))
        let again = await model.consent(to: held, askedForJustNow: true)

        onThePhone = try await store.pendingReservations()
        let named = try XCTUnwrap(onThePhone.first, "the reservation no longer waits")
        XCTAssertEqual(again, .wouldStop(named), "a yes to one recording was not answered with the one named now")
        XCTAssertEqual(TVDriver.asks(of: named), asksOfTheSecond)
        XCTAssertEqual(model.pending, [named], "the row on screen is not the row as it waits")
        expectEqual(await marks(television), ["recording.22 notOverlapped", "recording.23 notOverlapped"],
                    "a yes to one recording stopped another")

        expectEqual(await model.consent(to: named, askedForJustNow: true), .made(saying: nil))

        expectEqual(await marks(television), ["recording.22 fullyOverlapped", "recording.23 notOverlapped",
                                              "recording.24 notOverlapped"])
        expectEqual(await television.schedules.last?.eventId, wanted.eventID)
        XCTAssertEqual(model.reservations(for: wanted).map(\.device), [.tv], "the list read after it was not kept")
        expectEqual(try await store.pendingReservations(), [])
        XCTAssertTrue(model.pending.isEmpty, "what was made is still shown as waiting")
        XCTAssertNil(model.queueReport, "a reservation asked for just now is said on the strip as one that waited")
        expectEqual(await recorder.heard(since: heard), [], "the television's question asked the recorder")

        let (before, waited, _) = try await clashingHome(with: NamedRecorder(1))
        let first = await before.model.reserve(waited, on: .tv, quality: "DR", repeating: "none")
        guard case .wouldStop(let row) = first else { return XCTFail("the reservation was not held: \(first)") }
        expectEqual(await before.model.consent(to: row, askedForJustNow: false), .made(saying: nil))
        XCTAssertEqual(before.model.queueReport, Said.sent(waited.title, naming: "テレビ"))
    }

    // MARK: - what the reservations tab says of what waits

    /// 「もう一度送る」 as a screen asks for it hands back what the row came to, for that screen to say, and
    /// goes on telling the strip what any sending tells. A television's row that is turned down again is
    /// answered with the row and its reason, which the row says for itself, so nothing is left to say
    /// beside it; one that is made, as made; and a recorder's row hands nothing back, and says what it
    /// sent on the strip as it always has.
    ///
    /// What the television's sendings say is added to what the strip has unread, and no sentence is said
    /// twice. The row turned down again adds nothing to the sentence that sent the reader to it, the row
    /// made is said after that sentence, and another row turned down adds only that it was: where the
    /// reasons are has been said. A full stop in a title ends no sentence.
    ///
    /// With the television given up on and still silent no round runs, and the answer says which row goes
    /// by itself and which does not. One freed of a plain reason is handed back with none, to go when the
    /// television next answers. One held for what it would stop from recording keeps its reason and is
    /// said not to have been sent. Neither says anything on the strip.
    func testARowSentAgainIsAnsweredWhereItWasAskedAndGoesOnTellingTheStrip() async throws {
        let recorder = NamedRecorder(1)
        let reason = "前に断られた理由"
        let first = turnedDown(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)), for: reason)
        let home = try await launch(with: recorder, waiting: [first, notListed("サンプル。紀行", programme: 4402)])
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost), link = try XCTUnwrap(model.tv)
        let turnedAway = Said.refused("サンプル。紀行", naming: "テレビ")
        XCTAssertEqual(model.queueReport, turnedAway, "the connect's sending did not say what it turned down")
        // As the reservations tab reads the queue when it appears: in the order the programmes start.
        await model.loadPending()
        let (held, away) = (try XCTUnwrap(model.pending.first), try XCTUnwrap(model.pending.last))

        let again = await model.sendAgain(away)

        XCTAssertEqual(again, .waiting(away, saying: "テレビのチャンネル一覧にこの局が見つかりませんでした。"))
        XCTAssertNil(again?.besideItsRow, "the reason the row says for itself is to be said beside it too")
        XCTAssertEqual(model.queueReport, turnedAway, "a sentence the strip had unread was said a second time")

        expectEqual(await model.sendAgain(held), .made(saying: nil))

        XCTAssertEqual(host.reservations.map(\.eventID), [4401], "the list read after it was not kept")
        let made = turnedAway + "。" + Said.sent("サンプル劇場", naming: "テレビ")
        XCTAssertEqual(model.queueReport, made, "a row sent again took what the strip had unread, or said nothing")

        try await store.queue(notListed("サンプル。天気", programme: 4405))
        await host.refreshReservations()
        XCTAssertEqual(model.queueReport, made + "。「サンプル。天気」はテレビに登録できませんでした")

        let theirs = turnedDown(waiting("朝の番組", startingIn: 120, programme: 4321), for: reason)
        try await store.queue(theirs)
        let asked = await recorder.asked

        expectNil(await model.sendAgain(theirs), "a recorder's row handed a screen something to say")

        expectEqual(await recorder.asked(Self.create, since: asked), 1, "the recorder's row did not go to it once")
        XCTAssertEqual(model.flushReport, Said.sent("朝の番組", naming: "レコーダー"))

        await television.goSilent()
        _ = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(link.session.gaveUp)
        let freed = turnedDown(forTheTelevision(waiting("サンプル天気", startingIn: 181, programme: 4403)), for: reason)
        let stopping = turnedDown(forTheTelevision(waiting("サンプル音楽", startingIn: 182, programme: 4404)),
                                  for: Self.wouldStop)
        for row in [freed, stopping] { try await store.queue(row) }
        let strip = model.queueReport

        let goes = await model.sendAgain(freed), stays = await model.sendAgain(stopping)

        let onThePhone = try await store.pendingReservations()
        let (free, stopped) = (try XCTUnwrap(onThePhone.first { $0.id == freed.id }),
                               try XCTUnwrap(onThePhone.first { $0.id == stopping.id }))
        XCTAssertEqual([free.problem, stopped.problem], [nil, Self.wouldStop], "a reason stayed that goes, or went")
        XCTAssertEqual(goes, .waiting(free, saying: "テレビに接続していないため、予約を端末に保存しました。"
                                      + "次にテレビが答えたときに登録します。予約タブで削除できます。"))
        XCTAssertEqual(stays, .waiting(stopped, saying: "テレビに接続していません。"
                                       + "テレビの電源とネットワーク接続を確認してください。"))
        XCTAssertEqual(model.queueReport, strip, "a row that was not sent said something on the strip")
    }

    /// A waiting row says its device where there are two to tell apart, or where the row is not the
    /// recorder's, and nowhere else. What the tab says under what waits goes by the devices its rows wait
    /// for, and not by the devices saved. So in a home with a recorder alone no row of the recorder's says
    /// a device, and the footer is the two sentences it has always been, letter for letter; and with a
    /// television saved the recorder's rows alone are still said so. Nothing is asked of any device.
    func testAWaitingRowSaysItsDeviceAndTheFooterNamesTheDevicesWaitedFor() throws {
        let theirs = waiting("朝の番組", startingIn: 120, programme: 4321)
        let its = forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401))
        let reason = "前に断られた理由"
        let recorders = "レコーダーに届かなかった予約です。次にレコーダーにつながったときに登録します。"
        let televisions = "テレビにまだ届いていない予約です。次にテレビにつながったときに登録します。"
        let both = "レコーダーやテレビにまだ届いていない予約です。それぞれ、次につながったときに登録します。"
        let reasons = "理由が付いているものは自動では送り直しません。右にスワイプすると、もう一度送れます。"
        // As the tab reads it: from the rows on screen.
        func footer(of model: AppModel, over rows: [PendingReservation]) -> String {
            model.pending = rows
            return model.whatWaitsSays
        }

        let alone = try aBench().model(recorder: SilentRecorder())
        XCTAssertNil(alone.deviceSaid(for: theirs), "a row says its device in a home with one device")
        XCTAssertEqual(alone.deviceSaid(for: its), "テレビ", "a row that is not the recorder's does not say so")
        XCTAssertEqual(footer(of: alone, over: [theirs]), recorders)
        XCTAssertEqual(footer(of: alone, over: [turnedDown(theirs, for: reason)]), recorders + reasons)

        let two = try aBench().model(recorder: SilentRecorder(), television: NoTelevision(),
                                     credentials: MemoryTVCredentials())
        XCTAssertEqual([theirs, its].map { two.deviceSaid(for: $0) }, ["レコーダー", "テレビ"])
        XCTAssertEqual(footer(of: two, over: [theirs]), recorders, "said by the devices saved, not the rows")
        XCTAssertEqual(footer(of: two, over: [its]), televisions)
        XCTAssertEqual(footer(of: two, over: [theirs, its]), both)
        XCTAssertEqual(footer(of: two, over: [theirs, turnedDown(its, for: reason)]), both + reasons)

        let noRecorder = try aBench().modelWithNoRecorder(television: NoTelevision(),
                                                          credentials: MemoryTVCredentials())
        XCTAssertEqual(noRecorder.deviceSaid(for: its), "テレビ")
        XCTAssertEqual(footer(of: noRecorder, over: [its]), televisions)
    }

    /// 削除する at the tab's question takes a waiting row off the phone, and for a television's row does
    /// nothing while the television works -- here with a read of its list. The row's swipe is held back by
    /// the same, and this is for work begun while the question was up: a sending would go on to make the
    /// row after the reader was told that it is not sent. The row stays, on the phone and on screen.
    ///
    /// A recorder's row is held back by nothing, as it never was: it is deleted under the television's
    /// work, and under the recorder's own. Nor does the recorder's work hold a television's row back.
    func testAWaitingRowIsNotDeletedWhileTheTelevisionItWaitsForWorks() async throws {
        let recorder = NamedRecorder(1)
        let home = try await launch(with: recorder)
        let (model, store, door) = (home.model, home.store, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        // Each with a reason on it, so that no sending takes one meanwhile. Read in the order they start.
        let reason = "前に断られた理由"
        let morning = turnedDown(waiting("朝の番組", startingIn: 120, programme: 4321), for: reason)
        let noon = turnedDown(waiting("昼の番組", startingIn: 121, programme: 4322), for: reason)
        let its = turnedDown(forTheTelevision(waiting("サンプル劇場", startingIn: 122, programme: 4401)), for: reason)
        let another = turnedDown(forTheTelevision(waiting("サンプル紀行", startingIn: 123, programme: 4402)), for: reason)
        for row in [morning, noon, its, another] { try await store.queue(row) }
        // As the reservations tab reads the queue when it appears.
        await model.loadPending()

        await door.hold(only: "getScheduleList")
        let reading = Task { await host.loadReservations() }
        try await until("the read of the television's list was never out") { await door.isHolding }
        await model.deleteWaiting(its)
        expectEqual(try await store.pendingReservations().map(\.request.eventID), [4321, 4322, 4401, 4402],
                    "a television's row was deleted while the television was busy")
        await model.deleteWaiting(morning)
        expectEqual(try await store.pendingReservations().map(\.request.eventID), [4322, 4401, 4402],
                    "the television's work held a row of the recorder's back")
        XCTAssertEqual(model.pending.map(\.request.eventID), [4322, 4401, 4402])
        await door.letGo()
        await reading.value

        await recorder.hold(only: Self.list)
        let listing = Task { await model.loadReservations() }
        try await until("the recorder's list was never being read") { model.busy == "予約一覧を取得中" }
        await model.deleteWaiting(noon)
        await model.deleteWaiting(its)
        await recorder.letGo()
        await listing.value
        expectEqual(try await store.pendingReservations().map(\.request.eventID), [4402],
                    "the recorder's work held a row back, its own or the television's")
        XCTAssertEqual(model.pending.map(\.request.eventID), [4402])
    }

    // MARK: - taking the television away

    /// Taking the television away takes what waits for it as well, unsent, and nothing else. The question
    /// before it says how many reservations that is, counted on the phone: the queue on screen is read only
    /// once the reservations tab has been opened. Taken away, the television's reservation is gone from the
    /// phone and from the screen, the recorder's waits as it did with its reason, the television's address
    /// and registration are forgotten, and the television was asked nothing.
    ///
    /// Before that, twice, nothing is taken away. While the television is busy -- here with a read of its
    /// list -- nothing is done and nothing said: the button is held back by the same, and this is for a
    /// sending begun while the question was up. And when what waits cannot be deleted, the phone's cache
    /// being busy with another writer for longer than the app waits, the television stays with its
    /// registration, every reservation waits as it did, and the television's line says why.
    func testTakingTheTelevisionAwayTakesWhatWaitsForItAndNothingElse() async throws {
        let home = try await launch(with: NamedRecorder(1), busyTimeout: 200)
        let (model, television, store, door) = (home.model, home.television, home.store, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        for row in [turnedDown(waiting("朝の番組", startingIn: 120, programme: 4321), for: "前に断られた理由"),
                    forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401))] {
            try await store.queue(row)
        }
        let both = try await store.pendingReservations()
        XCTAssertTrue(model.pending.isEmpty, "the queue on screen was read: the count could be taken from it")

        expectEqual(await model.waitingForTheTelevision(), 1, "what waits was not counted on the phone")

        // As the reservations tab reads the queue when it appears.
        await model.loadPending()
        await door.hold(only: "getScheduleList")
        let reading = Task { await host.loadReservations() }
        try await until("the read of the television's list was never out") { await door.isHolding }
        expectFalse(await model.takeTheTelevisionAway(counted: 1), "a television that was busy was taken away")
        XCTAssertTrue(model.tvHost === host, "a television that was busy was let go of")
        XCTAssertNil(host.problem, "something was said of a television that was only busy")
        expectEqual(try await store.pendingReservations(), both, "a reservation went while the television was busy")
        await door.letGo()
        await reading.value
        let calls = await television.calls

        let writer = Writer(to: try model.guidePath())
        expectFalse(await model.takeTheTelevisionAway(counted: 1), "taken away though what waits could not be deleted")
        writer.letGo()
        XCTAssertTrue(model.tvHost === host, "the television was taken away over reservations that stayed")
        XCTAssertNotNil(model.surroundings.tvCredentials.load(), "its registration went all the same")
        XCTAssertEqual(host.problem, "送信待ちの予約を削除できなかったため、テレビを外していません。"
                       + "少し待ってから、もう一度お試しください。")
        expectEqual(try await store.pendingReservations(), both)
        XCTAssertEqual(model.pending, both)

        expectTrue(await model.takeTheTelevisionAway(counted: 1), "a television at rest was not taken away")

        let left = both.filter { $0.target == .recorder }
        XCTAssertEqual(left.map(\.problem), ["前に断られた理由"])
        expectEqual(try await store.pendingReservations(), left, "the television's stayed, or the recorder's went")
        XCTAssertEqual(model.pending, left, "the queue on screen still shows what waited for the television")
        XCTAssertNil(model.tv)
        XCTAssertNil(model.tvHost)
        XCTAssertNil(model.surroundings.tvCredentials.load(), "the registration was kept")
        XCTAssertNil(model.defaults.string(forKey: DefaultsKey.tvHost), "the address was kept")
        expectEqual(await television.calls, calls, "the television was asked something as it was taken away")
    }

    /// 外す is held to the count its question gave. A sending that began and ended while the question was
    /// up is over by the time 外す is pressed, and nothing shows it but what waits. Here the question said
    /// two, and a pull-down has made both on the television since. Nothing is taken away and nothing said:
    /// the television stays with its registration, and with what its sending said on the strip, which is
    /// where the two are said to have gone. Asked again the question counts none, and then the television
    /// is taken away.
    ///
    /// A queue that cannot be read is not counted as empty: there is no count, for a question that gives
    /// none. After a question that said two, 外す then does nothing. After one that gave no count it goes on
    /// to delete what waits, which fails: the television stays, and its line says why.
    func testTheTelevisionIsNotTakenAwayOverACountItsQuestionDidNotGive() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        for row in [forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)),
                    forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402))] {
            try await store.queue(row)
        }
        let said = await model.waitingForTheTelevision()
        XCTAssertEqual(said, 2)

        let outOfReach = QueueOutOfReach(in: try model.guidePath())
        expectNil(await model.waitingForTheTelevision(), "a queue that could not be read was counted as empty")
        expectFalse(await model.takeTheTelevisionAway(counted: said), "taken away with nothing to hold its count to")
        XCTAssertNil(host.problem, "a count that no longer holds went as far as the delete")
        expectFalse(await model.takeTheTelevisionAway(counted: nil), "taken away over a queue it could not delete from")
        XCTAssertEqual(host.problem, "送信待ちの予約を削除できなかったため、テレビを外していません。"
                       + "少し待ってから、もう一度お試しください。", "a question that gave no count was not acted on")
        outOfReach.putBack()
        XCTAssertTrue(model.tvHost === host, "the television was taken away over a queue that could not be read")
        expectEqual(await model.waitingForTheTelevision(), said)

        await host.refreshReservations()
        expectEqual(await television.schedules.map(\.eventId), [4401, 4402], "the sending did not make both")
        let registered = Said.sent("サンプル劇場", andOthers: 1, naming: "テレビ")
        XCTAssertEqual(model.queueReport, registered)
        expectFalse(await model.takeTheTelevisionAway(counted: said), "taken away over reservations made since")
        XCTAssertTrue(model.tvHost === host, "the television holds two reservations the app no longer shows")
        XCTAssertNotNil(model.surroundings.tvCredentials.load(), "its registration went all the same")
        XCTAssertNil(host.problem, "something was said of a count that no longer held")
        XCTAssertEqual(model.queueReport, registered, "what the strip said of the two went with the television")

        expectEqual(await model.waitingForTheTelevision(), 0)
        expectTrue(await model.takeTheTelevisionAway(counted: 0), "with nothing waiting, it was not taken away")
        XCTAssertNil(model.tv)
        XCTAssertNil(model.surroundings.tvCredentials.load(), "the registration was kept")
    }

    // MARK: - which line the strip shows

    /// The strip says one thing at a time, and which is the model's to choose (`AppModel.strip`). In a
    /// home with a recorder alone the order is the one it has always had: work under way; that another
    /// recorder took over, while the app is connected; what became of what was waiting, cut at three
    /// lines; that the data is invented, but not at the top of a sheet; the permission for the local
    /// network; the recorder given up on. Each is looked at while the one behind it holds as well.
    ///
    /// A reservation waits as another recorder answers at the address, and is held back: the strip says
    /// of the change first, and a read that is out goes ahead of that. Once that recorder has gone silent
    /// the change is not said, since the line says the lists were read again: what was held back is, and
    /// with that closed the reconnect is offered. The permission is said ahead of the reconnect, which
    /// would only run into it, and behind what was held back while that is unread. Connected again, the
    /// change is said after all.
    ///
    /// In the demo the strip says that the data is invented, on a screen and not at the top of a sheet,
    /// and what became of what was waiting goes ahead of that on both.
    func testWithARecorderAloneTheStripSaysOneThingAtATimeInTheOrderItAlwaysHas() async throws {
        let (bench, recorder, model) = try await connectedHome()
        XCTAssertNil(model.tv, "a television is saved in this home")
        XCTAssertNil(model.strip(), "a home at rest has a line on its strip")

        try await GuideStore(path: bench.guidePath).queue(waiting("朝の番組", startingIn: 120, programme: 4321))
        await recorder.become(2)
        await model.connect()
        try await untilIdle(model)
        let heldBack = AppModel.Strip.report(Said.heldBack(1), inFull: false)
        XCTAssertEqual(model.queueReport, Said.heldBack(1), "nothing was held back for the strip to say second")
        XCTAssertEqual(model.strip(), .anotherTookOver, "what was held back is said ahead of the change")

        await recorder.hold(only: Self.list)
        let reading = Task { await model.loadReservations() }
        try await until("the recorder's list was never being read") { model.busy == "予約一覧を取得中" }
        XCTAssertEqual(model.strip(), .busy("予約一覧を取得中"), "work under way is not what the strip says")
        await recorder.letGo()
        await reading.value
        XCTAssertEqual(model.strip(), .anotherTookOver)

        await recorder.goQuiet(on: Self.list)
        await model.loadReservations()
        XCTAssertTrue(model.gaveUp && model.anotherTookOver, "the recorder was not lost with the change unread")
        XCTAssertEqual(model.strip(), heldBack, "the lists are said to have been read again from a recorder now gone")
        XCTAssertEqual(model.strip(inSheet: true), heldBack)
        model.session.waitingForPermission()
        XCTAssertEqual(model.strip(), heldBack, "the permission is said ahead of what was held back, still unread")
        model.session.permissionCleared()
        model.closeQueueReport()
        XCTAssertEqual(model.strip(), .recorderGaveUp)

        // The bench takes the permission as given, so the session is told what the link tells it when the
        // system stops the app asking.
        model.session.waitingForPermission()
        XCTAssertEqual(model.strip(), .blocked, "the reconnect is offered where it would run into the same refusal")
        model.session.permissionCleared()
        XCTAssertEqual(model.strip(), .recorderGaveUp)

        await reconnect(model)
        XCTAssertEqual(model.strip(), .anotherTookOver, "the change went unsaid once the lists had been read again")
        // As the buttons of the two lines close them.
        model.anotherTookOver = false
        XCTAssertEqual(model.strip(), heldBack)
        model.closeQueueReport()
        XCTAssertNil(model.strip())

        await model.enterDemo()
        XCTAssertTrue(model.connected, "the demo did not start: \(model.problem ?? "no reason given")")
        XCTAssertEqual(model.strip(), .demo)
        XCTAssertNil(model.strip(inSheet: true), "the demo's line is at the top of a sheet")
        try await XCTUnwrap(model.store).queue(waiting("夜の番組", startingIn: 122, programme: 4323))
        await model.refreshReservations()
        let sent = AppModel.Strip.report(Said.sent("夜の番組"), inFull: false)
        XCTAssertEqual(model.strip(), sent, "that the data is invented is said ahead of what became of the queue")
        XCTAssertEqual(model.strip(inSheet: true), sent)
    }

    /// With a television saved, its own lines come after everything about the recorder: that it is to be
    /// registered again, and then that it was given up on. A television that wants the registration and
    /// has gone silent since is still said to want it. The recorder given up on is said ahead of both.
    ///
    /// What became of what was waiting is then shown in full: what a sending to a television says can end
    /// with what making a reservation did to another, which is the last thing a cut would leave.
    func testWithATelevisionSavedItsLinesComeAfterTheRecordersAndTheReportIsInFull() async throws {
        let recorder = NamedRecorder(1)
        let home = try await launch(with: recorder, waiting: [
            forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)),
        ])
        let (model, television) = (home.model, home.television)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let link = try XCTUnwrap(model.tv)
        XCTAssertEqual(model.strip(), .report(Said.sent("サンプル劇場", naming: "テレビ"), inFull: true))
        model.closeQueueReport()
        XCTAssertNil(model.strip(), "a home at rest has a line on its strip")

        await television.goSilent()
        _ = await link.ensureUp(evenIfRecent: true)
        XCTAssertEqual(model.strip(), .tvGaveUp)

        // It answers again, and no longer takes the app's cookie.
        await television.goSilent(false)
        model.surroundings.tvCredentials.save(TVCredentials(clientID: "BDBridge:test", cookie: "run out"))
        await link.connect()
        XCTAssertFalse(link.session.gaveUp, "a television that answered is still given up on")
        XCTAssertEqual(model.strip(), .tvNeedsPairing)

        await television.goSilent()
        await link.connect()
        XCTAssertTrue(link.session.gaveUp, "a television that went silent was not given up on")
        XCTAssertEqual(model.strip(), .tvNeedsPairing, "the reconnect is offered to a television to be registered")

        await recorder.goQuiet(on: Self.list)
        await model.loadReservations()
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.strip(), .recorderGaveUp, "a line of the television's is said ahead of the recorder's")
    }

    /// The television's disk has a line on the strip, the last of them all, while the disk is known to be
    /// away and a reservation waits for it to come back; and what the reservations tab says under what
    /// waits then ends with the same sentence. It is known from a sending that stopped for want of the
    /// disk, which puts nothing on the television's line of what went wrong.
    ///
    /// Only a reservation of the television's with no reason on it waits for the disk: with that row held
    /// for the reader, and a row of the recorder's waiting beside it, neither the strip nor the tab says
    /// the disk. A television given up on is said ahead of its disk. With the disk back, pulling the
    /// reservations down sends the row, and the disk is not said again of the next row to wait: that
    /// sending saw it there, and no connect has read it since.
    func testTheStripAndTheTabSayTheDiskIsAwayWhileAReservationWaitsForIt() async throws {
        let notFound = "録画用の USB HDD が見つからないため、テレビへの予約は送っていません"
        let televisions = "テレビにまだ届いていない予約です。次にテレビにつながったときに登録します。"
        let both = "レコーダーやテレビにまだ届いていない予約です。それぞれ、次につながったときに登録します。"
        let reasons = "理由が付いているものは自動では送り直しません。右にスワイプすると、もう一度送れます。"
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost), link = try XCTUnwrap(model.tv)
        let row = forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401))
        try await store.queue(row)
        await model.loadPending()
        XCTAssertNil(model.strip(), "the disk is said to be away while it is there")
        XCTAssertEqual(model.whatWaitsSays, televisions)

        await television.unmount()
        await host.refreshReservations()

        XCTAssertEqual(model.strip(), .tvDiskAway)
        XCTAssertEqual(TVDriver.diskNotFound, notFound)
        XCTAssertEqual(model.whatWaitsSays, televisions + notFound + "。")
        XCTAssertNil(model.problem(for: .tv), "a disk that is away went on the television's line")

        // Put there for the recorder and never sent: nothing here has the recorder's queue sent.
        try await store.queue(waiting("朝の番組", startingIn: 121, programme: 4321))
        try await store.setPendingProblem(row.id, "前に断られた理由")
        await model.loadPending()
        XCTAssertNil(model.strip(), "a row that waits for the reader, or for the recorder, is said to wait for a disk")
        XCTAssertEqual(model.whatWaitsSays, both + reasons)
        try await store.setPendingProblem(row.id, nil)
        await model.loadPending()
        XCTAssertEqual(model.strip(), .tvDiskAway)
        XCTAssertEqual(model.whatWaitsSays, both + notFound + "。")

        await television.goSilent()
        _ = await link.ensureUp(evenIfRecent: true)
        XCTAssertEqual(model.strip(), .tvGaveUp, "the disk is said ahead of a television that is not connected")
        await television.goSilent(false)
        await link.connect()
        XCTAssertEqual(model.strip(), .tvDiskAway)

        await television.unmount(false)
        await host.refreshReservations()

        XCTAssertEqual(model.strip(), .report(Said.sent("サンプル劇場", naming: "テレビ"), inFull: true))
        model.closeQueueReport()
        try await store.queue(forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402)))
        await model.loadPending()
        XCTAssertEqual(model.pending.map(\.problem), [nil, nil], "nothing is left waiting unsent to say the disk of")
        XCTAssertNil(model.strip(), "the disk is still said to be away after a sending that found it there")
        XCTAssertEqual(model.whatWaitsSays, both)
    }

    // MARK: - with no screen

    /// The Shortcuts action's answer in a home with a television: the recorder's sentence, as it reads with a
    /// television saved, then the television's, joined with a full stop; a device with nothing to say is left
    /// out, and 「送信待ちの予約はありません。」 is said once where neither has anything. With no sending of the
    /// television's -- no television saved, or the demo -- the answer is the one a home with a recorder alone
    /// has always had, letter for letter. In a home with a television and no recorder the recorder's sentence
    /// for that is not said, and the television's is the answer.
    ///
    /// One real sending of each device, made against the fakes, stands for a round that went; so does one of
    /// the television's that found nothing left to send, and one stopped for its disk or for want of a
    /// registration. A round of the recorder's with nothing in it is left out beside the television's; one
    /// that its silence cut short before anything went is said.
    func testTheActionAnswersForTheRecorderAndThenTheTelevision() async throws {
        let recorder = NamedRecorder(1)
        let home = try await launch(with: recorder)
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        try await store.queue(waiting("朝の番組", startingIn: 120, programme: 4321))
        try await store.queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        func client(with credentials: any TVCredentialStore) -> ScalarClient {
            ScalarClient(host: Bench.tvHost, transport: television, credentials: credentials)
        }
        func sendToTheTelevision(with credentials: any TVCredentialStore) async -> NoScreenSending {
            await TVDriver.sendWithNoScreen(client(with: credentials), store: store, knownAs: nil)
        }
        let recorders = await BackgroundWork.sendWaiting(client: aClient(of: recorder), store: store, mac: nil)
        func recordersRound() async -> BackgroundWork.Sending {
            .sent(await PendingQueue.flush(client: aClient(of: recorder), store: store))
        }
        let nothingForTheRecorder = await recordersRound()
        try await store.queue(waiting("昼の番組", startingIn: 150, programme: 4322))
        await recorder.goQuiet(on: Self.create)
        let recorderCutShort = await recordersRound()
        let televisions = await sendToTheTelevision(with: model.surroundings.tvCredentials)
        let nothingLeft = NoScreenSending.sent(
            await PendingQueue.flush(client: client(with: model.surroundings.tvCredentials), store: store))
        try await store.queue(forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402)))
        let unregistered = await sendToTheTelevision(with: MemoryTVCredentials())
        await television.unmount()
        let diskAway = await sendToTheTelevision(with: model.surroundings.tvCredentials)

        let made = (recorder: Said.sent("朝の番組", naming: "レコーダー"), tv: Said.sent("サンプル劇場", naming: "テレビ"))
        let nothing = "送信待ちの予約はありません。"
        let notAnswering = "テレビが応答しないため送っていません。次にテレビが答えたときに送ります"
        for sending in [recorders, .nothingWaiting, .unreachable, .anotherRecorder, .noRecorder, .demo] {
            XCTAssertEqual(SendWaitingIntent.saying(sending, beside: nil, televisionSaved: false),
                           SendWaitingIntent.saying(sending, televisionSaved: false), "\(sending)")
        }
        XCTAssertEqual(SendWaitingIntent.saying(recorders, beside: nil, televisionSaved: false), Said.sent("朝の番組"))
        let cases: [(String, BackgroundWork.Sending, NoScreenSending, String)] = [
            ("nothing anywhere", .nothingWaiting, .nothingWaiting, nothing),
            ("nothing left for the television", .nothingWaiting, nothingLeft, nothing),
            ("both made", recorders, televisions, made.recorder + "。" + made.tv),
            ("nothing in the recorder's round", nothingForTheRecorder, televisions, made.tv),
            ("the recorder's round cut short", recorderCutShort, televisions,
             "途中でレコーダーの応答がなくなりました。送信待ちの予約はそのまま残しています。" + made.tv),
            ("the recorder away", .unreachable, .nothingWaiting, "レコーダーに接続できませんでした。送信待ちの予約はそのまま残しています。"),
            ("the television away", .nothingWaiting, .unreachable, notAnswering),
            ("another of each", .anotherRecorder, .anotherAnswered,
             "これまでとは別のレコーダーが応答したため、送信待ちの予約はそのまま残しています。アプリを開いて確かめてください。"
                + "登録したテレビとは別の機器が応答しました。設定の「テレビ」から追加し直してください"),
            ("the television's disk away", .nothingWaiting, diskAway,
             "録画用の USB HDD が見つからないため、テレビへの予約は送っていません"),
            ("no registration kept", .nothingWaiting, unregistered,
             "テレビへの登録が必要です。設定の「テレビ」から登録してください"),
            ("a television alone, made", .noRecorder, televisions, made.tv),
            ("a television alone, away", .noRecorder, .unreachable, notAnswering),
            ("a television alone, nothing waiting", .noRecorder, .nothingWaiting, nothing),
        ]
        for (name, recorders, television, said) in cases {
            XCTAssertEqual(SendWaitingIntent.saying(recorders, beside: television, televisionSaved: true), said, name)
        }
        XCTAssertEqual(SendWaitingIntent.saying(.demo, beside: nil, televisionSaved: true), "サンプルデータの表示中は送りません。")
    }

    /// The screens and a run with no screen sending at once -- the app open as the action runs on arriving
    /// home -- make a television's reservation once. The screens' pull-down is held at the television's create;
    /// the action, with a client and a connection to the cache of its own, reads the MAC and then waits its turn
    /// (`PendingQueue.flush`), reading the queue afresh once it has it. Made by each, it would be on the
    /// television twice.
    func testTheScreensAndARunWithNoScreenAtOnceMakeATelevisionsReservationOnce() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, door) = (home.model, home.television, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        // Queued once the television is connected: its first connect would have sent it by itself.
        try await home.store.queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        let theirs = try GuideStore(path: try model.guidePath())
        let client = ScalarClient(host: Bench.tvHost, transport: door, credentials: model.surroundings.tvCredentials)
        let readsTheMAC = "getSystemSupportedFunction cookie=no pin=no"
        await door.hold(only: Self.tvCreate)

        let screens = Task { await host.refreshReservations() }
        try await until("the screens' sending never reached the create") { await door.isHolding }
        let macReads = await television.calls.filter { $0 == readsTheMAC }.count
        let action = Task {
            await BackgroundWork.sendToTheTelevision(client: client, store: theirs, mac: nil, told: TVTold(),
                                                     nextRun: Date().addingTimeInterval(6 * 3600))
        }
        try await until("the action never read the MAC") {
            await television.calls.filter { $0 == readsTheMAC }.count > macReads
        }
        // Long enough for the action to have sent it too, were it not waiting its turn.
        try await Task.sleep(for: .milliseconds(300))
        await door.letGo()
        await screens.value
        let run = await action.value

        expectEqual(await television.calls.filter { $0.hasPrefix(Self.tvCreate) }.count, 1, "made by each")
        expectEqual(await television.schedules.map(\.eventId), [4401])
        expectEqual(try await home.store.pendingReservations(), [])
        guard case .sent(let round) = run.sending else { return XCTFail("the action ran no round: \(run.sending)") }
        XCTAssertTrue(round.sent.isEmpty && round.alreadyThere.isEmpty && round.stopped == nil,
                      "the action's round found something to send")
        XCTAssertNil(TVDriver.says(run.sending, naming: "テレビ"))
    }

    /// What a run with no screen tells is read from the queue as the run left it, against the next run it is
    /// handed. A reservation the television makes is said as made, naming the television, and one it turns
    /// down as turned down, and neither is told as not having reached it. With the television silent, a
    /// reservation due before the next run is told in a notice of its own, ending with the television not
    /// answering; the same run again, from what the last one handed back, tells nothing. One due an hour after
    /// the next run is not told.
    func testWhatARunWithNoScreenTellsIsReadFromTheQueueItLeft() async throws {
        let bench = try aBench()
        let store = try GuideStore(path: bench.guidePath)
        let television = DemoTV()
        await television.receives([DemoTV.Station()])
        let client = ScalarClient(host: Bench.tvHost, transport: television,
                                  credentials: await registered(with: television))
        let nextRun = Date().addingTimeInterval(6 * 3600)
        func run(from told: TVTold) async -> (sending: NoScreenSending, notices: TVNotices, told: TVTold) {
            await BackgroundWork.sendToTheTelevision(client: client, store: store, mac: nil, told: told,
                                                     nextRun: nextRun)
        }
        try await store.queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        try await store.queue(notListed("サンプル特番", programme: 4405))

        let went = await run(from: TVTold())

        XCTAssertEqual(went.notices, TVNotices(queue: Said.sent("サンプル劇場", naming: "テレビ") + "。"
                                                + Said.refused("サンプル特番", naming: "テレビ")))

        await television.goSilent()
        let late = forTheTelevision(waiting("サンプル紀行", startingIn: 120, programme: 4402))
        try await store.queue(late)
        try await store.queue(forTheTelevision(waiting("サンプル天気", startingIn: 7 * 60, programme: 4403)))

        let silent = await run(from: went.told)

        XCTAssertEqual(silent.notices, TVNotices(notYet: "テレビにまだ届いていない予約があります（「サンプル紀行」"
                                                  + "\(startInJapan(late)) から）。"
                                                  + "テレビが応答しないため送っていません。次にテレビが答えたときに送ります"))
        let again = await run(from: silent.told)
        XCTAssertEqual(again.notices, TVNotices(), "told a second time")
    }

    /// A registration, or a television taken away, is a change: what the runs with no screen told of the
    /// television before is forgotten with it, so that the next run tells what it finds afresh. That goes
    /// for the reservations told of as not yet at the television as well: the warning about them can end by
    /// asking for the registration, and is taken away with what was told.
    func testARegistrationAgainOrTheTelevisionTakenAwayForgetsWhatWasToldOfIt() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let model = home.model
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let told = try JSONEncoder().encode(TVTold(stop: .disk))
        model.defaults.set(told, forKey: DefaultsKey.tvTold)

        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .registered)
        XCTAssertNil(model.defaults.data(forKey: DefaultsKey.tvTold), "kept over a registration again")

        let warned = TVTold(stop: .registration, rows: ["サンプルの行"])
        model.defaults.set(try JSONEncoder().encode(warned), forKey: DefaultsKey.tvTold)
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .registered)
        XCTAssertNil(model.defaults.data(forKey: DefaultsKey.tvTold), "the rows warned of kept over a registration")

        model.defaults.set(told, forKey: DefaultsKey.tvTold)
        model.removeTV()
        XCTAssertNil(model.defaults.data(forKey: DefaultsKey.tvTold), "kept after the television was taken away")
    }

    /// The television's two notifications have identifiers of their own, which the recorder's
    /// (`queue-flushed`) is not, nor either the other's: none takes another's place.
    func testTheTelevisionsNotificationsHaveIdentifiersOfTheirOwn() {
        XCTAssertEqual(Notify.televisionQueue, "tv-queue-flushed")
        XCTAssertEqual(Notify.televisionNotYet, "tv-not-yet-sent")
    }

    /// 外す and 削除する on a television's row wait for a sending under way with no screen, which the guards
    /// on the television's own work do not see: the action's sending, here held at the television's create
    /// while the model's link is idle. Neither has come back a moment after the create was held. Let go, the
    /// sending makes the row, and 外す then finds that what waits is no longer what its question counted: the
    /// television stays, with its registration. Deleted, a row the sending had in hand is made all the same,
    /// once, and the delete comes back after it, with the television's list read again and the row said as
    /// made, in the strip's sentence for a row sent: not as deleted.
    func testTakingTheTelevisionAwayAndDeletingItsRowWaitForASendingWithNoScreen() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, door) = (home.model, home.television, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let theirs = try GuideStore(path: try model.guidePath())
        let client = ScalarClient(host: Bench.tvHost, transport: door, credentials: model.surroundings.tvCredentials)
        // The action's sending, held at the television's create: what it came to, once let go.
        func heldAction() async throws -> Task<NoScreenSending, Never> {
            await door.hold(only: Self.tvCreate)
            let action = Task {
                await BackgroundWork.sendToTheTelevision(client: client, store: theirs, mac: nil, told: TVTold(),
                                                         nextRun: Date().addingTimeInterval(6 * 3600)).sending
            }
            try await until("the action never reached the create") { await door.isHolding }
            return action
        }

        let first = forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401))
        try await home.store.queue(first)
        let sending = try await heldAction()
        let returned = Returned()
        let takingAway = Task {
            let taken = await model.takeTheTelevisionAway(counted: 1)
            returned.yes = true
            return taken
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(returned.yes, "外す did not wait for the sending under way")
        await door.letGo()

        expectFalse(await takingAway.value, "taken away over a reservation the sending made")
        XCTAssertNotNil(model.tvHost, "the television was taken away")
        XCTAssertNotNil(model.surroundings.tvCredentials.load(), "its registration went")
        expectEqual(await television.schedules.map(\.eventId), [4401])
        guard case .sent(let round) = await sending.value else { return XCTFail("the action ran no round") }
        XCTAssertEqual(round.sent.map(\.id), [first.id])

        let second = forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402))
        try await home.store.queue(second)
        let again = try await heldAction()
        returned.yes = false
        let deleting = Task {
            let instead = await model.deleteWaiting(second)
            returned.yes = true
            return instead
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(returned.yes, "the delete did not wait for the sending under way")
        await door.letGo()
        let instead = await deleting.value

        expectEqual(await television.schedules.map(\.eventId), [4401, 4402])
        XCTAssertEqual(instead, Said.sent("サンプル紀行", naming: "テレビ"), "a reservation made was said to be deleted")
        XCTAssertEqual(model.tvHost?.reservations.compactMap(\.eventID).sorted(), [4401, 4402],
                       "the television's list was not read again")
        guard case .sent(let made) = await again.value else { return XCTFail("the action ran no round again") }
        XCTAssertEqual(made.sent.map(\.id), [second.id])
        expectEqual(try await home.store.pendingReservations(), [])
    }

    /// A recorder's waiting row is deleted at once, as it always has been, whatever the television's sending
    /// with no screen is doing: here the action's, held at the television's create. The recorder's row has a
    /// reason on it, so that no sending of the recorder's takes it meanwhile.
    func testARecordersWaitingRowIsDeletedAtOnceWhileATelevisionsCreateIsHeld() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, door) = (home.model, home.door)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        try await home.store.queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        let morning = turnedDown(waiting("朝の番組", startingIn: 150, programme: 4321), for: "前に断られた理由")
        try await home.store.queue(morning)
        let theirs = try GuideStore(path: try model.guidePath())
        let client = ScalarClient(host: Bench.tvHost, transport: door, credentials: model.surroundings.tvCredentials)
        await door.hold(only: Self.tvCreate)
        let action = Task {
            await BackgroundWork.sendToTheTelevision(client: client, store: theirs, mac: nil, told: TVTold(),
                                                     nextRun: Date().addingTimeInterval(6 * 3600))
        }
        try await until("the action never reached the create") { await door.isHolding }

        let returned = Returned()
        let deleting = Task {
            await model.deleteWaiting(morning)
            returned.yes = true
        }
        try await until("the recorder's row waited for the television's sending", within: 2) { returned.yes }
        let stillHeld = await door.isHolding
        XCTAssertTrue(stillHeld, "the television's create was let go before the delete came back")
        expectEqual(try await home.store.pendingReservations().map(\.request.eventID), [4401])
        await door.letGo()
        await deleting.value
        _ = await action.value
    }

    /// A delete whose row a sending made before its turn says the row was made though the app's own link
    /// cannot read the television's list -- here given up after a read met silence, while the action still
    /// reaches the television: a row not over leaves the queue only by being made or found there. One the
    /// same sending dropped because its programme was over is not said to be made.
    func testADeleteWhoseRowASendingTookIsSaidAsMadeThoughTheListCannotBeRead() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        await television.goSilent()
        await host.loadReservations()
        await television.goSilent(false)
        XCTAssertFalse(try XCTUnwrap(model.tvDriver).canBeAsked, "the app's link can still ask the television")
        let made = forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401))
        let over = forTheTelevision(waiting("サンプル朝市", startingIn: -120, programme: 4408))
        for row in [made, over] { try await store.queue(row) }
        let client = ScalarClient(host: Bench.tvHost, transport: television,
                                  credentials: model.surroundings.tvCredentials)
        _ = await BackgroundWork.sendToTheTelevision(client: client, store: try GuideStore(path: try model.guidePath()),
                                                     mac: nil, told: TVTold(),
                                                     nextRun: Date().addingTimeInterval(6 * 3600))
        expectEqual(await television.schedules.map(\.eventId), [4401])
        expectEqual(try await store.pendingReservations(), [])

        let instead = await model.deleteWaiting(made)
        XCTAssertEqual(instead, Said.sent("サンプル劇場", naming: "テレビ"), "a reservation made was said to be deleted")
        let dropped = await model.deleteWaiting(over)
        XCTAssertNil(dropped, "a reservation dropped as over was said to be made")
    }

    /// A delete whose row still waits, but whose programme the television lists -- the action's create taken
    /// and its answer lost -- says the row was made, takes it out of the queue as a row made, and keeps the
    /// list it read: deleted unsent, it would be a reservation on the television that the reader believes
    /// gone, which no later sending would look for.
    func testADeleteOfARowWhoseCreateTheTelevisionTookSaysItWasMade() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let row = forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401))
        try await store.queue(row)
        await television.atTheNextCreate(.carriedOutAndNotAnswered)
        let client = ScalarClient(host: Bench.tvHost, transport: television,
                                  credentials: model.surroundings.tvCredentials)
        let run = await BackgroundWork.sendToTheTelevision(client: client,
                                                           store: try GuideStore(path: try model.guidePath()),
                                                           mac: nil, told: TVTold(),
                                                           nextRun: Date().addingTimeInterval(6 * 3600))
        guard case .sent(let round) = run.sending, round.stopped == .silent(afterSending: true) else {
            return XCTFail("the create's answer was not lost: \(run.sending)")
        }
        expectEqual(try await store.pendingReservations().map(\.id), [row.id])

        let instead = await model.deleteWaiting(row)
        XCTAssertEqual(instead, Said.sent("サンプル劇場", naming: "テレビ"), "a reservation made was said to be deleted")
        expectEqual(try await store.pendingReservations(), [], "the row made was left waiting")
        XCTAssertEqual(model.tvHost?.reservations.compactMap(\.eventID), [4401], "the list read was not kept")
        expectEqual(await television.schedules.map(\.eventId), [4401])
    }

    /// A delete that waited its turn behind 外す, itself waiting behind the action's sending, finds its row
    /// gone with the television: it was deleted unsent, and is not said to be made. The row carries a reason,
    /// so that the sending leaves it to 外す.
    func testADeleteWhoseRowWentWithTheTelevisionIsNotSaidToBeMade() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, door, store) = (home.model, home.door, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        try await store.queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        let held = turnedDown(forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402)),
                              for: "前に断られた理由")
        try await store.queue(held)
        let client = ScalarClient(host: Bench.tvHost, transport: door, credentials: model.surroundings.tvCredentials)
        let theirs = try GuideStore(path: try model.guidePath())
        await door.hold(only: Self.tvCreate)
        let action = Task {
            await BackgroundWork.sendToTheTelevision(client: client, store: theirs, mac: nil, told: TVTold(),
                                                     nextRun: Date().addingTimeInterval(6 * 3600))
        }
        try await until("the action never reached the create") { await door.isHolding }
        let takingAway = Task { await model.takeTheTelevisionAway(counted: 1) }
        // Long enough for 外す to be waiting its turn before the delete asks for one.
        try await Task.sleep(for: .milliseconds(300))
        let deleting = Task { await model.deleteWaiting(held) }
        try await Task.sleep(for: .milliseconds(300))
        await door.letGo()
        _ = await action.value

        expectTrue(await takingAway.value, "外す did not take the television away")
        let instead = await deleting.value
        XCTAssertNil(instead, "a reservation gone with the television was said to be made")
    }

    /// A sending of the app's own that leaves none of the reservations a run with no screen warned of
    /// waiting takes that warning away and tells of them no more, the stop told kept; one that leaves one of
    /// them waiting -- here stopped for the television's disk -- changes nothing.
    func testTheAppsOwnSendingForgetsTheWarningOnceNoneOfItsRowsWaits() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, store) = (home.model, home.television, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)
        let late = forTheTelevision(waiting("サンプル紀行", startingIn: 120, programme: 4402))
        try await store.queue(late)
        let warned = TVTold(stop: .disk, rows: [late.id])
        model.defaults.set(try JSONEncoder().encode(warned), forKey: DefaultsKey.tvTold)
        func told() throws -> TVTold? {
            try model.defaults.data(forKey: DefaultsKey.tvTold).map { try JSONDecoder().decode(TVTold.self, from: $0) }
        }

        await television.unmount()
        await host.refreshReservations()
        XCTAssertEqual(try told(), warned, "forgotten while a reservation warned of still waits")

        await television.unmount(false)
        await host.refreshReservations()
        expectEqual(await television.schedules.map(\.eventId), [4402])
        XCTAssertEqual(try told(), TVTold(stop: .disk), "the reservations warned of still told of once sent")
    }

    /// A row has one delete at a time. A second delete of a television's row, asked for while the first waits
    /// its turn behind a sending with no screen -- the action's, held at the television's create -- comes back
    /// with nil, as the first does once it has deleted the row unsent: waiting behind the first, the second
    /// would find the row gone and say it was made. The row carries a reason, so that the sending leaves it.
    func testASecondDeleteOfARowBeingDeletedIsNotSaidAsMade() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, television, door, store) = (home.model, home.television, home.door, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        try await store.queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        let held = turnedDown(forTheTelevision(waiting("サンプル紀行", startingIn: 180, programme: 4402)),
                              for: "前に断られた理由")
        try await store.queue(held)
        let client = ScalarClient(host: Bench.tvHost, transport: door, credentials: model.surroundings.tvCredentials)
        let theirs = try GuideStore(path: try model.guidePath())
        await door.hold(only: Self.tvCreate)
        let action = Task {
            await BackgroundWork.sendToTheTelevision(client: client, store: theirs, mac: nil, told: TVTold(),
                                                     nextRun: Date().addingTimeInterval(6 * 3600))
        }
        try await until("the action never reached the create") { await door.isHolding }
        let first = Task { await model.deleteWaiting(held) }
        // Long enough for the first delete to be waiting its turn before the second is asked for.
        try await Task.sleep(for: .milliseconds(300))
        let second = Task { await model.deleteWaiting(held) }
        try await Task.sleep(for: .milliseconds(300))
        await door.letGo()
        _ = await action.value

        let firstSaid = await first.value
        XCTAssertNil(firstSaid, "a reservation deleted unsent was said to be made")
        let secondSaid = await second.value
        XCTAssertNil(secondSaid, "a reservation the delete before it took away was said to be made")
        expectEqual(await television.schedules.map(\.eventId), [4401])
        expectEqual(try await store.pendingReservations(), [])
    }

    /// A delete that leaves none of the reservations a run with no screen warned of waiting takes that warning
    /// away and tells of them no more, the stop told kept; one that leaves one of them waiting changes
    /// nothing. Both are deleted unsent.
    func testADeleteForgetsTheWarningOnceNoneOfItsRowsWaits() async throws {
        let home = try await launch(with: NamedRecorder(1))
        let (model, store) = (home.model, home.store)
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let early = forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401))
        let late = forTheTelevision(waiting("サンプル紀行", startingIn: 150, programme: 4402))
        for row in [early, late] { try await store.queue(row) }
        let warned = TVTold(stop: .disk, rows: [early.id, late.id])
        model.defaults.set(try JSONEncoder().encode(warned), forKey: DefaultsKey.tvTold)
        func told() throws -> TVTold? {
            try model.defaults.data(forKey: DefaultsKey.tvTold).map { try JSONDecoder().decode(TVTold.self, from: $0) }
        }

        let earlySaid = await model.deleteWaiting(early)
        XCTAssertNil(earlySaid, "a reservation deleted unsent was said to be made")
        XCTAssertEqual(try told(), warned, "forgotten while a reservation warned of still waits")

        let lateSaid = await model.deleteWaiting(late)
        XCTAssertNil(lateSaid, "a reservation deleted unsent was said to be made")
        XCTAssertEqual(try told(), TVTold(stop: .disk), "the reservations warned of still told of once deleted")
        expectEqual(try await store.pendingReservations(), [])
    }

    /// Whether something begun in a task of its own has come back, for a test to look at meanwhile.
    @MainActor
    private final class Returned {
        var yes = false
    }

    /// The hour and minute a reservation starts in Japan, as a notice writes it: no leading zero.
    private func startInJapan(_ row: PendingReservation) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "H:mm"
        return formatter.string(from: row.request.start)
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
    ///
    /// `busyTimeout` is how long the app's writes to its cache wait for another connection's, in
    /// milliseconds, for a test that holds the cache's lock on purpose: the app's own five seconds unless
    /// said.
    private func launch(with recorder: any HTTPTransport, waiting rows: [PendingReservation] = [],
                        busyTimeout: Int32? = nil,
                        holding method: String? = nil) async throws -> Home {
        let bench = try aBench()
        if let busyTimeout { bench.storeBusyTimeoutMilliseconds = busyTimeout }
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

    /// A reservation waiting for the television on a station its list does not have, three hours ahead:
    /// every sending turns it down, with the reason for that.
    private func notListed(_ title: String, programme: Int) -> PendingReservation {
        var row = forTheTelevision(waiting(title, startingIn: 180, programme: programme))
        row.request.serviceID = 1032
        return row
    }

    /// The same reservation as its device turned it down before: with a reason on it, which is what offers
    /// 「もう一度送る」 on its row.
    private func turnedDown(_ row: PendingReservation, for reason: String) -> PendingReservation {
        var row = row
        row.problem = reason
        return row
    }

    /// The reason a television's round writes on a reservation that would stop another from recording, as
    /// it reads on the phone: known by how it begins, and the one reason sending again does not take off.
    /// The recording it names is invented.
    private static let wouldStop = "この予約を入れると、次の予約は録画されません: 「サンプル番組」（サンプルテレビ 10/6 21:00）。"
        + "「もう一度送る」を選ぶと、それでも予約します。"

    /// The station a programme of the cached guide is on, as the invented television lists one it receives.
    private func station(of program: GuideProgramRow) -> DemoTV.Station {
        DemoTV.Station(scheme: program.broadcasting == "bs" ? "isdbbs" : "isdbt", serviceID: program.serviceID,
                       name: program.serviceName)
    }

    /// What waits, a row to a line: the programme, the device it waits for, the mode by its code -- 100 is
    /// DR -- and the reason on it.
    private func waits(_ rows: [PendingReservation]) -> [String] {
        rows.map { row in
            "\(row.request.eventID ?? 0) for \(row.target.rawValue) in \(row.request.qualityCode), "
                + (row.problem ?? "no reason")
        }
    }
}
