import XCTest
@testable import RecorderKit

/// A television of the 2014 sets' kind (`DemoTV(older:)`), which answers error 12 to a method in a version it does
/// not have: it is connected to all the same, its disk is not known, and what it cannot do is said in words.
@MainActor
final class OlderTelevisionTests: XCTestCase {
    private func attached(older: Bool) async -> (LinkWorld, DeviceLink, DemoTV) {
        let world = LinkWorld()
        let television = DemoTV(older: older)
        await television.knows("BDBridge:test", cookie: "kept")
        world.devices[Stub.host] = television
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let link = DeviceLink(host: Stub.host, session: SessionState(),
                              driver: TVDriver(credentials: credentials, nickname: "RecBridge", inFront: { false }),
                              environment: world.environment)
        link.owner = world
        await link.connect()
        return (world, link, television)
    }

    func testAnOlderTelevisionIsConnectedToWithItsDiskNotKnown() async throws {
        let (world, link, _) = await attached(older: true)
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        XCTAssertNil(world.problem)
        let driver = try XCTUnwrap(link.driver as? TVDriver)
        XCTAssertNil(driver.facts.storage, "a television that does not say its disk has none known")
        XCTAssertEqual(driver.facts.model, DemoTV.model)
    }

    func testWhatAnOlderTelevisionCannotDoIsSaidInWords() async throws {
        let (world, link, _) = await attached(older: true)
        let driver = try XCTUnwrap(link.driver as? TVDriver)
        let read = await driver.reservations()
        XCTAssertNil(read)
        XCTAssertEqual(world.problem, "このテレビは、RecBridge が使う方式での予約の一覧の読み取りに対応していません")
        XCTAssertTrue(link.session.connected, "a method the television does not have is no reason to lose it")
    }

    func testANewerTelevisionStillSaysItsDisk() async throws {
        let (_, link, _) = await attached(older: false)
        let driver = try XCTUnwrap(link.driver as? TVDriver)
        XCTAssertEqual(driver.facts.storage?.mounted, true)
    }

    func testTheStorageOfAnOlderTelevisionIsNoneAndNothingElseIsAsked() async throws {
        let television = DemoTV(older: true)
        await television.knows("BDBridge:test", cookie: "kept")
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let client = ScalarClient(host: Stub.host, transport: television, credentials: credentials)
        let storage = try await client.storage()
        XCTAssertNil(storage)
        let calls = await television.calls
        XCTAssertEqual(calls.count, 1, "the storage was asked once, and nothing in its place")
    }

    func testErrorTwelveIsSomethingTheTelevisionCannotDo() {
        let error = ScalarError.rpc(method: "addSchedule", version: "1.1", code: 12, message: "addSchedule")
        XCTAssertEqual(error.explanation, "このテレビは、RecBridge が使う方式での予約に対応していません")
        XCTAssertEqual(error.failure, .deviceCannot(reason: error.explanation))
    }
}
