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
