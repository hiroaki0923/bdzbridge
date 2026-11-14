import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The recorder's own keyword conditions as the reader works them (`RecorderRulesState`, `RecorderRuleSheetState`):
/// what is said over the list, a row's delete and its question, and the form for a new condition with its
/// registration. The reads and the writes themselves are the model's and its driver's, held elsewhere.
@MainActor
final class RecorderRulesStateTests: XCTestCase {
    /// A home whose recorder answers, with its conditions read.
    private func withConditions() async throws -> (bench: Bench, recorder: NamedRecorder, model: AppModel) {
        let (bench, recorder, model) = try await connectedHome(guide: false)
        await model.loadRecorderRules()
        XCTAssertFalse(model.recorderRules.isEmpty, "the demo was meant to hold a keyword condition")
        return (bench, recorder, model)
    }

    private func shown(_ state: RecorderRulesState) -> String {
        switch state.ask {
        case .confirm: "confirm"
        case .failed: "failed"
        case nil: "nothing"
        }
    }

    private func press(_ state: RecorderRulesState, acting: Bool, file: StaticString = #filePath,
                       line: UInt = #line) throws {
        let asked = try XCTUnwrap(state.ask, "nothing was asked", file: file, line: line)
        if acting { state.act(on: asked) }
        state.askClosed()
    }

    /// Over the list: loading until read, nothing over a list read, 条件が登録されていません once the recorder said
    /// it has none, and a failed read said even over a list read before.
    func testWhatIsSaidOverTheList() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        let state = RecorderRulesState(model: model)
        XCTAssertEqual(state.listSays, .loading)
        XCTAssertFalse(state.holdsAdding)
        // A first read that fails is said, not taken for one still on its way.
        await recorder.answer("X_GetPrefRecSettingList", with: .fault(501))
        await model.loadRecorderRules()
        XCTAssertTrue(model.recorderRules.isEmpty)
        guard case .failed = state.listSays else { return XCTFail("a first read that failed said \(state.listSays)") }
        await model.refreshRecorderRules()
        XCTAssertEqual(state.listSays, .nothing)
        let rule = try XCTUnwrap(model.recorderRules.first)
        XCTAssertEqual(state.details(of: rule), rule.details(disk: model.diskShown(rule)))

        await recorder.answer("X_GetPrefRecSettingList", with: .fault(501))
        await model.refreshRecorderRules()
        guard case .failed(let why) = state.listSays else {
            return XCTFail("a failed read was not said: \(state.listSays)")
        }
        XCTAssertTrue(why.hasSuffix("。"), "the reason is not said as a body: \(why)")
        XCTAssertFalse(model.recorderRules.isEmpty, "the list read before went with the failure")

