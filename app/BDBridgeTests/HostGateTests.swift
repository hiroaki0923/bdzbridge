import Foundation
import Observation
import RecorderKit
import XCTest
@testable import BDBridge

/// What the app holds of each device, and says on each device's line, where no test looked before: what the
/// phone's own cache writes on the recorder's line, what a search and the phone's own work leave there, the
/// strip's sentence for another recorder, what a recorder let go of leaves behind, how old each device's list is
/// said to be, the routed entries with no television in play, and what the screens are told through the model's
/// names.
///
/// Gates, as `FunnelGateTests` and `ReservationGateTests` are: each pins what the app does today, and says so
/// where that is not what anybody would choose. A test asks only what a screen asks and reads only what a screen
/// reads, but where it says it stands for the reader's own press. Nothing here reads the clock or picks a
/// reservation of the demo's: a row waiting is of the test's own making, relative to now.
@MainActor
final class HostGateTests: XCTestCase {
    // MARK: - the phone's own cache, on the recorder's line

    /// The cache cannot be opened: a folder stands where its database would be. No connect is set going, by the
    /// first `start()` or by any after it, and the recorder's line says that the cache could not be opened, and
    /// goes on saying it. A connect asked by hand -- which stands for the reader's 再接続 on the screen that says
    /// the recorder is not connected -- goes through with no cache, and its attach takes that line away. The
    /// television's line is not touched by any of it.
    ///
    /// As it is today: the phone's own failure is written on the recorder's line, where the next thing the
    /// recorder answers takes it away.
    func testACacheThatCannotBeOpenedIsSaidOnTheRecordersLine() async throws {
        let bench = try aBench()
        try FileManager.default.createDirectory(atPath: bench.guidePath, withIntermediateDirectories: true)
        let recorder = NamedRecorder(1), television = DemoTV()
        let model = bench.model(recorder: recorder, television: television,
                                credentials: await registered(with: television))
        let host = try XCTUnwrap(model.tvHost, "the television saved was meant to be in play")
        host.problem = lineLeft

        await model.start()
        await model.start()

        XCTAssertNil(model.store, "a folder where the database would be was opened as one")
        XCTAssertEqual(bench.clientsMade, 0, "a connect was set going with no cache to connect over")
        let said = try XCTUnwrap(model.problem(for: .recorder), "nothing says the cache could not be opened")
        XCTAssertTrue(said.hasPrefix("番組表の保存領域を開けませんでした: "), "what is said instead: \(said)")
        XCTAssertEqual(model.problem(for: .tv), lineLeft, "the cache's failure wrote on the television's line")

        await model.connect()

        XCTAssertTrue(model.connected, "a connect asked for by hand did not go through with no cache")
        XCTAssertEqual(bench.clientsMade, 1)
        XCTAssertNil(model.store)
        XCTAssertNil(model.problem(for: .recorder), "the recorder's attach left the cache's sentence on its line")
        XCTAssertEqual(model.problem(for: .tv), lineLeft, "the recorder's attach wrote on the television's line")
    }

    /// The cache cannot be read: it was opened, and the app connected over it, and then its `meta` table was put
    /// out of the app's reach (`MetaOutOfReach`), until the test ends. A read of the guide from the cache says so
    /// on the recorder's line; the reservations' read, which goes through, takes it away -- not a connect, which
    /// cannot go through while whose cache this is cannot be read. The television's line is not touched.
    ///
    /// As it is today, as for a cache that cannot be opened.
    func testACacheThatCannotBeReadIsSaidOnTheRecordersLineUntilTheRecorderAnswers() async throws {
        let home = try await atHomeWithATelevision()
        let (bench, model, host) = (home.bench, home.model, home.host)
        clearTheLine(on: model)
        host.problem = lineLeft
        let outOfReach = MetaOutOfReach(in: bench.guidePath)
        addTeardownBlock { outOfReach.putBack() }

        await model.reloadFromCache()

        let said = try XCTUnwrap(model.problem(for: .recorder), "nothing says the cache could not be read")
        XCTAssertTrue(said.hasPrefix("番組表を読み込めませんでした: "), "what is said instead: \(said)")
        XCTAssertEqual(model.problem(for: .tv), lineLeft, "the cache's failure wrote on the television's line")

        let read = await readTheReservations(model)
        XCTAssertNotNil(read, "the recorder's list was meant to be read")

        XCTAssertNil(model.problem(for: .recorder), "the reservations' read left the cache's sentence on the line")
        XCTAssertEqual(model.problem(for: .tv), lineLeft, "the recorder's read wrote on the television's line")
    }

