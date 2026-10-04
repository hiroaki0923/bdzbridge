import Foundation
import XCTest
@testable import RecorderKit

/// A television's row read into the terms the screens show a reservation in, a reservation the app holds
/// found again in the list just read from the television, and what the list holds for a request that waits to
/// be sent, with whether that is all the request asks. The rows are in the television's shapes with invented
/// values.
final class TVScheduleTests: XCTestCase {
    private let startText = "2026-11-01T21:00:00+0900"
    private let start = Date(timeIntervalSince1970: 1_793_534_400)

    private func uri(_ scheme: String = "isdbt", _ serviceID: Int = 1024,
                     _ station: String = "サンプルテレビ") -> String {
        "tv:\(scheme)?trip=65534.65533.\(serviceID)&srvName=\(station)"
    }

    /// A uri whose three numbers are written as given, where a test is about what stands for them.
    private func uri(trip: String) -> String { "tv:isdbt?trip=\(trip)&srvName=サンプルテレビ" }

    private func row(id: String = "recording.31", type: String = "recording", uri: String? = nil,
                     start: String? = nil, title: String? = "サンプル劇場", repeatType: String? = "1",
                     overlapStatus: String? = "notOverlapped", recordingStatus: String? = "notStarted",
                     quality: String? = "DR", eventId: String? = "12345") -> TVScheduleRow {
        TVScheduleRow(id: id, type: type, uri: uri ?? self.uri(), startDateTime: start ?? startText,
                      durationSec: 1800, title: title, channelName: "サンプルテレビ", repeatType: repeatType,
                      overlapStatus: overlapStatus, recordingStatus: recordingStatus, quality: quality,
                      eventId: eventId)
    }

    // MARK: - a row as a reservation

    /// Everything a screen reads, in the recorder's codes; the id as it was read; and the row itself kept, with
    /// the device it came from.
    func testARowBecomesAReservationInTheRecordersTerms() {
        let row = row()
        XCTAssertEqual(row.reservation(now: start.addingTimeInterval(-3600)), Reservation(
            id: "recording.31", title: "サンプル劇場", start: start, durationSec: 1800, repeatCode: "1",
            broadcastingType: 2, serviceID: 1024, eventID: 12345, qualityCode: 100, recording: false,
            conflict: false, destination: "", sizeMB: nil, creator: nil, genreCode: nil, device: .tv, tvRow: row))
    }

    /// A reservation made by its times has no programme id, a row may have no mode or one the recorder's table
    /// lacks, and no title; and a start is read to the second.
    func testWhatARowLacksIsLeftEmpty() throws {
        let bare = try XCTUnwrap(row(start: "2026-11-01T20:59:59+0900", title: nil, quality: nil, eventId: nil)
            .reservation())
        XCTAssertNil(bare.eventID)
        XCTAssertEqual(bare.qualityCode, 0)
        XCTAssertNil(bare.qualityName)
        XCTAssertEqual(bare.title, "")
        XCTAssertEqual(bare.start, start.addingTimeInterval(-1))
        XCTAssertEqual(row(quality: "なし").reservation()?.qualityCode, 0)
    }

    /// A reminder to watch is listed among the reservations and is not one.
    func testAReminderIsNotAReservation() {
        XCTAssertNil(row(id: "reminder.23", type: "reminder", quality: nil).reservation())
        XCTAssertNil(row(start: "あした").reservation(), "a row with no time to show")
    }

    /// The repeats are the recorder's spellings but for the one by the programme's name, which the recorder
    /// calls S001: left as `title` it would read as no repeat at all.
    func testARepeatIsSpelledAsTheRecorderSpellsIt() {
        let cases: [(String?, String, String?)] = [
            ("1", "1", "none"), ("d", "d", "daily"), ("w7", "w7", "sun"), ("title", "S001", "title"),
            (nil, "1", "none"),
        ]
        for (read, code, name) in cases {
            let reservation = row(repeatType: read).reservation()
            XCTAssertEqual(reservation?.repeatCode, code)
            XCTAssertEqual(reservation?.repeatName, name)
        }
    }

