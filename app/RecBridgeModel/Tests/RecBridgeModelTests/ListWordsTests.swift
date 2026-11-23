import XCTest
@testable import RecBridgeModel

/// The words the reservations' list and the recordings' say alike, as the screens have always said them, byte for
/// byte (`ListWords`).
final class ListWordsTests: XCTestCase {
    func testTheListsSayWhatTheyAlwaysSaidAlike() {
        XCTAssertEqual(ListWords.deleteLabel, "削除")
        XCTAssertEqual(ListWords.sortHeading, "並び順")
        XCTAssertEqual(ListWords.recordingMark, "録画中")
        XCTAssertEqual(ListWords.allLabel, "すべて")
    }

    /// The reservations' menu that narrows offers the same first choice: that word, not another typed the same.
    func testTheFirstChoiceOfTheReservationsKindsIsTheListsWord() {
        XCTAssertEqual(AppModel.ReservationKind.all.label, ListWords.allLabel)
        XCTAssertEqual(AppModel.ReservationKind.all.label, "すべて")
    }
}
