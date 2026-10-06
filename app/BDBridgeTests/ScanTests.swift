import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// レコーダーを探す, pressed on a bench: the model as the app makes it at its first launch, with no recorder
/// saved, on a Wi-Fi the test invents (`Bench.joinWiFi`). The search looks round that Wi-Fi's addresses, which
/// are reserved for documentation, and its requests go to the bench's subnet and nowhere else: nothing is put
/// on the network the tests run on.
///
/// A press is one look through the addresses, made at once with nothing asked before it, and said at once,
/// whatever the app's phase did meanwhile: the tests tell the model its phase as the first screen does, and
/// nothing goes by it but the log.
///
/// Unless that look was turned away -- more of its requests turned away than all the rest -- as the bench's
/// subnet turns one away when a test tells it to, and as the system did behind its question about the local
/// network on one phone: then nothing is said, the notice about the permission goes up, and the search asks
/// again, after each pause, at an address the look saw turned away, until a request is let out or the press
/// has had all it is allowed. The pauses are the bench's to hold.
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

    /// Nobody there, and the app stopped being active while the look went through the addresses, as it may
    /// for the system's question (not seen; the log's phase lines will say): the search looks through them
    /// once and says at once that it found nobody. Nothing is made of the app's phase, then or afterwards.
    func testNothingFoundIsSaidAtOnceAfterOneLookWhateverTheAppsPhaseDid() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        await subnet.hold()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the look never began", within: 3) { await subnet.asked > 0 }
        leave(model)
        comeBack(model)
        await subnet.letGo()
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

    /// The permission given, a press looks through the addresses at once, with nothing asked before the look
    /// -- no wait for the permission, no request to an address fixed beforehand -- and what it found is said
    /// at once: no pause, no single request, no notice. The look's first requests are out together before any
    /// has come back, and the look is all the subnet is asked.
    func testWithThePermissionGivenAPressLooksAtOnceWithNothingBeforeItAndSaysAtOnce() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.hold()
        let model = await aModel(on: bench)
        let hosts = (1...254).filter { $0 != 20 }.map { "192.0.2.\($0)" }
        let atOnce = 48

        model.scanForRecorders()
        try await until("the look's first requests were not out at once", within: 1) {
            await subnet.asked == atOnce
        }
        let first = await subnet.askedOf
        XCTAssertEqual(Set(first), Set(hosts.prefix(atOnce)), "something was asked before the look")
        XCTAssertFalse(model.scanBlocked, "the notice went up over a look under way")
        XCTAssertTrue(model.scanHoldsTheButton, "the button was live while the look went through the addresses")
        await subnet.letGo()
        try await until("the search never asked everybody") { await subnet.asked >= addresses }
        try await until("what was found was not said at once", within: 0.5) { model.scanOutcome != nil }
        // Long enough for a single request, or another look, to have been made.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked, "the notice about the permission is up")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.askedOf.sorted(), hosts.sorted(), "not the one look, each address asked once")
        XCTAssertEqual(bench.scanPauses, [], "a pause was made")
        XCTAssertEqual(bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }, [
            "press: 253 addresses to ask, the app active",
            "search: asked 253; answered [200: 1]; timed out 252; failed []; other 0; recorders 1; some s",
            "said: found 1",
        ], "something was done between the press and the look, or after it")
    }

    /// The app's own surroundings hand the search the app's own pause and transport, which every other test
    /// here has the bench's for: a pause before a single request lasts as long as the search asks, where one
    /// left out takes no time, and the requests go through the real session (`URLSessionTransport`), where one
    /// left out reaches nobody. The pause is only waited out and the transport only made: nothing is sent.
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

    // MARK: - a look that was turned away

    /// The first press on one phone, on 2026-10-06, as its log has it: the look made behind the system's
    /// question came back with 252 requests turned away at once (-1009) and one refused (-1004), by the
    /// address the system let through unasked. Nothing is said of having looked, nothing red: the notice about
    /// the permission goes up and the button is live. It stays up while the search asks again, once after
    /// each pause of a second, at one address the look saw turned away and never at the one that refused: at
    /// a pause, and with a single request out. When a request is let out the notice comes down, the addresses
    /// are looked through again with the search shown going, and the recorder is found with no other press.
    func testALookTurnedAwayButForOneRefusalIsAskedAgainWhereTurnedAwayAndFindsTheRecorder() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let letThrough = "192.0.2.1"
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)], refusing: [letThrough])
        await subnet.turnEverythingAway(but: letThrough)
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        XCTAssertNil(model.scanOutcome, "something was said of a look that was turned away")
        XCTAssertNotNil(model.scanning, "the search was over with the look turned away")
        XCTAssertFalse(model.scanHoldsTheButton, "the button was held back behind the notice")
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
        // The single request goes, and the look after it is held.
        await subnet.hold(after: 1)
        bench.letSingleRequestsGo()
        try await until("the look after the request that got out never began", within: 3) {
            await subnet.asked > addresses + 3
        }
        XCTAssertFalse(model.scanBlocked, "the notice stayed up over the look after a request got out")
        XCTAssertNotNil(model.scanning, "the look after a request got out was not shown as going")
        XCTAssertNil(model.scanOutcome, "something was said before the look after a request got out was over")
        await subnet.letGo()
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
            let singles = Array(askedOf[addresses..<addresses + 3])
            XCTAssertFalse(singles.contains(letThrough), "a single request was for the address that refused")
            XCTAssertEqual(Set(singles).count, 1, "the single requests were for more than one address: \(singles)")
            XCTAssertTrue(singles.allSatisfy(askedOf.prefix(addresses).contains), "not for an address of the look")
        }
        XCTAssertEqual(bench.scanPauses, Array(repeating: .seconds(1), count: 3), "a second before each single request")
        // The address asked again is the first the look saw turned away, which may be the recorder's: let out,
        // that one answers and any other is silent.
        let gotOut = askedOf.count > addresses && askedOf[addresses] == Bench.host ? "200" : "-1001"
        XCTAssertEqual(bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }, [
            "press: 253 addresses to ask, the app active",
            "search: asked 253; answered []; timed out 0; failed [-1009: 252, -1004: 1]; other 0; recorders 0;"
                + " some s",
            "search: turned away, nothing said; one address is asked a second",
            "single request: turned away (-1009), written for the first only",
            "single request: got out (\(gotOut)), after 3",
            "search: asked 253; answered [200: 1]; timed out 251; failed [-1004: 1]; other 0; recorders 1; some s",
            "said: found 1",
        ])
    }

    /// The same where the address let through unasked is silent on the port rather than refusing it, as a DNS
    /// server or a proxy behind a firewall may be: one request of the look times out and the rest are turned
    /// away. More were turned away than got out, so nothing is said and the notice goes up; the search asks
    /// again at an address the look saw turned away, never the silent one, and finds the recorder once let out.
    func testALookTurnedAwayButForOneTimeoutIsAskedAgainWhereTurnedAwayAndFindsTheRecorder() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let letThrough = "192.0.2.1"
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingAway(but: letThrough)
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        XCTAssertNil(model.scanOutcome, "something was said of a look that was turned away")
        XCTAssertFalse(model.scanHoldsTheButton, "the button was held back behind the notice")
        bench.letSingleRequestsGo()
        try await until("the search never came to its second pause", within: 3) { bench.scanPauses.count == 2 }
        XCTAssertTrue(model.scanBlocked, "the notice came down with every request turned away")
        await subnet.letEverythingOut()
        bench.letSingleRequestsGo()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked, "the notice stayed up over a search that had got out")
        let askedOf = await subnet.askedOf
        XCTAssertEqual(askedOf.count, addresses + 2 + addresses, "a look, two single requests, and one look more")
        XCTAssertFalse(askedOf.dropFirst(addresses).prefix(2).contains(letThrough),
                       "a single request was for the address let through")
        let gotOut = askedOf.count > addresses && askedOf[addresses] == Bench.host ? "200" : "-1001"
        XCTAssertEqual(bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }, [
            "press: 253 addresses to ask, the app active",
            "search: asked 253; answered []; timed out 1; failed [-1009: 252]; other 0; recorders 0; some s",
            "search: turned away, nothing said; one address is asked a second",
            "single request: turned away (-1009), written for the first only",
            "single request: got out (\(gotOut)), after 2",
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

    /// And a press after that starts over: the notice the last press left comes down with it, before its look
    /// has come back -- held here for as long as the test holds it -- and with the requests let out the look
    /// finds the recorder.
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
        await subnet.hold()
        model.scanForRecorders()
        try await until("the second press's look never began", within: 3) { await subnet.asked > askedByTheFirst }
        XCTAssertFalse(model.scanBlocked, "the last press's notice stood over a look that had said nothing yet")
        XCTAssertNotNil(model.scanning, "the second press's look was not shown as going")
        await subnet.letGo()
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
        try await expectSaidAtOnce(.nothing, cameBack: "answered []; timed out 253; failed []")
    }

    /// Nor is a look turned away whose addresses timed out or refused, with nobody answering: a home with no
    /// recorder and a few hosts that turn down the port. The timeouts are requests that were out.
    func testALookOfTimeoutsAndRefusalsIsNotTurnedAwayAndIsSaidAtOnce() async throws {
        let refusing = Set((101...106).map { "192.0.2.\($0)" })
        try await expectSaidAtOnce(.nothing, refusing: refusing,
                                   cameBack: "answered []; timed out 247; failed [-1004: 6]")
    }

    /// Nor a look most of whose requests got out and a few were turned away, as when the permission is given
    /// while the look goes: those sent before it turned away, and the rest out, silent.
    func testALookMostOfWhichGotOutIsNotTurnedAwayForAFewTurnedAwayAndIsSaidAtOnce() async throws {
        try await expectSaidAtOnce(.nothing, turnedAwayBefore: 5,
                                   cameBack: "answered []; timed out 248; failed [-1009: 5]")
    }

    /// And a look that found the recorder is said at once whatever its counts: the permission given late in
    /// the look, the requests sent before it turned away, which are most of them, and the rest out, the
    /// recorder's among them.
    func testALookThatFoundTheRecorderIsSaidAtOnceThoughMostOfItWasTurnedAway() async throws {
        try await expectSaidAtOnce(.found(1), recorders: ["192.0.2.250": NamedRecorder(1)], turnedAwayBefore: 200,
                                   cameBack: "answered [200: 1]; timed out 52; failed [-1009: 200]")
    }

    /// A press whose one look is said at once, as `said`: no notice, no pause, no single request and no second
    /// look. `turnedAwayBefore` has the system turn away the look's first requests, so many, and let out every
    /// one after them, as it does when the permission is given while a look goes.
    private func expectSaidAtOnce(_ said: AppModel.ScanOutcome, recorders: [String: any HTTPTransport] = [:],
                                  refusing: Set<String> = [], turnedAwayBefore: Int = 0, cameBack: String,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: recorders, refusing: refusing)
        if turnedAwayBefore > 0 {
            await subnet.turnEverythingAway()
            await subnet.hold(after: turnedAwayBefore)
        }
        let model = await aModel(on: bench)

        model.scanForRecorders()
        if turnedAwayBefore > 0 {
            try await until("the look never got past the requests turned away", within: 3) {
                await subnet.asked > turnedAwayBefore
            }
            await subnet.letEverythingOut()
            await subnet.letGo()
        }
        try await until("the search never asked everybody") { await subnet.asked >= self.addresses }
        try await until("what the look found was not said at once", within: 0.5) { model.scanOutcome != nil }
        // Long enough for a single request, or another look, to have been made.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(model.scanOutcome, said, file: file, line: line)
        XCTAssertFalse(model.scanBlocked, "the notice about the permission is up", file: file, line: line)
        XCTAssertNil(model.scanning, "the button was left held back after the search", file: file, line: line)
        expectEqual(await subnet.asked, addresses, "somebody was asked again after a look that had got out",
                    file: file, line: line)
        XCTAssertEqual(bench.scanPauses, [], "a pause was made, as before a single request", file: file, line: line)
        let recorders = if case .found(let count) = said { count } else { 0 }
        XCTAssertEqual(bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }, [
            "press: 253 addresses to ask, the app active",
            "search: asked 253; \(cameBack); other 0; recorders \(recorders); some s",
            recorders > 0 ? "said: found \(recorders)" : "said: nothing found",
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

    /// The phone moves to another subnet while the search is asking again after a look that was turned away
    /// whole. The Wi-Fi is read again before each single request, so nothing more is asked of an address of
    /// the subnet the look was made on: the look is made again at once on the new one, in place of that
    /// turn's single request. Turned away there too, the next single request is for an address that look saw
    /// turned away; let out, the recorder on the new Wi-Fi is found.
    func testTheWiFiMovedWhileOneAddressIsAskedIsLookedThroughInPlaceOfTheRequest() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let left = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await left.turnEverythingAway()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        let recorderElsewhere = "198.51.100.10"
        let joined = bench.joinWiFi(with: [recorderElsewhere: NamedRecorder(2)], as: Bench.phoneElsewhere)
        await joined.turnEverythingAway()
        bench.letSingleRequestsGo()
        try await until("the search never came to its second pause", within: 3) { bench.scanPauses.count == 2 }

        expectEqual(await left.asked, addresses, "a single request was made in the turn the Wi-Fi moved in")
        let lookedAgain = await joined.askedOf
        XCTAssertEqual(lookedAgain.count, addresses, "the new Wi-Fi was not looked through once in that turn")
        XCTAssertEqual(lookedAgain.filter { !$0.hasPrefix("198.51.100.") }, [], "the old subnet's addresses were asked")
        XCTAssertTrue(model.scanBlocked, "the notice came down with the new Wi-Fi's look turned away")
        XCTAssertNil(model.scanOutcome, "something was said while every request was being turned away")

        // The permission is the phone's, whichever subnet carries the request: both let it out.
        await left.letEverythingOut()
        await joined.letEverythingOut()
        bench.letSingleRequestsGo()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertEqual(model.found.map(\.host), [recorderElsewhere])
        // Read off both subnets: which one carried the request is the bench's affair, where it was for is not.
        let since = Array(await left.askedOf.dropFirst(addresses)) + Array(await joined.askedOf.dropFirst(addresses))
        XCTAssertEqual(since.count, 1 + addresses, "a single request and one look more")
        XCTAssertEqual(since.filter { !$0.hasPrefix("198.51.100.") }, [], "the old subnet's addresses were asked")
        XCTAssertTrue(lookedAgain.contains(since.first ?? ""), "the single request was not for an address of the look")
    }

    /// The phone moves to another subnet while the search is asking again, and the look made there in place
    /// of that turn's single request gets out: the notice comes down, and what it found is said, with no other
    /// press and nothing more asked of the old subnet.
    func testTheLookOnANewWiFiThatGetsOutTakesTheNoticeDownAndSaysWhatItFound() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let left = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await left.turnEverythingAway()
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        let recorderElsewhere = "198.51.100.10"
        let joined = bench.joinWiFi(with: [recorderElsewhere: NamedRecorder(2)], as: Bench.phoneElsewhere)
        bench.letSingleRequestsGo()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertEqual(model.found.map(\.host), [recorderElsewhere])
        XCTAssertFalse(model.scanBlocked, "the notice stayed up over what the new Wi-Fi's look found")
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await left.asked, addresses, "the old subnet was asked after the move")
        expectEqual(await joined.asked, addresses, "the new Wi-Fi was not looked through once")
        XCTAssertEqual(bench.scanPauses.count, 1, "a pause was made after the look that got out")
    }

    // MARK: - the button

    /// レコーダーを探す is held back, with its spinner, only while a search is under way with no notice about
    /// the permission up (`scanHoldsTheButton`, which both screens read): through a look, and not before the
    /// press, nor behind the notice -- while one address is asked again after a look that was turned away
    /// whole, and once those requests are used up.
    func testTheButtonIsHeldBackOnlyWhileASearchGoesWithNoNoticeUp() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingAway()
        await subnet.hold()
        let model = await aModel(on: bench)
        XCTAssertFalse(model.scanHoldsTheButton, "held back before any press")

        model.scanForRecorders()
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

    /// With the notice up the button is the reader's, and a press while the search is asking again after a
    /// look that was turned away starts over: the search under way is ended, its task cancelled, and only the
    /// second press's search asks anybody after the press.
    func testAPressWhileTheNoticeIsUpStartsOver() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        await subnet.turnEverythingAway()
        let model = await aModel(on: bench)
        model.scanForRecorders()
        try await until("the notice about the permission never went up", within: 3) { model.scanBlocked }
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        let first = try XCTUnwrap(model.scanTask)

        await subnet.letEverythingOut()
        model.scanForRecorders()
        XCTAssertTrue(first.isCancelled, "the first press's search was left running")
        bench.letEverySingleRequestGo()
        try await within(2, "the first press's search never ended") { await first.value }
        try await until("the second press's search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertFalse(model.scanBlocked)
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses + addresses, "the first press's search asked again after the press")
    }

    // MARK: - what a search leaves in the log

    /// The course of a first press as the log has it, for reading off a phone afterwards, in the phone's own
    /// case: the press, the look with how its requests came back, its being turned away, each change of the
    /// app's phase while the search asks again behind the system's question, as the question may make them, the
    /// single request that got out and how it came back, the look after it, and what was said. In counts and
    /// codes: no line has an address in it -- not the one the search asks again, which it keeps -- nor anything
    /// the recorder said of itself.
    func testASearchWritesItsCourseToTheLogInCountsAndCodes() async throws {
        let bench = try aBench()
        bench.holdTheSingleRequests()
        let letThrough = "192.0.2.1"
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)], refusing: [letThrough])
        await subnet.turnEverythingAway(but: letThrough)
        let model = await aModel(on: bench)

        model.scanForRecorders()
        try await until("the search never came to its first pause", within: 3) { bench.scanPauses.count == 1 }
        leave(model)
        comeBack(model)
        await subnet.letEverythingOut()
        bench.letSingleRequestsGo()
        try await until("the search never ended") { model.scanOutcome != nil }

        // How long a search took is the one thing in a line that is not the same at every run. The address
        // asked again may be the recorder's, which answers once let out, where any other is silent.
        let lines = bench.scanLog.map { $0.replacing(/; \d+\.\d\d s$/, with: "; some s") }
        let askedOf = await subnet.askedOf
        let gotOut = askedOf.count > addresses && askedOf[addresses] == Bench.host ? "200" : "-1001"
        XCTAssertEqual(lines, [
            "press: 253 addresses to ask, the app active",
            "search: asked 253; answered []; timed out 0; failed [-1009: 252, -1004: 1]; other 0; recorders 0;"
                + " some s",
            "search: turned away, nothing said; one address is asked a second",
            "phase: not active",
            "phase: active",
            "single request: got out (\(gotOut)), after 1",
            "search: asked 253; answered [200: 1]; timed out 251; failed [-1004: 1]; other 0; recorders 1; some s",
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
