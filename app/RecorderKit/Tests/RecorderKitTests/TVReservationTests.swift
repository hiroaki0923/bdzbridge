import Foundation
import XCTest
@testable import RecorderKit

/// A television's station read from a row of its list, and a reservation written as a television is sent one:
/// the start, the repeat, and the two bodies. The rows are in the television's shapes with invented values.
final class TVReservationTests: XCTestCase {
    private let uri = "tv:isdbbs?trip=65534.65533.2048&srvName=サンプルBS"

    /// A moment of November 2026 in Japan. Its first day is a Sunday there.
    private func japan(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let midnight = 1_793_458_800 + (day - 1) * 86_400
        return Date(timeIntervalSince1970: TimeInterval(midnight + hour * 3600 + minute * 60 + second))
    }

    /// Runs `check` with the phone in Japan and in three zones where the hour is another and, for most of the
    /// day, the date and the weekday as well: nine hours behind, nineteen behind, five ahead. The zone is the
    /// process's own, so it is put back whatever happens.
    private func inEachZone(_ check: (String) throws -> Void) throws {
        let phone = NSTimeZone.default
        defer { NSTimeZone.default = phone }
        for zone in ["Asia/Tokyo", "UTC", "Pacific/Honolulu", "Pacific/Kiritimati"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            try check(zone)
        }
    }

    // MARK: - a station

    /// A row of the list of stations, with the three fields that are looked at or pointedly not, as given:
    /// nil leaves the field out.
    private func row(uri: Any?, triplet: Any? = "65534.65533.2048", media: Any? = "tv") -> [String: Any] {
        var row: [String: Any] = ["title": "みほん放送", "index": 3, "dispNum": "999", "directRemoteNum": -1]
        row["uri"] = uri
        row["tripletStr"] = triplet
        row["programMediaType"] = media
        return row
    }

    /// A station is the type it was asked for under and the last number of its triplet, and its uri is kept as
    /// it came, byte for byte, whatever is in the name -- an ideographic space, a half-width one, an ampersand
    /// and what could pass for another query, a letter written in two scalars, nothing at all -- and whatever
    /// the row calls the station beside it. What kind of programme it says it carries is not looked at.
    func testAStationIsItsTypeItsServiceAndItsUriAsItCame() {
        let names = ["サンプル\u{3000}BS", "サンプル BS 4K", "サンプル&BS=2?trip=1.2.3&srvName=4", "サンフ\u{309A}ルBS", ""]
        for name in names {
            let uri = "tv:isdbbs?trip=65534.65533.2048&srvName=\(name)"
            let station = TVStation(row(uri: uri), broadcastingType: 3)
            XCTAssertEqual(station?.broadcastingType, 3, name)
            XCTAssertEqual(station?.serviceID, 2048, name)
            XCTAssertEqual(station.map { Array($0.uri.utf8) }, Array(uri.utf8), name)
        }
        let kinds: [Any?] = ["tv", "radio", "", nil, 7]
        for kind in kinds {
            XCTAssertEqual(TVStation(row(uri: uri, media: kind), broadcastingType: 3),
                           TVStation(broadcastingType: 3, serviceID: 2048, uri: uri), "\(String(describing: kind))")
        }
        XCTAssertEqual(TVStation(row(uri: uri, triplet: "0.0.65535"), broadcastingType: 24),
                       TVStation(broadcastingType: 24, serviceID: 65535, uri: uri))
    }

    /// A row with no uri, or with no triplet that reads as three numbers, is no station.
    func testARowWithNoUriOrNoTripletIsNoStation() {
        let noURI: [Any?] = [nil, "", 7]
        for missing in noURI {
            XCTAssertNil(TVStation(row(uri: missing), broadcastingType: 3), "\(String(describing: missing))")
        }
        let noTriplet: [Any?] = [
            nil, "", 2048, "2048", "65534.65533", "65534.65533.2048.1", "65534.65533.x", "65534.65533.-2048",
            "65534.65533.+5", "..2048", "65534.65533.", "65534.65533.65536",
        ]
        for missing in noTriplet {
            XCTAssertNil(TVStation(row(uri: uri, triplet: missing), broadcastingType: 3),
                         "\(String(describing: missing))")
        }
    }

