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

    /// The recorder takes a reservation to its USB disk in the very request the official app sends for the
    /// internal disk, with that one value changed: anything else that moved would be refused.
    func testAReservationToTheUSBDiskIsTheOfficialRequestWithOnlyItsDiskChanged() throws {
        let captured = try XCTUnwrap(Vectors.load("xsrs.json").dictionaries("create_elements")
            .first { $0.string("name").hasPrefix("captured") })
        let official = captured.string("elements")
        XCTAssertEqual(official.components(separatedBy: ">HDD<").count, 2, "the internal disk is named once")
        var request = try request(from: captured.dictionary("input"))
        request.destination = "USBHDD"

        XCTAssertEqual(XsrsElements.create(request),
                       official.replacingOccurrences(of: "<recordDestinationID>HDD</recordDestinationID>",
                                                     with: "<recordDestinationID>USBHDD</recordDestinationID>"))
    }

    /// A change sends back the disk the recorder named, now read from the recorder's own text. For the internal
    /// disk that has to come out as the official app sends it, or the recorder refuses the change.
    func testAChangeOfAReservationReadFromTheRecorderSendsTheInternalDiskAsCaptured() throws {
        let vector = try Vectors.load("xsrs.json").dictionary("parse_reservation")
        let held = try XCTUnwrap(XsrsParse.reservation(try XmlNode.parse(vector.string("item"))))
        let change = try XCTUnwrap(ReservationRequest(changing: held, quality: try XCTUnwrap(held.qualityName),
                                                      repeating: try XCTUnwrap(held.repeatName)))

        let elements = XsrsElements.update(id: held.id, change)
        XCTAssertEqual(elements.components(separatedBy: "<recordDestinationID>").count, 2, elements)
        XCTAssertTrue(elements.contains("<recordDestinationID>HDD</recordDestinationID>"), elements)
    }

    /// The same item as the recorder lists one on the USB disk: the disk is read from it, not taken for the internal
    /// one when the parser fails to see it, so the change sends it back.
    func testAChangeOfAReservationReadOnTheUSBDiskSendsThatDisk() throws {
        let vector = try Vectors.load("xsrs.json").dictionary("parse_reservation")
        let item = vector.string("item")
        let onUSB = item.replacingOccurrences(of: "<recordDestinationID>HDD</recordDestinationID>",
                                              with: "<recordDestinationID>USBHDD</recordDestinationID>")
        XCTAssertNotEqual(onUSB, item, "the captured item names its disk")
        let held = try XCTUnwrap(XsrsParse.reservation(try XmlNode.parse(onUSB)))
        let change = try XCTUnwrap(ReservationRequest(changing: held, quality: try XCTUnwrap(held.qualityName),
                                                      repeating: try XCTUnwrap(held.repeatName)))

        let elements = XsrsElements.update(id: held.id, change)
        XCTAssertTrue(elements.contains("<recordDestinationID>USBHDD</recordDestinationID>"),
                      "the disk the recorder listed was not read: \(elements)")
    }

    /// On a change the disk is text the recorder wrote, sent back, so it is escaped as the title is.
    func testADisksValueIsEscaped() {
        let request = ReservationRequest(title: "サンプル番組", start: Date(timeIntervalSince1970: 1_790_000_000),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2,
                                         serviceID: 0x400, qualityCode: 240, destination: "A&B<C>")
        let elements = XsrsElements.create(request)
        XCTAssertTrue(elements.contains("<recordDestinationID>A&amp;B&lt;C&gt;</recordDestinationID>"), elements)
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

    /// A reservation read from the recorder is the recorder's: no row of a television's comes with it, and what
    /// tells it apart in a list of both devices is its id as it stands.
    func testAReservationReadFromTheRecorderIsTheRecorders() throws {
        let vector = try Vectors.load("xsrs.json").dictionary("parse_reservation")
        let reservation = try XCTUnwrap(XsrsParse.reservation(try XmlNode.parse(vector.string("item"))))

        XCTAssertEqual(reservation.device, .recorder)
        XCTAssertNil(reservation.tvRow)
        XCTAssertFalse(reservation.id.isEmpty)
        XCTAssertEqual(reservation.listKey, reservation.id)
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

    func testRecorderRuleParsingMatchesTheVector() throws {
        let vector = try Vectors.load("xsrs.json").dictionary("recorder_rules")
        let rules = try XsrsParse.objects(inResult: vector.string("list_result")).map(XsrsParse.recorderRule)
        let expected = vector.dictionaries("parsed")
        XCTAssertEqual(rules.count, expected.count)
        for (rule, row) in zip(rules, expected) {
            XCTAssertEqual(rule.id, row.string("id"))
            XCTAssertEqual(rule.name, row.string("name"))
            XCTAssertEqual(rule.keywords, row["keywords"] as? [String])
            XCTAssertEqual(rule.excluded, row["excluded"] as? [String])
            XCTAssertEqual(rule.logic, row.string("logic"))
            XCTAssertEqual(rule.genreLevel1, row.int("genre_level1"))
            XCTAssertEqual(rule.genreLevel2, row.int("genre_level2"))
            XCTAssertEqual(rule.timeScope, row.string("time_scope"))
            XCTAssertEqual(rule.broadcastingScope, row.string("broadcasting_scope"))
            XCTAssertEqual(rule.qualityCode, row.int("quality_code"))
            XCTAssertEqual(rule.qualityCode4K, row.int("quality_code_4k"))
            XCTAssertEqual(rule.destination, row.string("destination"))
        }
    }

    func testRecorderRuleElementsMatchTheVectors() throws {
        let cases = try Vectors.load("xsrs.json").dictionary("recorder_rules").dictionaries("create_elements")
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let input = testCase.dictionary("input")
            let request = RecorderRuleRequest(keywords: input["keywords"] as? [String] ?? [],
                                              excluded: input["excluded"] as? [String] ?? [],
                                              logic: input["logic"] as? String ?? "OR",
                                              genreLevel1: input.int("genre_level1"),
                                              genreLevel2: input.int("genre_level2"),
                                              timeScope: input["time_scope"] as? String ?? "ALL",
                                              broadcastingScope: input["broadcasting_scope"] as? String ?? "ALL",
                                              qualityCode: try XCTUnwrap(input.int("quality_code")))
            XCTAssertEqual(XsrsElements.recorderRule(request), testCase.string("elements"), testCase.string("name"))
        }
    }

    /// A keyword condition to the USB disk is each condition the vectors pin with its disk changed and nothing
    /// else: the recorder took every other element of those as they are, and a condition is created and deleted,
    /// never written back, so an element that moved could not be put right in place.
    func testAConditionToTheUSBDiskIsTheConditionWithOnlyItsDiskChanged() throws {
        let cases = try Vectors.load("xsrs.json").dictionary("recorder_rules").dictionaries("create_elements")
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let input = testCase.dictionary("input")
            let request = RecorderRuleRequest(keywords: input["keywords"] as? [String] ?? [],
                                              excluded: input["excluded"] as? [String] ?? [],
                                              logic: input["logic"] as? String ?? "OR",
                                              genreLevel1: input.int("genre_level1"),
                                              genreLevel2: input.int("genre_level2"),
                                              timeScope: input["time_scope"] as? String ?? "ALL",
                                              broadcastingScope: input["broadcasting_scope"] as? String ?? "ALL",
                                              qualityCode: try XCTUnwrap(input.int("quality_code")),
                                              destination: "USBHDD")
            let pinned = testCase.string("elements")
            XCTAssertEqual(pinned.components(separatedBy: ">HDD<").count, 2, "the internal disk is named once")
            XCTAssertEqual(XsrsElements.recorderRule(request),
                           pinned.replacingOccurrences(of: "<recordDestinationID>HDD</recordDestinationID>",
                                                       with: "<recordDestinationID>USBHDD</recordDestinationID>"),
                           testCase.string("name"))
        }
    }

    /// A condition's disk is read from the list as the request carries it, and one listed with none is on the
    /// internal disk. The list is the captured one with its disk changed, a made-up answer until the recorder has
    /// been seen to list a condition to its USB disk.
    func testAConditionsDiskIsReadBack() throws {
        let captured = try Vectors.load("xsrs.json").dictionary("recorder_rules").string("list_result")
        let onUSB = captured.replacingOccurrences(of: "<recordDestinationID>HDD</recordDestinationID>",
                                                  with: "<recordDestinationID>USBHDD</recordDestinationID>")
        XCTAssertNotEqual(onUSB, captured, "the captured list names a disk")

        let rules = try XsrsParse.objects(inResult: onUSB).map(XsrsParse.recorderRule)
        let named = try XsrsParse.objects(inResult: captured).map { $0.child("recordDestinationID") != nil }
        XCTAssertEqual(rules.map(\.destination), named.map { $0 ? "USBHDD" : "HDD" })
        XCTAssertTrue(named.contains(false), "every condition in the list names a disk")
    }
}