    /// The one status seen on a row that loses is `fullyOverlapped`; any other but `notOverlapped` reads as
    /// a conflict too, one the television has never said included. A row that says nothing does not.
    func testAnyOverlapButNoneIsAConflict() {
        let cases: [(String?, Bool)] = [
            ("notOverlapped", false), ("fullyOverlapped", true), ("invented", true), (nil, false),
        ]
        for (status, conflict) in cases {
            XCTAssertEqual(row(overlapStatus: status).reservation()?.conflict, conflict, status ?? "absent")
        }
    }

    /// Any status but `notStarted` is a recording under way -- what a television says of one has not been
    /// seen, so the status here is no real one -- and only between the row's own start and end: a row left in
    /// the list after its programme does not go on reading as one. A row that says nothing is not recording.
    func testARowIsRecordingOnlyInsideItsOwnTimes() {
        let cases: [(String?, TimeInterval, Bool)] = [
            ("invented", -1, false), ("invented", 0, true), ("invented", 1799, true), ("invented", 1800, false),
            ("notStarted", 900, false), (nil, 900, false),
        ]
        for (status, after, recording) in cases {
            let reservation = row(recordingStatus: status).reservation(now: start.addingTimeInterval(after))
            XCTAssertEqual(reservation?.recording, recording, "\(status ?? "absent") at \(after)")
        }
    }

    /// The broadcasting type is the uri's scheme and the service id the last of its three numbers, which end
    /// at the first `&` or with the uri. The station name after them is as the television has it, whatever is
    /// in it, and may be empty or not there at all. A service id is anything its sixteen bits hold.
    func testTheChannelIsCutOutOfTheUri() {
        for (scheme, type) in [("isdbt", 2), ("isdbbs", 3), ("isdbcs", 4), ("isdbs3bs", 23), ("isdbs3cs", 24)] {
            let reservation = row(uri: uri(scheme, 2048)).reservation()
            XCTAssertEqual(reservation?.broadcastingType, type, scheme)
            XCTAssertEqual(reservation?.serviceID, 2048, scheme)
        }
        let named = [
            "tv:isdbt?trip=65534.65533.1024", "tv:isdbt?trip=65534.65533.1024&", uri("isdbt", 1024, ""),
            uri("isdbt", 1024, "サンプル&テレビ=2?trip=1.2.3&srvName=4"),
        ]
        for uri in named {
            let reservation = row(uri: uri).reservation()
            XCTAssertEqual(reservation?.broadcastingType, 2, uri)
            XCTAssertEqual(reservation?.serviceID, 1024, uri)
        }
        for serviceID in [0, 65535] {
            XCTAssertEqual(TVScheduleRow.channel(of: uri("isdbt", serviceID))?.serviceID, serviceID)
        }
    }

    /// A uri that is not in the form names no channel, neither half of one: another scheme or none, fewer
    /// numbers than three or more, a number that is not digits alone -- signed, empty, letters -- and a service
    /// id past sixteen bits. The row is still a reservation, to be shown and deleted by what it is.
    func testAUriThatCannotBeReadLeavesTheChannelEmptyAndTheRowListed() {
        let unreadable = [
            "", "usb:recStorage", "tv:isdbt", uri("isdbx"), "dv:isdbt?trip=65534.65533.1024&srvName=サンプルテレビ",
            "isdbt?trip=65534.65533.1024&srvName=サンプルテレビ", uri(trip: "65534.1024"),
            uri(trip: "65534.65533.1024.1"), uri(trip: "65534.65533.x"), uri(trip: "a.b.1024"),
            uri(trip: "65534.65533.-1024"), uri(trip: "-65534.65533.1024"), uri(trip: "65534.65533.+5"),
            uri(trip: "..1024"), uri(trip: "65534.65533."), uri(trip: "65534.65533.70000"),
            uri(trip: "65534.65533.65536"),
        ]
        for uri in unreadable {
            let reservation = row(uri: uri).reservation()
            XCTAssertEqual(reservation?.broadcastingType, 0, uri)
            XCTAssertEqual(reservation?.serviceID, 0, uri)
            XCTAssertEqual(reservation?.tvRow?.uri, uri)
        }
    }

    // MARK: - finding it again

    /// The television's reservations as the app holds them after a read: the reminders are not among them.
    private func list(_ rows: TVScheduleRow...) -> [Reservation] {
        rows.compactMap { $0.reservation() }
    }

