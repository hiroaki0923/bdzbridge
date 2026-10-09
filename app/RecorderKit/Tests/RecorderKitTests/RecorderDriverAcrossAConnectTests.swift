import Foundation
import XCTest
@testable import RecorderKit

/// What the recorder's driver sends after a wait inside one of its operations -- the queue read before what waits
/// is sent, the USB slot waited for before a change or a reservation that names it -- when something has been
/// made meanwhile: a connect to another address the reader chose, which lets go of the recorder the operation was
/// asked of; a check by another operation that heard the recorder busy; a connect that found the same recorder at
/// another address, which lets go of nothing. On a link of the test's own, in a world that puts down what was
/// asked at each address (`LinkWorld`).
@MainActor
final class RecorderDriverAcrossAConnectTests: XCTestCase {
    /// A sending of what waits for the recorder, held as the host is told the queue may have changed: the moment
    /// before the queue is read. Meanwhile the reader chooses another address, where the same recorder answers and
    /// is connected to. The recorder the sending was asked of has been let go of, so nothing is sent, to either
    /// address, and the row still waits. Again with the recorder still in play, while a check by another
    /// operation hears it busy: nothing is sent on the strength of that check either.
    func testASendingWhoseRecorderIsLetGoOfWhileItsQueueIsReadSendsNothing() async throws {
        for meanwhile in ["another address chosen", "a check heard the recorder busy"] {
            let world = LinkWorld()
            let store = try temporaryStore()
            world.cache = store
            let first = try ScriptedRecorder(at: Stub.host, udn: DeviceLinkTests.udn, world: world)
            world.devices[Stub.host] = first
            world.devices[DeviceLinkTests.moved] = try ScriptedRecorder(at: DeviceLinkTests.moved,
                                                                        udn: DeviceLinkTests.udn, world: world)
            let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
            let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                                  environment: world.environment)
            link.owner = world
            await link.connect()
            XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
            try await store.queue(pending("サンプル劇場", start: Date().addingTimeInterval(24 * 3600)))
            let waiting = try await store.pendingReservations()

            world.onQueueWritten = {
                world.onQueueWritten = nil
                if meanwhile == "another address chosen" {
                    link.forgetTheDevice()
                    link.host = DeviceLinkTests.moved
                    await link.connect()
                    XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
                } else {
                    await first.answer(.busy)
                    _ = await link.check(evenIfRecent: true)
                    await first.answer(.itself)
                    XCTAssertFalse(link.mayBeSent, "the check was meant to hear the recorder busy")
                }
                world.events = []
            }
            let sent = await driver.sendWhatWaits()

            XCTAssertNil(sent.round, "a round ran: \(meanwhile)")
            XCTAssertNil(sent.list, meanwhile)
            XCTAssertEqual(world.events.filter { $0.hasPrefix("ask") }, [], "something was sent: \(meanwhile)")
            expectEqual(try await store.pendingReservations(), waiting, meanwhile)
            XCTAssertFalse(link.session.gaveUp, meanwhile)
        }
    }

    /// A change, and a reservation, that go to the USB disk while the slot has not answered it since the recorder
    /// last answered, with the slot's read held. Meanwhile the recorder falls silent where it was and a connect
    /// finds it at another address, where it says it is the same recorder: nothing was let go of, and the link
    /// asks through a client of the connect's own. The slot's read let go answers the disk; the change and the
    /// create go to the address the recorder answers at now, nothing more is asked where it was, and nobody is
    /// given up on.
    func testAWriteThatWaitedForTheSlotGoesWhereTheRecorderAnswersNow() async throws {
        let program = try await aProgramme()
        for write in ["the change", "the reservation"] {
            let world = LinkWorld()
            let store = try temporaryStore()
            try await store.keep(knownUSBDisk: Self.usbDisk)
            world.cache = store
            // The slot is not read again by itself while the test runs: it is the write that waits for it.
            world.slotReadAgainAfter = .seconds(600)
            let held = try ReservationRequest(title: "サンプル劇場", start: program.start.addingTimeInterval(86_400),
                                              durationSec: 1800, repeatCode: XCTUnwrap(Codes.repeatCodes["none"]),
                                              broadcastingType: 2, serviceID: 0x400,
                                              qualityCode: XCTUnwrap(Codes.quality["DR"]), eventID: 0x311f)
            let first = try SlotRecorder(at: Stub.host, udn: DeviceLinkTests.udn, holding: [("2200", held)],
                                         world: world)
            let found = try SlotRecorder(at: DeviceLinkTests.moved, udn: DeviceLinkTests.udn,
                                         holding: [("2200", held)], world: world)
            world.devices[Stub.host] = first
            world.devices[DeviceLinkTests.moved] = found
            world.near = [DeviceLinkTests.moved]
            world.found = try await RecorderClient(host: DeviceLinkTests.moved, transport: found).describe()
            let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
            let link = DeviceLink(host: Stub.host, session: SessionState(mac: DeviceLinkTests.mac), driver: driver,
                                  environment: world.environment)
            link.owner = world
            await link.connect()
            XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
            XCTAssertTrue(link.session.usbDiskUnanswered, "the slot was meant to be still to answer the disk")
            let listed = await driver.reservations()
            let row = try XCTUnwrap(listed?.first)
            let began = link.generation

            await first.holdTheSlot()
            let writing = Task { () -> String in
                if write == "the change" {
                    let came = await driver.update(row, quality: "SR", repeating: "none", disk: RecorderDisk.usbID,
                                                   inHand: { [] })
                    return came.altered.map { "\($0)" } ?? "nil"
                }
                let came = await driver.reserve(program, quality: "DR", repeating: "none", disk: RecorderDisk.usbID)
                return "\(came.reserved)"
            }
            await first.whenTheSlotIsHeld()
            await first.goSilent()
            await found.answerTheSlotWithTheDisk()
            await link.connect()
            XCTAssertEqual(link.host, DeviceLinkTests.moved, "the recorder was not followed")
            XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
            XCTAssertEqual(link.generation, began, "the same recorder at another address let go of it")
            world.events = []
            await first.answerTheSlotWithTheDisk()
            await first.letTheSlotGo()

            let came = await writing.value
            XCTAssertTrue(came.hasPrefix(write == "the change" ? "done" : "made"), "\(write): \(came)")
            let asked = write == "the change" ? "X_UpdateRecordSchedule" : "X_CreateRecordSchedule"
            XCTAssertFalse(world.events.contains("ask \(asked) at \(Stub.host)"),
                           "\(write) went where the recorder was")
            XCTAssertTrue(world.events.contains("ask \(asked) at \(DeviceLinkTests.moved)"),
                          "\(write) did not go where the recorder answers now")
            XCTAssertTrue(link.session.connected, write)
            XCTAssertFalse(link.session.gaveUp, write)
        }
    }

    /// The disk kept with the cache, and the slot answering it.
    static let usbDisk = RecorderDisk(destination: RecorderDisk.usbID, name: "録画用ディスク", mounted: true,
                                      freeMB: 123_456, totalMB: 2_000_398, registered: "2026-01-02T03:04:05+0900")

    /// A programme of the vectors' guide, read as the cache gives one.
    private func aProgramme() async throws -> GuideProgramRow {
        let store = try temporaryStore()
        let midnight = try XCTUnwrap(RecorderTime.parse("2026-09-14T00:00:00+09:00"))
        let guide = try Data(contentsOf: Vectors.directory.appendingPathComponent("epg-sample.dat"))
        _ = try await store.replace(try Epg.decode(guide), broadcasting: "td", at: midnight)
        let programs = try await store.programs(broadcasting: "td", since: midnight, limit: 5)
        return try XCTUnwrap(programs.first { !$0.title.isEmpty }, "the vectors' guide has no programme")
    }
}