    // MARK: - a reservation as it is sent

    /// A start is written in Japan's time with the offset as the television writes it, `+0900` with no colon,
    /// whatever zone the phone is in -- also where the day in Japan is not the day in UTC, on either side of
    /// midnight. It names the time it was written from, and it is not how the recorder is sent one.
    func testAStartIsWrittenAsTheTelevisionWritesOneWhateverThePhonesZone() throws {
        let cases = [
            (japan(1, 21), "2026-11-01T21:00:00+0900"), (japan(2, 0, 30), "2026-11-02T00:30:00+0900"),
            (japan(1, 8, 59, 59), "2026-11-01T08:59:59+0900"), (japan(1, 0), "2026-11-01T00:00:00+0900"),
            (japan(30, 23, 59, 59), "2026-11-30T23:59:59+0900"),
        ]
        try inEachZone { zone in
            for (date, text) in cases {
                XCTAssertEqual(TVReservationBody.start(date), text, "the phone in \(zone)")
                XCTAssertEqual(RecorderTime.parse(text), date)
                XCTAssertNotEqual(RecorderTime.format(date), text)
            }
        }
    }

    /// Once and daily go as the recorder spells them and the repeat by the programme's name as `title`, at
    /// any hour of any day. A code the recorder's table does not have is not sent: the television's own
    /// `title` among them, which no request carries.
    func testARepeatIsSpelledAsTheTelevisionSpellsIt() throws {
        try inEachZone { zone in
            for day in 1...7 {
                for hour in [0, 3, 4, 12, 21] {
                    let start = japan(day, hour), at = "day \(day) at \(hour), the phone in \(zone)"
                    XCTAssertEqual(TVReservationBody.repeatType(for: "1", start: start), "1", at)
                    XCTAssertEqual(TVReservationBody.repeatType(for: "d", start: start), "d", at)
                    XCTAssertEqual(TVReservationBody.repeatType(for: "S001", start: start), "title", at)
                    for unknown in ["title", "", "w0", "w8", "w17", "W1", "daily", "S002"] {
                        XCTAssertNil(TVReservationBody.repeatType(for: unknown, start: start), "\(unknown) on \(at)")
                    }
                }
            }
        }
    }

    /// A weekly code is sent only for a start on its own weekday in Japan, whatever day it is where the phone
    /// is; Monday to Friday not for a Saturday's or a Sunday's programme, and Monday to Saturday not for a
    /// Sunday's. From four in the morning on: that is where a day of the guide begins.
    func testAWeeklyRepeatIsSentOnlyOnItsOwnDayInJapan() throws {
        let days = [(1, "w7"), (2, "w1"), (3, "w2"), (4, "w3"), (5, "w4"), (6, "w5"), (7, "w6")]
        try inEachZone { zone in
            for (day, own) in days {
                for (hour, minute) in [(4, 0), (8, 59), (12, 0), (21, 0), (23, 59)] {
                    let start = japan(day, hour, minute), at = "day \(day) at \(hour):\(minute), the phone in \(zone)"
                    for code in days.map(\.1) {
                        XCTAssertEqual(TVReservationBody.repeatType(for: code, start: start),
                                       code == own ? code : nil, "\(code) on \(at)")
                    }
                    XCTAssertEqual(TVReservationBody.repeatType(for: "w15", start: start),
                                   (2...6).contains(day) ? "w15" : nil, "Monday to Friday on \(at)")
                    XCTAssertEqual(TVReservationBody.repeatType(for: "w16", start: start),
                                   (2...7).contains(day) ? "w16" : nil, "Monday to Saturday on \(at)")
                }
            }
        }
    }

