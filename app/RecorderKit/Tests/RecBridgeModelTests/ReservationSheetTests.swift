import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// A reservation's sheet as the reader works it (`ReservationSheetState`): the change offered once a picker holds
/// something the device does not, what a change sent comes to, and the delete with its question. The change and
/// the delete themselves are the model's and its drivers', held elsewhere; here is what the sheet makes of them.
@MainActor
final class ReservationSheetTests: XCTestCase {
    /// A model connected to a recorder that answers, holding one reservation made just now in DR.
    private func withAReservation() async throws -> (recorder: NamedRecorder, model: AppModel, row: Reservation) {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        let programmes = try await programmesNotReserved(model, 1)
        let program = try XCTUnwrap(programmes.first)
        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none"), .made(saying: nil))
        let row = try XCTUnwrap(model.reservations(for: program).first { $0.device == .recorder })
        return (recorder, model, row)
    }

    /// The pickers start from what the recorder holds, and the change is offered only while one holds something
    /// else, under a button that names the device and the driver's footer.
    func testTheChangeIsOfferedOnlyWhileAPickerHoldsSomethingElse() async throws {
        let (_, model, row) = try await withAReservation()
        let sheet = ReservationSheetState(reservation: row, model: model)
        await sheet.opened()
        XCTAssertEqual(sheet.quality, "DR")
        XCTAssertEqual(sheet.repeating, row.repeatName ?? "none")
        XCTAssertFalse(sheet.settled)
        XCTAssertFalse(sheet.changed, "the change was offered with nothing changed")
        XCTAssertTrue(sheet.diskChoices.isEmpty, "a home with no USB disk was offered a disk")
        XCTAssertNil(sheet.diskShown)

        sheet.quality = try XCTUnwrap(RecorderDriver.recordsIn.first { $0 != "DR" })
        XCTAssertTrue(sheet.changed)
        XCTAssertEqual(sheet.changeLabel, "変更を\(DeviceSlot.recorder.label)に送る")
        XCTAssertEqual(sheet.changeFooter,
                       RecorderDriver.changeFooter(followsItsProgramme: row.eventID != nil, offersADisk: false))
        sheet.quality = "DR"
        XCTAssertFalse(sheet.changed, "putting the mode back left the change offered")
    }

    /// A change made with nothing to add closes the sheet at once, under the changing line while it is out. One the
    /// recorder turns down says why, and closing that report closes the sheet: the list was read again on the way.
    func testAChangeMadeClosesTheSheetAndOneTurnedDownClosesItOnItsReport() async throws {
        let (recorder, model, row) = try await withAReservation()
        let other = try XCTUnwrap(RecorderDriver.recordsIn.first { $0 != "DR" })
        let sheet = ReservationSheetState(reservation: row, model: model)
        await sheet.opened()
        sheet.quality = other
        sheet.sendTheChange()
        XCTAssertEqual(sheet.asking, RecorderDriver.changingLine, "the change was not held under its line")
        try await until("the change never came back") { sheet.asking == nil }
        XCTAssertTrue(sheet.done, "a change made did not close the sheet: \(sheet.failure ?? "no report")")
        XCTAssertFalse(sheet.isAsking)

        let changed = try XCTUnwrap(model.reservations.first { $0.id == row.id })
        let again = ReservationSheetState(reservation: changed, model: model)
        await again.opened()
        again.quality = "DR"
        await recorder.answer(ReservationWrite.change.rawValue, with: .fault(402))
        again.sendTheChange()
        try await until("the change never came back") { again.asking == nil }
        XCTAssertTrue(again.isAsking, "the change turned down was not reported")
        XCTAssertEqual(again.askTitle, "エラー")
        XCTAssertFalse(again.asksBeforeDeleting)
        XCTAssertFalse(again.done, "the sheet closed before its report was read")
        again.askClosed()
        XCTAssertTrue(again.done, "closing the report of a change turned down left the sheet open")
    }

    /// 予約を削除 asks first, in the question's words; a no leaves the sheet as it was, and the yes deletes the
    /// reservation under the deleting line and closes the sheet.
    func testADeleteIsAskedFirstAndTheYesClosesTheSheet() async throws {
        let (_, model, row) = try await withAReservation()
        let sheet = ReservationSheetState(reservation: row, model: model)
        await sheet.opened()
        sheet.delete()
        XCTAssertTrue(sheet.isAsking)
        XCTAssertTrue(sheet.asksBeforeDeleting)
        XCTAssertEqual(sheet.askTitle, "この予約を削除しますか？")
        XCTAssertTrue(sheet.askMessage.hasPrefix("\(Format.dateTime.string(from: row.start)) \(row.title)\n"),
                      sheet.askMessage)
        sheet.askClosed()
        XCTAssertFalse(sheet.isAsking)
        XCTAssertFalse(sheet.done, "a no closed the sheet")

        sheet.delete()
        sheet.confirmDelete()
        sheet.askClosed()
        XCTAssertEqual(sheet.asking, RecorderDriver.deletingLine)
        try await until("the delete never came back") { sheet.asking == nil }
        XCTAssertTrue(sheet.done, sheet.failure ?? "no report")
        XCTAssertFalse(model.reservations.contains { $0.id == row.id })
    }
}
