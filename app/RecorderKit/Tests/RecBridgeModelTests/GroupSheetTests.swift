import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// One programme's recordings as the reader works them (`GroupSheetState`): the selection, the runs it starts and
/// when it ends, a row's own delete and 保護解除 with the sheet held meanwhile, and what the one alert says. The
/// runs and the writes themselves are the model's and its drivers', held elsewhere.
@MainActor
final class GroupSheetTests: XCTestCase {
    /// A home whose recorder answers, its recordings read, and the programme of them with the most recordings.
    private func withAProgramme() async throws -> (recorder: NamedRecorder, model: AppModel, sheet: GroupSheetState) {
        let (_, recorder, model) = try await connectedHome()
        await model.loadTitles()
        try await until("the recordings were never read") { !model.titles.isEmpty }
        let group = try XCTUnwrap(model.titleGroups.max { $0.count < $1.count })
        XCTAssertGreaterThan(group.count, 1, "the demo has no programme recorded more than once")
        return (recorder, model, GroupSheetState(group: group, model: model))
    }

    private func shown(_ sheet: GroupSheetState) -> String {
        switch sheet.ask(among: sheet.members) {
        case .bulk: "bulk"
        case .one: "one"
        case .failed: "failed"
        case .told: "told"
        case nil: "nothing"
        }
    }

    /// The button under the question, pressed as the sheet presses it: the action with what the alert was put up
    /// with, and then the alert's closing.
    private func press(_ sheet: GroupSheetState, acting: Bool, file: StaticString = #filePath,
                       line: UInt = #line) throws {
        let members = sheet.members
        let asked = try XCTUnwrap(sheet.ask(among: members), "nothing was asked", file: file, line: line)
        if acting { sheet.act(on: asked, chosen: sheet.chosen(among: members)) }
        sheet.askClosed()
    }

    /// 選択 turns to 完了 and back, the ticks going either way; a row tapped is ticked and unticked; 削除できるものを
    /// すべて選択 ticks what a delete would take and no more; and the bar of what to do is there only with a tick.
    func testTheSelectionTicksRowsAndGoesWithPicking() async throws {
        let (_, model, sheet) = try await withAProgramme()
        let members = sheet.members
        XCTAssertEqual(members.count, sheet.group.count)
        XCTAssertEqual(sheet.selectLabel, "選択")
        XCTAssertFalse(sheet.offersActions(on: sheet.chosen(among: members)))

        sheet.toggleSelecting()
        XCTAssertEqual(sheet.selectLabel, "完了")
        XCTAssertNil(sheet.swipe(for: members[0]), "a row offered its swipe while picking")
        sheet.toggle(members[0])
        XCTAssertTrue(sheet.isSelected(members[0]))
        var chosen = sheet.chosen(among: members)
        XCTAssertEqual(chosen.map(\.listKey), [members[0].listKey])
        XCTAssertTrue(sheet.offersActions(on: chosen))
        XCTAssertEqual(GroupSheetState.countLine(chosen), "1 件")
        XCTAssertTrue(GroupSheetState.deleteLabel(chosen).hasPrefix("選択した 1 件を削除（"), GroupSheetState.deleteLabel(chosen))
        sheet.toggle(members[0])
        XCTAssertFalse(sheet.isSelected(members[0]))

        sheet.selectWhatCanBeDeleted(among: members)
        chosen = sheet.chosen(among: members)
        XCTAssertEqual(Set(chosen.map(\.listKey)), Set(members.filter { model.whyNot(deleting: $0) == nil }.map(\.listKey)))
        XCTAssertTrue(chosen.allSatisfy(sheet.wouldBeDeleted))
        sheet.selectNothing()
        XCTAssertTrue(sheet.chosen(among: members).isEmpty)

        sheet.toggle(members[0])
        sheet.toggleSelecting()
        XCTAssertEqual(sheet.selectLabel, "選択")
        XCTAssertTrue(sheet.selected.isEmpty, "完了 left the ticks")
        XCTAssertEqual(sheet.swipe(for: members[0]), model.swipe(for: members[0]))
    }

