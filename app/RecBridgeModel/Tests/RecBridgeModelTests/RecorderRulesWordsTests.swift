import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The words of the keyword conditions' list and of the form for a new one, as the screens have always said them, byte
/// for byte, and the ones they say as other screens do (`RecorderRulesState`, `RecorderRuleSheetState`).
@MainActor
final class RecorderRulesWordsTests: XCTestCase {
    func testTheListSaysWhatItAlwaysSaid() {
        XCTAssertEqual(RecorderRulesState.title, "おまかせ・まる録")
        XCTAssertEqual(RecorderRulesState.addLabel, "条件を追加")
        XCTAssertEqual(RecorderRulesState.deleteLabel, "削除")
        XCTAssertEqual(RecorderRulesState.failureTitle, "エラー")
        XCTAssertEqual(RecorderRuleSheetState.title, "条件を追加")
    }

    /// The words said as another screen says them are those words, not others typed the same.
    func testTheListSaysTheWordsOfTheScreensItSharesThemWith() {
        XCTAssertEqual(RecorderRulesState.addLabel, RecorderRuleSheetState.title)
        XCTAssertEqual(RecorderRulesState.deleteLabel, ListWords.deleteLabel)
    }

    /// The question and the answer keep their buttons: 削除する and キャンセル for the question, OK for the answer.
    func testTheQuestionAndTheAnswerSayWhatTheyAlwaysSaid() async throws {
        let (_, _, model) = try await connectedHome(guide: false)
        await model.loadRecorderRules()
        let rule = try XCTUnwrap(model.recorderRules.first)
        let state = RecorderRulesState(model: model)
        let question = RecorderRulesState.Ask.confirm(rule)
        XCTAssertEqual(state.actionLabel(for: question)?.label, "削除する")
        XCTAssertEqual(state.actionLabel(for: question)?.destructive, true)
        XCTAssertEqual(state.closingLabel(for: question), "キャンセル")
        XCTAssertEqual(state.actionLabel(for: question)?.label, SheetWords.confirmDeleteLabel)
        XCTAssertEqual(state.closingLabel(for: question), SheetWords.cancelLabel)
        let answer = RecorderRulesState.Ask.failed("why")
        XCTAssertNil(state.actionLabel(for: answer))
        XCTAssertEqual(state.closingLabel(for: answer), "OK")
        XCTAssertEqual(state.closingLabel(for: answer), SheetWords.okLabel)
    }
}
