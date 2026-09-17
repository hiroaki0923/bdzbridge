import XCTest

private func labelContains(_ text: String) -> NSPredicate {
    NSPredicate(format: "label CONTAINS %@", text)
}

/// Takes the App Store screenshots, on invented data.
///
/// Every launch here passes `-demoData 1`, which puts the app on a recorder made of canned answers and a
/// guide full of programmes that do not exist (see `DemoData`). Nothing on these screens comes from anyone's
/// real recorder.
///
/// The shots are attachments on the test result; `app/scripts/screenshots/capture.sh` runs this and lifts
/// them out. Without `BDBRIDGE_SHOTS` in the environment the whole thing is skipped, so an ordinary test run
/// does not stop to take pictures.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppStoreScreenshots() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BDBRIDGE_SHOTS"] == nil,
                      "set BDBRIDGE_SHOTS to take the App Store screenshots")

        // 1. The guide as a grid: time down, channels across, genres in colour, reservations marked.
        try shot("01_guide_grid", arguments: ["-startTab", "guide", "-guideMode", "grid"]) { app in
            self.waitFor(app.staticTexts["サンプルテレビ"], "01_guide_grid")
            // One step out, so a couple of hours either side of now are in the picture rather than one.
            let out = app.buttons["表示を縮小"]
            if out.waitForExistence(timeout: 10) { out.tap() }
        }

        // 2. One programme, and what a reservation of it would be. Reached through the search, which is the
        //    one route to a named programme that does not depend on the time of day.
        try shot("02_program", arguments: ["-startTab", "search"]) { app in
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
            field.tap()
            field.typeText("遠い灯台")
            let result = app.staticTexts.matching(labelContains("遠い灯台")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 20), "the search found nothing")
            result.tap()
            let reserve = app.buttons["録画予約する"]
            XCTAssertTrue(reserve.waitForExistence(timeout: 20), "the programme sheet never opened")
            // The sheet asks the recorder whether anything clashes; wait for the answer, which is the line
            // worth having in the picture.
            _ = app.staticTexts["重複する予約はありません"].waitForExistence(timeout: 20)
        }

        // 3. What the recorder is going to record, the recorder's own おまかせ reservations among them.
        try shot("03_reservations", arguments: ["-startTab", "reservations"]) { app in
            self.waitFor(app.staticTexts.matching(labelContains("ひかりの街")).firstMatch, "03_reservations")
        }

        // 4. What is on the disk, with the free space in the title bar.
        try shot("04_recordings", arguments: ["-startTab", "recordings", "-recordingsMode", "list"]) { app in
            self.waitFor(app.staticTexts.matching(labelContains("空色パズル")).firstMatch, "04_recordings")
        }

        // 5. The same recordings gathered into programmes.
        try shot("05_groups", arguments: ["-startTab", "recordings", "-recordingsMode", "groups"]) { app in
            self.waitFor(app.staticTexts.matching(labelContains("ひかりの街")).firstMatch, "05_groups")
        }

        // 6. The recorder's own keyword recording, which the app can read and write.
        try shot("06_rules", arguments: ["-startTab", "reservations"]) { app in
            let rules = app.buttons["おまかせ・まる録"]
            XCTAssertTrue(rules.waitForExistence(timeout: 20), "the toolbar button never appeared")
            rules.tap()
            let condition = app.staticTexts.matching(labelContains("サンプル劇場")).firstMatch
            XCTAssertTrue(condition.waitForExistence(timeout: 20), "the conditions never loaded")
        }
    }

    // MARK: - plumbing

    private func waitFor(_ element: XCUIElement, _ name: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(name): the screen never appeared")
    }

    /// Launches the app on the demo recorder, lets the caller get the screen ready, and attaches the picture.
    private func shot(_ name: String, arguments: [String],
                      prepare: (XCUIApplication) throws -> Void) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "1"] + arguments
        app.launch()
        try prepare(app)
        // The lists animate in, and a shot taken on the first frame catches them half drawn.
        Thread.sleep(forTimeInterval: 1.2)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
