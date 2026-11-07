import XCTest
@testable import RecorderKit

/// What the screens say of a reservation, a waiting row and a link (`ReservationSentences.swift`,
/// `PendingQueue.notYetAt`, `SessionState.standing`).
@MainActor
final class ReservationSentencesTests: XCTestCase {
    private func reservation(on device: DeviceSlot = .recorder, creator: String? = "2200",
                             eventID: Int? = 0x311f) -> Reservation {
        var row = Reservation(id: "a", title: "サンプル番組", start: Date(timeIntervalSince1970: 1_800_000_000),
                              durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 0x400,
                              eventID: eventID, qualityCode: 240, recording: false, conflict: false,
                              destination: "HDD", sizeMB: nil, creator: creator, genreCode: nil)
        row.device = device
        return row
    }

    func testDeletingSaysWhichDeviceItLeavesAndThatTheRecorderMayMakeItsOwnAgain() {
        XCTAssertEqual(reservation().whatDeletingDoes(fromTheList: true), "レコーダーから削除されます。")
        XCTAssertEqual(reservation(on: .tv).whatDeletingDoes(fromTheList: false), "テレビから削除されます。")
        let itsOwn = reservation(creator: "1100")
        XCTAssertEqual(itsOwn.whatDeletingDoes(fromTheList: true),
                       "レコーダーから削除されます。\n" + RecorderDriver.mayComeBackFromTheList)
        XCTAssertEqual(itsOwn.whatDeletingDoes(fromTheList: false),
                       "レコーダーから削除されます。\n" + RecorderDriver.mayComeBack,
                       "asked from a sheet, the programme's or the reservation's")
    }

    func testWhoMadeItAndWhetherItFollowsItsProgramme() {
        XCTAssertEqual(reservation(creator: "1100").madeBy, "レコーダー（おまかせ録画）")
        XCTAssertEqual(reservation(creator: "2200").madeBy, "アプリから")
        XCTAssertEqual(reservation(creator: nil).madeBy, "不明")
        XCTAssertEqual(reservation().followsItsProgramme, "時間が変わっても追いかけます")
        XCTAssertNil(reservation(eventID: nil).followsItsProgramme, "a reservation by time alone follows nothing")
    }

    func testAWaitingRowSaysWhichDeviceItWillNotReach() throws {
        let program = GuideProgramRow(broadcasting: "td", serviceID: 0x400, serviceName: "サンプル総合",
                                      eventID: 0x311f, start: Date(timeIntervalSince1970: 1_800_000_000),
                                      end: Date(timeIntervalSince1970: 1_800_001_800), title: "サンプル番組",
                                      summary: "", extended: "", genres: [], copyControl: 0, parental: 0,
                                      isReference: false, referenceServiceID: nil, referenceEventID: nil)
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        let row = PendingReservation(request: request, serviceName: "サンプル総合", queuedAt: Date(), target: .tv)
        XCTAssertEqual(row.whatDeletingDoes, "この端末から削除し、テレビには送りません。")
        XCTAssertEqual(PendingQueue.notYetAt(.tv), PendingQueue.whatWaits(for: [.tv], anyHeld: false, diskAway: false))
        XCTAssertEqual(PendingQueue.notYetAt(.recorder),
                       PendingQueue.whatWaits(for: [.recorder], anyHeld: false, diskAway: false))
    }

    /// How a link stands once connected or connecting is held by its own tests, which make those states; here
    /// what a link that has not connected says.
    func testALinkNotConnectedSaysSoAndATelevisionToRegisterSaysThatFirst() {
        let session = SessionState()
        XCTAssertEqual(session.standing(), "接続していません")
        XCTAssertEqual(session.standing(needsPairing: true), "登録が必要です")
    }
}
