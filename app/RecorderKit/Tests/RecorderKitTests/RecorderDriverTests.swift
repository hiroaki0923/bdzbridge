import Foundation
import XCTest
@testable import RecorderKit

/// What the recorder's driver does with the reservations asked of it after its attach, on a link of its own in
/// a world that puts down what it was asked (`LinkWorld`). The steps themselves are held by the app's tests, which
/// ask them through the screens' entries; here, what needs no screen: the rule both drivers keep at their doors,
/// that a row of another device is refused with nothing read, sent or said, as `TVDriverTests` holds it for the
/// television's.
@MainActor
final class RecorderDriverTests: XCTestCase {
    /// A line an earlier failure left on the screen.
    static let left = "left by the request before"

    /// A row that waits for the television, sent again through the recorder's driver, is none of its: nothing is
    /// asked of the recorder, the row keeps its reason on the phone, the host is told nothing -- not even that the
    /// queue was written -- no line goes up, and the line of what went wrong is as it was. Nothing is handed back.
    /// The recorder is there and connected, and a row of its own waits with no reason beside the television's, so
    /// that any sending would have asked it something. With the cache gone, the recorder's own row is refused the
    /// same way.
    func testATelevisionsRowSentAgainThroughTheRecordersDriverIsLeftAlone() async throws {
        let world = LinkWorld()
        let store = try temporaryStore()
        world.cache = store
        world.devices[Stub.host] = try ScriptedRecorder(at: Stub.host, udn: DeviceLinkTests.udn, world: world)
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")

        let tomorrow = Date().addingTimeInterval(24 * 3600)
        let televisions = pending("サンプル紀行", eventID: 0x3120, start: tomorrow, problem: "前に断られた理由",
                                  target: .tv)
        let recorders = pending("サンプル劇場", eventID: 0x3121, start: tomorrow)
        try await store.queue(televisions)
        try await store.queue(recorders)
        let waiting = try await store.pendingReservations()
        world.events = []
        world.problem = Self.left
        let begun = world.begun.count
        let tries = link.session.link.tries

        let sent = await driver.resend(televisions)

        XCTAssertNil(sent.round, "a round ran for another device's row")
        XCTAssertNil(sent.list, "the list was read for another device's row")
        XCTAssertNil(sent.came)
        XCTAssertEqual(world.events, [], "something was asked, sent or told for another device's row")
        expectEqual(try await store.pendingReservations(), waiting, "the queue was written for another device's row")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for another device's row")
        XCTAssertEqual(world.problem, Self.left, "something was said for another device's row")
        XCTAssertTrue(link.session.connected)
        XCTAssertEqual(link.session.link.tries, tries, "a connect was made for another device's row")

        world.cache = nil
        let withoutACache = await driver.resend(recorders)
        XCTAssertNil(withoutACache.round)
        XCTAssertNil(withoutACache.list)
        XCTAssertEqual(world.events, [], "something was asked, sent or told with no cache to send from")
        expectEqual(try await store.pendingReservations(), waiting)
        XCTAssertEqual(world.problem, Self.left)
    }
}