    /// A reservation that follows its programme is that programme's under its id, wherever the start has
    /// moved to; and the row to write to is the one just read.
    func testAReservationIsFoundByItsIdAndItsProgramme() throws {
        let held = try XCTUnwrap(row().reservation())
        let moved = row(start: "2026-11-01T21:15:00+0900", title: "サンプル劇場　拡大版")
        let listed = list(row(id: "recording.32", uri: uri("isdbt", 1032)), moved)
        XCTAssertEqual(listed.tvTarget(of: held), .found(listed[1]))
        XCTAssertEqual(listed[1].tvRow, moved)
    }

    /// Without its id it is gone, though the programme is listed under another: that may be another
    /// reservation of it, and nothing is picked by the programme alone. A reminder never gets into the list,
    /// under whatever id.
    func testWithoutItsIdItIsGone() throws {
        let held = try XCTUnwrap(row().reservation())
        XCTAssertEqual(list(row(id: "recording.33")).tvTarget(of: held), .gone)
        XCTAssertEqual(list(row(type: "reminder", quality: nil)).tvTarget(of: held), .gone)
        XCTAssertEqual(list().tvTarget(of: held), .gone)
    }

    /// Its id on another channel or another programme is not it: the television has given the id to
    /// something else, and the programme under another id is not picked in its place.
    func testItsIdOnAnotherProgrammeIsChanged() throws {
        let held = try XCTUnwrap(row().reservation())
        for other in [row(uri: uri("isdbt", 1032)), row(eventId: "12346")] {
            XCTAssertEqual(list(other, row(id: "recording.33")).tvTarget(of: held), .changed, "\(other)")
        }
    }

    /// What is not surely the reservation held is not written to: an id on two rows, though both are the
    /// programme; a programme id that one side has and the other has not, with the channel and the start the
    /// same; and a reservation held with no row of the television's to check by, which is gone only when its
    /// id is.
    func testWhatIsNotSurelyTheReservationHeldIsNotFound() throws {
        let followed = try XCTUnwrap(row().reservation())
        let timed = try XCTUnwrap(row(eventId: nil).reservation())
        var rowless = followed
        rowless.tvRow = nil
        let cases: [(String, Reservation, [Reservation], TVTarget)] = [
            ("the id on two rows", followed, list(row(), row()), .changed),
            ("the id on two rows, one of them the programme", followed, list(row(eventId: "12346"), row()), .changed),
            ("a programme id gained", timed, list(row()), .changed),
            ("a programme id lost", followed, list(row(eventId: nil)), .changed),
            ("no row held, the id listed", rowless, list(row()), .changed),
            ("no row held, the id not listed", rowless, list(row(id: "recording.33")), .gone),
        ]
        for (name, held, listed, expected) in cases {
            XCTAssertEqual(listed.tvTarget(of: held), expected, name)
        }
        XCTAssertEqual(list(row()).tvTarget(of: followed), .found(followed), "and alone under its id it is found")
    }

    /// A reservation made by its times has no programme to go by, and goes by its start as the television
    /// wrote it.
    func testAReservationMadeByItsTimesGoesByItsStart() throws {
        let held = try XCTUnwrap(row(eventId: nil).reservation())
        let listed = list(row(eventId: nil))
        XCTAssertEqual(listed.tvTarget(of: held), .found(listed[0]))
        XCTAssertEqual(list(row(start: "2026-11-01T21:15:00+0900", eventId: nil)).tvTarget(of: held), .changed)
        XCTAssertEqual(list(row(uri: uri("isdbt", 1032), eventId: nil)).tvTarget(of: held), .changed)
    }

    // MARK: - what the television holds for a request

