import XCTest
@testable import RecorderKit

/// The recorder answers UPnP error 402 to any deviation in a request, so these compare whole payload strings
/// rather than parsed shapes.
final class XsrsVectorTests: XCTestCase {
    private func request(from input: [String: Any]) throws -> ReservationRequest {
        let start = try XCTUnwrap(RecorderTime.parse(input.string("start")), "unparsable start in the vector")
        return ReservationRequest(
            title: input.string("title"),
            start: start,
            durationSec: try XCTUnwrap(input.int("duration_sec")),
            repeatCode: input.string("repeat_code"),
            broadcastingType: try XCTUnwrap(input.int("broadcasting_type")),
            serviceID: try XCTUnwrap(input.int("service_id")),
            qualityCode: try XCTUnwrap(input.int("quality_code")),
            eventID: input.int("event_id")
        )
    }

    func testSoapBodyMatchesTheVector() throws {
        let example = try Vectors.load("xsrs.json").dictionary("soap").dictionary("example")
        let arguments = example.list("args").compactMap { pair -> (String, String)? in
            guard let pair = pair as? [String], pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
        XCTAssertEqual(Soap.body(service: example.string("service"), action: example.string("action"),
                                 arguments: arguments),
                       example.string("body"))
    }

    func testCreateElementsMatchTheVectors() throws {
        let cases = try Vectors.load("xsrs.json").dictionaries("create_elements")
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let built = XsrsElements.create(try request(from: testCase.dictionary("input")))
            XCTAssertEqual(built, testCase.string("elements"), testCase.string("name"))
        }
    }

    func testUpdateElementsCarryTheID() throws {
        let vector = try Vectors.load("xsrs.json").dictionary("update_elements")
        let built = XsrsElements.update(id: vector.string("reservation_id"),
                                        try request(from: vector.dictionary("input")))
        XCTAssertEqual(built, vector.string("elements"))
    }

    func testTitleUpdateElementsCarryOnlyTheChanges() throws {
        let cases = try Vectors.load("xsrs.json").dictionaries("title_update_elements")
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let input = testCase.dictionary("input")
            let built = XsrsElements.titleUpdate(id: input.string("title_id"),
                                                 title: input["title"] as? String,
                                                 protected: input["protected"] as? Bool,
                                                 isNew: input["is_new"] as? Bool)
            XCTAssertEqual(built, testCase.string("elements"))
        }
    }

    func testReservationParsingMatchesTheVector() throws {
        let vector = try Vectors.load("xsrs.json").dictionary("parse_reservation")
        let item = try XmlNode.parse(vector.string("item"))
        let reservation = try XCTUnwrap(XsrsParse.reservation(item))
        let expected = vector.dictionary("expected")

        XCTAssertEqual(reservation.id, expected.string("id"))
        XCTAssertEqual(reservation.title, expected.string("title"))
        XCTAssertEqual(RecorderTime.format(reservation.start), expected.string("start"))
        XCTAssertEqual(reservation.durationSec, expected.int("duration_sec"))
        XCTAssertEqual(reservation.repeatCode, expected.string("repeat_code"))
        XCTAssertEqual(reservation.broadcastingType, expected.int("broadcasting_type"))
        XCTAssertEqual(reservation.serviceID, expected.int("service_id"))
        XCTAssertEqual(reservation.eventID, expected.int("event_id"))
        XCTAssertEqual(reservation.qualityCode, expected.int("quality_code"))
        XCTAssertEqual(reservation.recording, expected.bool("recording"))
        XCTAssertEqual(reservation.conflict, expected.bool("conflict"))
        XCTAssertEqual(reservation.destination, expected.string("destination"))
        XCTAssertEqual(reservation.sizeMB, expected.int("size_mb"))
        XCTAssertEqual(reservation.creator, expected["creator"] as? String)
        XCTAssertEqual(reservation.genreCode, expected.int("genre_code"))
    }

    func testTitleParsingMatchesTheVectors() throws {
        let cases = try Vectors.load("xsrs.json").dictionaries("parse_title")
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let item = try XmlNode.parse(testCase.string("item"))
            let title = try XCTUnwrap(XsrsParse.title(item))
            let expected = testCase.dictionary("expected")

            XCTAssertEqual(title.id, expected.string("id"))
            XCTAssertEqual(title.title, expected.string("title"))
            XCTAssertEqual(RecorderTime.format(title.start), expected.string("start"))
            XCTAssertEqual(title.durationSec, expected.int("duration_sec"))
            XCTAssertEqual(title.broadcastingType, expected.int("broadcasting_type"))
            XCTAssertEqual(title.serviceID, expected.int("service_id"))
            XCTAssertEqual(title.qualityCode, expected.int("quality_code"))
            XCTAssertEqual(title.protected, expected.bool("protected"))
            XCTAssertEqual(title.isNew, expected.bool("is_new"))
            XCTAssertEqual(title.destination, expected.string("destination"))
            XCTAssertEqual(title.sizeMB, expected.int("size_mb"))
            XCTAssertEqual(title.genreCode, expected.int("genre_code"))
            XCTAssertEqual(title.lastPlayed.map(RecorderTime.format), expected["last_played"] as? String)
            XCTAssertEqual(title.resumeSec, expected.int("resume_sec"))
        }
    }

    func testDlnaIDIsTheLowThirtyTwoBitsOfTheTitleID() throws {
        let item = try XmlNode.parse(
            "<item id=\"0x0000010000034d78\"><scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
            + "<scheduledDuration>60</scheduledDuration></item>")
        XCTAssertEqual(try XCTUnwrap(XsrsParse.title(item)).dlnaID, "V_216440")
    }
}
