import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// レコーダーを探す, pressed on a bench: the model as the app makes it at its first launch, with no recorder
/// saved, on a Wi-Fi the test invents (`Bench.joinWiFi`). The search looks round that Wi-Fi's addresses, which
/// are reserved for documentation, and its requests go to the bench's subnet and nowhere else: nothing is put
/// on the network the tests run on.
///
/// The first press on a phone raises the system's question about the local network, and the search waits for
/// the answer before it asks anybody (`LocalNetwork.waitForAccess`, which the package tries on connections of
/// its own). Here the wait is the bench's to hold and to end each of the three ways it ends. Behind it the
/// search is one look through the addresses, said at once, whatever the app's phase did meanwhile: the tests
/// tell the model its phase as the first screen does, and nothing goes by it but the log.
///
/// Unless that look was turned away whole, as the bench's subnet turns one away when a test tells it to: then
/// nothing is said, the notice about the permission goes up, and the search asks one address after each pause
/// until a request is let out or the press has had all it is allowed. The pauses are the bench's to hold.
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

    /// Nobody there. The search waited for the permission, and the app stopped being active meanwhile, as it
    /// may for the system's question (not seen; the log's phase lines will say): let go, the search looks
    /// through the addresses once and says at once that it found nobody. Nothing is made of the app's phase,
    /// then or afterwards.
    func testNothingFoundIsSaidAtOnceAfterOneLookWhateverTheAppsPhaseDid() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        leave(model)
        comeBack(model)
        bench.letThePermissionGo(allowed: true)
        try await until("the search never asked everybody") { await subnet.asked >= addresses }
        try await until("nothing found was not said at once", within: 0.5) { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "the addresses were looked through more than once")
        leave(model)
        comeBack(model)
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await subnet.asked, addresses, "the search was made again for the app's phase changing")
        XCTAssertEqual(model.scanOutcome, .nothing)
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

    /// The wait ends with the permission given, and the Wi-Fi has gone meanwhile: the reader may be a long
    /// time over the system's question. The Wi-Fi is read again after the wait, whatever it answered short of
    /// giving up, so that is what is said. Nobody is asked, and no search is under way afterwards.
    func testAWaitAllowedAfterTheWiFiHasGoneSaysThereIsNoWiFi() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        bench.leaveWiFi()
        bench.letThePermissionGo(allowed: true)
        try await until("the search never ended", within: 3) { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .noWiFi)
        XCTAssertFalse(model.scanBlocked, "the screen still says the permission is in the way")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, 0, "the addresses of a Wi-Fi the phone has left were asked")
        XCTAssertEqual(bench.scanLog.last, "no Wi-Fi left to look round")
        expectNoSearchUnderWay(model, on: bench)
    }

    /// And the phone has gone to another Wi-Fi meanwhile, with a recorder of its own there: the look goes
    /// through that Wi-Fi's addresses, and through none of the one the press was made on.
    func testAWaitAnsweredOnAnotherWiFiLooksThroughThatWiFisAddresses() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let left = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        let recorderElsewhere = "198.51.100.10"
        let joined = bench.joinWiFi(with: [recorderElsewhere: NamedRecorder(2)], as: Bench.phoneElsewhere)
        bench.letThePermissionGo(allowed: true)
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertEqual(model.found.map(\.host), [recorderElsewhere])
        expectEqual(await left.asked, 0, "the Wi-Fi the phone had left was looked through")
        let askedOf = await joined.askedOf
        XCTAssertEqual(askedOf.count, addresses, "each address of the Wi-Fi the phone is on is asked once")
        XCTAssertEqual(askedOf.filter { !$0.hasPrefix("198.51.100.") }, [],
                       "addresses of the Wi-Fi the press was made on were asked")
    }

    /// The wait ends with no path for another reason than the permission, and the Wi-Fi is still there: the
    /// search goes on. It looks through the addresses once and says what it found.
    func testAWaitWithNoPathOnAWiFiStillThereLooksOnceAndSaysWhatItFound() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        bench.letThePermissionGo(allowed: false)
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked, "the screen still says the permission is in the way")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "each address of the subnet is asked once")
        XCTAssertEqual(bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }, [
            "press: 253 addresses to ask, the app active",
            "the wait for the permission is over: no path, and not for the permission",
            "search: asked 253; answered [200: 1]; timed out 252; failed []; other 0; recorders 1; some s",
            "said: found 1",
        ])
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
        // The bench's wait ends only when the test lets it go; the app's ends when its task is cancelled.
        XCTAssertTrue(search.isCancelled, "the search's task was left waiting after the screen had gone")
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

    /// The app's own surroundings hand its search the package's wait for the permission
    /// (`LocalNetwork.waitForAccess`), and not one that lets it straight through: every other test here has
    /// the bench's. Called in a task cancelled before it begins, the package's wait is over at once, without a
    /// yes and before it has made a connection, where a wait that let everything through would say allowed.
    /// Aimed at this machine's loopback all the same.
    func testTheAppsSearchWaitsWithThePackagesOwnWait() async throws {
        let wait = Surroundings.app.waitForLocalNetwork
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await wait("127.0.0.1") {}
        }

        let access = try await within(2, "the app's wait never ended") { await waiting.value }

        XCTAssertEqual(access, .unavailable, "the app's search does not wait with the package's wait")
    }

    /// And they hand it the app's own pause and transport, which every other test here has the bench's for: a
    /// pause before a single request lasts as long as the search asks, where one left out takes no time, and
    /// the requests go through the real session (`URLSessionTransport`), where one left out reaches nobody. The
    /// pause is only waited out and the transport only made: nothing is sent.
    func testTheAppsSearchPausesForAsLongAsItAsksAndSendsThroughTheRealSession() async throws {
        let app = Surroundings.app
        let pause = app.scanPause
        let began = ContinuousClock.now

        try await within(2, "the app's pause never ended") { await pause(.milliseconds(300)) }

        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(300),
                                    "the app's search does not pause for as long as it asks")
        XCTAssertTrue(app.scanTransport() is URLSessionTransport,
                      "the app's search does not send through the real session")
    }

    /// The wait gives up with the permission still in the way. The search is over without having asked
    /// anybody and says nothing of having looked: the notice about the permission stays, and the button is
    /// the reader's again.
    func testAWaitThatGivesUpLeavesTheNoticeAndSaysNothingWasLookedFor() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        bench.giveUpOnThePermission()
        try await until("the search never ended", within: 3) { model.scanning == nil }
        // Long enough for a search that went on all the same to have asked.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(model.scanBlocked, "the notice about the permission was taken down")
        XCTAssertNil(model.scanOutcome, "something was said of a search that asked nobody")
        XCTAssertEqual(model.found, [])
        expectEqual(await subnet.asked, 0, "somebody was asked with the permission still in the way")
        XCTAssertEqual(bench.scanLog.last,
                       "the wait for the permission is over: given up, the permission still in the way")
        expectNoSearchUnderWay(model, on: bench)
    }

    /// And a press after that starts over. The notice the last press left comes down with the press, before
    /// the wait has said anything of its own -- its connection is on its way, here for as long as the test
    /// holds it -- and once the permission is there the search is made and finds the recorder.
    func testAPressAfterTheWaitGaveUpStartsOver() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)
        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        bench.giveUpOnThePermission()
        try await until("the first press's search never ended", within: 3) { model.scanning == nil }
        XCTAssertTrue(model.scanBlocked)

        bench.holdThePermission(sayingSo: false)
        model.scanForRecorders()
        try await until("the second press's search never began", within: 3) { model.scanning != nil }
        XCTAssertFalse(model.scanBlocked, "the last press's notice stood over a wait that had said nothing yet")
        bench.letThePermissionGo(allowed: true)
        try await until("the second press's search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "each address of the subnet is asked once")
    }

    // MARK: - a look that was turned away whole

    /// The wait said the local network was reached, and the look that followed was turned away whole, as it
    /// is if the wait was wrong behind the system's question: every request failed at once for want of a
    /// network to send on. Nothing is said of having looked. The notice about the permission goes up, and it
    /// stays up while the search asks one address -- the neighbour on the Wi-Fi the phone is on, read again
    /// before each request -- once after each pause of a second: at a pause, and with a single request out.
    /// When a request is let out the notice comes down, the addresses are looked through again, and the
    /// recorder is found with no other press.
    func testALookTurnedAwayWholeIsMadeAgainOnceASingleRequestGetsOut() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingAway()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        XCTAssertNil(model.scanOutcome, "something was said of a look that was turned away whole")
        XCTAssertNotNil(model.scanning, "the search was over with the look turned away")
        expectEqual(await subnet.asked, addresses, "somebody was asked before the first pause was over")

        await subnet.hold()
        bench.letSingleRequestsGo()
        try await until("the first single request was never made", within: 3) { await subnet.asked == addresses + 1 }
        XCTAssertTrue(model.scanBlocked, "the notice came down with a single request out")
        await subnet.letGo()
        try await until("the search never came to its second pause", within: 3) { bench.scanPauses.count == 2 }
        XCTAssertTrue(model.scanBlocked, "the notice came down between two single requests")
        bench.letSingleRequestsGo()
        try await until("the search never came to its third pause", within: 3) { bench.scanPauses.count == 3 }
        expectEqual(await subnet.asked, addresses + 2, "more than one request was made for a pause, or none")
        XCTAssertTrue(model.scanBlocked, "the notice came down between two single requests")
        XCTAssertNil(model.scanOutcome, "something was said while every request was being turned away")

        await subnet.letEverythingOut()
        bench.letSingleRequestsGo()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertEqual(model.found.map(\.host), [Bench.host])
        XCTAssertFalse(model.scanBlocked, "the notice stayed up over a search that had got out")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        let askedOf = await subnet.askedOf
        XCTAssertEqual(askedOf.count, addresses + 3 + addresses, "a look, three single requests, and one look more")
        // Read only where there are that many, so that a search that asked fewer fails above and does not
        // stop the test host here.
        if askedOf.count >= addresses + 3 {
            XCTAssertEqual(Array(askedOf[addresses..<addresses + 3]), Array(repeating: "192.0.2.1", count: 3),
                           "the single requests were not for the neighbour on the Wi-Fi the phone is on")
        }
        XCTAssertEqual(bench.scanPauses, Array(repeating: .seconds(1), count: 3), "a second before each single request")
        XCTAssertEqual(bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }, [
            "press: 253 addresses to ask, the app active",
            "the wait for the permission is over: allowed",
            "search: asked 253; answered []; timed out 0; failed [-1009: 253]; other 0; recorders 0; some s",
            "search: turned away whole, nothing said; one address is asked a second",
            "single request: got out, after 3",
            "search: asked 253; answered [200: 1]; timed out 252; failed []; other 0; recorders 1; some s",
            "said: found 1",
        ])
    }

    /// And that is not done without end. Nothing is ever let out: after as many single requests as one press
    /// is allowed the search is over, having said nothing of having looked. The notice about the permission
    /// stays, and no search is under way.
    func testASearchTurnedAwayToTheLastSingleRequestGivesUpWithTheNoticeUp() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingAway()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never ended") { model.scanning == nil }
        // Long enough for a search that went on all the same to have asked again.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(AppModel.singleRequestsAllowed, 120)
        XCTAssertTrue(model.scanBlocked, "the notice about the permission was taken down")
        XCTAssertNil(model.scanOutcome, "something was said of a search of which nothing got out")
        XCTAssertEqual(model.found, [])
        expectEqual(await subnet.asked, addresses + 120, "one look, and the single requests a press is allowed")
        XCTAssertEqual(bench.scanPauses, Array(repeating: .seconds(1), count: 120),
                       "a pause before each single request, and none after the last")
        XCTAssertEqual(bench.scanLog.last, "single requests: given up after 120")
        expectNoSearchUnderWay(model, on: bench)
    }

    /// And a press after that starts over: the notice the last press left comes down with it, and with the
    /// requests let out the search is made and finds the recorder.
    func testAPressAfterASearchTurnedAwayToTheEndStartsOver() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingAway()
        let model = await aModel(on: bench)
        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the first press's search never ended") { model.scanning == nil }
        XCTAssertTrue(model.scanBlocked)
        let askedByTheFirst = await subnet.asked

        await subnet.letEverythingOut()
        bench.holdThePermission(sayingSo: false)
        model.scanForRecorders()
        try await until("the second press's search never began", within: 3) { model.scanning != nil }
        XCTAssertFalse(model.scanBlocked, "the last press's notice stood over a wait that had said nothing yet")
        bench.letThePermissionGo(allowed: true)
        try await until("the second press's search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, askedByTheFirst + addresses, "each address of the subnet is asked once")
        XCTAssertEqual(bench.scanPauses.count, 120, "the second press made a pause, as before a single request")
    }

    /// A look that got out and found nobody, every address silent: a home with no recorder on its Wi-Fi. That
    /// is said at once, as it was before a look could be turned away: no notice, no pause, no single request
    /// and no second look.
    func testALookThatGotOutAndFoundNobodyIsSaidAtOnceWithNoSingleRequest() async throws {
        try await expectNothingFoundIsSaidAtOnce(nobody: .silent, cameBack: "timed out 253; failed []")
    }

    /// Nor is a look turned away when every address refused the connection: each of them was reached.
    func testALookEveryAddressRefusedIsNotTurnedAwayAndIsSaidAtOnce() async throws {
        try await expectNothingFoundIsSaidAtOnce(nobody: .refusing, cameBack: "timed out 0; failed [-1004: 253]")
    }

    private func expectNothingFoundIsSaidAtOnce(nobody: Subnet.Nobody, cameBack: String,
                                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(nobody: nobody)
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never asked everybody") { await subnet.asked >= self.addresses }
        try await until("nothing found was not said at once", within: 0.5) { model.scanOutcome != nil }
        // Long enough for a single request, or another look, to have been made.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(model.scanOutcome, .nothing, file: file, line: line)
        XCTAssertFalse(model.scanBlocked, "the notice about the permission is up", file: file, line: line)
        XCTAssertNil(model.scanning, "the button was left held back after the search", file: file, line: line)
        expectEqual(await subnet.asked, addresses, "somebody was asked again after a look that had got out",
                    file: file, line: line)
        XCTAssertEqual(bench.scanPauses, [], "a pause was made, as before a single request", file: file, line: line)
        XCTAssertEqual(bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }, [
            "press: 253 addresses to ask, the app active",
            "the wait for the permission is over: allowed",
            "search: asked 253; answered []; \(cameBack); other 0; recorders 0; some s",
            "said: nothing found",
        ], file: file, line: line)
    }

    /// The screen that asked goes away while the search is asking one address after a look that was turned
    /// away: at a pause, and with a single request out, which comes back afterwards as one that got out. The
    /// search is over either way. Its task is cancelled, nobody more is asked and nothing is said, and the
    /// addresses are not looked through again.
    func testLeavingTheScreenEndsASearchThatIsAskingOneAddress() async throws {
        for requestOut in [false, true] {
            let stoppedAt = requestOut ? "with a single request out" : "at a pause"
            let bench = try aBench()
            bench.holdTheSingleRequests()
            let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
            await subnet.turnEverythingAway()
            let model = await aModel(on: bench)

            model.scanForRecorders()
            try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
            bench.letSingleRequestsGo(2)
            try await until("the search never came to its third pause", within: 3) { bench.scanPauses.count == 3 }
            var asked = addresses + 2
            if requestOut {
                await subnet.hold()
                await subnet.letEverythingOut()
                bench.letSingleRequestsGo()
                asked += 1
                try await until("the third single request was never made", within: 3) { await subnet.asked == asked }
            }
            let search = try XCTUnwrap(model.scanTask)
            model.stopScanning()
            XCTAssertTrue(search.isCancelled, "\(stoppedAt): the search's task was left running")
            XCTAssertFalse(model.scanBlocked, "\(stoppedAt): the screen still says the permission is in the way")
            XCTAssertNil(model.scanning, "\(stoppedAt): the search was shown as still going")
            bench.letEverySingleRequestGo()
            await subnet.letEverythingOut()
            await subnet.letGo()
            try await within(2, "\(stoppedAt): the search that was stopped never ended") { await search.value }

            expectEqual(await subnet.asked, asked, "\(stoppedAt): somebody was asked after the screen had gone")
            XCTAssertNil(model.scanOutcome, "\(stoppedAt): something was said after the screen had gone")
            XCTAssertEqual(model.found, [], stoppedAt)
            XCTAssertNil(model.scanning, "\(stoppedAt): the search was shown as going again")
            XCTAssertFalse(model.scanBlocked, stoppedAt)
        }
    }

    /// The phone leaves the Wi-Fi while the search is asking one address after a look that was turned away:
    /// at a pause, and with a single request out, which then gets out. The Wi-Fi is read again before each
    /// single request and before the look after one that got out, so the search says there is no Wi-Fi, the
    /// notice about the permission comes down, and nobody more is asked.
    func testTheWiFiGoneWhileOneAddressIsAskedIsSaidAndNobodyMoreIsAsked() async throws {
        for requestOut in [false, true] {
            let leftAt = requestOut ? "with a single request out" : "at a pause"
            let bench = try aBench()
            bench.holdTheSingleRequests()
            let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
            await subnet.turnEverythingAway()
            let model = await aModel(on: bench)

            model.scanForRecorders()
            try await until("\(leftAt): the notice never went up", within: 3) { model.scanBlocked }
            try await until("\(leftAt): the search never came to its first pause", within: 3) {
                bench.scanPauses.count == 1
            }
            var asked = addresses
            if requestOut {
                await subnet.hold()
                await subnet.letEverythingOut()
                bench.letSingleRequestsGo()
                asked += 1
                try await until("\(leftAt): the single request was never made", within: 3) {
                    await subnet.asked == asked
                }
            }
            bench.leaveWiFi()
            if requestOut { await subnet.letGo() } else { bench.letSingleRequestsGo() }
            try await until("\(leftAt): the search never said anything", within: 3) { model.scanOutcome != nil }

            XCTAssertEqual(model.scanOutcome, .noWiFi, leftAt)
            XCTAssertFalse(model.scanBlocked, "\(leftAt): the notice about the permission stayed up")
            XCTAssertNil(model.scanning, "\(leftAt): the button was left held back")
            expectEqual(await subnet.asked, asked, "\(leftAt): somebody was asked with the phone off the Wi-Fi")
            XCTAssertEqual(bench.scanLog.last, "no Wi-Fi left to look round", leftAt)
            expectNoSearchUnderWay(model, on: bench)
        }
    }

    /// The phone moves to another Wi-Fi while the search is asking one address after a look that was turned
    /// away whole. The Wi-Fi is read again before each single request, so the next one goes to the neighbour on
    /// the Wi-Fi the phone is on now, and not to the one the press was made on and the wait aimed at.
    func testASingleRequestAfterTheWiFiChangedGoesToTheNeighbourOnTheNewWiFi() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let left = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await left.turnEverythingAway()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        let joined = bench.joinWiFi(as: Bench.phoneElsewhere)
        await joined.turnEverythingAway()
        bench.letSingleRequestsGo()
        try await until("the search never came to its second pause", within: 3) { bench.scanPauses.count == 2 }

        // Read off both subnets: which one carried the request is the bench's affair, where it was for is not.
        let leftSince = Array(await left.askedOf.dropFirst(addresses))
        let joinedSince = await joined.askedOf
        XCTAssertEqual(leftSince + joinedSince, ["198.51.100.1"],
                       "the single request was not for the neighbour on the Wi-Fi the phone is on now")
        XCTAssertTrue(model.scanBlocked, "the notice came down with the request turned away")
        XCTAssertNil(model.scanOutcome, "something was said while every request was being turned away")
    }

    // MARK: - the button

    /// レコーダーを探す is held back, with its spinner, only while a search is under way with no notice about
    /// the permission up (`scanHoldsTheButton`, which both screens read): through a look, and not before the
    /// press, nor behind the notice -- while the wait says the permission is in the way, while one address is
    /// asked after a look that was turned away whole, and once those requests are used up.
    func testTheButtonIsHeldBackOnlyWhileASearchGoesWithNoNoticeUp() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        bench.holdTheSingleRequests()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingAway()
        await subnet.hold()
        let model = await aModel(on: bench)
        XCTAssertFalse(model.scanHoldsTheButton, "held back before any press")

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        XCTAssertNotNil(model.scanning)
        XCTAssertFalse(model.scanHoldsTheButton, "held back behind the notice while the wait waits")

        bench.letThePermissionGo(allowed: true)
        try await until("the look never began", within: 3) { await subnet.asked > 0 }
        XCTAssertFalse(model.scanBlocked)
        XCTAssertTrue(model.scanHoldsTheButton, "live while a look went through the addresses")

        await subnet.letGo()
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        XCTAssertTrue(model.scanBlocked)
        XCTAssertNotNil(model.scanning)
        XCTAssertFalse(model.scanHoldsTheButton, "held back behind the notice while one address is asked")

        bench.letEverySingleRequestGo()
        try await until("the search never ended") { model.scanning == nil }
        XCTAssertTrue(model.scanBlocked)
        XCTAssertFalse(model.scanHoldsTheButton, "held back once the single requests were used up")
    }

    /// With the notice up the button is the reader's, and a press while the wait is still held starts over:
    /// the search under way is ended, its task cancelled, and only the second press's search asks anybody once
    /// the permission comes.
    func testAPressWhileTheNoticeIsUpStartsOver() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)
        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        let first = try XCTUnwrap(model.scanTask)

        model.scanForRecorders()
        XCTAssertTrue(first.isCancelled, "the first press's search was left running")
        bench.letThePermissionGo(allowed: true)
        try await within(2, "the first press's search never ended") { await first.value }
        try await until("the second press's search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "the addresses were looked through for both presses")
    }

    // MARK: - what a search leaves in the log

    /// The course of a first press as the log has it, for reading off a phone afterwards: the press, each
    /// change of the app's phase while the search waits for the permission, as the system's question may make
    /// them, the end of the wait, the search with how its requests came back, and what was said. In counts
    /// and codes: no line has an address in it, nor anything the recorder said of itself.
    func testASearchWritesItsCourseToTheLogInCountsAndCodes() async throws {
        let bench = try aBench()
        bench.holdThePermission()
        bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never said the permission was in the way", within: 3) { model.scanBlocked }
        leave(model)
        comeBack(model)
        bench.letThePermissionGo(allowed: true)
        try await until("the search never ended") { model.scanOutcome != nil }

        // How long a search took is the one thing in a line that is not the same at every run.
        let lines = bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }
        XCTAssertEqual(lines, [
            "press: 253 addresses to ask, the app active",
            "phase: not active",
            "phase: active",
            "the wait for the permission is over: allowed",
            "search: asked 253; answered [200: 1]; timed out 252; failed []; other 0; recorders 1; some s",
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
    /// it has got to.
    private func aModel(on bench: Bench) async -> AppModel {
        let model = bench.modelWithNoRecorder()
        await model.start()
        addTeardownBlock { @MainActor in model.stopScanning() }
        return model
    }

    /// The app stops being active, as it does under Control Centre, and as it may for as long as a question of
    /// the system's is up over it: whether the local network's does has not been seen.
    private func leave(_ model: AppModel) {
        model.activeChanged(to: false)
    }

    /// The app is active again.
    private func comeBack(_ model: AppModel) {
        model.activeChanged(to: true)
    }

    /// The app goes to the background, as it does for the home screen or another app: it stops being active on
    /// the way there, if it had not already.
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
