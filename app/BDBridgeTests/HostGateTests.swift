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