        for rule in model.recorderRules { expectTrue(await removeACondition(model, rule)) }
        await model.refreshRecorderRules()
        XCTAssertEqual(state.listSays, .empty)
        XCTAssertEqual(RecorderRulesState.noConditions, "条件が登録されていません")
    }

    /// A row's 削除 asks first, naming the condition; キャンセル leaves it, and 削除する deletes it saying nothing.
    func testADeleteIsAskedFirstAndTheYesDeletes() async throws {
        let (_, _, model) = try await withConditions()
        let rule = try XCTUnwrap(model.recorderRules.first)
        let state = RecorderRulesState(model: model)
        XCTAssertFalse(state.holdsDeleting)

        state.delete(rule)
        XCTAssertEqual(shown(state), "confirm")
        XCTAssertEqual(state.askTitle, "この条件を削除しますか？")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertEqual(state.message(for: asked),
                       "「\(rule.name)」をレコーダーから削除します。本体で設定した対象チャンネルの指定も削除されます。")
        XCTAssertEqual(state.actionLabel(for: asked)?.label, "削除する")
        XCTAssertEqual(state.actionLabel(for: asked)?.destructive, true)
        XCTAssertEqual(state.closingLabel(for: asked), "キャンセル")
        XCTAssertFalse(state.holdsTheAction(for: asked))

        try press(state, acting: false)
        XCTAssertEqual(shown(state), "nothing")
        XCTAssertTrue(model.recorderRules.contains { $0.id == rule.id }, "キャンセル deleted the condition")

        state.delete(rule)
        try press(state, acting: true)
        try await until("the condition was never deleted") { !model.recorderRules.contains { $0.id == rule.id } }
        XCTAssertEqual(shown(state), "nothing", "a delete that went through said something")
    }

    /// A delete the recorder turns down is said once the question has closed, under エラー with OK alone, and wins
    /// over a question put up since; the pick goes with the recorder's lists.
    func testADeleteTurnedDownIsSaidAndThePickGoesWithTheRecordersLists() async throws {
        let (_, recorder, model) = try await withConditions()
        let rule = try XCTUnwrap(model.recorderRules.first)
        let state = RecorderRulesState(model: model)
        await recorder.answer("X_DeletePrefRecSetting", with: .fault(402))
        state.delete(rule)
        try press(state, acting: true)
        try await until("the refusal was never said") { self.shown(state) == "failed" }
        XCTAssertEqual(state.askTitle, "エラー")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertNil(state.actionLabel(for: asked))
        XCTAssertEqual(state.closingLabel(for: asked), "OK")
        state.delete(rule)
        XCTAssertEqual(shown(state), "failed", "a question went over the failure")
        state.askClosed()

        state.delete(rule)
        state.recordersListsLetGo()
        XCTAssertEqual(shown(state), "nothing", "the recorder's lists went and its condition stayed picked")
    }

    /// The form starts at the mode the settings hold; it says why it cannot be sent in place of the hint, and holds
    /// レコーダーに登録 until it can; the last keyword row is kept and the rows stop at the recorder's limits.
    func testTheFormStartsAtTheSettingsModeAndHoldsUntilItCanBeSent() async throws {
        let (_, _, model) = try await withConditions()
        model.defaults.set("XSR", forKey: DefaultsKey.defaultQuality)
        let sheet = RecorderRuleSheetState(model: model)
        XCTAssertEqual(sheet.draft.quality, "XSR")
        XCTAssertNil(sheet.chosenDisk)
        XCTAssertEqual(sheet.keywordFooter, RecorderRuleDraft.needsAKeywordOrAGenre.asABody)
        XCTAssertTrue(sheet.holdsRegistering)

        sheet.draft.keywords[0].text = "みほん"
        XCTAssertEqual(sheet.keywordFooter, "番組名や番組内容に含まれる言葉です。5 つまで登録できます。")
        XCTAssertFalse(sheet.holdsRegistering)

        sheet.removeKeyword(sheet.draft.keywords[0].id)
        XCTAssertEqual(sheet.draft.keywords.count, 1, "the only keyword row was taken away")
        for _ in 0..<10 { sheet.addKeyword() }
        XCTAssertEqual(sheet.draft.keywords.count, RecorderRuleDraft.keywordLimit)
        sheet.removeKeyword(sheet.draft.keywords[1].id)
        XCTAssertEqual(sheet.draft.keywords.count, RecorderRuleDraft.keywordLimit - 1)
        for _ in 0..<10 { sheet.addExclusion() }
        XCTAssertEqual(sheet.draft.excluded.count, RecorderRuleDraft.excludedLimit)
        sheet.removeExclusion(sheet.draft.excluded[0].id)
        XCTAssertEqual(sheet.draft.excluded.count, RecorderRuleDraft.excludedLimit - 1)
        XCTAssertEqual(RecorderRuleSheetState.excludedFooter, "この言葉を含む番組は録画しません。2 つまで登録できます。")

        sheet.draft.genre = try XCTUnwrap(RecorderRuleDraft.genres.first)
        XCTAssertEqual(sheet.subGenres, RecorderRuleDraft.subGenres(of: sheet.draft.genre))
        XCTAssertEqual(sheet.broadcastingScopes, RecorderRuleDraft.broadcastingScopes(guide: model.counts))
    }

    /// レコーダーに登録 holds the form from the press, and a condition made closes it; one turned down is said, and
    /// the form stays.
    func testARegistrationClosesTheFormOrSaysWhyNot() async throws {
        let (_, recorder, model) = try await withConditions()
        addTeardownBlock { await recorder.letGo() }
        let before = model.recorderRules.count

        let refused = RecorderRuleSheetState(model: model)
        refused.draft.keywords[0].text = "ためしの言葉"
        await recorder.answer("X_CreatePrefRecSetting", with: .fault(402))
        refused.register()
        XCTAssertTrue(refused.asking, "the form was not held from the press")
        XCTAssertTrue(refused.holdsRegistering)
        try await until("the registration never came back") { !refused.asking }
        XCTAssertFalse(refused.done)
        XCTAssertTrue(refused.failureMessage?.hasSuffix("。") == true, "\(refused.failureMessage ?? "nothing said")")
        refused.failureClosed()
        XCTAssertNil(refused.failureMessage)

        let sheet = RecorderRuleSheetState(model: model)
        sheet.draft.keywords[0].text = "ためしの言葉"
        sheet.register()
        try await until("the registration never came back") { !sheet.asking }
        XCTAssertTrue(sheet.done, "a condition made did not close the form: \(sheet.failureMessage ?? "")")
        XCTAssertNil(sheet.failureMessage)
        XCTAssertEqual(model.recorderRules.count, before + 1)
    }

    /// A registration turned down for a disk that cannot be had sends the form back to the internal disk, named;
    /// one turned down for anything else leaves the disk as picked.
    func testARefusedDiskSendsTheFormBackToTheInternalDisk() async throws {
        let bench = try aBench()
        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot()), times: 1000)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        addTeardownBlock { await recorder.letGo() }
        XCTAssertEqual(model.diskChoices.map(\.destination), ["HDD", "USBHDD"])

        let kept = RecorderRuleSheetState(model: model)
        kept.draft.keywords[0].text = "ためしの言葉"
        kept.chosenDisk = "USBHDD"
        await recorder.answer("X_CreatePrefRecSetting", with: .fault(402))
        kept.register()
        try await until("the registration never came back") { !kept.asking }
        XCTAssertNotNil(kept.failureMessage)
        XCTAssertEqual(kept.chosenDisk, "USBHDD", "a refusal for something else changed the disk picked")

        let gone = RecorderRuleSheetState(model: model)
        gone.draft.keywords[0].text = "ためしの言葉"
        gone.chosenDisk = "USBHDD2"
        gone.register()
        try await until("the registration never came back") { !gone.asking }
        XCTAssertNotNil(gone.failureMessage, "a disk that cannot be had was sent")
        XCTAssertFalse(gone.done)
        XCTAssertEqual(gone.chosenDisk, RecorderDisk.internalID, "the form did not go back to the internal disk")
    }
}
