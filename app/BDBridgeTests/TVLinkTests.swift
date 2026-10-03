import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The television beside the recorder: added by the PIN it shows, connected on a link of its own, and neither
/// device held up by the other's silence. Let go of in the demo and given back after it, and taken away whole.
@MainActor
final class TVLinkTests: XCTestCase {
    /// Credentials the television knows, with a cookie it gave out a day ago.
    private func registered(with television: DemoTV) async -> MemoryTVCredentials {
        await television.knows("BDBridge:test", cookie: "kept")
        return MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                 cookieReceived: Date().addingTimeInterval(-86_400),
                                                 cookieMaxAge: 1_209_600))
    }

    /// A television is found at its address, asks for its PIN, and with it is registered, saved and connected:
    /// its address and its MAC go in the defaults, its registration in the store.
    func testATelevisionIsAddedByItsPIN() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV(power: "active")
        let credentials = MemoryTVCredentials()
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials, saved: false)
        await model.start()
        XCTAssertNil(model.tv)

        expectEqual(await model.findTV(at: Bench.tvHost), .on(model: DemoTV.model))
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .pinNeeded)
        XCTAssertNil(credentials.load(), "kept something before the PIN")
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: DemoTV.pin), .registered)

        try await until("the television was not connected") { model.tv?.session.connected == true }
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.tvHost), Bench.tvHost)
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.tvMac), DemoTV.mac)
        let kept = try XCTUnwrap(credentials.load())
        XCTAssertTrue(kept.clientID.hasPrefix("BDBridge:"))
        XCTAssertNotNil(kept.cookie)
        XCTAssertEqual(model.tvDriver?.facts.model, DemoTV.model)
        let calls = await television.calls
        let registrations = calls.filter { $0.hasPrefix("actRegister") }
        XCTAssertEqual(registrations, ["actRegister cookie=no pin=no", "actRegister cookie=no pin=yes"])
    }

    /// A television in standby shows no PIN, so it is found but not asked for one.
    func testATelevisionInStandbyIsNotAskedForItsPIN() async throws {
        let bench = try aBench()
        let television = DemoTV()
        let model = bench.model(recorder: SilentRecorder(), television: television, credentials: MemoryTVCredentials(),
                                saved: false)

        expectEqual(await model.findTV(at: Bench.tvHost), .standby(model: DemoTV.model))
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") })
    }

    /// The television's silence holds up nothing of the recorder's, and the recorder's nothing of the
    /// television's: each gives up on its own, and the other connects.
    func testNeitherDevicesSilenceHoldsUpTheOther() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let quietTV = DemoTV()
        await quietTV.goSilent()
        let model = bench.model(recorder: DemoRecorder(), television: quietTV,
                                credentials: await registered(with: quietTV))
        await model.start()
        try await untilConnected(model)
        try await until("the television was not given up on") { model.tv?.session.gaveUp == true }
        XCTAssertFalse(model.gaveUp, "the television's silence gave up on the recorder")

        let other = try aBench()
        try await other.cacheAGuide()
        let television = DemoTV()
        let second = other.model(recorder: SilentRecorder(), television: television,
                                 credentials: await registered(with: television))
        await second.start()
        try await until("the television was not connected") { second.tv?.session.connected == true }
        try await untilGivenUp(second)
        XCTAssertTrue(second.tv?.session.connected == true, "the recorder's silence took the television with it")
    }

    /// A television saved without a working registration answers, and is said to need one; the recorder is
    /// connected as ever.
    func testATelevisionWithoutARegistrationIsSaidToNeedOne() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: DemoRecorder(), television: DemoTV(), credentials: MemoryTVCredentials())
        await model.start()

        try await until("the television was not said to need a registration") { model.tvDriver?.facts.needsPairing == true }
        try await untilConnected(model)
        XCTAssertNotNil(model.tvHost?.problem)
        XCTAssertNil(model.problem, "the television's problem was said as the recorder's")
    }

    /// The demo lets go of the real television, which would otherwise answer beside the invented recorder, and
    /// gives it back when it ends.
    func testTheDemoLetsGoOfTheTelevisionAndGivesItBack() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        let model = bench.model(recorder: DemoRecorder(), television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await untilConnected(model)
        XCTAssertNotNil(model.tv)

        await model.enterDemo()
        XCTAssertNil(model.tv)
        try await untilIdle(model)

        await model.leaveDemo()
        XCTAssertNotNil(model.tv)
        try await until("the television was not connected again") { model.tv?.session.connected == true }
    }

    /// Coming back to the app on another network, and a report of the network changing, reach the television's
    /// link as they reach the recorder's: a television given up on is tried again by each.
    func testComingBackAndANewNetworkReachTheTelevisionToo() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        await television.goSilent()
        let model = bench.model(recorder: DemoRecorder(), television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await untilConnected(model)
        try await until("the television was not given up on") { model.tv?.session.gaveUp == true }

        await television.goSilent(false)
        bench.network = "elsewhere"
        model.wentToBackground()
        await model.returnedToForeground()
        try await until("coming back did not try the television again") { model.tv?.session.connected == true }

        await television.goSilent()
        _ = await model.tv?.ensureUp(evenIfRecent: true)
        XCTAssertEqual(model.tv?.session.gaveUp, true)
        await television.goSilent(false)
        bench.network = "further"
        model.networkReported()
        try await until("a report of the network did not try the television again") {
            model.tv?.session.connected == true
        }
    }

    /// Taking the television away forgets its link, its address and its registration.
    func testTakingTheTelevisionAwayForgetsItWhole() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        let credentials = await registered(with: television)
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials)
        await model.start()
        try await until("the television was not connected") { model.tv?.session.connected == true }

        model.removeTV()

        XCTAssertNil(model.tv)
        XCTAssertNil(credentials.load())
        XCTAssertNil(bench.defaults.string(forKey: DefaultsKey.tvHost))
        XCTAssertNil(bench.defaults.string(forKey: DefaultsKey.tvMac))
    }
}
