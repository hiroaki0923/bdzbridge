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

    func testTheFormSaysWhatItAlwaysSaid() {
        XCTAssertEqual(RecorderRuleSheetState.failureTitle, "エラー")
        XCTAssertEqual(RecorderRuleSheetState.registerLabel, "レコーダーに登録")
        XCTAssertEqual(RecorderRuleSheetState.keywordHeading, "キーワード")
        XCTAssertEqual(RecorderRuleSheetState.keywordPlaceholder, "キーワード")
        XCTAssertEqual(RecorderRuleSheetState.addKeywordLabel, "キーワードを追加")
        XCTAssertEqual(RecorderRuleSheetState.excludedHeading, "除外ワード")
        XCTAssertEqual(RecorderRuleSheetState.excludedPlaceholder, "除外ワード")
        XCTAssertEqual(RecorderRuleSheetState.addExclusionLabel, "除外ワードを追加")
        XCTAssertEqual(RecorderRuleSheetState.logicLabel, "検索方法")
        XCTAssertEqual(RecorderRuleSheetState.narrowingHeading, "絞り込み")
        XCTAssertEqual(RecorderRuleSheetState.subGenreLabel, "サブジャンル")
        XCTAssertEqual(RecorderRuleSheetState.scopeLabel, "放送")
        XCTAssertEqual(RecorderRuleSheetState.timeLabel, "時間帯")
        XCTAssertEqual(RecorderRuleSheetState.removeRowLabel, "この行を削除")
        XCTAssertEqual(RecorderRuleSheetState.anyGenreLabel, "指定しない")
        XCTAssertEqual(RecorderRuleSheetState.allSubGenresLabel, "すべて")
    }

    /// The form's labels that the sheets say too are the sheets' words, and the form's alert is the list's.
    func testTheFormSaysTheWordsOfTheScreensItSharesThemWith() {
        XCTAssertEqual([SheetWords.genre, SheetWords.quality, SheetWords.disk, SheetWords.cancelLabel, SheetWords.okLabel],
                       ["ジャンル", "録画モード", "録画先", "キャンセル", "OK"])
        XCTAssertEqual(RecorderRuleSheetState.failureTitle, RecorderRulesState.failureTitle)
        XCTAssertEqual(RecorderRuleSheetState.keywordPlaceholder, RecorderRuleSheetState.keywordHeading)
        XCTAssertEqual(RecorderRuleSheetState.excludedPlaceholder, RecorderRuleSheetState.excludedHeading)
    }
}
