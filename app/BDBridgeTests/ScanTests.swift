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
/// not at all for a search that found somebody or for an app that was active throughout. The press is carried
/// across the question and across nothing else: not across a visit to the background, where the question
/// never sends the app, and not to a Wi-Fi of other addresses than the press's. The tests tell the model its
/// phase as the first screen does.
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

    /// On no Wi-Fi a press says so and asks nobody, and that is the end of it: no search is under way
    /// afterwards.
    func testAPressWithNoWiFiSaysSoAndIsOver() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        bench.leaveWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the press never said anything") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .noWiFi)
        XCTAssertNil(model.scanning, "the button was held back with nothing to look round")
        expectEqual(await subnet.asked, 0, "the addresses of a Wi-Fi the phone has left were asked")
        XCTAssertEqual(bench.scanLog, ["press: no Wi-Fi to look round"])
        expectNoSearchUnderWay(model, on: bench)
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

    /// Whether the app has stopped being active is counted from the press. It was away and back before this
    /// one, as it nearly always has been by the time anybody presses, and is active from the press to the
    /// end: nobody there is said after one search.
    func testAPressAfterTheAppWasAwayAndBackIsNotSearchedAgainForThat() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)
        leave(model)
        comeBack(model)

        model.scanForRecorders()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing)
        expectEqual(await subnet.asked, addresses,
                    "the search was made again for the app having been away before the press")
    }

    /// And each press has the one more search to itself. The first press's search is made once more, the app
    /// having stopped being active over it; then the app is at the home screen and back, which is none of the
    /// next press's business; and the second press's search is made once more as well, the app having
    /// stopped being active over that one too.
    func testEachPressHasItsOwnOneMoreSearch() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        comeBack(model)
        try await until("the first press's search was not made once more", within: 3) {
            await subnet.asked == addresses * 2
        }
        try await until("the first press's search never ended", within: 3) { model.scanOutcome != nil }
        XCTAssertEqual(model.scanOutcome, .nothing)
        goToTheBackground(model)
        comeBack(model)

        model.scanForRecorders()
        leave(model)
        comeBack(model)
        try await until("the second press's search was not made once more", within: 3) {
            await subnet.asked == addresses * 4
        }
        // The second press has cleared what the first said by now, so this is its own.
        try await until("the second press's search never ended", within: 3) { model.scanOutcome != nil }
        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses * 4, "two searches to each press, and no more")
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
        let search = try XCTUnwrap(model.scanTask)
        model.stopScanning()
        XCTAssertNil(model.scanAwaitsActive, "the search was left waiting, for good if the app never came back")
        try await within(2, "the search that was stopped never ended") { await search.value }
        await subnet.letThrough()
        comeBack(model)
        try await Task.sleep(for: .milliseconds(300))

        expectEqual(await subnet.asked, addresses, "the search was made again after the screen had gone")
        XCTAssertNil(model.scanOutcome, "something was said after the screen had gone")
        XCTAssertEqual(model.found, [])
        XCTAssertNil(model.scanning)
    }

    /// Another press while a search waits for the app to be active takes its place. The search that waited is
    /// over -- its task ends, where one that was only cancelled would wait for good -- and the new press has a
    /// search of its own: the app stopped being active before that press and not since, so nobody there is
    /// said after one look, and the first press's one more is not made when the app is active again.
    func testAnotherPressEndsASearchWaitingToBeMadeOnceMore() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        try await until("the search never came to wait for the app to be active") { model.scanAwaitsActive != nil }
        let first = try XCTUnwrap(model.scanTask)
        model.scanForRecorders()
        try await within(2, "the search another press took the place of never ended") { await first.value }
        try await until("the second press's search never ended", within: 3) {
            await subnet.asked == addresses * 2 && model.scanOutcome != nil
        }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        comeBack(model)
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await subnet.asked, addresses * 2, "the first press's search was made once more after all")
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

    // MARK: - carried across the system's question, and across nothing else

    /// The app goes to the background while a search waits for it to be active: the home screen, with the
    /// question still up or after it. The question never sends the app there, and what the app comes back to
    /// from there can be another network at any time, so the press is not carried across it. Nothing found is
    /// said there and then, as the press's own search left it, without the wait there would be after the app
    /// became active -- half a minute here, which the test does not wait out.
    func testAVisitToTheBackgroundEndsASearchWaitingToBeMadeOnceMore() async throws {
        let bench = try aBench()
        bench.scanAgainDelay = .seconds(30)
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        try await until("the search never came to wait for the app to be active") { model.scanAwaitsActive != nil }
        goToTheBackground(model)
        try await until("nothing found was not said when the app went to the background", within: 3) {
            model.scanOutcome != nil
        }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        XCTAssertNil(model.scanAwaitsActive, "the search was left waiting for the app to be active")
        expectEqual(await subnet.asked, addresses, "the search was made again after a visit to the background")
        XCTAssertEqual(bench.scanLog.suffix(3), [
            "phase: background",
            "nothing found; the app went to the background since the press; not searched again",
            "said: nothing found",
        ])
    }

    /// The same while nothing found is still being held: it is said when that moment is over, with the app
    /// still in the background, and not kept for the app to be active again. Nor is the search made again
    /// once it is.
    func testAVisitToTheBackgroundWhileNothingFoundIsHeldEndsTheCarryingToo() async throws {
        let bench = try aBench()
        bench.emptyScanHold = .milliseconds(300)
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the first search never ended") { await subnet.asked == addresses }
        goToTheBackground(model)
        try await until("nothing found was not said with the app in the background", within: 3) {
            model.scanOutcome != nil
        }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        XCTAssertNil(model.scanAwaitsActive, "the search was left waiting for the app to be active")
        comeBack(model)
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await subnet.asked, addresses, "the search was made again after a visit to the background")
    }

    /// And the same in the wait after the app is active again: the question answered, and the home screen
    /// within the second. The search is not made in the background, nor when the app comes back from it,
    /// though the recorder would answer now.
    func testAVisitToTheBackgroundOnceTheAppIsActiveAgainEndsTheCarryingToo() async throws {
        let bench = try aBench()
        bench.scanAgainDelay = .seconds(1)
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingBack()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        try await until("the search never came to wait for the app to be active") { model.scanAwaitsActive != nil }
        await subnet.letThrough()
        comeBack(model)
        // Into the wait after the app is active, and well short of its end.
        try await Task.sleep(for: .milliseconds(100))
        goToTheBackground(model)
        try await until("the search never ended", within: 3) { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing, "the search was made again after a visit to the background")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        comeBack(model)
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await subnet.asked, addresses, "the search was made again after a visit to the background")
    }

    /// The phone has left its Wi-Fi by the time the search is to be made once more. The interfaces are read
    /// again before it, as they are after the wait for the permission: with none, it says there is no Wi-Fi
    /// rather than ask the addresses of the press, and no search is under way afterwards.
    func testASearchIsNotMadeOnceMoreWithTheWiFiGone() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingBack()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        try await until("the search never came to wait for the app to be active") { model.scanAwaitsActive != nil }
        await subnet.letThrough()
        bench.leaveWiFi()
        comeBack(model)
        try await until("the search never ended", within: 3) { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .noWiFi)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "the addresses of a Wi-Fi the phone has left were asked")
        XCTAssertEqual(bench.scanLog.last, "no Wi-Fi left to look round")
        expectNoSearchUnderWay(model, on: bench)
    }

    /// The phone is on another Wi-Fi by then, of other addresses, as after a change made in Control Centre,
    /// which leaves the app where it is. The addresses of the press are another network's now and are not
    /// asked there: what the press's own search came to is said.
    func testASearchIsNotMadeOnceMoreOnAnotherWiFi() async throws {
        let bench = try aBench()
        let home = bench.joinWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        leave(model)
        try await until("the search never came to wait for the app to be active") { model.scanAwaitsActive != nil }
        let elsewhere = bench.joinWiFi(as: Bench.phoneElsewhere)
        comeBack(model)
        try await until("the search never ended", within: 3) { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await home.asked, addresses, "each address of the press's Wi-Fi is asked once")
        expectEqual(await elsewhere.asked, 0, "the addresses of the press were asked on another Wi-Fi")
        XCTAssertEqual(bench.scanLog.suffix(2), [
            "other addresses than at the press; not searched again",
            "said: nothing found",
        ])
    }

    // MARK: - the wait for the local network permission

    /// The system's question is up when a search comes to it. The search waits there: nobody is asked behind
    /// the question, and the screen says what is in the way with the search still going. Allowed, the search
    /// is made and finds the recorder.
    func testASearchWaitsForThePermissionBeforeItAsksAnybody() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        // Long enough for a search that went on behind the question to have asked.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.scanBlocked, "the screen stopped saying the permission is in the way")
        XCTAssertNotNil(model.scanning, "the search was not shown as still going")
        XCTAssertNil(model.scanOutcome, "something was said behind the system's question")
        expectEqual(await subnet.asked, 0, "somebody was asked behind the system's question")

        bench.letThePermissionGo(allowed: true)
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked, "the screen still says the permission is in the way")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "each address of the subnet is asked once")
    }

    /// The wait ends without the permission, and the Wi-Fi has gone meanwhile: that is what is said, rather
    /// than look through its addresses and say nobody was found. Nobody is asked, and no search is under way
    /// afterwards.
    func testAWaitThatEndsWithTheWiFiGoneSaysThereIsNoWiFi() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        bench.leaveWiFi()
        bench.letThePermissionGo(allowed: false)
        try await until("the search never ended", within: 3) { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .noWiFi)
        XCTAssertFalse(model.scanBlocked, "the screen still says the permission is in the way")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, 0, "the addresses of a Wi-Fi the phone has left were asked")
        XCTAssertEqual(bench.scanLog.last, "no Wi-Fi left to look round")
        expectNoSearchUnderWay(model, on: bench)
    }

    /// The screen that asked goes away while the search waits for the permission, as the tutorial does when
    /// it is closed with the question up. The search is over: nobody is asked and nothing is said, though the
    /// reader allows the local network afterwards and the recorder is there.
    func testLeavingTheScreenEndsASearchWaitingForThePermission() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        let search = try XCTUnwrap(model.scanTask)
        model.stopScanning()
        XCTAssertFalse(model.scanBlocked, "the screen still says the permission is in the way")
        XCTAssertNil(model.scanning, "the search was shown as still going after the screen had gone")
        bench.letThePermissionGo(allowed: true)
        try await within(2, "the search that was stopped never ended") { await search.value }

        expectEqual(await subnet.asked, 0, "the search was made after the screen had gone")
        XCTAssertNil(model.scanOutcome, "something was said after the screen had gone")
        XCTAssertEqual(model.found, [])
        XCTAssertNil(model.scanning)
        XCTAssertFalse(model.scanBlocked)
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

    /// The app goes to the background, as it does for the home screen or another app and never for a question
    /// of the system's: it stops being active on the way there, if it had not already.
    private func goToTheBackground(_ model: AppModel) {
        model.activeChanged(to: false)
        model.wentToBackground()
    }

    /// Holds that the model has no search under way, by what it writes for the log: the app's phase changing
    /// and the screen going away are written for a search under way, and here write nothing.
    private func expectNoSearchUnderWay(_ model: AppModel, on bench: Bench,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let written = bench.scanLog
        goToTheBackground(model)
        comeBack(model)
        model.stopScanning()
        XCTAssertEqual(bench.scanLog, written, "written to the log with no search under way", file: file, line: line)
    }
}