/// A recorder at one address for the tests of a write that waits for the USB slot: it says who it is, or nothing
/// once it has gone silent; answers its slot with no disk until told to answer the disk known, holding the next
/// read of the slot when told; and keeps reservations as the rehearsals' recorder does (`RecorderReservations`).
/// Each ask is put down in the world, by its SOAP action or the file's name.
actor SlotRecorder: HTTPTransport {
    private let host: String
    private let description: String
    private let reservations: RecorderReservations
    private weak var world: LinkWorld?
    private var silent = false
    private var answersTheDisk = false
    private var holdsTheSlot = false
    private var held: CheckedContinuation<Void, Never>?
    private var watching: CheckedContinuation<Void, Never>?

    init(at host: String, udn: String, holding rows: [(creator: String, request: ReservationRequest)],
         world: LinkWorld) throws {
        self.host = host
        self.world = world
        description = try Vectors.descriptionXML(udn: udn)
        reservations = try RecorderReservations(rows, guide: Data())
    }

    func goSilent() { silent = true }
    func answerTheSlotWithTheDisk() { answersTheDisk = true }
    /// The next read of the slot gets no answer until `letTheSlotGo`.
    func holdTheSlot() { holdsTheSlot = true }

    func whenTheSlotIsHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { watching = $0 }
    }

    func letTheSlotGo() {
        held?.resume()
        held = nil
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let action = request.headers["SOAPACTION"]?.split(separator: "#").last.map { String($0.dropLast()) }
        await world?.put("ask \(action ?? request.url.lastPathComponent) at \(host)")
        if silent { throw RecorderError.transport("The request timed out.") }
        if request.url.lastPathComponent == "description.xml" {
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        guard action == "X_GetMediaInfo" else { return try await reservations.answer(request) }
        if holdsTheSlot {
            holdsTheSlot = false
            await withCheckedContinuation { slot in
                held = slot
                watching?.resume()
                watching = nil
            }
        }
        return answersTheDisk ? Self.diskAnswered : Self.noneAnswered
    }

    private static let diskAnswered = Stub.soap("X_GetMediaInfo", result:
        "<?xml version=\"1.0\"?><xsrs xmlns=\"urn:schemas-xsrs-org:metadata-1-0/x_srs/\"><name>録画用ディスク</name>"
        + "<mount>1</mount><remain>123456</remain><total>2000398</total>"
        + "<registeredTime>2026-01-02T03:04:05+0900</registeredTime><recordableRemain>654321</recordableRemain></xsrs>")
    /// As the slot answered right after a waking with a disk connected: no name and no registration, not mounted
    /// and of no size, which is no disk.
    private static let noneAnswered = Stub.soap("X_GetMediaInfo", result:
        "<?xml version=\"1.0\"?><xsrs xmlns=\"urn:schemas-xsrs-org:metadata-1-0/x_srs/\"><name></name><mount>0</mount>"
        + "<remain>0</remain><total>0</total><registeredTime></registeredTime><recordableRemain>0</recordableRemain>"
        + "</xsrs>")
}
