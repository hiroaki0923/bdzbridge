import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The reservations' list's words as the screen has always said them, byte for byte (`ReservationsState`), and what
/// is worked out from a count or a waiting reservation.
@MainActor
final class ReservationsWordsTests: XCTestCase {
    func testTheReservationsListSaysWhatTheScreenSaid() {
        XCTAssertEqual(ReservationsState.title, "予約")
        XCTAssertEqual(ReservationsState.conditionsLabel, "おまかせ・まる録")
        XCTAssertEqual(ReservationsState.menuLabel, "並び順を変更")
        XCTAssertEqual(ReservationsState.kindHeading, "種類")
        XCTAssertEqual(ReservationsState.conflictMark, "重複")
        XCTAssertEqual(ReservationsState.recorderMadeMark, "おまかせ")
        XCTAssertEqual(ReservationsState.sendAgainLabel, "もう一度送る")
    }

    /// What is said as another screen or sheet says it is that word, not another one typed the same.
    func testWhatTheReservationsSayAsOthersDoIsTheirWord() {
        XCTAssertEqual(ReservationsState.conditionsLabel, RecorderRulesState.title)
        XCTAssertEqual(ReservationsState.sendAgainLabel, ProgramSheetState.sendAgainLabel)
        XCTAssertEqual(ReservationsState.recorderMadeMark, AppModel.ReservationKind.automatic.label)
    }

    /// The count is put in as the screen's text put an Int into a sentence: grouped from 1,000.
    func testTheWaitingHeadingCountsAsTheScreenCounted() {
        XCTAssertEqual(ReservationsState.waitingHeading(0), "送信待ち 0 件")
        XCTAssertEqual(ReservationsState.waitingHeading(1), "送信待ち 1 件")
        XCTAssertEqual(ReservationsState.waitingHeading(999), "送信待ち 999 件")
        XCTAssertEqual(ReservationsState.waitingHeading(1_000), "送信待ち 1,000 件")
        XCTAssertEqual(ReservationsState.waitingHeading(12_345), "送信待ち 12,345 件")
    }

    // MARK: - a waiting row's details

    /// 21:00 on a Monday, Japanese time, which a stored time reads as.
    private let start = RecorderTime.parse("2026-11-23T21:00:00+09:00")!

    private func waiting(eventID: Int?, qualityCode: Int = 100, station: String = "サンプルテレビ")
        -> PendingReservation {
        let request = ReservationRequest(title: "番組", start: start, durationSec: 1800, repeatCode: "1",
                                         broadcastingType: 2, serviceID: 1024, qualityCode: qualityCode,
                                         eventID: eventID)
        return PendingReservation(request: request, serviceName: station)
    }

    func testAWaitingRowSaysEveryPartInOrder() {
        XCTAssertEqual(
            ReservationsState.waitingDetails(waiting(eventID: nil), device: "レコーダー", disk: "USB HDD"),
            "レコーダー · USB HDD · 11/23(月) 21:00 · サンプルテレビ · DR(高画質) · 時刻指定")
    }

    func testAWaitingRowLeavesOutWhatIsNotSaid() {
        XCTAssertEqual(ReservationsState.waitingDetails(waiting(eventID: 7), device: "テレビ", disk: nil),
                       "テレビ · 11/23(月) 21:00 · サンプルテレビ · DR(高画質)")
        XCTAssertEqual(ReservationsState.waitingDetails(waiting(eventID: 7), device: nil, disk: nil),
                       "11/23(月) 21:00 · サンプルテレビ · DR(高画質)")
        XCTAssertEqual(ReservationsState.waitingDetails(waiting(eventID: nil), device: nil, disk: "USB HDD"),
                       "USB HDD · 11/23(月) 21:00 · サンプルテレビ · DR(高画質) · 時刻指定")
    }

    /// A mode the tables do not know is left out, and one they know only by name is said by it; a station with no
    /// name is still a part, as it always was.
    func testAWaitingRowSaysTheModeOnlyWhereTheTablesKnowIt() {
        XCTAssertEqual(ReservationsState.waitingDetails(waiting(eventID: 7, qualityCode: 9999), device: nil, disk: nil),
                       "11/23(月) 21:00 · サンプルテレビ")
        XCTAssertEqual(ReservationsState.waitingDetails(waiting(eventID: 7, qualityCode: 210), device: nil, disk: nil),
                       "11/23(月) 21:00 · サンプルテレビ · XR")
        XCTAssertEqual(ReservationsState.waitingDetails(waiting(eventID: 7, station: ""), device: nil, disk: nil),
                       "11/23(月) 21:00 ·  · DR(高画質)")
    }
}