    /// 選択した N 件を削除 asks first, saying how many and how much; the yes starts the run over what the delete would
    /// take, ends the selection, and the recordings go.
    func testTheBulkDeleteIsAskedAndEndsTheSelectionOnceBegun() async throws {
        let (_, model, sheet) = try await withAProgramme()
        sheet.toggleSelecting()
        sheet.selectWhatCanBeDeleted(among: sheet.members)
        let chosen = sheet.chosen(among: sheet.members)
        XCTAssertFalse(chosen.isEmpty)
        XCTAssertFalse(sheet.holdsActions(on: chosen))

        sheet.deleteChosen()
        XCTAssertEqual(shown(sheet), "bulk")
        let asked = try XCTUnwrap(sheet.ask(among: sheet.members))
        XCTAssertEqual(sheet.askTitle(asked, chosen: chosen), "選択した \(chosen.count) 件を削除しますか？")
        XCTAssertEqual(sheet.actionLabel(for: asked, chosen: chosen)?.label, "\(chosen.count) 件を削除する")
        XCTAssertEqual(sheet.actionLabel(for: asked, chosen: chosen)?.destructive, true)
        XCTAssertEqual(sheet.closingLabel(for: asked), "キャンセル")
        XCTAssertTrue(sheet.message(for: asked, chosen: chosen).hasPrefix("合計 "))
        XCTAssertTrue(sheet.message(for: asked, chosen: chosen).contains("保護された録画と録画中のものは削除されません。"))
        XCTAssertFalse(sheet.holdsTheAction(for: asked, chosen: chosen))

        try press(sheet, acting: false)
        XCTAssertEqual(shown(sheet), "nothing")
        XCTAssertTrue(sheet.selecting, "キャンセル ended the selection")
        XCTAssertEqual(sheet.chosen(among: sheet.members).count, chosen.count)

        sheet.deleteChosen()
        try press(sheet, acting: true)
        XCTAssertFalse(sheet.selecting, "the run began and the selection stayed")
        XCTAssertTrue(sheet.selected.isEmpty)
        try await until("the run never ended") { model.job?.finished == true }
        let left = Set(model.titles.map(\.listKey))
        XCTAssertTrue(chosen.allSatisfy { !left.contains($0.listKey) }, "a recording chosen is still listed")
        XCTAssertEqual(model.job?.progressLine.hasPrefix("削除中 "), true)
        XCTAssertNil(model.job?.whyItStopped)
    }

    /// A press that starts nothing -- a run is under way already -- leaves the selection as it was, for the reader
    /// to press again; 保護する over the ticked rows ends it once its run has begun.
    func testAPressHeldOffKeepsTheSelection() async throws {
        let (recorder, model, sheet) = try await withAProgramme()
        addTeardownBlock { await recorder.letGo() }
        let members = sheet.members
        sheet.toggleSelecting()
        sheet.toggle(members[0])
        let chosen = sheet.chosen(among: members)

        // A run over the rest, held at its first write.
        await recorder.hold(only: "X_UpdateTitle")
        XCTAssertTrue(model.startBulk(.protecting(true), ids: members.dropFirst().filter { !$0.protected }.map(\.id)))
        try await until("the run never began") { model.jobRunning }
        XCTAssertTrue(sheet.holdsActions(on: chosen))
        XCTAssertTrue(sheet.holdsProtectingAll(members))
        sheet.deleteChosen()
        let asked = try XCTUnwrap(sheet.ask(among: members))
        XCTAssertTrue(sheet.holdsTheAction(for: asked, chosen: chosen))
        sheet.act(on: asked, chosen: chosen)
        sheet.askClosed()
        XCTAssertTrue(sheet.selecting, "a press that started nothing ended the selection")
        XCTAssertTrue(sheet.isSelected(members[0]))
        sheet.protect(true, chosen)
        XCTAssertTrue(sheet.selecting, "a protect that started nothing ended the selection")

        await recorder.letGo()
        try await until("the run never ended") { model.job?.finished == true }
        try await until("a run could not be started again") { !sheet.holdsActions(on: chosen) }
        sheet.protect(true, chosen)
        XCTAssertFalse(sheet.selecting, "the protect began and the selection stayed")
        try await until("the second run never ended") { model.job?.finished == true && !model.jobRunning }
    }

