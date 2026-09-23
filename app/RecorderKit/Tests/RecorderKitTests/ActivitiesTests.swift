import XCTest
@testable import RecorderKit

/// The line the app shows while it is working with the recorder. Everything that waits for the app to be
/// idle -- reconnecting on return to the foreground, the buttons that are greyed out meanwhile -- waits for
/// `current` to come back to nil, so the case that matters is that it always does.
final class ActivitiesTests: XCTestCase {
    func testNothingUnderWayShowsNothing() {
        let activities = Activities()
        XCTAssertNil(activities.current)
        XCTAssertTrue(activities.isEmpty)
    }

    /// The order the serial client finishes things in: first begun, first done. Saving the line on the way
    /// in and restoring it on the way out left "予約一覧を取得中" on screen for good in exactly this order.
    func testWorkFinishingInTheOrderItBeganLeavesNothingBehind() {
        var activities = Activities()
        let reservations = activities.begin("予約一覧を取得中")
        let titles = activities.begin("録画一覧を取得中")
        XCTAssertEqual(activities.current, "録画一覧を取得中", "the latest is the one shown")

        activities.end(reservations)
        XCTAssertEqual(activities.current, "録画一覧を取得中", "the line of work still going stays up")

        activities.end(titles)
        XCTAssertNil(activities.current, "nothing is under way, so nothing is said")
    }

    func testWorkFinishingInsideOutLeavesNothingBehind() {
        var activities = Activities()
        let waking = activities.begin("レコーダーを起動しています（0 秒）")
        let attaching = activities.begin("接続中")

        activities.end(attaching)
        XCTAssertEqual(activities.current, "レコーダーを起動しています（0 秒）",
                       "the outer line comes back when the inner work is done")

        activities.end(waking)
        XCTAssertNil(activities.current)
    }

    func testTheSameWordsTwiceAreTwoLines() {
        var activities = Activities()
        let first = activities.begin("予約一覧を取得中")
        let second = activities.begin("予約一覧を取得中")

        activities.end(first)
        XCTAssertEqual(activities.current, "予約一覧を取得中", "the second load is still going")
        activities.end(second)
        XCTAssertNil(activities.current)
    }

    func testAnUpdateChangesOnlyItsOwnLineAndKeepsItsPlace() {
        var activities = Activities()
        let guide = activities.begin("番組表を取得中")
        activities.update(guide, to: "番組表を取得中 (地上デジタル)")
        XCTAssertEqual(activities.current, "番組表を取得中 (地上デジタル)")

        let titles = activities.begin("録画一覧を取得中")
        activities.update(guide, to: "番組表を取得中 (BS)")
        XCTAssertEqual(activities.current, "録画一覧を取得中",
                       "an earlier piece of work moving on does not push in front of a later one")

        activities.end(titles)
        XCTAssertEqual(activities.current, "番組表を取得中 (BS)", "and its latest words are the ones shown after")
    }

    func testALateUpdateDoesNotBringALineBack() {
        var activities = Activities()
        let waking = activities.begin("レコーダーを起動しています（3 秒）")
        activities.end(waking)
        activities.update(waking, to: "レコーダーを起動しています（4 秒）")
        XCTAssertNil(activities.current)
    }

    func testEndingTwiceIsHarmless() {
        var activities = Activities()
        let first = activities.begin("予約を削除中")
        let second = activities.begin("予約一覧を取得中")
        activities.end(first)
        activities.end(first)
        XCTAssertEqual(activities.current, "予約一覧を取得中", "ending again did not take someone else's line")
        activities.end(second)
        XCTAssertTrue(activities.isEmpty)
    }
}
