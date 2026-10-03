import Foundation
import XCTest
@testable import RecorderKit

/// A television on a link: attached without being woken, told from another by the MAC it wakes on, asked for a
/// registration when it has none that works, and given a new cookie when the one in hand is past half its life.
@MainActor
final class TVDriverTests: XCTestCase {
    /// A link to `television` at `Stub.host`, its driver keeping `credentials`.
    private func makeLink(_ television: DemoTV, _ credentials: MemoryTVCredentials) -> (DeviceLink, TVDriver, LinkWorld) {
        let world = LinkWorld()
        world.devices[Stub.host] = television
        let driver = TVDriver(credentials: credentials, nickname: "BD Bridge")
        let link = DeviceLink(host: Stub.host, session: SessionState(), driver: driver, environment: world.environment)
        link.owner = world
        return (link, driver, world)
    }

    /// Credentials the television knows, with a cookie received `daysAgo`.
    private func registered(with television: DemoTV, daysAgo: Double = 1) async -> MemoryTVCredentials {
        await television.knows("BDBridge:test", cookie: "kept")
        return MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                 cookieReceived: Date().addingTimeInterval(-daysAgo * 86_400),
                                                 cookieMaxAge: 1_209_600))
    }

    /// A registered television is attached as it is, in standby: it says which one it is, its model and its disk,
    /// what waits is sent, and nothing wakes it. A cookie a day old is not renewed. The address and the MAC are
    /// written down.
    func testARegisteredTelevisionIsAttachedWithoutBeingWoken() async {
        let television = DemoTV()
        let (link, driver, world) = makeLink(television, await registered(with: television))

        await link.connect()

        XCTAssertTrue(link.session.connected)
        XCTAssertEqual(link.session.timesAttached, 1)
        XCTAssertEqual(driver.facts.model, DemoTV.model)
        XCTAssertEqual(driver.facts.storage, TVStorage(mounted: true, freeMB: 400, totalMB: 1000))
        XCTAssertFalse(driver.facts.needsPairing)
        XCTAssertEqual(world.events, ["address \(Stub.host)", "MAC \(DemoTV.mac)", "send what waits", "reached"])
        let calls = await television.calls
        XCTAssertEqual(calls, ["getSystemSupportedFunction cookie=no pin=no", "getInterfaceInformation cookie=no pin=no",
                               "getStorageList cookie=yes pin=no"])
    }

    /// Without a registration it answers, so it is there and not given up on; but nothing that needs one is sent,
    /// and the screens are told a PIN is wanted.
    func testWithNoRegistrationItIsThereButAsksForOne() async {
        let television = DemoTV()
        let (link, driver, world) = makeLink(television, MemoryTVCredentials())

        await link.connect()

        XCTAssertTrue(driver.facts.needsPairing)
        XCTAssertEqual(link.session.timesAttached, 0)
        XCTAssertFalse(link.session.gaveUp)
        XCTAssertFalse(link.session.unreachable)
        XCTAssertEqual(world.problem, ScalarError.notRegistered.explanation)
        XCTAssertFalse(world.events.contains("send what waits"))
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("getStorageList") }, "asked without a registration")
    }

    /// A cookie the television no longer takes is a registration gone: the same, after one ask.
    func testARefusedCookieAsksForTheRegistrationAgain() async {
        let television = DemoTV()
        let (link, driver, _) = makeLink(television, MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "stale")))

        await link.connect()

        XCTAssertTrue(driver.facts.needsPairing)
        XCTAssertFalse(link.session.gaveUp)
        let calls = await television.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("getStorageList") }.count, 1)
        XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") }, "the app registered by itself")
    }

    /// A cookie past half its life is renewed by a connect, after the read that shows the registration is
    /// there, with nothing on the request: the cookie in hand stays good, and the new one is kept.
    func testACookiePastHalfItsLifeIsRenewedWithNothingOnIt() async throws {
        let television = DemoTV()
        let credentials = await registered(with: television, daysAgo: 8)
        let (link, _, _) = makeLink(television, credentials)

        await link.connect()

        XCTAssertTrue(link.session.connected)
        let calls = await television.calls
        XCTAssertEqual(Array(calls.suffix(2)), ["getStorageList cookie=yes pin=no", "actRegister cookie=no pin=no"])
        let kept = try XCTUnwrap(credentials.load())
        XCTAssertNotEqual(kept.cookie, "kept")
        XCTAssertFalse(kept.renewalDue(now: Date()))
    }

    /// Another television at the address is not taken up: its cookie would not do, and what waits was made for
    /// the one registered. Nothing that needs a registration is sent to it.
    func testAnotherTelevisionAtTheAddressIsNotTakenUp() async {
        let television = DemoTV()
        let (link, _, world) = makeLink(television, await registered(with: television))
        await link.connect()
        XCTAssertTrue(link.session.connected)

        await television.becomeAnother(mac: "f8:4e:17:00:00:0b")
        let before = await television.calls.count
        await link.connect()

        XCTAssertFalse(link.session.connected)
        XCTAssertEqual(world.problem, TVDriver.anotherAnswered)
        let after = await television.calls.dropFirst(before)
        XCTAssertEqual(Array(after), ["getSystemSupportedFunction cookie=no pin=no"])
    }

    /// Silence is given up on at once: a television is not woken, nor looked for elsewhere.
    func testASilentTelevisionIsGivenUpWithoutWaking() async {
        let television = DemoTV()
        await television.goSilent()
        let (link, _, world) = makeLink(television, await registered(with: television))

        await link.connect()

        XCTAssertTrue(link.session.gaveUp)
        XCTAssertFalse(link.session.connected)
        XCTAssertEqual(world.count("packet"), 0, "a packet was sent to a television")
        XCTAssertEqual(world.count("search"), 0)
        let calls = await television.calls
        XCTAssertEqual(calls.count, 1, "asked again after silence")
    }

    /// The check before an operation asks whether it is on, and silence there is given up on as well.
    func testTheCheckBeforeAnOperationAsksWhetherItIsOn() async {
        let television = DemoTV()
        let (link, _, world) = makeLink(television, await registered(with: television))
        await link.connect()

        let up = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(up)
        let calls = await television.calls
        XCTAssertEqual(calls.last, "getPowerStatus cookie=no pin=no")

        await television.goSilent()
        let down = await link.ensureUp(evenIfRecent: true)
        XCTAssertFalse(down)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertEqual(world.count("packet"), 0)
    }
}
