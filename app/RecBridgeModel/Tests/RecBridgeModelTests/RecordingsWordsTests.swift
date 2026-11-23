import Foundation
import XCTest
@testable import RecBridgeModel

/// The recordings' list's words as the screen has always said them, byte for byte (`RecordingsState`), and what is
/// worked out from a count.
@MainActor
final class RecordingsWordsTests: XCTestCase {
    func testTheRecordingsListSaysWhatTheScreenSaid() {
        XCTAssertEqual(RecordingsState.viewMenuLabel, "表示を変える")
        XCTAssertEqual(RecordingsState.viewHeading, "表示")
        XCTAssertEqual(RecordingsState.destinationHeading, "録画先")
        XCTAssertEqual(RecordingsState.genreHeading, "ジャンル")
        XCTAssertEqual(RecordingsState.viewingHeading, "視聴状態")
        XCTAssertEqual(RecordingsState.filterMenuLabel(hasDestinations: false), "ジャンル・並び順・視聴状態で絞り込む")
        XCTAssertEqual(RecordingsState.filterMenuLabel(hasDestinations: true),
                       "録画先・ジャンル・並び順・視聴状態で絞り込む")
    }

    func testWhatTheRecordingsSayAsOthersDoIsTheirWord() {
        XCTAssertEqual(RecordingsState.destinationHeading, SheetWords.disk)
        XCTAssertEqual(RecordingsState.genreHeading, SheetWords.genre)
        XCTAssertEqual(RecordingsState.viewingHeading, TitleSheetState.viewingLabel)
    }

    /// A recording's row says 削除 as the lists do, and 保護解除 of its own.
    func testARecordingsSwipeSaysWhatTheScreenSaid() {
        XCTAssertEqual(AppModel.TitleSwipe.delete.label, "削除")
        XCTAssertEqual(AppModel.TitleSwipe.unprotect.label, "保護解除")
        XCTAssertEqual(AppModel.TitleSwipe.delete.label, ListWords.deleteLabel)
    }

    /// The counts are put in as the screen's text put an Int into a sentence: grouped where the reader's locale puts
    /// a separator.
    func testTheGenreChoicesCountAsTheScreenCounted() {
        XCTAssertEqual(RecordingsState.allGenresLabel(count: 0), "すべて 0")
        XCTAssertEqual(RecordingsState.allGenresLabel(count: 999), "すべて 999")
        XCTAssertEqual(RecordingsState.allGenresLabel(count: 1_000), "すべて \(asATextShowsIt(1_000))")
        XCTAssertEqual(RecordingsState.allGenresLabel(count: 12_345), "すべて \(asATextShowsIt(12_345))")
        XCTAssertEqual(RecordingsState.genreChoiceLabel(0x3, count: 1), "ドラマ 1")
        XCTAssertEqual(RecordingsState.genreChoiceLabel(0x3, count: 999), "ドラマ 999")
        XCTAssertEqual(RecordingsState.genreChoiceLabel(0x7, count: 1_000), "アニメ／特撮 \(asATextShowsIt(1_000))")
        XCTAssertEqual(RecordingsState.genreChoiceLabel(0xF, count: 12_345), "その他 \(asATextShowsIt(12_345))")
        if let separator = Locale.current.groupingSeparator, !separator.isEmpty, asATextShowsIt(1_000) != "1000" {
            XCTAssertEqual(RecordingsState.allGenresLabel(count: 1_000), "すべて 1\(separator)000")
            XCTAssertEqual(RecordingsState.genreChoiceLabel(0xF, count: 12_345), "その他 12\(separator)345")
        }
    }
}
