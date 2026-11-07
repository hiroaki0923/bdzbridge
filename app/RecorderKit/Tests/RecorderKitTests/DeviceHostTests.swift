import XCTest
@testable import RecorderKit

/// The six entries of a device's reservations, written once for both hosts (`DeviceHost`), over a stand-in host and
/// driver: the cache opened first, a list kept where the entry began to keep it, what follows a reservation and a
/// sending, and what is said with no driver to ask. What a driver does is its own tests'.
@MainActor
final class DeviceHostTests: XCTestCase {
    private final class Driver: ReservationDriver {
        var canBeAsked = true
        var events: [String] = []
        var list: [Reservation]? = []
        /// Holds the read of the list until `release`.
        var holdsTheRead = false
        private var held: CheckedContinuation<Void, Never>?
        var isHolding: Bool { held != nil }
        func release() {
            held?.resume()
            held = nil
        }

        func reservations() async -> [Reservation]? {
            events.append("read")
            if holdsTheRead { await withCheckedContinuation { held = $0 } }
            return list
        }
        func refreshReservations() async -> [Reservation]? {
            events.append("refresh")
            return list
        }
        func cancel(_ reservation: Reservation) async -> (deleted: Altered?, list: [Reservation]?) {
            events.append("cancel \(reservation.id)")
            return (.notDone("断られました"), list)
        }
        func update(_ reservation: Reservation, _ terms: ReservationTerms) async
            -> (altered: Altered?, list: [Reservation]?) {
            events.append("update \(reservation.id) \(terms.quality)")
            return (.done(saying: nil), list)
        }
        func reserve(_ program: GuideProgramRow, _ terms: ReservationTerms) async
            -> (reserved: Reserved, list: [Reservation]?) {
            events.append("reserve \(program.eventID)")
            return (.made(saying: "予約しました"), list)
        }
        func resend(_ waiting: PendingReservation, neverWaited: Bool) async
            -> (round: PendingQueue.Outcome?, list: [Reservation]?, came: Reserved?) {
            events.append("resend")
            return (PendingQueue.Outcome(slot: .tv), list, .made(saying: nil))
        }
    }

    private final class Host: DeviceHost {
        static var slot: DeviceSlot { .tv }
        var problem: String?
        var isBusy = false
        var reservations: [Reservation] = []
        var reservationsByProgram: [String: Reservation] = [:]
        var reservationsRead: Date?
        var report: String?
        var reservationDriver: (any ReservationDriver)?
        var deviceSession: SessionState?
        /// Where a list is kept now: a name, which an entry notes as it begins.
        var keptOn = "first"
        var kept: [String] = []
        var events: [String] = []
        var keeping: @MainActor ([Reservation]) -> Void {
            let on = keptOn
            return { [unowned self] list in kept.append("\(on): \(list.count)") }
        }
        /// Holds the opening of the cache until `release`.
        var holdsTheCache = false
        private var held: CheckedContinuation<Void, Never>?
        var isHolding: Bool { held != nil }
        func release() {
            held?.resume()
            held = nil
        }
        func openCache() async {
            events.append("open the cache")
            if holdsTheCache { await withCheckedContinuation { held = $0 } }
        }
        func afterAReservation(_ reserved: Reserved) async { events.append("after \(reserved)") }
        func tell(_ round: PendingQueue.Outcome?) async { events.append(round == nil ? "tell nothing" : "tell the round") }
    }

    private var host: Host!
    private var driver: Driver!

    override func setUp() async throws {
        host = Host()
        driver = Driver()
        host.reservationDriver = driver
    }

    private func reservation(_ id: String) -> Reservation {
        Reservation(id: id, title: "サンプル番組", start: Date(timeIntervalSince1970: 1_800_000_000), durationSec: 1800,
                    repeatCode: "1", broadcastingType: 2, serviceID: 0x400, eventID: 0x311f, qualityCode: 240,
                    recording: false, conflict: false, destination: "HDD", sizeMB: nil, creator: "1100",
                    genreCode: nil)
    }

    private var program: GuideProgramRow {
        GuideProgramRow(broadcasting: "td", serviceID: 0x400, serviceName: "サンプル総合", eventID: 0x311f,
                        start: Date(timeIntervalSince1970: 1_800_000_000),
                        end: Date(timeIntervalSince1970: 1_800_001_800), title: "サンプル番組", summary: "",
                        extended: "", genres: [], copyControl: 0, parental: 0, isReference: false,
                        referenceServiceID: nil, referenceEventID: nil)
    }

