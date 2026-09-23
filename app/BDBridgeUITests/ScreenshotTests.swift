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
        //    Opened at seven in the evening rather than at whatever time the shot is taken, so the picture
        //    is of an evening's television and not of the small hours. Nothing is tapped here: tapping the
        //    zoom button once landed on the programme behind it and the "guide" shot came out as a
        //    programme sheet.
        try shot("01_guide_grid",
                 arguments: ["-startTab", "guide", "-guideMode", "grid", "-guideOpenAt", "19:00"]) { app in
            self.waitFor(app.staticTexts["サンプルテレビ"], "01_guide_grid")
        }

        // 2. The same guide as a list, which is the other way the screen is read: logos, genres, what is
        //    already set to record, and the description under each programme.
        try shot("02_guide_list",
                 arguments: ["-startTab", "guide", "-guideMode", "list", "-guideOpenAt", "19:00"]) { app in
            self.waitFor(app.staticTexts.matching(labelContains("ひかりの街")).firstMatch, "02_guide_list")
        }

        // 3. One programme, and what a reservation of it would be. Reached through the search, which is the
        //    one route to a named programme that does not depend on the time of day.
        try shot("03_program", arguments: ["-startTab", "search"], sheet: true) { app in
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
            _ = app.staticTexts["時間が重なる予約はありません"].waitForExistence(timeout: 20)
        }

        // 4. What the recorder is going to record, the recorder's own おまかせ reservations among them.
        try shot("04_reservations", arguments: ["-startTab", "reservations"]) { app in
            self.waitFor(app.staticTexts.matching(labelContains("ひかりの街")).firstMatch, "04_reservations")
        }

        // 5. What is on the disk, with the free space in the title bar.
        try shot("05_recordings", arguments: ["-startTab", "recordings", "-recordingsMode", "list"]) { app in
            self.waitFor(app.staticTexts.matching(labelContains("空色パズル")).firstMatch, "05_recordings")
        }

        // 6. The same recordings gathered into programmes.
        try shot("06_groups", arguments: ["-startTab", "recordings", "-recordingsMode", "groups"]) { app in
            self.waitFor(app.staticTexts.matching(labelContains("ひかりの街")).firstMatch, "06_groups")
        }

        // 7. The recorder's own keyword recording, which the app can read and write.
        try shot("07_rules", arguments: ["-startTab", "reservations"]) { app in
            let rules = app.buttons["おまかせ・まる録"]
            XCTAssertTrue(rules.waitForExistence(timeout: 20), "the toolbar button never appeared")
            rules.tap()
            let condition = app.staticTexts.matching(labelContains("サンプル劇場")).firstMatch
            XCTAssertTrue(condition.waitForExistence(timeout: 20), "the conditions never loaded")
        }
    }

    // MARK: - plumbing

    /// What the app remembers between launches and the pictures must not inherit from whatever was done on
    /// the simulator before: the guide's broadcasting type, and the orders of the reservations and the
    /// recordings. A launch argument outranks what the app saves.
    static let pinned = ["-guideBroadcasting", "td", "-reservationSort", "time", "-recordingsSort", "newest"]

    private func waitFor(_ element: XCUIElement, _ name: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(name): the screen never appeared")
    }

    /// Launches the app on the demo recorder, lets the caller get the screen ready, and attaches the picture.
    private func shot(_ name: String, arguments: [String], sheet: Bool = false,
                      prepare: (XCUIApplication) throws -> Void) throws {
        let app = XCUIApplication()
        // The demo's own strip is off here: these are pictures of the app as it looks with a recorder. The
        // broadcasting type, the orders and the default recording mode are kept from one launch to the next,
        // so they are pinned too. The mode only here: the demo's tests change it, which a pin would stop.
        app.launchArguments = ["-demoData", "1", "-demoBanner", "0", "-defaultQuality", "LSR"] + Self.pinned
            + arguments
        app.launch()
        try prepare(app)
        // The lists animate in, and a shot taken on the first frame catches them half drawn.
        Thread.sleep(forTimeInterval: 1.2)
        // A stray tap can leave a sheet over the screen that was meant to be photographed, and the shot
        // still gets filed under the name of the screen it was supposed to be. Every sheet here closes with
        // the same round button, so its absence is the check.
        XCTAssertEqual(app.buttons["閉じる"].exists, sheet,
                       sheet ? "\(name): the sheet was not open" : "\(name): a sheet was over the screen")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
