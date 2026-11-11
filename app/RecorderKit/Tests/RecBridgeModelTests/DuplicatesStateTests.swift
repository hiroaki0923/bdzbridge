import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The duplicates' view as the reader works it (`DuplicatesState`): what it says before and after a scan, the
/// ticks and the marks that follow them, and the delete of what is ticked with its question -- or, while a set
/// would lose every copy, the answer that names it. The scan and the run themselves are the model's and the
/// package's, held elsewhere.
@MainActor
final class DuplicatesStateTests: XCTestCase {
    /// At home with a recorder that holds one broadcast twice, the second copy protected, its recordings read.
    private func withACopy() async throws -> (recorder: NamedRecorder, model: AppModel, state: DuplicatesState) {
        let (_, recorder, model) = try await connectedHome(guide: false)
        await recorder.haveACopy()
        await model.loadTitles()
        return (recorder, model, DuplicatesState(model: model))
    }

    private func scan(_ model: AppModel) async throws {
        model.startDuplicateScan()
        try await until("the scan never ended") { !model.jobRunning }
    }

    /// Before a scan the view offers one and says what it does; with nothing read to look through, the scan is
    /// held.
    func testBeforeAScanTheViewOffersOne() async throws {
        let (_, _, model) = try await connectedHome(guide: false)
        let state = DuplicatesState(model: model)
        XCTAssertEqual(state.promptTitle, "重複した録画を探す")
        XCTAssertTrue(state.promptDetail.hasPrefix("タイトルと長さが同じ録画について、"))
        XCTAssertEqual(state.scanLabel, "検出を開始")
        XCTAssertTrue(state.holdsTheScan, "a scan was offered with no recordings read")
        await model.loadTitles()
        XCTAssertFalse(state.holdsTheScan)
        XCTAssertNil(state.deleteLabel)
        XCTAssertNil(state.unreadLine)

        // No copies on this recorder: scanned, and nothing found.
        state.scan()
        try await until("the scan never ended") { !model.jobRunning && model.scannedForDuplicates }
        XCTAssertTrue(model.duplicates.isEmpty)
        XCTAssertEqual(state.promptTitle, "重複はありませんでした")
        XCTAssertEqual(state.scanLabel, "もう一度調べる")
    }

    /// The set found: the copy the recorder will not part with is kept and its tick held; the other is ticked by
    /// the scan and marked 削除, and unticking it marks it 残す and takes the delete off the foot.
    func testTheMarksFollowTheTicks() async throws {
        let (_, model, state) = try await withACopy()
        try await scan(model)
        let set = try XCTUnwrap(model.duplicates.first)
        XCTAssertEqual(model.duplicates.count, 1)
        XCTAssertEqual(state.details(of: set), "2 本 · \(Format.gigabytes(set.sizeGB)) · \(set.confidence.label)")
        let kept = try XCTUnwrap(set.items.first { $0.protected })
        let going = try XCTUnwrap(set.items.first { !$0.protected })

        XCTAssertFalse(state.deletable(kept))
        XCTAssertTrue(state.keeps(kept))
        XCTAssertEqual(state.mark(kept), "残す")
        XCTAssertTrue(state.holdsTheTick(kept), "the tick of a copy the recorder refuses to delete was live")
        state.toggle(kept)
        XCTAssertTrue(state.keeps(kept), "a tick on a copy that cannot be deleted marked it as going")
        state.toggle(kept)

        XCTAssertTrue(state.deletable(going))
        XCTAssertFalse(state.keeps(going), "the scan did not tick the copy to delete")
        XCTAssertEqual(state.mark(going), "削除")
        XCTAssertFalse(state.holdsTheTick(going))
        XCTAssertEqual(state.tickLabel(going), "\(Format.dateTime.string(from: going.start))の録画を削除する対象に選ぶ")
        XCTAssertEqual(state.reason(going, in: set), set.reasons[going.id])
        XCTAssertEqual(state.details(of: going).last, going.watchState.label)
        XCTAssertEqual(state.chosen.map(\.id), [going.id])
        XCTAssertEqual(state.deleteLabel?.hasPrefix("選択した 1 件を削除（"), true)

        state.toggle(going)
        XCTAssertTrue(state.keeps(going))
        XCTAssertEqual(state.mark(going), "残す")
        XCTAssertNil(state.deleteLabel)
        XCTAssertTrue(state.chosen.isEmpty)
    }

    /// The delete at the foot asks first, saying how many and that the unticked stay; the yes starts the run over
    /// what is ticked, and the copy goes.
    func testTheDeleteIsAskedAndTakesWhatIsTicked() async throws {
        let (_, model, state) = try await withACopy()
        try await scan(model)
        let going = try XCTUnwrap(state.chosen.first)
        XCTAssertFalse(state.holdsDeleting)

        state.delete()
        XCTAssertTrue(state.confirming)
        XCTAssertEqual(state.askTitle, "重複した 1 件を削除しますか？")
        XCTAssertTrue(state.askMessage.hasPrefix("合計 "))
        XCTAssertTrue(state.askMessage.contains("チェックの無いものは残ります。"))
        XCTAssertTrue(state.askMessage.hasSuffix("。"))
        XCTAssertEqual(state.actionLabel, "1 件を削除する")
        XCTAssertEqual(state.closingLabel, "キャンセル")
        XCTAssertFalse(state.holdsTheAction)

        state.act()
        state.confirming = false
        XCTAssertTrue(model.jobRunning || model.job?.finished == true, "the run was not started")
        XCTAssertTrue(state.holdsTheTick(going) || model.job?.finished == true, "a tick was live while the run worked from the ticks")
        try await until("the run never ended") { !model.jobRunning }
        XCTAssertFalse(model.titles.contains { $0.id == going.id }, "the copy ticked is still listed")
    }

    /// With every copy of a set ticked nothing is deleted: the alert names the set and has only OK.
    func testASetThatWouldLoseEveryCopyIsNamedInsteadOfDeleted() async throws {
        let (_, model, state) = try await withACopy()
        let protected = try XCTUnwrap(Duplicates.candidates(model.titles).flatMap { $0 }.first { $0.protected })
        expectEqual(await model.setProtected(protected, false), .done(saying: nil))
        try await scan(model)
        let set = try XCTUnwrap(model.duplicates.first)
        XCTAssertTrue(set.items.allSatisfy(state.deletable))
        for copy in set.items where state.keeps(copy) { state.toggle(copy) }
        XCTAssertEqual(state.emptied.map(\.id), [set.id])

        state.delete()
        XCTAssertEqual(state.askTitle, "1 本も残らない組があります")
        XCTAssertTrue(state.askMessage.hasPrefix("次の組はすべてにチェックが付いていて、削除すると 1 本も残りません。"))
        XCTAssertTrue(state.askMessage.hasSuffix("・\(set.title)"), state.askMessage)
        XCTAssertNil(state.actionLabel)
        XCTAssertEqual(state.closingLabel, "OK")
    }
}
