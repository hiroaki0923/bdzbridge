import Foundation
import RecorderKit
import XCTest

/// What a device's list holds of a row that waits to be sent: a reservation of its programme that is all the
/// row asks for. The rows are read as the recorder's list gives them (`XsrsParse.reservation`).
final class ByProgramTests: XCTestCase {
    /// A row waiting for the recorder, of the sample programme, asking for `repeatCode`.
    private func waiting(repeating repeatCode: String) -> PendingReservation {
        PendingReservation(request: ReservationRequest(title: "サンプル番組",
                                                       start: Date(timeIntervalSince1970: 1_790_000_000),
                                                       durationSec: 1800, repeatCode: repeatCode,
                                                       broadcastingType: 2, serviceID: 0x400, qualityCode: 240,
                                                       eventID: 0x311f),
                           serviceName: "サンプルテレビ")
    }

    /// A reservation as the recorder lists one: of the sample programme unless another is named, repeating
    /// `repeatCode`, made by `creator` -- an app's unless said, the recorder's own as `1100`.
    private func listed(repeating repeatCode: String, creator: String = "2200", programme: Int = 0x311f,
                        serviceID: Int = 0x400) throws -> Reservation {
        let item = "<item id=\"0x1\"><title>サンプル番組</title>"
            + "<scheduledStartDateTime>2026-09-21T21:00:00+0900</scheduledStartDateTime>"
            + "<scheduledDuration>1800</scheduledDuration>"
            + "<scheduledConditionID>\(repeatCode)</scheduledConditionID>"
            + "<scheduledChannelID broadcastingType=\"2\">0x\(String(serviceID, radix: 16))</scheduledChannelID>"
            + "<desiredMatchingID>0x\(String(programme, radix: 16))</desiredMatchingID>"
            + "<reservationCreatorID>\(creator)</reservationCreatorID></item>"
        return try XCTUnwrap(XsrsParse.reservation(try XmlNode.parse(item)))
    }

    /// A row that asks for a repeat is not answered by the programme reserved once, nor by a repeat on fewer
    /// of its days; it is by the same repeat, and by one that takes in each of its days. A row for once is
    /// answered by anything of its programme. 番組名 goes by no day, and only once falls short of it. A
    /// reservation the recorder made for itself answers for no row, whatever its repeat; nor does one of
    /// another programme or channel. A list with a reservation that falls short beside one that does not
    /// answers for the row.
    func testAListedReservationAnswersForAWaitingRowOnlyWhenItIsAllTheRowAsksFor() throws {
        let rows: [(String, asked: String, listed: [Reservation], answers: Bool)] = [
            ("once, listed once", "1", [try listed(repeating: "1")], true),
            ("once, listed 毎週", "1", [try listed(repeating: "w1")], true),
            ("毎週, listed once", "w1", [try listed(repeating: "1")], false),
            ("毎週, listed 毎週", "w1", [try listed(repeating: "w1")], true),
            ("毎週, listed 毎日", "w1", [try listed(repeating: "d")], true),
            ("毎日, listed 毎週", "d", [try listed(repeating: "w1")], false),
            ("月−金, listed 月−土", "w15", [try listed(repeating: "w16")], true),
            ("月−土, listed 月−金", "w16", [try listed(repeating: "w15")], false),
            ("番組名, listed once", "S001", [try listed(repeating: "1")], false),
            ("番組名, listed 番組名", "S001", [try listed(repeating: "S001")], true),
            ("番組名, listed 毎週", "S001", [try listed(repeating: "w1")], true),
            ("once, the recorder's own once", "1", [try listed(repeating: "1", creator: "1100")], false),
            ("毎週, the recorder's own 毎週", "w1", [try listed(repeating: "w1", creator: "1100")], false),
            ("once, another programme", "1", [try listed(repeating: "1", programme: 0x3120)], false),
            ("once, another channel", "1", [try listed(repeating: "1", serviceID: 0x408)], false),
            ("毎週, once and 毎週 listed", "w1", [try listed(repeating: "1"), try listed(repeating: "w1")], true),
            ("once, the recorder's own and an app's", "1",
             [try listed(repeating: "1", creator: "1100"), try listed(repeating: "1")], true),
            ("once, nothing listed", "1", [], false),
        ]
        for (name, asked, list, answers) in rows {
            XCTAssertEqual(ByProgram.lists(waiting(repeating: asked), in: list), answers, name)
        }
    }

    /// A row made by its times carries no programme id and is answered by nothing, whatever stands listed.
    func testARowWithNoProgrammeIdIsAnsweredByNothing() throws {
        var row = waiting(repeating: "1")
        row.request.eventID = nil
        XCTAssertFalse(ByProgram.lists(row, in: [try listed(repeating: "1")]))
    }
}
