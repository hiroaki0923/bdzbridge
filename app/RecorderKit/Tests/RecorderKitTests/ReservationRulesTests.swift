import Foundation
import XCTest
@testable import RecorderKit

/// The rules about a reservation that the app's screens used to hold themselves: finding again the one the
/// recorder has renumbered, and building the request for a new one and for a changed one.
final class ReservationRulesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func reservation(id: String, broadcastingType: Int = 2, serviceID: Int = 0x400, start: Date? = nil,
                             eventID: Int? = 0x311f, qualityCode: Int = 240, repeatCode: String = "1")
        -> Reservation {
        Reservation(id: id, title: "サンプル番組", start: start ?? self.start, durationSec: 1800,
                    repeatCode: repeatCode, broadcastingType: broadcastingType, serviceID: serviceID,
                    eventID: eventID, qualityCode: qualityCode, recording: false, conflict: false,
                    destination: "HDD", sizeMB: nil, creator: "1100", genreCode: nil)
    }

    // MARK: - finding it again

    func testAReservationIsFoundByItsIdWhileTheIdStands() {
        let held = reservation(id: "0x1")
        let list = [reservation(id: "0x2", serviceID: 0x408), held]
        XCTAssertEqual(list.current(held)?.id, "0x1")
    }

    /// The recorder renumbers its own automatic reservations a block at a time, the programmes unchanged.
    func testARenumberedReservationIsFoundByItsChannelAndStart() {
        let held = reservation(id: "0x1")
        let list = [reservation(id: "0x7", serviceID: 0x408), reservation(id: "0x9")]
        XCTAssertEqual(list.current(held)?.id, "0x9")
    }

    func testTheIdWinsOverAnotherReservationOnTheSameChannelAndStart() {
        let held = reservation(id: "0x1")
        let list = [reservation(id: "0x9"), held]
        XCTAssertEqual(list.current(held)?.id, "0x1")
    }

    /// While the id stands it is the reservation, even if what it says about the channel or the start has
    /// changed: a programme the recorder follows moves with its broadcast.
    func testTheIdIsItEvenWhenTheStartHasMoved() {
        let held = reservation(id: "0x1")
        let moved = reservation(id: "0x1", start: start.addingTimeInterval(900))
        let list = [reservation(id: "0x9"), moved]
        XCTAssertEqual(list.current(held), moved)
    }

    func testAnotherChannelAnotherTypeOrAnotherStartIsNotIt() {
        let held = reservation(id: "0x1")
        let list = [reservation(id: "0x2", serviceID: 0x408),
                    reservation(id: "0x3", broadcastingType: 3),
                    reservation(id: "0x4", start: start.addingTimeInterval(60))]
        XCTAssertNil(list.current(held))
        XCTAssertNil([Reservation]().current(held))
    }

    /// A television numbers its reservations for itself and may hold the same programme. Its row is not found
    /// among the recorder's, by the id or by the channel and the start, though it shares them all: what was
    /// found would be changed or deleted in its place. In a list of both, each finds its own.
    func testARowOfAnotherDeviceIsNotIt() {
        let held = reservation(id: "0x1")
        var televisions = held
        televisions.device = .tv
        XCTAssertNil([held].current(televisions), "found by its id")
        XCTAssertNil([reservation(id: "0x9")].current(televisions), "found by its channel and its start")
        XCTAssertEqual([televisions, held].current(held), held)
        XCTAssertEqual([held, televisions].current(televisions), televisions)
    }

    // MARK: - the request for a new one

    private func program(broadcasting: String = "td") -> GuideProgramRow {
        GuideProgramRow(broadcasting: broadcasting, serviceID: 0x400, serviceName: "サンプル総合", eventID: 0x311f,
                        start: start, end: start.addingTimeInterval(1800), title: "サンプル番組", summary: "",
                        extended: "", genres: [], copyControl: 0, parental: 0, isReference: false,
                        referenceServiceID: nil, referenceEventID: nil)
    }

    func testAProgrammeBecomesARequestThatFollowsIt() throws {
        let request = try XCTUnwrap(ReservationRequest(program: program(), quality: "DR", repeating: "none"))
        XCTAssertEqual(request, ReservationRequest(title: "サンプル番組", start: start, durationSec: 1800,
                                                   repeatCode: "1", broadcastingType: 2, serviceID: 0x400,
                                                   qualityCode: try XCTUnwrap(Codes.quality["DR"]),
                                                   eventID: 0x311f))
    }

    func testNamesTheTablesDoNotKnowMakeNoRequest() {
        XCTAssertNil(ReservationRequest(program: program(), quality: "なし", repeating: "none"))
        XCTAssertNil(ReservationRequest(program: program(), quality: "DR", repeating: "なし"))
        XCTAssertNil(ReservationRequest(program: program(broadcasting: "なし"), quality: "DR", repeating: "none"))
    }

    // MARK: - the request for a changed one

    /// Only the mode and the repeat change. The title, the times, the channel and the programme id are the
    /// reservation's own, so one that follows its programme goes on following it.
    func testAChangeKeepsEverythingButTheModeAndTheRepeat() throws {
        let held = reservation(id: "0x1")
        let request = try XCTUnwrap(ReservationRequest(changing: held, quality: "LSR", repeating: "daily"))
        XCTAssertEqual(request, ReservationRequest(title: held.title, start: held.start, durationSec: 1800,
                                                   repeatCode: "d", broadcastingType: 2, serviceID: 0x400,
                                                   qualityCode: try XCTUnwrap(Codes.quality["LSR"]),
                                                   eventID: 0x311f))
    }

    func testAChangeOfATimeOnlyReservationStaysTimeOnly() throws {
        let held = reservation(id: "0x1", eventID: nil)
        let request = try XCTUnwrap(ReservationRequest(changing: held, quality: "DR", repeating: "none"))
        XCTAssertNil(request.eventID)
    }

    func testAChangeToNamesTheTablesDoNotKnowMakesNoRequest() {
        let held = reservation(id: "0x1")
        XCTAssertNil(ReservationRequest(changing: held, quality: "なし", repeating: "none"))
        XCTAssertNil(ReservationRequest(changing: held, quality: "DR", repeating: "なし"))
    }
}
