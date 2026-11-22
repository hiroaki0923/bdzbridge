import Foundation
import XCTest
@testable import RecBridgeModel

/// The names of the tabs as the bar has always said them, byte for byte (`TabWords`).
final class TabWordsTests: XCTestCase {
    func testTheTabsAreNamedAsTheBarNamedThem() {
        XCTAssertEqual(TabWords.guide, "番組表")
        XCTAssertEqual(TabWords.search, "検索")
        XCTAssertEqual(TabWords.reservations, "予約")
        XCTAssertEqual(TabWords.recordings, "録画")
        XCTAssertEqual(TabWords.settings, "設定")
    }

    /// The settings' tab is the settings' own title.
    func testTheSettingsTabIsTheSettingsTitle() {
        XCTAssertEqual(TabWords.settings, SettingsWords.title)
    }
}