    /// A row's own delete from its swipe: asked, then sent with the sheet held until it is answered, the swipes
    /// held meanwhile; and one the recorder turns down is said under エラー, which wins over the bulk question.
    func testARowsDeleteHoldsTheSheetUntilItIsAnswered() async throws {
        let (recorder, model, sheet) = try await withAProgramme()
        addTeardownBlock { await recorder.letGo() }
        let members = sheet.members
        let title = try XCTUnwrap(members.first { model.swipe(for: $0) == .delete })
        XCTAssertFalse(sheet.holds(title))

        await recorder.answer("X_DeleteTitle", with: .fault(402))
        sheet.delete(title)
        XCTAssertEqual(shown(sheet), "one")
        let asked = try XCTUnwrap(sheet.ask(among: members))
        XCTAssertEqual(sheet.askTitle(asked, chosen: []), "この録画を削除しますか？")
        XCTAssertEqual(sheet.message(for: asked, chosen: []), AppModel.deleteMessage(title))
        try press(sheet, acting: true)
        XCTAssertTrue(sheet.asking, "the sheet was not held while its delete was out")
        try await until("the delete never came back") { !sheet.asking }
        XCTAssertEqual(shown(sheet), "failed")
        XCTAssertEqual(sheet.askTitle(sheet.ask(among: members), chosen: []), "エラー")
        sheet.toggleSelecting()
        sheet.toggle(title)
        sheet.deleteChosen()
        XCTAssertEqual(shown(sheet), "failed", "the bulk question went over a failure")
        sheet.askClosed()
        sheet.toggleSelecting()

        await recorder.hold(only: "X_DeleteTitle")
        let count = await recorder.heard.count
        sheet.delete(title)
        try press(sheet, acting: true)
        try await until("the delete was never sent") { await recorder.heard(since: count).contains("X_DeleteTitle") }
        XCTAssertTrue(sheet.asking)
        XCTAssertTrue(sheet.holds(try XCTUnwrap(members.last)), "another row's swipe was live with a delete out")
        await recorder.letGo()
        try await until("the delete never came back") { !sheet.asking }
        XCTAssertEqual(shown(sheet), "nothing", "a delete that went through said something")
        XCTAssertFalse(sheet.members.contains { $0.listKey == title.listKey })
    }

    /// What a programme's row and a job's bar say.
    func testAProgrammesRowAndAJobsBarAreWorded() async throws {
        let (_, _, sheet) = try await withAProgramme()
        let group = sheet.group
        XCTAssertEqual(group.countSaid, "\(group.count) 件")
        XCTAssertTrue(group.sizeSaid.hasSuffix(" GB"))
        XCTAssertEqual(group.newSaid, group.newCount > 0 ? "未視聴 \(group.newCount)" : nil)
        XCTAssertEqual(group.protectedSaid, group.protectedCount > 0 ? "🔒 \(group.protectedCount)" : nil)
        XCTAssertTrue(group.span.contains(" 〜 "))
        XCTAssertTrue(group.span.hasPrefix(Format.dateTime.string(from: group.earliest)))

        var one = group
        one.lastEnd = one.earliest.addingTimeInterval(1800)
        if Format.day.string(from: one.earliest) == Format.day.string(from: one.lastEnd) {
            XCTAssertTrue(one.span.hasSuffix("〜 " + Format.time.string(from: one.lastEnd)), one.span)
        }
        XCTAssertEqual(BulkJob.stopping, "中止します…")
        XCTAssertEqual(BulkJob.pausesAway, "アプリを離れると一時停止し、戻ると再開します")
    }
}
