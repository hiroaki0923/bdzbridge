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
/// well: what a row sent again from it came to, the device each waiting row says, and what is said under
/// them. And so is what the settings need: a television is taken away together with what waits for it.
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
        XCTAssertNil(model.queued, "the television's reservation is said to wait for the recorder")
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
        expectFalse(await model.takeTheTelevisionAway(), "a television that was busy was taken away")
        XCTAssertTrue(model.tvHost === host, "a television that was busy was let go of")
        XCTAssertNil(host.problem, "something was said of a television that was only busy")
        expectEqual(try await store.pendingReservations(), both, "a reservation went while the television was busy")
        await door.letGo()
        await reading.value
        let calls = await television.calls

        let writer = Writer(to: try model.guidePath())
        expectFalse(await model.takeTheTelevisionAway(), "taken away though what waits could not be deleted")
        writer.letGo()
        XCTAssertTrue(model.tvHost === host, "the television was taken away over reservations that stayed")
        XCTAssertNotNil(model.surroundings.tvCredentials.load(), "its registration went all the same")
        XCTAssertEqual(host.problem, "送信待ちの予約を削除できなかったため、テレビを外していません。"
                       + "少し待ってから、もう一度お試しください。")
        expectEqual(try await store.pendingReservations(), both)
        XCTAssertEqual(model.pending, both)

        expectTrue(await model.takeTheTelevisionAway(), "a television at rest was not taken away")

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
