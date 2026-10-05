import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// レコーダーを探す, pressed on a bench: the model as the app makes it at its first launch, with no recorder
/// saved, on a Wi-Fi the test invents (`Bench.joinWiFi`). The search looks round that Wi-Fi's addresses, which
/// are reserved for documentation, and its requests go to the bench's subnet and nowhere else: nothing is put
/// on the network the tests run on.
///
/// The first press on a phone raises the system's question about the local network, and the search begun by
/// it has come back with nothing after the reader allowed it. Why is not known, so the rule held here reads
/// nothing of the system's: a search that found nobody is made once more when the app has stopped being
/// active since the press and is active again, as it is once the question has gone -- once to a press, and
/// not at all for a search that found somebody or for an app that was active throughout. The tests tell the
/// model its phase as the first screen does.
@MainActor
final class ScanTests: XCTestCase {
    /// The addresses of the Wi-Fi a bench's phone is put on: a /24 without the network's own, the broadcast
    /// address and the phone's. A search asks each once.
    private let addresses = 253

    func testAPressFindsTheRecorderOnTheWiFi() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = bench.modelWithNoRecorder()
        await model.start()

        model.scanForRecorders()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertEqual(model.found.map(\.host), [Bench.host])
        XCTAssertEqual(model.found.first?.udn, NamedRecorder.udn(1))
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        XCTAssertFalse(model.scanBlocked)
        expectEqual(await subnet.asked, addresses, "each address of the subnet is asked once")
    }

    func testAPressThatFindsNobodySaysSo() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        let model = bench.modelWithNoRecorder()
        await model.start()

        model.scanForRecorders()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertEqual(model.scanOutcome?.text, "レコーダーが見つかりませんでした")
        XCTAssertEqual(model.found, [])
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "each address of the subnet is asked once")
    }

    // MARK: - once more, when the app has come back to being active since the press

    /// The first press as a phone has shown it: the recorder is there, and every request of the search is
    /// turned back, so that the search is over before the system's question has taken the app out of being
    /// active. Nothing found is held for the moment in which the question does, and is not said behind it;
    /// when the app is active again the search is made once more, a wait after that, and finds the recorder.
    func testASearchThatFoundNobodyIsMadeOnceMoreWhenTheAppIsActiveAgain() async throws {
        let bench = try aBench()
        let wait = Duration.milliseconds(200)
        bench.emptyScanHold = .milliseconds(500)
        bench.scanAgainDelay = wait
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingBack()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the first search never ended") { await subnet.asked == addresses }
        leave(model)
        // Well past the moment nothing found is held for and the wait after it: a search that did not wait
        // for the app to be active would have been made again by now.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNil(model.scanOutcome, "nothing found was said while the app was not active")
        XCTAssertNotNil(model.scanning, "the search was not shown as still going")
        expectEqual(await subnet.asked, addresses, "the search was made again before the app was active")

        await subnet.letThrough()
        let back = ContinuousClock.now
        comeBack(model)
        try await until("the second search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1), "nothing found was said, or the recorder not found")
        XCTAssertEqual(model.found.map(\.host), [Bench.host])
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses * 2, "each address is asked once more")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - back, wait,
                                    "the search was made again without the wait after the app is active")
    }

    /// Nobody there, and the app active from the press to the end: nothing found is said once the moment it is
    /// held for is over, and the search is not made again.
    func testNothingFoundWithTheAppActiveThroughoutIsSaidAfterAMomentAndNotSearchedAgain() async throws {
        let bench = try aBench()
        let moment = Duration.milliseconds(300)
        bench.emptyScanHold = moment
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)

        let pressed = ContinuousClock.now
        model.scanForRecorders()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - pressed, moment, "said before the moment was over")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "the search was made again with the app active throughout")
    }

    /// Nobody there, and the app away and back since the press: the second search finds nobody too, and that
    /// is said. A press has one more search and no third, however often the app comes back after it.
    func testNothingFoundASecondTimeIsSaidAndNotSearchedAThirdTime() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        comeBack(model)
        try await until("the search never ended", within: 3) { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses * 2, "each address is asked once more, and only once more")

        leave(model)
        comeBack(model)
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await subnet.asked, addresses * 2, "the search was made a third time")
        XCTAssertEqual(model.scanOutcome, .nothing)
    }

    /// The screen that asked goes away while the search waits for the app to be active again, as the tutorial
    /// does when it is closed: nothing more is sent, though the recorder would answer now, and nothing is said.
    func testLeavingTheScreenEndsASearchWaitingToBeMadeOnceMore() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingBack()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        try await until("the first search never ended") { await subnet.asked == addresses }
        // Well past the moment nothing found is held for: the search is waiting for the app to be active.
        try await Task.sleep(for: .milliseconds(300))
        model.stopScanning()
        XCTAssertNil(model.scanAwaitsActive, "the search was left waiting, for good if the app never came back")
        await subnet.letThrough()
        comeBack(model)
        try await Task.sleep(for: .milliseconds(300))

        expectEqual(await subnet.asked, addresses, "the search was made again after the screen had gone")
        XCTAssertNil(model.scanOutcome, "something was said after the screen had gone")
        XCTAssertEqual(model.found, [])
        XCTAssertNil(model.scanning)
    }

    /// A search that finds a recorder is as it was: said at once, with no moment's hold -- half a minute here,
    /// which the test does not wait out -- and not made again, though the app was away and back meanwhile.
    func testASearchThatFindsARecorderSaysSoAtOnceAndIsNotMadeAgain() async throws {
        let bench = try aBench()
        bench.emptyScanHold = .seconds(30)
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        comeBack(model)
        try await until("a search that found the recorder did not say so at once", within: 3) {
            model.scanOutcome != nil
        }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await subnet.asked, addresses, "the search was made again though it had found the recorder")
    }

    // MARK: - what a search leaves in the log

    /// The course of a first press as the log has it, for reading off a phone afterwards: the press, the end of
    /// the wait for the permission, each search with how its requests came back, each change of the app's
    /// phase meanwhile, that the search was to be made once more, and what was said. In counts and codes: no
    /// line has an address in it, nor anything the recorder said of itself.
    func testASearchWritesItsCourseToTheLogInCountsAndCodes() async throws {
        let bench = try aBench()
        bench.emptyScanHold = .milliseconds(500)
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingBack()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the first search never ended") { bench.scanLog.contains { $0.hasPrefix("first search") } }
        leave(model)
        try await until("the search never came to wait for the app to be active") { model.scanAwaitsActive != nil }
        await subnet.letThrough()
        comeBack(model)
        try await until("the second search never ended") { model.scanOutcome != nil }

        // How long a search took is the one thing in a line that is not the same at every run.
        let lines = bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }
        XCTAssertEqual(lines, [
            "press: 253 addresses to ask, the app active",
            "the wait for the permission is over: allowed",
            "first search: asked 253; answered []; timed out 0; failed []; other 253; recorders 0; some s",
            "phase: not active",
            "nothing found; the app stopped being active since the press, times: 1; not active now; "
                + "to be searched once more when active",
            "phase: active",
            "second search: asked 253; answered [200: 1]; timed out 0; failed []; other 252; recorders 1; some s",
            "said: found 1",
        ])
        let recorder = try XCTUnwrap(model.found.first)
        let itsOwn = ["192.0.2.", recorder.friendlyName, recorder.product, recorder.model, recorder.udn]
        for line in bench.scanLog {
            XCTAssertNil(itsOwn.first { !$0.isEmpty && line.contains($0) }, "in the log: \(line)")
        }
    }

    // MARK: - what the tests do

    /// A model at its first launch on the bench, started. Its search is stopped when the test is over, wherever
    /// it has got to: one left waiting for the app to be active would wait for good.
    private func aModel(on bench: Bench) async -> AppModel {
        let model = bench.modelWithNoRecorder()
        await model.start()
        addTeardownBlock { @MainActor in model.stopScanning() }
        return model
    }

    /// The app stops being active, as it does for as long as a question of the system's is up over it.
    private func leave(_ model: AppModel) {
        model.activeChanged(to: false)
    }

    /// The app is active again.
    private func comeBack(_ model: AppModel) {
        model.activeChanged(to: true)
    }
}
