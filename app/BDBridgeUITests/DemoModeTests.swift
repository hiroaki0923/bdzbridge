import XCTest

/// The demo is offered to people who have no recorder, and it has to leave nothing behind for the ones who
/// then go and set a real one up. That is the promise worth a test: the invented guide lives in its own
/// database, ending the demo deletes it and puts the previous recorder back, and choosing a recorder from
/// inside the demo ends it too and keeps the one chosen. Its invented guide is also what a screen that needs
/// a guide is tried against, as the search by a name in the cast and the channel settings are below.
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

    /// A name in the cast is only in a programme's details, which the guide's search now reads. The demo's
    /// dramas list an invented cast there, so searching for one of the names finds them, and a result found
    /// that way says so on its row, since neither its title nor its description would.
    func testSearchingTheGuideByANameInTheCastSaysWhereItWasFound() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tabBars.buttons["検索"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("みほん花子")

        let detail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "詳細：")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "no result said it was found in the details")
        XCTAssertTrue(detail.label.contains("出演　サンプル太郎、みほん花子"), "the snippet was \(detail.label)")

        endTheDemo(app)
    }

    /// Channels are hidden from the settings, and the guide follows at once. A list narrowed to the channel
    /// hidden goes back to every channel rather than staying empty with nothing to say why, and a switch of
    /// broadcasting type lets go of the channel as well. The demo has no CS guide, and the guide says so
    /// rather than pointing at the refresh button.
    func testHidingAChannelTakesItOutOfTheGuide() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        // The list narrowed to the channel about to be hidden.
        guideMenu(app, "地デジ").tap()
        let narrowTo = app.buttons["サンプル教育"]
        XCTAssertTrue(narrowTo.waitForExistence(timeout: 10), "the channel menu did not list the channel")
        narrowTo.tap()
        XCTAssertTrue(guideMenu(app, "サンプル教育").waitForExistence(timeout: 10), "the list was not narrowed")

        app.tabBars.buttons["設定"].tap()
        let arrange = app.buttons["チャンネルの表示と並び順"]
        scroll(app, to: arrange)
        XCTAssertTrue(arrange.exists, "the settings did not offer the channels")
        arrange.tap()
        let channel = app.switches["サンプル教育"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10), "the channel was not listed")
        XCTAssertEqual(channel.value as? String, "1", "the channel started hidden")
        channel.switches.firstMatch.tap()
        let hidden = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: channel)
        wait(for: [hidden], timeout: 10)

        // Gone from the guide, and the list is no longer narrowed to it.
        app.tabBars.buttons["番組表"].tap()
        XCTAssertTrue(guideMenu(app, "地デジ").waitForExistence(timeout: 10),
                      "the list stayed narrowed to a hidden channel")
        XCTAssertTrue(app.staticTexts["サンプルテレビ"].waitForExistence(timeout: 10), "the guide went empty")
        XCTAssertFalse(app.staticTexts["サンプル教育"].exists, "the hidden channel was still in the guide")

        // Back, and the reset brings it back.
        app.tabBars.buttons["設定"].tap()
        let reset = app.buttons["レコーダーの順に戻して、すべて表示"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "the channels screen had no reset")
        reset.tap()
        let confirm = app.buttons["レコーダーの順に戻す"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the reset did not ask first")
        confirm.tap()
        let shown = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: channel)
        wait(for: [shown], timeout: 10)

        // A channel chosen on one broadcasting type is let go on another, and the demo's missing CS is said.
        app.tabBars.buttons["番組表"].tap()
        guideMenu(app, "地デジ").tap()
        XCTAssertTrue(narrowTo.waitForExistence(timeout: 10), "the channel menu did not list the channel again")
        narrowTo.tap()
        guideMenu(app, "サンプル教育").tap()
        let cs = app.buttons["CS"]
        XCTAssertTrue(cs.waitForExistence(timeout: 10), "the menu did not offer CS")
        cs.tap()
        XCTAssertTrue(guideMenu(app, "CS").waitForExistence(timeout: 10), "the channel was kept on CS")
        XCTAssertTrue(app.staticTexts["CS の番組表はありません"].waitForExistence(timeout: 10),
                      "the empty CS guide did not say the demo has none")

        endTheDemo(app)
    }

    // MARK: - steps

    /// A row further down a form is not there to find until it has been scrolled into view.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<8 where !element.waitForExistence(timeout: 2) || !element.isHittable {
            app.swipeUp()
        }
    }

    /// The guide's broadcasting type and channel menu, by what its title says.
    private func guideMenu(_ app: XCUIApplication, _ heading: String) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", heading)).firstMatch
    }

    /// No recorder and no MAC, so the tutorial is the first thing up. `-demoData` is deliberately not passed:
    /// the argument domain outranks what the app writes, and the app has to be able to turn the demo on
    /// itself.
    private func launchWithoutARecorder() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-recorderHost", "", "-recorderMac", "", "-startTab", "guide", "-guideMode", "list"]
        app.launch()
        // A previous run on this simulator may have left the demo on. The tutorial comes up only at launch,
        // so once the demo is over the app is launched again.
        if demoStrip(app).waitForExistence(timeout: 10) {
            endTheDemo(app)
            _ = app.staticTexts["レコーダーが登録されていません"].waitForExistence(timeout: 30)
            app.terminate()
            app.launch()
        }
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
