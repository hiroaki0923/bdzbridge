import Foundation
import XCTest
import RecorderKit

/// What the app's hosts ask both drivers through (`ReservationDriver`), the six steps written once over it. Here
/// the one rule both doors keep, asked through the protocol of each driver alike: a row of another device is
/// refused, with nothing read, sent or said, as `RecorderDriverTests` and `TVDriverTests` hold it for each driver
/// by its own forms. Each device is there and connected, so that anything asked would have reached it.
@MainActor
final class ReservationDriverTests: XCTestCase {
    /// A line an earlier failure left on the screen.
    static let left = "left by the request before"

    func testEachDriverRefusesARowOfAnotherDeviceThroughTheProtocol() async throws {
        let recorderWorld = LinkWorld()
        recorderWorld.cache = try temporaryStore()
        recorderWorld.devices[Stub.host] = try ScriptedRecorder(at: Stub.host, udn: DeviceLinkTests.udn,
                                                                world: recorderWorld)
        let recorder = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let recorderLink = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: recorder,
                                      environment: recorderWorld.environment)
        recorderLink.owner = recorderWorld
        await recorderLink.connect()
        XCTAssertTrue(recorderLink.session.connected, recorderWorld.problem ?? "no reason given")

        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date().addingTimeInterval(-86_400),
                                                            cookieMaxAge: 1_209_600))
        let televisionWorld = LinkWorld()
        televisionWorld.cache = try temporaryStore()
        televisionWorld.devices[Stub.host] = television
        let tv = TVDriver(credentials: credentials, nickname: "BD Bridge", inFront: { true })
        let tvLink = DeviceLink(host: Stub.host, session: SessionState(device: nil), driver: tv,
                                environment: televisionWorld.environment)
        tvLink.owner = televisionWorld
        await tvLink.connect()
        XCTAssertTrue(tvLink.session.connected, televisionWorld.problem ?? "no reason given")

        let tomorrow = Date().addingTimeInterval(24 * 3600)
        let televisions = try XCTUnwrap(DemoTV.Schedule(id: "recording.41", title: "サンプル劇場", start: tomorrow,
                                                        eventId: 12345).row.reservation())
        var recorders = televisions
        recorders.id = "0x29"
        recorders.device = .recorder
        recorders.tvRow = nil
        let doors: [(driver: any ReservationDriver, world: LinkWorld, another: Reservation,
                     waiting: PendingReservation, which: String)] = [
            (recorder, recorderWorld, televisions, pending("サンプル紀行", start: tomorrow, target: .tv),
             "the recorder's driver"),
            (tv, televisionWorld, recorders, pending("サンプル紀行", start: tomorrow, target: .recorder),
             "the television's driver"),
        ]
        for door in doors {
            XCTAssertTrue(door.driver.canBeAsked, "\(door.which) could not be asked, so its door was not reached")
            door.world.events = []
            door.world.problem = Self.left
            let begun = door.world.begun.count
            let asked = await television.calls

            let cancelled = await door.driver.cancel(door.another)
            let changed = await door.driver.update(door.another,
                                                   .changing(quality: "DR", repeating: "none", disk: nil))
            let sent = await door.driver.resend(door.waiting, neverWaited: false)

            XCTAssertNil(cancelled.deleted, door.which)
            XCTAssertNil(cancelled.list, "\(door.which) read the list for another device's row")
            XCTAssertNil(changed.altered, door.which)
            XCTAssertNil(changed.list, "\(door.which) read the list for another device's row")
            XCTAssertNil(sent.round, "\(door.which) ran a round for another device's row")
            XCTAssertNil(sent.list, door.which)
            XCTAssertNil(sent.came, door.which)
            XCTAssertEqual(door.world.events, [], "\(door.which) asked, sent or told something for another's row")
            let after = await television.calls
            XCTAssertEqual(after, asked, "\(door.which): the television was sent something for another's row")
            XCTAssertEqual(Array(door.world.begun.dropFirst(begun)), [], "\(door.which) put a line up")
            XCTAssertEqual(door.world.problem, Self.left, "\(door.which) said something for another's row")
        }
    }
}
