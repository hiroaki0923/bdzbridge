import XCTest

/// The demo is offered to people who have no recorder, and it has to leave nothing behind for the ones who
/// then go and set a real one up. That is the promise worth a test: the invented guide lives in its own
/// database, ending the demo deletes it and puts the previous recorder back, and choosing a recorder from
/// inside the demo ends it too and keeps the one chosen.
final class DemoModeTests: XCTestCase {
    private static let demoHost = "192.0.2.63"
    private static let demoMac = "f8:4e:17:00:00:00"

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheDemoFillsTheAppAndEndingItLeavesNothingBehind() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        // The settings, once seen in the demo, show its address and its MAC, which have to go with it.
        app.tabBars.buttons["設定"].tap()
        let address = addressField(app)
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the settings had no address field")
        XCTAssertEqual(address.value as? String, Self.demoHost)
        app.tabBars.buttons["番組表"].tap()

        endTheDemo(app)

        // Back to a first launch: no recorder, and none of the invented programmes left in the cache.
        XCTAssertTrue(app.staticTexts["レコーダーが登録されていません"].waitForExistence(timeout: 30),
                      "ending the demo did not put the app back")
        XCTAssertFalse(demoStrip(app).exists, "the demo strip stayed after the demo ended")

        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the settings had no address field")
        XCTAssertNotEqual(address.value as? String, Self.demoHost, "the settings kept the demo's address")
        XCTAssertNotEqual(macField(app).value as? String, Self.demoMac, "the settings kept the demo's MAC")
    }

    /// Trying the demo and then setting up the real recorder is the way most people arrive. Choosing one used
    /// to go through the invented recorder, which said it had connected, and ending the demo then put back
    /// the recorder from before it -- none -- so the one chosen was lost.
    ///
    /// The address chosen is this device's own loopback, where nothing listens on the recorder's port: the
    /// connect is refused at once and nothing leaves the machine. `-recorderMac ""` leaves the app with no
    /// MAC once the demo is over, so no magic packet is sent either.
    func testChoosingARecorderInTheDemoEndsItAndKeepsTheChoice() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tabBars.buttons["設定"].tap()
        let address = addressField(app)
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the settings had no address field")
        // At the far end, where a right-aligned field puts the cursor after the text.
        address.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let typed = address.value as? String ?? ""
        address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 4))
        // The return key puts the keyboard away, which otherwise covers the tab bar.
        address.typeText("127.0.0.1\n")

        let connect = app.buttons["このアドレスに接続"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "the settings did not offer to connect")
        connect.tap()

        // Over as soon as the recorder is chosen, and the address chosen is the one kept.
        XCTAssertTrue(app.buttons["サンプルデータで試す"].waitForExistence(timeout: 10),
                      "choosing a recorder did not end the demo")
        XCTAssertEqual(address.value as? String, "127.0.0.1", "the address chosen was not kept")

        // Nothing answers there, and the app says so rather than showing the demo as connected.
        app.tabBars.buttons["番組表"].tap()
        XCTAssertTrue(app.staticTexts["レコーダーに接続していません"].waitForExistence(timeout: 30),
                      "the app did not say it could not reach the recorder chosen")
        XCTAssertFalse(demoStrip(app).exists, "the demo strip stayed after a recorder was chosen")
        XCTAssertFalse(app.staticTexts["レコーダーが登録されていません"].exists,
                       "the recorder chosen was forgotten")
    }

    // MARK: - steps

    /// No recorder and no MAC, so the tutorial is the first thing up. `-demoData` is deliberately not passed:
    /// the argument domain outranks what the app writes, and the app has to be able to turn the demo on
    /// itself.
    private func launchWithoutARecorder() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-recorderHost", "", "-recorderMac", "", "-startTab", "guide", "-guideMode", "list"]
        app.launch()
        // A previous run on this simulator may have left the demo on.
        if demoStrip(app).waitForExistence(timeout: 10) { endTheDemo(app) }
        return app
    }

    private func startTheDemo(_ app: XCUIApplication) {
        let tryDemo = app.buttons["サンプルデータで試す"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 20), "the tutorial did not offer the demo")
        tryDemo.tap()

        XCTAssertTrue(demoStrip(app).waitForExistence(timeout: 30), "nothing said the data was invented")
        let invented = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "サンプル")).firstMatch
        XCTAssertTrue(invented.waitForExistence(timeout: 30), "the guide did not fill")
    }

    /// Taps 終了 on the strip once it can be: it is held off while the demo's own connect is under way.
    private func endTheDemo(_ app: XCUIApplication) {
        let end = app.buttons["終了"]
        XCTAssertTrue(end.waitForExistence(timeout: 30), "the strip had no 終了")
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: end)
        wait(for: [enabled], timeout: 30)
        end.tap()
    }

    private func demoStrip(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["サンプルデータを表示しています"]
    }

    private func addressField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "192.168.1.10")).firstMatch
    }

    private func macField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "接続時に自動で記録")).firstMatch
    }
}
