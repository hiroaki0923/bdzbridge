import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// A programme's sheet as the reader works it (`ProgramSheetState`): what it offers, what it asks before it sends,
/// what each answer does, and what goes from it when the model lets a device's lists go under it. The requests
/// themselves -- a reservation, a delete, a row sent again -- are the model's and its drivers', held elsewhere;
/// here is what the sheet makes of them.
@MainActor
final class ProgramSheetTests: XCTestCase {
    /// A model connected to a recorder that answers, with the demo's guide cached.
    private func connected() async throws -> (bench: Bench, model: AppModel) {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorders: [Bench.host: NamedRecorder(1)])
        await model.start()
        try await untilConnected(model)
        return (bench, model)
    }

    /// A model whose recorder said nothing, given up on: what it is asked to make goes to the queue.
    private func offline() async throws -> AppModel {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: SilentRecorder())
        await model.start()
        try await untilGivenUp(model)
        return model
    }

    /// A home with both devices connected: a recorder that answers, and a television the app is registered with:
    /// the demo's, switched on and receiving every station of the guide, which makes a reservation at once.
    private func atHome() async throws -> AppModel {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoLineUp.television()
        let credentials = await registered(with: television)
        let model = bench.model(recorder: NamedRecorder(1), television: HeldTelevision(television, holding: false),
                                credentials: credentials)
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        return model
    }

    /// The sheet's one question or answer, by its case's name, for a test to say which is up.
    private func shown(_ sheet: ProgramSheetState) -> String {
        switch sheet.ask {
        case nil: "nothing"
        case .reserve(let device, let disk)?: "reserve on \(device.label)" + (disk.map { ", \($0)" } ?? "")
        case .cancel?: "cancel"
        case .cancelPending?: "cancel pending"
        case .failed?: "failed"
        case .kept(_, let stays)?: stays ? "kept, staying" : "kept"
        case .said?: "said"
        case .wouldStop?: "would stop"
        }
    }

    /// What the reader does with what is up: the button that does something, or the one that closes, and then it
    /// goes from the screen, as the screen takes it down after either.
    private func press(_ sheet: ProgramSheetState, acting: Bool) throws {
        let asked = try XCTUnwrap(sheet.ask, "nothing was up to press")
        if acting { sheet.act(on: asked) } else { sheet.close(asked) }
        sheet.askClosed()
    }

    /// The sheet starts at the mode the settings hold, and at LSR when what they hold is no mode the recorder
    /// records in.
    func testItStartsAtTheSettingsMode() async throws {
        let (bench, model) = try await connected()
        let program = try await aProgramme(model)
        bench.defaults.set("DR", forKey: DefaultsKey.defaultQuality)
        XCTAssertEqual(ProgramSheetState(program: program, model: model).quality, "DR")
        bench.defaults.set("知らない画質", forKey: DefaultsKey.defaultQuality)
        XCTAssertEqual(ProgramSheetState(program: program, model: model).quality, DefaultQuality.fallback)
    }

    /// With the recorder alone, 録画予約 is the recorder's and says nothing of where it goes. 録画予約する asks
    /// first, in the question's words, and the yes makes the reservation, under the reserving line while it is
    /// out, and closes the sheet; a no leaves the sheet as it was.
    func testTheRecorderIsAskedBeforeAReservationAndTheYesMakesIt() async throws {
        let (_, model) = try await connected()
        let programs = try await programmesNotReserved(model, 1)
        let program = try XCTUnwrap(programs.first)
        let sheet = ProgramSheetState(program: program, model: model)
        XCTAssertEqual(sheet.device, .recorder)
        XCTAssertTrue(sheet.offersAReservation(on: .recorder))
        XCTAssertNil(sheet.destinationChoices, "a home with one device was offered a choice of where")
        XCTAssertFalse(sheet.showsTheDestinationAlone)

        sheet.reserveOnTheRecorder()
        XCTAssertEqual(shown(sheet), "reserve on \(DeviceSlot.recorder.label)", "no disk is named with none to pick")
        XCTAssertEqual(sheet.askTitle, "この番組を録画予約しますか？")
        let asked = try XCTUnwrap(sheet.ask)
        XCTAssertEqual(sheet.actionLabel(for: asked)?.label, "予約する")
        XCTAssertEqual(sheet.closingLabel(for: asked), "キャンセル")
        let message = sheet.message(for: asked)
        XCTAssertTrue(message.hasPrefix("\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n"),
                      message)
        XCTAssertTrue(message.hasSuffix(RecorderDriver.confirming(away: false)), message)

        try press(sheet, acting: false)
        XCTAssertEqual(shown(sheet), "nothing")
        XCTAssertFalse(sheet.done)
        XCTAssertNil(model.reservation(for: program), "the no made a reservation")

        sheet.reserveOnTheRecorder()
        try press(sheet, acting: true)
        XCTAssertEqual(sheet.asking, RecorderDriver.reservingLine, "the reservation was not held under its line")
        XCTAssertTrue(sheet.holdsTheSheet)
        try await until("the reservation never came back") { !sheet.holdsTheSheet }
        XCTAssertTrue(sheet.done, "a reservation made did not close the sheet: \(shown(sheet))")
        XCTAssertNotNil(model.reservation(for: program))
    }

    /// Away from home the question says the reservation will wait, and it does: said as kept, and the sheet
    /// closes once that is read. Opened again, the sheet shows the row under its heading and offers no second
    /// reservation, which would only replace it in the queue.
    func testAReservationMadeAwayIsKeptAndTheRowIsShown() async throws {
        let model = try await offline()
        let program = try await aProgramme(model)
        let sheet = ProgramSheetState(program: program, model: model)
        sheet.reserveOnTheRecorder()
        XCTAssertEqual(sheet.askTitle, RecorderDriver.keepingTitle)
        try press(sheet, acting: true)
        try await until("the reservation never came back") { !sheet.holdsTheSheet }
        XCTAssertEqual(shown(sheet), "kept")
        XCTAssertEqual(sheet.askTitle, "送信待ちにしました")
        try press(sheet, acting: false)
        XCTAssertTrue(sheet.done)

        let again = ProgramSheetState(program: program, model: model)
        XCTAssertNotNil(again.waiting(on: .recorder), "nothing waited for the recorder")
        XCTAssertEqual(again.waitingHeading(.recorder), "この番組は送信待ちです")
        XCTAssertNil(again.device, "a programme that waits was offered another reservation")
        XCTAssertFalse(again.offersAReservation(on: .recorder))
    }

    /// A waiting row deleted from the sheet: the question first, then the delete, which puts up no line and holds
    /// the sheet until it is over, and closes it with nothing left waiting.
    func testDeletingAWaitingRowHoldsTheSheetUntilItIsGone() async throws {
        let model = try await offline()
        let program = try await aProgramme(model)
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"))
        let sheet = ProgramSheetState(program: program, model: model)
        let waiting = try XCTUnwrap(sheet.waiting(on: .recorder))
        sheet.deleteWaiting(waiting)
        XCTAssertEqual(shown(sheet), "cancel pending")
        XCTAssertEqual(sheet.askTitle, "送信待ちの予約を削除しますか？")
        let asked = try XCTUnwrap(sheet.ask)
        XCTAssertEqual(sheet.actionLabel(for: asked)?.destructive, true)
        try press(sheet, acting: true)
        XCTAssertNil(sheet.asking, "the delete of a waiting row put up a line")
        XCTAssertTrue(sheet.holdsTheSheet, "the sheet was not held while the delete was out")
        try await until("the delete never came back") { !sheet.holdsTheSheet }
        XCTAssertTrue(sheet.done)
        XCTAssertNil(model.pending(for: program))
    }

    /// The recorder's reservation deleted from the sheet: asked, held under the deleting line, and the sheet
    /// closes. Picked for deletion and then let go of with the recorder's lists, the question goes; the next
    /// recorder attached is asked afresh what a reservation would clash with, and only after a let-go.
    func testTheRecordersReservationIsDeletedAndALetGoTakesThePickGoes() async throws {
        let (_, model) = try await connected()
        let programs = try await programmesNotReserved(model, 1)
        let program = try XCTUnwrap(programs.first)
        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none"), .made(saying: nil))
        let sheet = ProgramSheetState(program: program, model: model)
        let reservation = try XCTUnwrap(sheet.reservation)
        XCTAssertEqual(sheet.recordersHeading, "この番組は予約済みです")
        XCTAssertTrue(sheet.offersChanging(reservation))

        let key = sheet.checkKey
        sheet.recorderAttached()
        XCTAssertEqual(sheet.checkKey, key, "an attach with nothing let go of had the recorder asked again")
        sheet.delete(reservation)
        XCTAssertEqual(shown(sheet), "cancel")
        sheet.recordersListsLetGo()
        XCTAssertEqual(shown(sheet), "nothing", "a reservation of a recorder let go of stayed picked")
        sheet.recorderAttached()
        XCTAssertNotEqual(sheet.checkKey, key, "the next recorder was not asked what the reservation clashes with")

        sheet.delete(reservation)
        try press(sheet, acting: true)
        XCTAssertEqual(sheet.asking, RecorderDriver.deletingLine)
        try await until("the delete never came back") { !sheet.holdsTheSheet }
        XCTAssertTrue(sheet.done, shown(sheet))
        XCTAssertNil(model.reservation(for: program))
    }

    /// What the recorder says a reservation would clash with is asked only where 録画予約 is the recorder's. Of a
    /// programme no device holds: one the recorder holds offers no 録画予約, and is asked nothing (`aProgramme` can
    /// hand back one the demo has reserved, as it does from nine at night).
    func testTheClashesAreAskedOnlyOfTheRecorder() async throws {
        let (_, model) = try await connected()
        let programs = try await programmesNotReserved(model, 1)
        let sheet = ProgramSheetState(program: try XCTUnwrap(programs.first), model: model)
        await sheet.check()
        XCTAssertEqual(sheet.conflicts, [])
        XCTAssertFalse(sheet.checking)

        let home = try await atHome()
        let frees = try await programmesNotReserved(home, 1)
        let free = try XCTUnwrap(frees.first)
        let televisions = ProgramSheetState(program: free, model: home)
        televisions.choose(.tv)
        await televisions.check()
        XCTAssertNil(televisions.conflicts, "the recorder was asked about a reservation for the television")
    }

    /// With a television beside the recorder, both free: a choice of where, the recorder first. The television
    /// picked, its section starts from no repeat, its question says what the television's driver says, and the
    /// yes makes it there. A television's reservation picked for deletion goes with the television's lists.
    func testWithATelevisionTheReaderPicksWhereItGoes() async throws {
        let model = try await atHome()
        let programs = try await programmesNotReserved(model, 1)
        let program = try XCTUnwrap(programs.first)
        let sheet = ProgramSheetState(program: program, model: model)
        XCTAssertEqual(sheet.destinationChoices, [.recorder, .tv])
        XCTAssertEqual(sheet.device, .recorder)
        XCTAssertEqual(sheet.recordersHeading, DeviceSlot.recorder.label)

        sheet.repeating = "daily"
        sheet.choose(.tv)
        XCTAssertEqual(sheet.device, .tv)
        XCTAssertTrue(sheet.offersAReservation(on: .tv))
        sheet.deviceChanged(to: sheet.device)
        XCTAssertEqual(sheet.repeating, "none", "a repeat picked under the recorder was carried to the television")

        sheet.reserveOnTheTelevision()
        XCTAssertEqual(shown(sheet), "reserve on \(DeviceSlot.tv.label)")
        let asked = try XCTUnwrap(sheet.ask)
        XCTAssertTrue(sheet.message(for: asked).hasSuffix(TVDriver.confirming), sheet.message(for: asked))
        try press(sheet, acting: true)
        XCTAssertEqual(sheet.asking, TVDriver.reservingLine)
        try await until("the television's reservation never came back") { !sheet.holdsTheSheet }
        XCTAssertTrue(sheet.done, shown(sheet))
        let made = try XCTUnwrap(model.reservations(for: program).first { $0.device == .tv })

        let after = ProgramSheetState(program: program, model: model)
        XCTAssertEqual(after.televisions?.id, made.id)
        XCTAssertEqual(after.destinationChoices, nil, "the television that holds it was offered again")
        XCTAssertTrue(after.showsTheDestinationAlone, "where it goes was not said with one device free")
        after.delete(made)
        XCTAssertEqual(shown(after), "cancel")
        after.recordersListsLetGo()
        XCTAssertEqual(shown(after), "cancel", "the recorder's let-go took the television's reservation's question")
        after.televisionsListsLetGo()
        XCTAssertEqual(shown(after), "nothing", "a reservation of a television let go of stayed picked")
    }
}
