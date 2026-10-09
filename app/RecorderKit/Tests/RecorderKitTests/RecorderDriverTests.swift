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

    /// What the recorder's driver gives its host to say when nothing could be asked because the app is not
    /// connected: that it is not, and to press 再接続; and, while the local network permission is what stands in
    /// the way, the title the screens give that. In the letters the screens have shown.
    func testTheDriverSaysWhyTheAppIsNotConnected() async throws {
        let world = LinkWorld()
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                              environment: world.environment)
        link.owner = world
        XCTAssertEqual(driver.whyNotConnected, "レコーダーに接続していません。「再接続」を押してから、もう一度お試しください。")
        XCTAssertEqual(driver.whyNotConnected, RecorderDriver.notConnected)

        world.blocked = true
        await link.connect()
        XCTAssertTrue(link.session.connectBlocked, "the connect did not end waiting for the permission")
        XCTAssertEqual(driver.whyNotConnected, "ローカルネットワークへのアクセスが許可されていません")
        XCTAssertEqual(driver.whyNotConnected, LocalNetwork.accessNotAllowed)
    }

    /// A television's reservation given to the recorder's driver to delete is none of its: nothing is asked of
    /// the recorder, not the read a delete begins with, the list in hand is not looked at, no line goes up and
    /// the line of what went wrong is as it was. Nothing was deleted, and no list is handed back. The recorder is
    /// there and connected, and the list in hand holds the very row, so that a delete that went on would have
    /// asked it something.
    func testATelevisionsReservationDeletedThroughTheRecordersDriverIsLeftAlone() async throws {
        let (world, driver, link) = try await connected()
        let televisions = try Self.televisionsReservation()
        let begun = world.begun.count
        var lookedIn = 0

        let came = await driver.cancel(televisions, inHand: {
            lookedIn += 1
            return [televisions]
        })

        XCTAssertFalse(came.deleted)
        XCTAssertNil(came.list, "a list was read for another device's reservation")
        XCTAssertEqual(world.events, [], "something was asked, sent or told for another device's reservation")
        XCTAssertEqual(lookedIn, 0, "the list in hand was looked in for another device's reservation")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for another device's reservation")
        XCTAssertEqual(world.problem, Self.left, "something was said for another device's reservation")
        XCTAssertTrue(link.session.connected)
    }

    /// The same for a change: no result, no list, nothing asked or looked at, no line, the line as it was. Nor is
    /// the disk the last request found not to be had forgotten, as a change of the recorder's own begins by doing:
    /// the sheets go on reading it for the request that found it.
    func testATelevisionsReservationChangedThroughTheRecordersDriverIsLeftAlone() async throws {
        let (world, driver, link) = try await connected()
        let televisions = try Self.televisionsReservation()
        link.session.slotHadNoDisk(for: RecorderDisk.usbID)
        let begun = world.begun.count
        var lookedIn = 0

        let came = await driver.update(televisions, quality: "SR", repeating: "daily", disk: nil, inHand: {
            lookedIn += 1
            return [televisions]
        })

        XCTAssertNil(came.altered, "a change of another device's reservation was answered")
        XCTAssertNil(came.list, "a list was read for another device's reservation")
        XCTAssertEqual(world.events, [], "something was asked, sent or told for another device's reservation")
        XCTAssertEqual(lookedIn, 0, "the list in hand was looked in for another device's reservation")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for another device's reservation")
        XCTAssertEqual(world.problem, Self.left, "something was said for another device's reservation")
        XCTAssertEqual(link.session.diskNotHad, RecorderDisk.usbID,
                       "the disk not had was forgotten for another device's reservation")
        XCTAssertTrue(link.session.connected)
    }

    /// A recorder at the bench's address, on a link of the test's own connected to it a moment ago, and the world
    /// it reaches, with nothing put down yet and an earlier failure's line left. The link is handed back with the
    /// driver, which holds it weakly.
    private func connected() async throws -> (LinkWorld, RecorderDriver, DeviceLink) {
        let world = LinkWorld()
        world.devices[Stub.host] = try ScriptedRecorder(at: Stub.host, udn: DeviceLinkTests.udn, world: world)
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        world.events = []
        world.problem = Self.left
        return (world, driver, link)
    }

    /// A reservation of a programme as a television lists it, read the way its driver reads one.
    private static func televisionsReservation() throws -> Reservation {
        try XCTUnwrap(TVScheduleRow(id: "recording.41", type: "recording",
                                    uri: "tv:isdbt?trip=65534.65533.1024&srvName=サンプルテレビ",
                                    startDateTime: "2030-11-01T21:00:00+0900", durationSec: 3600,
                                    title: "サンプル劇場", channelName: "サンプルテレビ", repeatType: "1",
                                    overlapStatus: "notOverlapped", recordingStatus: "notStarted", quality: "DR",
                                    eventId: "12345").reservation())
    }
}
