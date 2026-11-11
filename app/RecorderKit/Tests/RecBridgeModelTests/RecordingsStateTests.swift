import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The recordings' screen as the reader works it (`RecordingsState`): what a row's swipe offers, the delete's
/// question and what the one alert says, 保護解除 from a protected row, and what the screen says under its title in
/// each of its views. The delete and the protect themselves are the model's and its drivers', held elsewhere.
@MainActor
final class RecordingsStateTests: XCTestCase {
    /// A home whose recorder answers, with its recordings read.
    private func withRecordings() async throws -> (recorder: NamedRecorder, model: AppModel) {
        let (_, recorder, model) = try await connectedHome()
        await model.loadTitles()
        try await until("the recordings were never read") { !model.titles.isEmpty }
        return (recorder, model)
    }

    /// A recording that is neither being recorded nor protected: one whose row offers the delete.
    private func aDeletable(_ model: AppModel) throws -> RecordedTitle {
        try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected && model.whyNot(deleting: $0) == nil })
    }

    private func shown(_ state: RecordingsState) -> String {
        switch state.ask {
        case .confirm: "confirm"
        case .failed: "failed"
        case .told: "told"
        case nil: "nothing"
        }
    }

    /// The button under the question, pressed as the screen presses it: the action with the value the alert was
    /// put up with, and then the alert's closing, which is what lets go of the question.
    private func press(_ state: RecordingsState, acting: Bool, file: StaticString = #filePath,
                       line: UInt = #line) throws {
        let asked = try XCTUnwrap(state.ask, "nothing was asked", file: file, line: line)
        if acting { state.act(on: asked) }
        state.askClosed()
    }

    /// What a row offers under a swipe goes by the delete's own door: 削除 where it would be let through, 保護解除 on
    /// a protected one, and nothing on one still being recorded.
    func testARowsSwipeOffersWhatTheDeletesDoorWouldLetThrough() async throws {
        let (_, model) = try await withRecordings()
        XCTAssertEqual(model.swipe(for: try aDeletable(model)), .delete)
        let protected = try XCTUnwrap(model.titles.first { $0.protected && !$0.recording }, "the demo has no protected recording")
        XCTAssertEqual(model.swipe(for: protected), .unprotect)
        var recording = try aDeletable(model)
        recording.recording = true
        XCTAssertNil(model.swipe(for: recording), "a recording being recorded was offered a swipe")
    }

    /// A swipe's 削除 asks first, saying what is about to go; キャンセル leaves the recording, and 削除する deletes it
    /// and says nothing more.
    func testADeleteIsAskedFirstAndTheYesDeletes() async throws {
        let (_, model) = try await withRecordings()
        let title = try aDeletable(model)
        let state = RecordingsState(model: model)
        XCTAssertEqual(shown(state), "nothing")
        XCTAssertFalse(state.holds(title), "a row was held with nothing under way")

        state.delete(title)
        XCTAssertEqual(shown(state), "confirm")
        XCTAssertEqual(state.askTitle, "この録画を削除しますか？")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertEqual(state.message(for: asked), AppModel.deleteMessage(title))
        XCTAssertEqual(state.actionLabel(for: asked)?.label, "削除する")
        XCTAssertEqual(state.actionLabel(for: asked)?.destructive, true)
        XCTAssertEqual(state.closingLabel(for: asked), "キャンセル")
        XCTAssertFalse(state.holdsTheAction(for: asked))

        try press(state, acting: false)
        XCTAssertEqual(shown(state), "nothing")
        XCTAssertTrue(model.titles.contains { $0.listKey == title.listKey }, "キャンセル deleted the recording")

        state.delete(title)
        try press(state, acting: true)
        XCTAssertEqual(shown(state), "nothing", "the question stayed up after its button")
        try await until("the recording was never deleted") { !model.titles.contains { $0.listKey == title.listKey } }
        XCTAssertEqual(shown(state), "nothing", "a delete that went through said something")
    }

    /// A delete the recorder turns down is said once the question has closed, under エラー with only OK, and wins
    /// over a question put up since.
    func testADeleteTurnedDownIsSaidOnceTheQuestionHasClosed() async throws {
        let (recorder, model) = try await withRecordings()
        let title = try aDeletable(model)
        let state = RecordingsState(model: model)
        await recorder.answer("X_DeleteTitle", with: .fault(402))
        state.delete(title)
        try press(state, acting: true)
        try await until("the refusal was never said") { self.shown(state) == "failed" }
        XCTAssertEqual(state.askTitle, "エラー")
        let asked = try XCTUnwrap(state.ask)
        XCTAssertNil(state.actionLabel(for: asked))
        XCTAssertEqual(state.closingLabel(for: asked), "OK")
        XCTAssertFalse(state.holdsTheAction(for: asked))
        XCTAssertTrue(model.titles.contains { $0.listKey == title.listKey }, "the recording turned down went all the same")

        state.delete(title)
        XCTAssertEqual(shown(state), "failed")
        state.askClosed()
        XCTAssertEqual(shown(state), "nothing", "closing the report left the question behind it")
    }

    /// 保護解除 from a protected row takes the protection off, after which the row offers the delete; one the
    /// recorder turns down is said in the alert.
    func testAProtectedRowIsUnprotectedFromItsSwipe() async throws {
        let (recorder, model) = try await withRecordings()
        let protected = try XCTUnwrap(model.titles.first { $0.protected && !$0.recording })
        let state = RecordingsState(model: model)

        await recorder.answer("X_UpdateTitle", with: .fault(402))
        state.unprotect(protected)
        try await until("the refusal was never said") { self.shown(state) == "failed" }
        state.askClosed()
        XCTAssertEqual(model.titles.first { $0.listKey == protected.listKey }?.protected, true)

        state.unprotect(protected)
        try await until("the protection never came off") {
            model.titles.first { $0.listKey == protected.listKey }?.protected == false
        }
        XCTAssertEqual(shown(state), "nothing", "a protection taken off said something")
        let now = try XCTUnwrap(model.titles.first { $0.listKey == protected.listKey })
        XCTAssertEqual(model.swipe(for: now), .delete)
    }

    /// The row picked is read back out of the list, so a question about a row that has gone comes down by itself.
    /// The recorder's lists going lets go of the pick; the television's going, only of a row no list holds.
    func testThePickGoesWithItsRowAndWithTheRecordersLists() async throws {
        let (_, model) = try await withRecordings()
        let title = try aDeletable(model)
        let state = RecordingsState(model: model)

        state.delete(title)
        state.televisionsListsLetGo()
        XCTAssertEqual(shown(state), "confirm", "the television's lists going took a recorder's row with them")
        state.recordersListsLetGo()
        XCTAssertEqual(shown(state), "nothing", "the recorder's lists went and its row stayed picked")

        state.delete(title)
        expectEqual(await model.delete(title), .done(saying: nil))
        XCTAssertEqual(shown(state), "nothing", "a question stayed up about a row the list no longer holds")
    }

    /// Under the title: how many recordings, programmes or sets of duplicates, by the view that is on, after the
    /// disk and the genre the list is narrowed to; and the menu's icon marks a list narrowed or sorted otherwise.
    func testTheSubtitleSaysWhatTheViewShows() async throws {
        let (_, model) = try await withRecordings()
        let state = RecordingsState(model: model)
        XCTAssertEqual(state.subtitle(in: .list), "\(model.shownTitles.count) 件")
        XCTAssertEqual(state.subtitle(in: .groups), "\(model.titleGroups.count) 番組")
        XCTAssertEqual(state.subtitle(in: .dups), "\(model.duplicates.count) 組の重複")
        XCTAssertFalse(state.filtering)
        XCTAssertTrue(state.heading.hasPrefix("残り ") || state.heading == "録画", state.heading)

        let genre = try XCTUnwrap(model.titleGenreCounts.keys.sorted().first)
        model.titleGenre = genre
        XCTAssertEqual(state.subtitle(in: .list), "\(try XCTUnwrap(Codes.genreLabel[genre])) · \(model.shownTitles.count) 件")
        XCTAssertTrue(state.filtering)
        model.titleGenre = nil
        model.titleSort = .oldest
        XCTAssertTrue(state.filtering)
        model.titleSort = .newest
        XCTAssertFalse(state.filtering)

        XCTAssertEqual(RecordingsState.Mode(kept: "groups"), .groups)
        XCTAssertEqual(RecordingsState.Mode(kept: "dups"), .dups)
        XCTAssertEqual(RecordingsState.Mode(kept: nil), .list)
        XCTAssertEqual(RecordingsState.Mode(kept: "something else"), .list)
        XCTAssertEqual(RecordingsState.Mode.allCases.map(\.label), ["一覧", "まとめ", "重複"])
    }
}