    func testTheCacheIsOpenedBeforeEachEntryAsksTheDevice() async {
        let terms = ReservationTerms.changing(quality: "DR", repeating: "1", disk: nil)
        _ = await host.readReservations()
        await host.refreshReservations()
        _ = await host.cancel(reservation("a"))
        _ = await host.change(reservation("a"), terms)
        _ = await host.reserve(program, .reserving(quality: "DR", repeating: "1", disk: "HDD"))
        XCTAssertEqual(host.events.filter { $0 == "open the cache" }.count, 5)
        XCTAssertEqual(driver.events, ["read", "refresh", "cancel a", "update a DR", "reserve \(0x311f)"])

        host.events = []
        _ = await host.readReservationsNow()
        XCTAssertEqual(host.events, [], "the read with nothing before it opens nothing")
    }

    func testAListIsKeptWhereTheEntryBeganToKeepIt() async {
        driver.list = [reservation("a"), reservation("b")]
        driver.holdsTheRead = true
        let host = host!, driver = driver!
        let reading = Task { await host.readReservations() }
        let holding = await eventually { driver.isHolding }
        XCTAssertTrue(holding)
        host.keptOn = "second"
        driver.release()
        let read = await reading.value
        XCTAssertEqual(read?.count, 2)
        XCTAssertEqual(host.kept, ["first: 2"], "a list read for a device let go of meanwhile is kept where it began")

        // Let go of while the cache was being opened, before anything was asked.
        driver.holdsTheRead = false
        host.holdsTheCache = true
        host.kept = []
        host.keptOn = "third"
        let again = Task { await host.readReservations() }
        let opening = await eventually { host.isHolding }
        XCTAssertTrue(opening)
        host.keptOn = "fourth"
        host.release()
        _ = await again.value
        XCTAssertEqual(host.kept, ["third: 2"])
    }

    func testAListThatCouldNotBeReadLeavesTheLastOne() async {
        driver.list = nil
        let read = await host.readReservations()
        XCTAssertNil(read)
        XCTAssertEqual(host.kept, [])
    }

    func testARefusedDeleteKeepsTheListItRead() async {
        driver.list = [reservation("b")]
        let came = await host.cancel(reservation("a"))
        XCTAssertEqual(came, .notDone("断られました"))
        XCTAssertEqual(host.kept, ["first: 1"])
    }

    func testAReservationIsFollowedByTheHostsOwnSteps() async {
        let came = await host.reserve(program, .reserving(quality: "DR", repeating: "1", disk: "HDD"))
        XCTAssertEqual(came, .made(saying: "予約しました"))
        XCTAssertEqual(host.events, ["open the cache", "after \(Reserved.made(saying: "予約しました"))"])
    }

    func testARowSentAgainIsToldAsASendingUnlessItNeverWaited() async throws {
        let row = PendingReservation(request: try XCTUnwrap(ReservationRequest(program: program, quality: "DR",
                                                                                repeating: "none")),
                                     serviceName: "サンプル総合", queuedAt: Date(), target: .tv)
        await host.resend(row)
        XCTAssertEqual(host.events.last, "tell the round")
        await host.resend(row, neverWaited: true)
        XCTAssertEqual(host.events.last, "tell nothing", "a reservation asked for a moment ago is said by its result")
    }

    func testWithNoDriverNothingIsSentAndTheDeviceIsNotConnected() async {
        host.reservationDriver = nil
        let cancelled = await host.cancel(reservation("a"))
        XCTAssertEqual(cancelled, .notDone(DeviceSlot.tv.notConnected))
        let changed = await host.change(reservation("a"), .changing(quality: "DR", repeating: "1", disk: nil))
        XCTAssertEqual(changed, .notDone(DeviceSlot.tv.notConnected))
        let reserved = await host.reserve(program, .reserving(quality: "DR", repeating: "1", disk: "HDD"))
        XCTAssertEqual(reserved, .notDone(DeviceSlot.tv.notConnected))
        XCTAssertFalse(host.events.contains { $0.hasPrefix("after") }, "nothing follows a reservation not sent")
        XCTAssertEqual(driver.events, [])
    }

    func testWhatIsShownIsOldOnlyWhileTheDeviceCannotBeAsked() {
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        host.reservationsRead = read
        XCTAssertNil(host.staleSince, "nothing old is shown with no rows")
        host.reservations = [reservation("a")]
        XCTAssertNil(host.staleSince, "the list is read as a screen appears while the device can be asked")
        driver.canBeAsked = false
        XCTAssertEqual(host.staleSince, read)
        host.reservationDriver = nil
        XCTAssertEqual(host.staleSince, read, "with its link gone as well")
    }
}