    /// No weekly code is sent for a start before four in the morning in Japan, where the day by the calendar
    /// is not the day by the guide: not that day's own, not the day before's, neither of the two ranges.
    func testNoWeeklyRepeatIsSentForAStartBeforeFourInTheMorning() throws {
        let weekly = ["w1", "w2", "w3", "w4", "w5", "w6", "w7", "w15", "w16"]
        try inEachZone { zone in
            for day in 1...7 {
                for (hour, minute, second) in [(0, 0, 0), (1, 30, 0), (3, 59, 59)] {
                    let start = japan(day, hour, minute, second)
                    for code in weekly {
                        XCTAssertNil(TVReservationBody.repeatType(for: code, start: start),
                                     "\(code) on day \(day) at \(hour):\(minute), the phone in \(zone)")
                    }
                }
            }
        }
    }

    /// A reservation's body is written for a programme on a station: the station's uri as it came, the
    /// request's title, start and length, the repeat and the programme id in the television's spellings. The
    /// create is sent seven fields and the question before it five, and no others -- no mode, whatever mode
    /// the request names. There is no body for a request with no programme id, nor for one whose repeat a
    /// television is not sent, nor for a station that is not the request's own channel: another kind of
    /// broadcast, or another service of the same kind.
    func testABodyIsWrittenForAProgrammeOnAStation() throws {
        let station = TVStation(broadcastingType: 3, serviceID: 2048,
                                uri: "tv:isdbbs?trip=65534.65533.2048&srvName=サンプル\u{3000}BS 4K")
        var request = ReservationRequest(title: "サンプル劇場 前編", start: japan(1, 21), durationSec: 1800,
                                         repeatCode: "S001", broadcastingType: 3, serviceID: 2048, qualityCode: 230,
                                         eventID: 12345)

        let body = try XCTUnwrap(TVReservationBody(request, on: station))

        XCTAssertEqual(Array(body.uri.utf8), Array(station.uri.utf8))
        XCTAssertEqual(body.title, "サンプル劇場 前編")
        XCTAssertEqual(body.startDateTime, "2026-11-01T21:00:00+0900")
        XCTAssertEqual(body.durationSec, 1800)
        XCTAssertEqual(body.repeatType, "title")
        XCTAssertEqual(body.eventId, "12345")
        let question: [String: Any] = [
            "uri": station.uri, "title": "サンプル劇場 前編", "startDateTime": "2026-11-01T21:00:00+0900",
            "durationSec": 1800, "repeatType": "title",
        ]
        let create: [String: Any] = [
            "type": "recording", "uri": station.uri, "title": "サンプル劇場 前編",
            "startDateTime": "2026-11-01T21:00:00+0900", "durationSec": 1800, "repeatType": "title",
            "eventId": "12345",
        ]
        XCTAssertEqual(body.asking as NSDictionary, question as NSDictionary)
        XCTAssertEqual(body.creating as NSDictionary, create as NSDictionary)

        let others = [(2, 2048, "another kind of broadcast"), (3, 2049, "another service"), (2, 1024, "both")]
        for (type, serviceID, name) in others {
            let other = TVStation(broadcastingType: type, serviceID: serviceID, uri: station.uri)
            XCTAssertNil(TVReservationBody(request, on: other), "a station that is not the programme's: \(name)")
        }

        request.repeatCode = "w1"
        XCTAssertNil(TVReservationBody(request, on: station), "Monday's code on a Sunday's programme")
        request.repeatCode = "w7"
        XCTAssertEqual(TVReservationBody(request, on: station)?.repeatType, "w7")
        request.eventID = 0
        XCTAssertEqual(TVReservationBody(request, on: station)?.eventId, "0")
        request.eventID = nil
        XCTAssertNil(TVReservationBody(request, on: station), "a reservation made by its times")
    }
}