    /// A request is found in the television's list by its channel and its programme id, and by nothing else.
    /// The row is the request's under whatever title the television lists it, wherever its start has moved
    /// to, whatever its repeat and whatever the television calls the station. A reminder to watch the
    /// programme is no match, nor a row on another service or another kind of broadcast, nor one whose uri
    /// names no channel; and a row at the request's own start under its own title is no match either when it
    /// is another programme's, or was made by its times. A request with no programme id matches nothing.
    func testARequestIsFoundInTheListByItsChannelAndItsProgramme() {
        let request = ReservationRequest(title: "サンプル劇場", start: start, durationSec: 1800, repeatCode: "1",
                                         broadcastingType: 2, serviceID: 1024, qualityCode: 100, eventID: 12345)
        let cases: [(String, TVScheduleRow, Bool)] = [
            ("as it was sent", row(), true),
            ("under a title of the television's own", row(title: "サンプル番組\u{3000}12345\u{1F211}"), true),
            ("with no title", row(title: nil), true),
            ("its start moved", row(start: "2026-11-01T21:15:00+0900"), true),
            ("on another day", row(start: "2026-11-08T21:00:00+0900"), true),
            ("with another repeat", row(repeatType: "w7"), true),
            ("the station under another name", row(uri: uri("isdbt", 1024, "サンプル\u{3000}テレビ")), true),
            ("marked as losing to others", row(overlapStatus: "fullyOverlapped"), true),
            ("a reminder to watch the programme", row(id: "reminder.23", type: "reminder", quality: nil), false),
            ("on another service", row(uri: uri("isdbt", 1032)), false),
            ("on another kind of broadcast", row(uri: uri("isdbbs", 1024)), false),
            ("a uri that names no channel", row(uri: "tv:isdbt"), false),
            ("another programme, at its start and under its title", row(eventId: "12346"), false),
            ("made by its times, at its start and under its title", row(eventId: nil), false),
            ("a programme id that is not written as one is sent", row(eventId: "012345"), false),
        ]
        for (name, listed, found) in cases {
            XCTAssertEqual([listed].holding(request), found ? listed : nil, name)
        }

        // Among others it is the row itself that is handed back, and the first of two.
        let listed = [row(id: "reminder.23", type: "reminder", quality: nil), row(id: "recording.30", eventId: "12346"),
                      row(id: "recording.32", start: "2026-11-01T21:15:00+0900"), row(id: "recording.33")]
        XCTAssertEqual(listed.holding(request), listed[2])
        XCTAssertNil([TVScheduleRow]().holding(request))

        var timed = request
        timed.eventID = nil
        XCTAssertNil([row(eventId: nil), row()].holding(timed), "a request with no programme id was found")
    }

    /// A row the television holds for a request is less than the request asks for when it records the
    /// programme once -- its repeat `1`, or none said -- and the request asks for a repeat: any repeat, one
    /// that a television is not sent for the programme included, here Monday's weekly code and Monday to
    /// Friday on a Sunday's programme. Nothing else falls short: once asked, whatever is held; and a repeat
    /// asked where a repeat is held, the same one or another.
    func testOnlyAProgrammeRecordedOnceFallsShortOfARepeatAskedFor() {
        let cases: [(asked: String, held: String?, short: Bool)] = [
            ("1", "1", false), ("1", nil, false), ("1", "w7", false), ("1", "title", false),
            ("w7", "w7", false), ("w7", "d", false), ("S001", "title", false), ("d", "w16", false),
            ("w1", "w7", false),
            ("w7", "1", true), ("w7", nil, true), ("d", "1", true), ("S001", "1", true), ("S001", nil, true),
            ("w1", "1", true), ("w15", nil, true),
        ]
        for (asked, held, short) in cases {
            let request = ReservationRequest(title: "サンプル劇場", start: start, durationSec: 1800,
                                             repeatCode: asked, broadcastingType: 2, serviceID: 1024,
                                             qualityCode: 100, eventID: 12345)
            XCTAssertEqual(row(repeatType: held).fallsShort(of: request), short,
                           "\(asked) asked, \(held ?? "nothing said") held")
        }
    }

    // MARK: - telling the devices' rows apart

    /// A recorder's row goes by its id, as it did while its were the only ones; a television's says which
    /// device, and its id stays what a delete sends.
    func testTheKeyOfARowInAListOfBothDevices() throws {
        let television = try XCTUnwrap(row().reservation())
        var recorder = television
        recorder.id = "0x1"
        recorder.device = .recorder
        XCTAssertEqual(recorder.listKey, "0x1")
        XCTAssertEqual(television.listKey, "tv|recording.31")
        XCTAssertEqual(television.id, "recording.31")
        XCTAssertEqual(DeviceSlot.tv.rawValue, "tv")
    }
}
