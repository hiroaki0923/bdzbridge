import Foundation
import XCTest
@testable import RecorderKit

/// What the recorder's driver does with the reservations asked of it after its attach, on a link of its own in
/// a world that puts down what it was asked (`LinkWorld`). The steps themselves are held by the app's tests, which
/// ask them through the screens' entries; here, what needs no screen: the rule both drivers keep at their doors,
/// that a row of another device is refused with nothing read, sent or said, as `TVDriverTests` holds it for the
/// television's; and the rule the change's door keeps of a reservation being recorded or over.
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

    /// With nothing to send, the recorder is asked nothing and no line goes up, as for a television: rows with a
    /// reason on them wait for the reader -- one held for another recorder, one turned down before -- and a
    /// sending finds nothing to send and runs no round. One whose programme is over, beside them, is dropped,
    /// still with no line and nothing asked of the recorder, and the round says so; the rows with a reason are
    /// held as they were. The recorder is there and connected, a moment ago, so that a sending with something to
    /// send would have asked it.
    func testWithNothingToSendTheRecorderIsAskedNothingAndNoLineGoesUp() async throws {
        // At whole seconds, as the cache keeps a start, so that the rows read back are the ones queued.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let tomorrow = now.addingTimeInterval(24 * 3600)
        let held = pending("サンプル劇場", eventID: 0x3121, start: tomorrow,
                           problem: RecorderDriver.heldForAnotherRecorder)
        let refused = pending("サンプル紀行", eventID: 0x3122, start: tomorrow.addingTimeInterval(3600),
                              problem: "前に断られた理由")
        let over = pending("サンプル天気", eventID: 0x3123, start: now.addingTimeInterval(-7200))
        // The round that ran, by what it dropped and what it held, nil for none.
        let cases: [(String, queued: [PendingReservation], came: (expired: [String], held: [String])?)] = [
            ("rows with a reason alone", [held, refused], nil),
            ("a row that is over beside them", [over, held, refused], ([over.id], [held.id, refused.id])),
        ]
        for (name, queued, came) in cases {
            let (world, driver, link) = try await connected()
            let store = try temporaryStore()
            for row in queued { try await store.queue(row) }
            world.cache = store
            let begun = world.begun.count

            let sent = await driver.sendWhatWaits()

            XCTAssertEqual(sent.round == nil, came == nil, "a round ran, or none did: \(name)")
            if let round = sent.round, let came {
                XCTAssertEqual(round.slot, .recorder, name)
                XCTAssertNil(round.stopped, name)
                XCTAssertEqual(round.expired.map(\.id), came.expired, name)
                XCTAssertEqual(round.held.map(\.id), came.held, name)
                XCTAssertEqual(round.sent + round.refused + round.deferred + round.alreadyThere, [], name)
            }
            XCTAssertNil(sent.list, name)
            XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up: \(name)")
            XCTAssertEqual(world.events.filter { $0.hasPrefix("ask") }, [], "the recorder was asked: \(name)")
            expectEqual(try await store.pendingReservations(), [held, refused], name)
            XCTAssertEqual(world.problem, Self.left, name)
            XCTAssertTrue(link.session.connected, name)
        }
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
    /// the recorder, not the read a delete begins with, no line goes up and the line of what went wrong is as it
    /// was. Nothing was deleted, and no result or list is handed back. The recorder is there and connected, so
    /// that a delete that went on would have asked it something.
    func testATelevisionsReservationDeletedThroughTheRecordersDriverIsLeftAlone() async throws {
        let (world, driver, link) = try await connected()
        let televisions = try Self.televisionsReservation()
        let begun = world.begun.count

        let came = await driver.cancel(televisions)

        XCTAssertNil(came.deleted, "a delete of another device's reservation was answered")
        XCTAssertNil(came.list, "a list was read for another device's reservation")
        XCTAssertEqual(world.events, [], "something was asked, sent or told for another device's reservation")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for another device's reservation")
        XCTAssertEqual(world.problem, Self.left, "something was said for another device's reservation")
        XCTAssertTrue(link.session.connected)
    }

    /// The same for a change: no result, no list, nothing asked, no line, the line as it was. Nor is the disk
    /// the last request found not to be had forgotten, as a change of the recorder's own begins by doing: the
    /// sheets go on reading it for the request that found it.
    func testATelevisionsReservationChangedThroughTheRecordersDriverIsLeftAlone() async throws {
        let (world, driver, link) = try await connected()
        let televisions = try Self.televisionsReservation()
        link.session.slotHadNoDisk(for: RecorderDisk.usbID)
        let begun = world.begun.count

        let came = await driver.update(televisions, quality: "SR", repeating: "daily", disk: nil)

        XCTAssertNil(came.altered, "a change of another device's reservation was answered")
        XCTAssertNil(came.list, "a list was read for another device's reservation")
        XCTAssertEqual(world.events, [], "something was asked, sent or told for another device's reservation")
        XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for another device's reservation")
        XCTAssertEqual(world.problem, Self.left, "something was said for another device's reservation")
        XCTAssertEqual(link.session.diskNotHad, RecorderDisk.usbID,
                       "the disk not had was forgotten for another device's reservation")
        XCTAssertTrue(link.session.connected)
    }

    /// Which of the recorder's reservations can be changed: not one the recorder says it is recording, whatever
    /// the clock says, nor one whose end has passed -- at its end, too -- and any other, a second before its end
    /// included. Each in the letters the screens show. And the change's door asks it of the row it is given: a
    /// reservation being recorded, or over, is answered with its sentence, nothing is read, sent or told, no line
    /// goes up and the line an earlier failure left stays, though the recorder is there and connected.
    func testAChangeOfAReservationBeingRecordedOrOverIsTurnedAwayAtItsDoor() async throws {
        let recording = "録画中の予約は変更できません。"
        let over = "放送が終わった予約は変更できません。"
        XCTAssertEqual(RecorderDriver.changeRecording, recording)
        XCTAssertEqual(RecorderDriver.changeEnded, over)
        var row = try Self.televisionsReservation()
        row.device = .recorder
        let start = row.start
        let end = row.end
        var beingRecorded = row
        beingRecorded.recording = true

        let cases: [(name: String, row: Reservation, now: Date, why: String?)] = [
            ("a day ahead", row, start - 86_400, nil),
            ("begun, and not recording by its flag", row, start + 60, nil),
            ("a second before its end", row, end - 1, nil),
            ("at its end", row, end, over),
            ("a day after its end", row, end + 86_400, over),
            ("recording, a day ahead by the clock", beingRecorded, start - 86_400, recording),
            ("recording, and begun", beingRecorded, start + 60, recording),
            ("recording, and over by the clock", beingRecorded, end + 60, recording),
        ]
        for (name, row, now, why) in cases {
            XCTAssertEqual(RecorderDriver.whyNot(changing: row, now: now), why, name)
        }

        let (world, driver, link) = try await connected()
        var ended = row
        ended.start = Date() - 7_200
        for (name, row, why) in [("being recorded", beingRecorded, recording), ("over", ended, over)] {
            let begun = world.begun.count
            let came = await driver.update(row, quality: "SR", repeating: "none", disk: nil)
            XCTAssertEqual(came.altered, .notDone(why), name)
            XCTAssertNil(came.list, "a list was read for a reservation \(name)")
            XCTAssertEqual(world.events, [], "something was asked, sent or told for a reservation \(name)")
            XCTAssertEqual(Array(world.begun.dropFirst(begun)), [], "a line went up for a reservation \(name)")
            XCTAssertEqual(world.problem, Self.left, "something was said on the line for a reservation \(name)")
        }
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
