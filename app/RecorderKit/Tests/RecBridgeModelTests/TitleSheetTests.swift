import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// A recording's sheet as the reader works it (`TitleSheetState`): what it says of the recording and its playback,
/// the protect and the delete held while their own request is out, the delete's question, and the sheet closing for
/// a recording gone. The operations themselves are the model's and its drivers', held elsewhere; here is what the
/// sheet makes of them.
@MainActor
final class TitleSheetTests: XCTestCase {
    /// A model connected to the demo's recorder, with its recordings read.
    private func withRecordings() async throws -> AppModel {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: DemoRecorder())
        await model.start()
        try await untilConnected(model)
        await model.loadTitles()
        try await until("the recordings were never read") { !model.titles.isEmpty }
        return model
    }

    /// A recording that is neither being recorded nor protected: one the sheet lets be deleted.
    private func aDeletable(_ model: AppModel) throws -> RecordedTitle {
        try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected && model.whyNot(deleting: $0) == nil })
    }

    func testTheSheetSaysTheRecordingAndWhereItPlays() async throws {
        let model = try await withRecordings()
        let title = try aDeletable(model)
        let sheet = TitleSheetState(title: title, model: model)
        await sheet.opened()
        XCTAssertEqual(sheet.current.id, title.id)
        XCTAssertTrue(sheet.offersPlayback, "a recorder's recording was not offered playback")
        XCTAssertEqual(sheet.protectLabel, "保護（自動削除の対象外にする）")
        XCTAssertNil(sheet.whyNotPlayed)
        XCTAssertEqual(sheet.playbackNote, "レコーダーに接続されたテレビで再生されます。")
        XCTAssertFalse(sheet.holdsPlayback)
        XCTAssertFalse(sheet.holdsProtect)
        XCTAssertFalse(sheet.holdsDelete)
        XCTAssertFalse(sheet.done)
        XCTAssertFalse(sheet.isAsking)

        // Watched partway: 最初から再生 on the button, and how far in the 視聴状態.
        if let partway = model.titles.first(where: { $0.watchState == .partway && $0.resumeSec != nil && !$0.recording }) {
            let partwaySheet = TitleSheetState(title: partway, model: model)
            XCTAssertEqual(partwaySheet.playLabel, "最初から再生")
            XCTAssertEqual(partwaySheet.viewing, "\(partway.watchState.label)（\((partway.resumeSec ?? 0) / 60)分）")
        }
        XCTAssertEqual(sheet.playLabel, title.watchState == .partway ? "最初から再生" : "再生")

        // A television's row is not played from the sheet, and is protected under the plain word.
        var television = title
        television.device = .tv
        let tvSheet = TitleSheetState(title: television, model: model)
        XCTAssertFalse(tvSheet.offersPlayback)
        XCTAssertEqual(tvSheet.protectLabel, "保護")
    }

    /// この録画を削除 asks first, in the question's words; a no leaves the sheet as it was, and the yes deletes the
    /// recording with the sheet held until it is answered, then closes it.
    func testADeleteIsAskedFirstAndTheYesClosesTheSheet() async throws {
        let model = try await withRecordings()
        let title = try aDeletable(model)
        let sheet = TitleSheetState(title: title, model: model)

        sheet.delete()
        XCTAssertTrue(sheet.isAsking)
        XCTAssertTrue(sheet.asksBeforeDeleting)
        XCTAssertEqual(sheet.askTitle, "この録画を削除しますか？")
        XCTAssertEqual(sheet.askMessage, "\(title.title)\n" + [title].deletedForGood.asABody)
        sheet.askClosed()
        XCTAssertFalse(sheet.isAsking, "キャンセル left the question up")
        XCTAssertFalse(sheet.done)

        sheet.delete()
        sheet.confirmDelete()
        sheet.askClosed()
        XCTAssertTrue(sheet.asking, "the delete was not held while it was out")
        XCTAssertTrue(sheet.holdsDelete && sheet.holdsProtect && sheet.holdsPlayback, "the buttons were not held")
        XCTAssertFalse(sheet.done, "the sheet closed before its delete was answered")
        try await until("the delete never came back") { !sheet.asking }
        XCTAssertTrue(sheet.done, "the delete went through and the sheet stayed: \(sheet.failure ?? "no report")")
        XCTAssertNil(model.row(like: title), "the recording deleted is still listed")
    }

    /// 保護 holds the sheet until it is answered; protected, the recording cannot be deleted, which is said under the
    /// delete in its driver's words.
    func testProtectingHoldsTheSheetAndThenTheDeleteSaysWhy() async throws {
        let model = try await withRecordings()
        let title = try aDeletable(model)
        let sheet = TitleSheetState(title: title, model: model)

        sheet.setProtected(true)
        XCTAssertTrue(sheet.asking)
        XCTAssertTrue(sheet.holdsProtect)
        try await until("the protect never came back") { !sheet.asking }
        XCTAssertNil(sheet.failure)
        XCTAssertTrue(sheet.current.protected, "the live copy was not the protected one")
        XCTAssertEqual(sheet.whyNotDeleted, RecorderDriver.protectedCannotBeDeleted)
        XCTAssertTrue(sheet.holdsDelete)
        XCTAssertFalse(sheet.done)
    }

    /// A recording deleted from under the sheet -- by the list's swipe, or a run -- closes it, as its own delete
    /// does; not while a question of its own is up.
    func testARecordingGoneFromTheListClosesTheSheetOnceNothingOfItsOwnIsUp() async throws {
        let model = try await withRecordings()
        let title = try aDeletable(model)
        let sheet = TitleSheetState(title: title, model: model)
        sheet.delete()
        if case .notDone(let why) = await model.delete(title) { XCTFail("the delete did not go through: \(why)") }
        XCTAssertNil(model.row(like: title))
        XCTAssertFalse(sheet.done, "the sheet closed under its own question")
        sheet.askClosed()
        XCTAssertTrue(sheet.done, "a recording gone from the list left its sheet open")
    }
}
