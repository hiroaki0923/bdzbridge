import XCTest

/// The demo is offered to people who have no recorder, and it has to leave nothing behind for the ones who
/// then go and set a real one up. That is the promise worth a test: the invented guide lives in its own
/// database, and ending the demo deletes it and puts the previous recorder back.
final class DemoModeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheDemoFillsTheAppAndEndingItLeavesNothingBehind() {
        let app = XCUIApplication()
        // No recorder, so the tutorial is the first thing up. `-demoData` is deliberately not passed: the
        // argument domain outranks what the app writes, and the app has to be able to turn the demo on
        // itself.
        app.launchArguments = ["-recorderHost", "", "-startTab", "guide", "-guideMode", "list"]
        app.launch()

        // A previous run on this simulator may have left the demo on.
        let strip = app.staticTexts["サンプルデータを表示しています"]
        if strip.waitForExistence(timeout: 10) { app.buttons["終了"].tap() }

        let tryDemo = app.buttons["サンプルデータで試す"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 20), "the tutorial did not offer the demo")
        tryDemo.tap()

        XCTAssertTrue(strip.waitForExistence(timeout: 30), "nothing said the data was invented")
        let invented = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "サンプル")).firstMatch
        XCTAssertTrue(invented.waitForExistence(timeout: 30), "the guide did not fill")

        app.buttons["終了"].tap()

        // Back to a first launch: no recorder, and none of the invented programmes left in the cache.
        XCTAssertTrue(app.staticTexts["レコーダーが登録されていません"].waitForExistence(timeout: 30),
                      "ending the demo did not put the app back")
        XCTAssertFalse(strip.exists, "the demo strip stayed after the demo ended")
    }
}