    // MARK: - a search, and the phone's own work

    /// レコーダーとテレビを探す, pressed with a line left on each device's line: the recorder's goes as the search
    /// begins, whatever it comes to -- here, with the phone on no Wi-Fi, that there is none to look round -- and
    /// the television's stays.
    ///
    /// As it is today: the search is the one thing of the phone's own that takes a device's line away, and it
    /// takes the recorder's alone.
    func testASearchTakesTheRecordersLineAwayAndLeavesTheTelevisions() async throws {
        let home = try await atHomeWithATelevision()
        let model = home.model
        leaveALine(on: model)
        home.host.problem = lineLeft

        model.scanForDevices()
        try await until("the search never said what it came to") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .noWiFi, "the phone was meant to be on no Wi-Fi")
        XCTAssertNil(model.problem(for: .recorder), "the search left the recorder's line")
        XCTAssertEqual(model.problem(for: .tv), lineLeft, "the search took the television's line away")
    }

    /// What the phone does with its own cache and queue leaves both devices' lines as they were: a reservation
    /// waiting for the recorder deleted, the queue read again, the guide read from the cache, and a channel
    /// hidden. A reservation waiting for the television deleted, with the television there to ask, leaves the
    /// recorder's line; the television's goes, taken away by the read of its list that the delete makes in the
    /// queue's turn, which went through.
    func testThePhonesOwnWorkLeavesBothLinesAsTheyWere() async throws {
        let home = try await atHomeWithATelevision()
        let (model, television) = (home.model, home.television)
        let store = try XCTUnwrap(model.store)
        let mine = waiting("サンプル紀行", startingIn: 180, programme: 4402)
        try await store.queue(mine)
        await model.loadPending()
        leaveALine(on: model)
        home.host.problem = lineLeft
        func bothLeft(by what: String, line: UInt = #line) {
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(what) took the recorder's line", line: line)
            XCTAssertEqual(model.problem(for: .tv), lineLeft, "\(what) took the television's line", line: line)
        }

        _ = await model.deleteWaiting(mine)
        expectEqual(try await store.pendingReservations().map(\.id), [], "the recorder's waiting row is still there")
        bothLeft(by: "a waiting row of the recorder's deleted")

        await model.loadPending()
        bothLeft(by: "the queue read again")

        await model.reloadFromCache()
        bothLeft(by: "the guide read from the cache")

        let channel = try XCTUnwrap(model.channels.first, "the cached guide was meant to list a channel")
        try await model.setChannelPreferences(broadcasting: model.broadcasting, hidden: [channel.serviceID])
        XCTAssertFalse(model.channels.contains { $0.serviceID == channel.serviceID }, "the channel was not hidden")
        bothLeft(by: "a channel hidden")

        let theirs = waiting("サンプル劇場", startingIn: 120, programme: 4401, for: .tv)
        try await store.queue(theirs)
        await model.loadPending()
        let calls = await television.calls.count

        _ = await model.deleteWaiting(theirs)

        expectEqual(try await store.pendingReservations().map(\.id), [], "the television's waiting row is still there")
        expectTrue(await television.calls.dropFirst(calls).contains { $0.hasPrefix("getScheduleList") },
                   "the television's delete read nothing of the television")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the television's waiting row took the recorder's line")
        XCTAssertNil(model.problem(for: .tv), "the read the television's delete made left the television's line")
    }

    /// A reservation waiting for `device`, of the test's own making: half an hour on the demo's first channel, in
    /// DR and not repeated, starting so many minutes from now, with `problem` as its reason when one is given.
    private func waiting(_ title: String, startingIn minutes: Double, programme: Int,
                         for device: DeviceSlot = .recorder, problem: String? = nil) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Date().addingTimeInterval(minutes * 60),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        var row = PendingReservation(request: request, serviceName: "サンプルテレビ", problem: problem)
        row.target = device
        return row
    }

    // MARK: - two sentences of the hosts

    /// What the strip says once another recorder has taken the last one's place, by its letters, and that the
    /// strip chooses it only while the app is connected: the line says that the lists were read again, which
    /// they were not if that recorder has gone quiet since. Here it is asked for its list and says nothing.
    func testTheStripsSentenceForAnotherRecorderIsChosenOnlyWhileConnected() async throws {
        XCTAssertEqual(AppModel.anotherTookOverLine, Said.anotherTookOver)

        let (_, recorder, model) = try await connectedHome()
        await recorder.become(2)
        await model.connect()
        try await untilIdle(model)
        XCTAssertTrue(model.anotherTookOver, "the recorder at the address was meant to be another")
        XCTAssertTrue(model.connected, model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.strip(), .anotherTookOver)

        await recorder.goQuiet(on: Ask.reservations)
        await model.loadReservations()

        XCTAssertTrue(model.gaveUp, "the recorder was meant to have gone quiet")
        XCTAssertTrue(model.anotherTookOver, "that another recorder answered went with the silence")
        XCTAssertFalse(model.connected)
        XCTAssertEqual(model.strip(), .recorderGaveUp,
                       "the lists are said to have been read again from a recorder gone")
    }

    /// Not connected, on each device's line: with a line left there and the device known to be away, the link's
    /// check before an operation has nothing to ask, and asks its host to say so. The recorder's line then says
    /// that the app is not connected to the recorder (`Said.notConnected`), and the television's that it is not
    /// connected to the television (`TVDriver.notConnected`), each leaving the other's line alone. The check is
    /// reached past every door of an operation (`makeSure`, and the television's link asked the same).
    ///
    /// Everywhere else in the app's tests the recorder's sentence is a result's reason: here it is the line's.
    func testNotConnectedIsWhatEachDevicesLineSaysWhenItsCheckHasNothingToAsk() async throws {
        let home = try await atHomeWithATelevision()
        let (recorder, television, model, link) = (home.recorder, home.television, home.model, home.link)
        await recorder.goQuiet(on: Ask.reservations)
        await model.loadReservations()
        XCTAssertTrue(model.offline, "the recorder was meant to be known to be away")
        leaveALine(on: model)
        let heard = await recorder.heard.count

        expectFalse(await makeSure(model), "a recorder known to be away was taken for one to ask")

        XCTAssertEqual(model.problem(for: .recorder), Said.notConnected)
        expectEqual(await recorder.heard(since: heard), [], "a recorder known to be away was asked")

        await television.goSilent()
        expectFalse(await link.ensureUp(evenIfRecent: true), "a television that said nothing was taken for one to ask")
        XCTAssertTrue(link.session.gaveUp, "the television was meant to be known to be away")
        home.host.problem = lineLeft
        let calls = await television.calls.count

        expectFalse(await link.ensureUp(evenIfRecent: true), "a television known to be away was taken for one to ask")

        XCTAssertEqual(model.problem(for: .tv), TVDriver.notConnected)
        XCTAssertEqual(model.problem(for: .recorder), Said.notConnected,
                       "the television's check wrote the recorder's line")
        expectEqual(await television.calls.count, calls, "a television known to be away was asked")
    }

    // MARK: - a recorder let go of

    /// The recorder let go of by hand (`forgetTheRecorder`, as the gate of a write across a let-go calls it: no
    /// screen gets here with a read out, the choice of a recorder being held while one is), with its recordings'
    /// read out. What no other test looks at goes with it: when the list was read, and how many candidates a scan
    /// left out unread. The read out is still counted while it is out, and what it brings back is not kept. The
    /// count of reservations held for another recorder, which the strip said before, is said afresh by the next
    /// sending, and once.
    func testWhatARecorderLetGoOfByHandLeavesBehind() async throws {
        let (recorder, model) = try await everythingRead()
        await recorder.hold(only: Ask.recordings)
        let before = await recorder.asked
        let reading = Task { await model.refreshTitles() }
        try await until("the recordings were never asked for") {
            await recorder.asked(Ask.recordings, since: before) == 1
        }
        let counted = model.titleReads
        XCTAssertGreaterThan(counted, 0, "the read out was meant to be counted")

        model.forgetTheRecorder()

        XCTAssertNil(model.reservationsRead, "when the last recorder's list was read stayed")
        XCTAssertEqual(model.unreadDuplicates, 0, "what the last recorder's scan left unread stayed")
        XCTAssertEqual(model.titleReads, counted, "the read out on the recorder let go of is no longer counted")
        XCTAssertNil(model.queueReport, "what the strip said of the last recorder's queue stayed")
        await recorder.letGo()
        await reading.value
        XCTAssertEqual(model.titleReads, 0)
        XCTAssertTrue(model.titles.isEmpty, "the recordings read for the recorder let go of were kept")
        XCTAssertFalse(model.titlesLoaded)

        await reconnect(model)
        XCTAssertEqual(model.queueReport, Said.heldBack(1), "the count held for another recorder was not said afresh")
    }

    /// The same when another recorder describes itself on a connect (`anotherDeviceDescribedItself`): looked at
    /// while that connect is held at its read of the newcomer's list, and so before anything of the newcomer's is
    /// read. The read of the recordings out on the last one is still counted, and what it brings back is not
    /// kept; the newcomer's attach says the count held for another recorder afresh, and once.
    func testWhatARecorderLetGoOfForAnotherOnAConnectLeavesBehind() async throws {
        let (recorder, model) = try await everythingRead()
        await recorder.hold(only: Ask.recordings)
        let before = await recorder.asked
        let reading = Task { await model.refreshTitles() }
        try await until("the recordings were never asked for") {
            await recorder.asked(Ask.recordings, since: before) == 1
        }
        let counted = model.titleReads
        XCTAssertGreaterThan(counted, 0, "the read out was meant to be counted")
        await recorder.become(2)
        await recorder.holdTheNext(Ask.reservations)
        let connecting = Task { await model.connect() }
        try await until("the newcomer's list was never asked for") {
            await recorder.asked(Ask.reservations, since: before) == 1
        }

        XCTAssertTrue(model.anotherTookOver, "the recorder at the address was meant to be another")
        XCTAssertNil(model.reservationsRead, "when the last recorder's list was read stayed")
        XCTAssertEqual(model.unreadDuplicates, 0, "what the last recorder's scan left unread stayed")
        XCTAssertEqual(model.titleReads, counted, "the read out on the recorder let go of is no longer counted")
        await recorder.letGo(only: Ask.recordings)
        await reading.value
        XCTAssertTrue(model.titles.isEmpty, "the recordings read for the recorder let go of were kept")
        XCTAssertFalse(model.titlesLoaded)

        await recorder.letGo()
        await connecting.value
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.queueReport, Said.heldBack(1), "the count held for another recorder was not said afresh")
    }

    /// A write out on the recorder as it is let go of by hand (`forgetTheRecorder`, as the gates of a write
    /// across a let-go call it: a choice cannot be made while a line is up): the write's line stays up until its
    /// request ends, and the recorder is busy for its buttons until then.
    ///
    /// As it is today. A television's lines come down at once as its host is let go of (`TVReservationTests`).
    func testTheLineOfAWriteOutOnTheRecorderLetGoOfStaysUpUntilItEnds() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        addTeardownBlock { await recorder.letGo() }
        await model.loadTitles()
        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        await recorder.hold(only: Ask.changeRecording)
        let before = await recorder.asked
        let protecting = Task { await protectARecording(model, title, true) }
        try await until("the protect was never sent") {
            await recorder.asked(Ask.changeRecording, since: before) == 1
        }
        let line = try XCTUnwrap(model.busy, "the protect has no line up")

        model.forgetTheRecorder()

        XCTAssertEqual(model.busy, line, "the line of a write still out went with the recorder")
        XCTAssertTrue(model.isBusy(for: .recorder), "the recorder's buttons were let go with a write still out")
        await recorder.letGo()
        _ = await protecting.value
        XCTAssertNil(model.busy)
        XCTAssertFalse(model.isBusy(for: .recorder))
    }

    /// At home with the first recorder, everything of it read that a recorder let go of leaves: its reservations,
    /// its recordings with one broadcast on its disk twice, its keyword conditions, a scan for duplicates that
    /// could not read one of the two copies' texts, and a reservation held for another recorder, which a
    /// pull-down has said on the strip. Whatever a test holds of the recorder is let go as it ends.
    private func everythingRead() async throws -> (recorder: NamedRecorder, model: AppModel) {
        let (_, recorder, model) = try await connectedHome(guide: false)
        addTeardownBlock { await recorder.letGo() }
        await recorder.haveACopy()
        await model.loadTitles()
        await model.loadRecorderRules()
        await recorder.answer(Ask.details, with: .fault(402))
        model.startDuplicateScan()
        try await until("the scan never ended") { !model.jobRunning }
        XCTAssertGreaterThan(model.unreadDuplicates, 0, "the scan was meant to leave a copy unread")
        let store = try XCTUnwrap(model.store)
        try await store.queue(waiting("サンプル紀行", startingIn: 180, programme: 4402,
                                      problem: Said.heldForAnotherRecorder))
        await model.refreshReservations()
        XCTAssertEqual(model.queueReport, Said.heldBack(1), "the reservation held was not said on the strip")
        XCTAssertNotNil(model.reservationsRead)
        XCTAssertFalse(model.recorderRules.isEmpty)
        return (recorder, model)
    }

    // MARK: - how old a list is, and the routed entries

    /// Since when each device's list is old, by one rule for both, row by row: nil with no rows; nil while the
    /// device can be asked; nil while a connect to a device that answered last time is out; and the time the list
    /// was read while the device answers and cannot be asked -- the recorder connected from the attach before a
    /// reconnect it answered busy at the door, the television to be registered again -- and once it has been
    /// given up on after silence. In each row the recorder's (`reservationsStaleSince`) and the television's
    /// (`TVHost.staleSince`) are the same, nil or the read's own time.
    func testHowOldEachDevicesListIsGoesByOneRuleForBoth() async throws {
        let empty = NamedRecorder.Answer.result("<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\"></xsrs>")
        let home = try await atHomeWithATelevision(answering: empty)
        let (recorder, television, model, host, link) = (home.recorder, home.television, home.model, home.host,
                                                         home.link)
        func row(_ name: String, old: Bool, line: UInt = #line) {
            if old {
                XCTAssertNotNil(model.reservationsRead, name, line: line)
                XCTAssertEqual(model.reservationsStaleSince, model.reservationsRead, "the recorder's, \(name)",
                               line: line)
                XCTAssertNotNil(host.reservationsRead, name, line: line)
                XCTAssertEqual(host.staleSince, host.reservationsRead, "the television's, \(name)", line: line)
            } else {
                XCTAssertNil(model.reservationsStaleSince, "the recorder's, \(name)", line: line)
                XCTAssertNil(host.staleSince, "the television's, \(name)", line: line)
            }
        }
        func bothGiveUp() async {
            await recorder.goQuiet(for: 1)
            expectFalse(await makeSure(model), "a recorder that said nothing was taken for one to ask")
            await television.goSilent()
            expectFalse(await link.ensureUp(evenIfRecent: true), "a television that said nothing was taken for one")
            XCTAssertTrue(model.gaveUp && link.session.gaveUp, "a device was meant to be given up on")
        }

        // No rows, read and then given up on.
        XCTAssertTrue(model.reservations.isEmpty && host.reservations.isEmpty, "a device was meant to list nothing")
        await bothGiveUp()
        row("no rows", old: false)

        // Back, with rows: both can be asked.
        await television.goSilent(false)
        await television.put([DemoTV.Schedule(id: "recording.41", start: Date().addingTimeInterval(7200))])
        await model.refreshReservations()
        await host.refreshReservations()
        XCTAssertTrue(model.connected && link.session.connected, "a device did not come back")
        XCTAssertFalse(model.reservations.isEmpty || host.reservations.isEmpty, "a device was meant to list rows")
        row("can be asked", old: false)

        // A connect out to each, which answered last time.
        let count = await recorder.heard.count
        await recorder.hold(only: Ask.description)
        let connecting = Task { await model.connect() }
        try await until("the recorder's connect was never out") {
            await recorder.heard(since: count).contains(Ask.description)
        }
        await home.door.hold(only: "getSystemSupportedFunction")
        let reaching = Task { await link.connect() }
        try await until("the television's connect was never out") { await home.door.isHolding }
        row("a connect out to a device that answered last time", old: false)
        await recorder.letGo()
        await home.door.letGo()
        await connecting.value
        await reaching.value
        row("connected again", old: false)

        // Given up on after silence.
        await bothGiveUp()
        row("given up on", old: true)

        // Back, and then answering but not to be asked.
        await television.goSilent(false)
        await model.refreshReservations()
        await host.refreshReservations()
        XCTAssertTrue(model.connected && link.session.connected, "a device did not come back")
        await recorder.busyAtTheDoor()
        await model.connect()
        XCTAssertTrue(model.connected && !model.offline, "the recorder was meant to stay connected, answering busy")
        home.credentials.save(TVCredentials(clientID: "BDBridge:test", cookie: "run out"))
        await host.loadReservations()
        XCTAssertEqual(model.tvDriver?.facts.needsPairing, true, "the television was meant to want registering again")
        row("answering and not to be asked", old: true)
        await recorder.comeFree()
    }

    /// The routed entries with no television in play -- taken away, its rows still in hand -- and the recorder:
    /// a reservation on the television, a change and a delete of a television's reservation are not done, the
    /// app not being connected to it; a waiting row of the television's sent again comes to nothing; and the
    /// delete of such a row does nothing, the row still in the phone's queue, a television let go of counting as
    /// busy. The recorder is asked nothing for any of them, not made sure of, and its line is left.
    ///
    /// And on a model not yet started, with a television saved: a television's change, delete and sending again
    /// leave the cache unopened, and a reservation on it opens it.
    ///
    /// As it is today: what opens the cache first differs between the television's entries.
    func testWithNoTelevisionInPlayItsRowsAreTurnedAwayAndTheRecorderIsLeftAlone() async throws {
        let schedule = DemoTV.Schedule(id: "recording.41", start: Date().addingTimeInterval(7200))
        let home = try await atHomeWithATelevision(holding: [schedule])
        let (recorder, model) = (home.recorder, home.model)
        let store = try XCTUnwrap(model.store)
        let program = try await aProgramme(model)
        let reservation = try XCTUnwrap(home.host.reservations.first, "the television's list was meant to be read")
        let theirs = waiting("サンプル劇場", startingIn: 120, programme: 4401, for: .tv)
        try await store.queue(theirs)
        await model.loadPending()
        model.removeTV()
        XCTAssertNil(model.tvHost, "the television was meant to be taken away")
        leaveALine(on: model)
        let heard = await recorder.heard.count

        expectEqual(await model.reserve(program, on: .tv, quality: "DR", repeating: "none"),
                    .notDone(TVDriver.notConnected))
        expectEqual(await model.change(reservation, quality: "DR", repeating: "none"), .notDone(TVDriver.notConnected))
        expectEqual(await model.cancel(reservation), .notDone(TVDriver.notConnected))
        expectNil(await model.resend(theirs))
        expectNil(await model.deleteWaiting(theirs))

        expectEqual(try await store.pendingReservations().map(\.id), [theirs.id],
                    "a row of a television let go of was taken off the phone")
        expectEqual(await recorder.heard(since: heard), [], "the recorder was asked on a television's account")
        XCTAssertFalse(isMakingSure(model))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a television's entry wrote the recorder's line")

        // A model not yet started, with a television saved.
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        let fresh = bench.model(recorder: SilentRecorder(), television: television,
                                credentials: await registered(with: television))
        _ = await fresh.change(reservation, quality: "DR", repeating: "none")
        XCTAssertNil(fresh.store, "a television's change opened the cache")
        _ = await fresh.cancel(reservation)
        XCTAssertNil(fresh.store, "a television's delete opened the cache")
        _ = await fresh.resend(theirs)
        XCTAssertNil(fresh.store, "a television's row sent again opened the cache")
        _ = await fresh.reserve(program, on: .tv, quality: "DR", repeating: "none")
        XCTAssertNotNil(fresh.store, "a reservation on the television did not open the cache")
        // The first connect that reservation set going, over before the test is.
        try await untilGivenUp(fresh)
        try await untilTheTelevisionIsConnected(fresh)
    }

    // MARK: - what the screens are told

    /// What a screen reads of the recorder through the model's names is told of a change to it, as Observation
    /// tells a view (`withObservationTracking`): the recorder's list, its recordings, its keyword conditions, the
    /// job, what the strip says of its queue and its line, each when what was read or done is kept -- and every one
    /// of them when the recorder is let go of. Each value here does change, so that what is told is the change and
    /// not only the write.
    func testWhatTheScreensReadOfTheRecorderIsToldOfAChange() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        addTeardownBlock { await recorder.letGo() }
        XCTAssertFalse(model.reservations.isEmpty, "the demo was meant to list reservations")

        await recorder.answer(Ask.reservations, with: .result("<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\"></xsrs>"))
        var told = watching { _ = model.reservations }
        _ = await readTheReservations(model)
        XCTAssertTrue(model.reservations.isEmpty, "the list read was meant to be empty")
        XCTAssertTrue(told.yes, "a screen that read the recorder's list was not told of the list kept")

        told = watching { _ = model.titles }
        await model.loadTitles()
        XCTAssertFalse(model.titles.isEmpty, "the demo was meant to list recordings")
        XCTAssertTrue(told.yes, "a screen that read the recordings was not told of the list kept")

        told = watching { _ = model.recorderRules }
        await model.loadRecorderRules()
        XCTAssertFalse(model.recorderRules.isEmpty, "the demo was meant to list keyword conditions")
        XCTAssertTrue(told.yes, "a screen that read the keyword conditions was not told of the list kept")

        told = watching { _ = model.job }
        model.startDuplicateScan()
        try await until("the scan never ended") { !model.jobRunning }
        XCTAssertNotNil(model.job, "the scan was meant to leave its job")
        XCTAssertTrue(told.yes, "a screen that read the job was not told of the scan")

        let store = try XCTUnwrap(model.store)
        try await store.queue(waiting("サンプル紀行", startingIn: 180, programme: 4402,
                                      problem: Said.heldForAnotherRecorder))
        told = watching { _ = model.flushReport }
        await model.refreshReservations()
        XCTAssertEqual(model.flushReport, Said.heldBack(1), "the reservation held was not said on the strip")
        XCTAssertTrue(told.yes, "a screen that read the strip's report was not told of what a sending said")
        XCTAssertFalse(model.reservations.isEmpty, "the pull-down was meant to read the demo's list again")

        leaveALine(on: model)
        told = watching { _ = model.problem(for: .recorder) }
        _ = await readTheReservations(model)
        XCTAssertNil(model.problem(for: .recorder), "the read that went through left the line")
        XCTAssertTrue(told.yes, "a screen that read the recorder's line was not told that it was taken away")

        leaveALine(on: model)
        let watched: [(String, Told)] = [
            ("the reservations", watching { _ = model.reservations }),
            ("the recordings", watching { _ = model.titles }),
            ("the keyword conditions", watching { _ = model.recorderRules }),
            ("the job", watching { _ = model.job }),
            ("the strip's report", watching { _ = model.flushReport }),
            ("the line", watching { _ = model.problem(for: .recorder) }),
        ]
        model.forgetTheRecorder()
        for (what, told) in watched {
            XCTAssertTrue(told.yes, "a screen that read \(what) was not told that the recorder was let go of")
        }
        XCTAssertTrue(model.reservations.isEmpty && model.titles.isEmpty && model.recorderRules.isEmpty)
        XCTAssertNil(model.job)
        XCTAssertNil(model.flushReport)
    }

    /// Whether what `read` read has been told of a change since: set by Observation, from whichever thread makes
    /// the change, and read by the test.
    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var told = false
        var yes: Bool { lock.withLock { told } }
        func tell() { lock.withLock { told = true } }
    }

    /// Reads what `read` reads as a view does, and hands back what says whether that was told of a change since.
    private func watching(_ read: () -> Void) -> Told {
        let told = Told()
        withObservationTracking(read, onChange: { told.tell() })
        return told
    }

    // MARK: - the links' wait for the permission

    /// A recorder silent at its address on a phone the system keeps off the local network: a connect waits for
    /// the permission in place of saying that the recorder did not answer (`connectBlocked`), and the model's wait
    /// is begun once. A delete pressed meanwhile is not sent: it says that the local network is not allowed, and
    /// the line, which the link took down as it began to wait, stays empty. The wait ends with a connect that went
    /// through, and with the recorder let go of: when the permission comes after either, nothing is connected to.
    ///
    /// The bench's wait, like the one at an address given for a television, lasts until the test ends it, as a
    /// real one ends when its task is: that a wait was ended is seen in what its end does not set going.
    func testARecorderKeptOffTheLocalNetworkWaitsForThePermissionUntilAConnectOrALetGo() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let free = try await programmesNotReserved(model, 1)
        let program = try XCTUnwrap(free.first)
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"),
                   whyNotJustNow(model) ?? "the reservation was not made")
        let row = try XCTUnwrap(model.reservation(for: program), "the reservation made was meant to be listed")
        bench.linksAreKeptOff = true
        await recorder.goQuiet(for: 1_000)
        leaveALine(on: model)

        await model.connect()

        guard model.connectBlocked else { return XCTFail("a recorder silent behind the permission was not waited for") }
        try await until("the model's wait for the permission was never begun") {
            !bench.linksPermissionWaits.isEmpty
        }
        XCTAssertEqual(bench.linksPermissionWaits, [Bench.host])
        let heard = await recorder.heard.count

        expectEqual(await model.cancel(row), .notDone(LocalNetwork.accessNotAllowed))

        expectEqual(await recorder.heard(since: heard), [], "the delete was sent while the permission was waited for")
        XCTAssertNil(model.problem(for: .recorder), "a line stands while the permission is waited for")
        XCTAssertEqual(bench.linksPermissionWaits, [Bench.host], "the permission was waited for again")

        // Ended by a connect that went through.
        await recorder.goQuiet(for: 0)
        await reconnect(model)
        XCTAssertFalse(model.connectBlocked)
        var made = bench.clientsMade
        bench.theLinksPermissionComes()
        await letTheEndOfAWaitRun()
        XCTAssertEqual(bench.clientsMade, made, "the permission coming after a connect set another going")

        // Ended by the recorder let go of.
        await recorder.goQuiet(for: 1_000)
        await model.connect()
        guard model.connectBlocked else { return XCTFail("the recorder was meant to be waited for again") }
        try await until("the model's wait was never begun again") { bench.linksPermissionWaits.count > 1 }
        XCTAssertEqual(bench.linksPermissionWaits, [Bench.host, Bench.host])
        model.forgetTheRecorder()
        made = bench.clientsMade
        bench.theLinksPermissionComes()
        await letTheEndOfAWaitRun()
        XCTAssertEqual(bench.clientsMade, made, "the permission coming after a let-go set a connect going")
    }

    /// The same of a television's link: silent at its address on a phone the system keeps off the local network,
    /// its connect waits for the permission, and its host's wait is begun once. The wait ends with a connect that
    /// went through, and with the television taken away: when the permission comes after either, the television
    /// is not connected to.
    func testATelevisionKeptOffTheLocalNetworkWaitsForThePermissionUntilAConnectOrALetGo() async throws {
        let home = try await atHomeWithATelevision()
        let (bench, television, model, link) = (home.bench, home.television, home.model, home.link)
        bench.linksAreKeptOff = true
        await television.goSilent()

        await link.connect()

        guard link.session.connectBlocked else {
            return XCTFail("a television silent behind the permission was not waited for")
        }
        try await until("the host's wait for the permission was never begun") {
            !bench.linksPermissionWaits.isEmpty
        }
        XCTAssertEqual(bench.linksPermissionWaits, [Bench.tvHost])

        // Ended by a connect that went through.
        await television.goSilent(false)
        await link.connect()
        XCTAssertTrue(link.session.connected, "the television did not come back")
        XCTAssertFalse(link.session.connectBlocked)
        var made = bench.televisionTransportsMade.count
        bench.theLinksPermissionComes()
        await letTheEndOfAWaitRun()
        XCTAssertEqual(bench.televisionTransportsMade.count, made,
                       "the permission coming after a connect set another going")

        // Ended by the television taken away.
        await television.goSilent()
        await link.connect()
        guard link.session.connectBlocked else { return XCTFail("the television was meant to be waited for again") }
        try await until("the host's wait was never begun again") { bench.linksPermissionWaits.count > 1 }
        XCTAssertEqual(bench.linksPermissionWaits, [Bench.tvHost, Bench.tvHost])
        model.removeTV()
        made = bench.televisionTransportsMade.count
        bench.theLinksPermissionComes()
        await letTheEndOfAWaitRun()
        XCTAssertEqual(bench.televisionTransportsMade.count, made,
                       "the permission coming after the television was taken away set a connect going")
    }

    /// Lets what the end of a wait for the permission sets going -- a connect, from a wait nobody ended -- come as
    /// far as making its client: the wait's task resumes on the main actor after a turn elsewhere, and is given
    /// that many turns, as the gates of a run give one to get to its wait.
    private func letTheEndOfAWaitRun() async {
        for _ in 0..<10_000 { await Task.yield() }
    }

    // MARK: - what the tests start from

    /// At home with the first recorder at `Bench.host` and a television, both connected to and nothing under way:
    /// the guide cached, and each device's reservations read by its connect. The television receives the station
    /// the waiting rows of these tests are on, holds `rows`, and answers through a door a test can hold
    /// (`HeldTelevision`); `list`, when given, is what the recorder answers its connect's read of its list with.
    /// Whatever a test held of either is let go as the test ends, however it ends.
    private func atHomeWithATelevision(holding rows: [DemoTV.Schedule] = [],
                                       answering list: NamedRecorder.Answer? = nil) async throws -> Home {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        if let list { await recorder.answer(Ask.reservations, with: list) }
        let television = DemoTV()
        await television.receives([DemoTV.Station()])
        await television.put(rows)
        let door = HeldTelevision(television, holding: false)
        addTeardownBlock {
            await door.letGo()
            await recorder.letGo()
        }
        let credentials = await registered(with: television)
        let model = bench.model(recorder: recorder, television: door, credentials: credentials)
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        return Home(bench: bench, recorder: recorder, television: television, door: door, credentials: credentials,
                    model: model, host: try XCTUnwrap(model.tvHost), link: try XCTUnwrap(model.tv))
    }

    private struct Home {
        let bench: Bench
        let recorder: NamedRecorder
        let television: DemoTV
        let door: HeldTelevision
        let credentials: MemoryTVCredentials
        let model: AppModel
        let host: TVHost
        let link: DeviceLink
    }
}
