import XCTest

/// A label that holds each of these words, wherever it has them.
private func labelContains(_ words: String...) -> NSPredicate {
    NSCompoundPredicate(andPredicateWithSubpredicates: words.map { NSPredicate(format: "label CONTAINS %@", $0) })
}

/// The demo is offered to people who have no recorder, and it has to leave nothing behind for the ones who
/// then go and set a real one up. That is the promise worth a test: the invented guide lives in its own
/// database, ending the demo deletes it and puts the previous recorder back, and choosing a recorder from
/// inside the demo ends it too and keeps the one chosen. Its invented guide is also what a screen that needs
/// a guide is tried against, as the search by a name in the cast, the channel settings and the guide's list
/// at a large text size are below, and its reservations and recordings what the sheets opened from them are.
/// Its invented television, which the reader adds from the demo's search, is what the television's screens are
/// tried against, and it has to go with the demo as well.
final class DemoModeTests: XCTestCase {
    private static let demoHost = "192.0.2.63"
    private static let demoMac = "f8:4e:17:00:00:00"
    private static let demoTVHost = "192.0.2.64"

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheDemoFillsTheAppAndEndingItLeavesNothingBehind() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        // The settings, once seen in the demo, show its address and its MAC, which have to go with it.
        app.tab(.settings).tap()
        let address = addressField(app)
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the settings had no address field")
        XCTAssertEqual(address.value as? String, Self.demoHost)
        app.tab(.guide).tap()

        endTheDemo(app)

        // Back to a first launch: no recorder, and none of the invented programmes left in the cache.
        XCTAssertTrue(app.staticTexts["レコーダーが追加されていません"].waitForExistence(timeout: 30),
                      "ending the demo did not put the app back")
        XCTAssertFalse(demoStrip(app).exists, "the demo strip stayed after the demo ended")

        app.tab(.settings).tap()
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

        app.tab(.settings).tap()
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

        // Over as soon as the recorder is chosen, and the address chosen is the one kept. The demo's button is
        // further down the form than the screen reaches.
        let tryDemo = app.buttons["サンプルデータで試す"]
        scroll(app, to: tryDemo)
        XCTAssertTrue(tryDemo.exists, "choosing a recorder did not end the demo")
        scrollBack(app, to: address)
        XCTAssertEqual(address.value as? String, "127.0.0.1", "the address chosen was not kept")

        // Nothing answers there, and the app says so rather than showing the demo as connected.
        app.tab(.guide).tap()
        XCTAssertTrue(app.staticTexts["レコーダーの応答がありません"].waitForExistence(timeout: 30),
                      "the app did not say it could not reach the recorder chosen")
        XCTAssertFalse(demoStrip(app).exists, "the demo strip stayed after a recorder was chosen")
        XCTAssertFalse(app.staticTexts["レコーダーが追加されていません"].exists,
                       "the recorder chosen was forgotten")
    }

    /// A name in the cast is only in a programme's details, which the guide's search now reads. The demo's
    /// dramas list an invented cast there, so searching for one of the names finds them, and a result found
    /// that way says so on its row, since neither its title nor its description would.
    func testSearchingTheGuideByANameInTheCastSaysWhereItWasFound() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.search).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("みほん花子")

        let detail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "詳細：")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "no result said it was found in the details")
        XCTAssertTrue(detail.label.contains("出演　サンプル太郎、みほん花子"), "the snippet was \(detail.label)")

        endTheDemo(app)
    }

    /// What the search finds is of every day, where the guide's list is of one day and the reservations' list is under
    /// the days' headings, so a row found says its day: a programme's above its time, in the column beside its title,
    /// and a reservation's before its time. The demo's weekly drama is in the guide on more than one day, and reserved.
    func testWhatTheSearchFindsSaysItsDay() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.search).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        // The return key puts the keyboard away, which otherwise covers the results.
        field.typeText("ひかりの街\n")

        let title = app.staticTexts.matching(labelContains("ひかりの街")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the search found no programme")
        let day = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\d{1,2}/\\d{1,2}\\(.\\)")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 10), "a programme found did not say its day")
        XCTAssertLessThanOrEqual(day.frame.maxX, title.frame.minX, "the day was not in the column beside the title")

        let reservations = app.segmentedControls.buttons["予約"]
        XCTAssertTrue(reservations.waitForExistence(timeout: 10), "the search offered no 予約")
        reservations.tap()
        let when = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@",
                                                        "\\d{1,2}/\\d{1,2}\\(.\\) \\d{2}:\\d{2}\\s.*")).firstMatch
        XCTAssertTrue(when.waitForExistence(timeout: 20), "a reservation found did not say its day")

        clearTheSearchOnAnIPad(app)
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

        app.tab(.settings).tap()
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
        app.tab(.guide).tap()
        XCTAssertTrue(guideMenu(app, "地デジ").waitForExistence(timeout: 10),
                      "the list stayed narrowed to a hidden channel")
        XCTAssertTrue(channelLine(app, "サンプルテレビ").waitForExistence(timeout: 10), "the guide went empty")
        XCTAssertFalse(channelLine(app, "サンプル教育").exists, "the hidden channel was still in the guide")

        // Back, and the reset brings it back.
        app.tab(.settings).tap()
        let reset = app.buttons["レコーダーの順に戻して、すべて表示"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "the channels screen had no reset")
        reset.tap()
        let confirm = app.buttons["レコーダーの順に戻す"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the reset did not ask first")
        confirm.tap()
        let shown = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: channel)
        wait(for: [shown], timeout: 10)

        // A channel chosen on one broadcasting type is let go on another, and the demo's missing CS is said.
        app.tab(.guide).tap()
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

    /// At an accessibility text size the guide's list puts the time above the title: a time column wide enough
    /// for the time left the title a few characters a line. And the channel's line under the title is one
    /// text, which wraps across the row, where it was a row of views each squeezed into a column of its own.
    func testTheGuideListStacksAtAnAccessibilityTextSize() {
        let app = launchWithoutARecorder(textSize: "UICTContentSizeCategoryAccessibilityL")
        startTheDemo(app)

        let line = channelLine(app, "サンプルテレビ")
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the guide showed no programme on the channel")
        let time = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\d{1,2}:\\d{2}\\s+\\d+分"))
            .firstMatch
        XCTAssertTrue(time.exists, "the time and the length were not one line of their own")
        XCTAssertEqual(time.frame.minX, line.frame.minX, accuracy: 2, "the time was still in a column beside the title")
        if onAnIPad {
            // An iPad's row is wide enough for the whole line, which is then one line, as the time's is, and only as
            // wide as its words.
            XCTAssertLessThan(line.frame.height, time.frame.height * 1.5, "the channel's line was squeezed into a column")
        } else {
            XCTAssertGreaterThan(line.frame.width, app.windows.firstMatch.frame.width * 0.4,
                                 "the channel's line was squeezed into a column")
        }

        endTheDemo(app)
    }

    /// The recorder marks a reservation 重複 without saying what with, and its sheet now names the
    /// reservations at the same hours. The demo's おまかせ reservations carry the recorder's own creator id,
    /// so the list marks them, and deleting is called 削除 on the sheet as it is in the list.
    func testAReservationMarkedAsClashingNamesTheOnesAtTheSameTime() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.reservations).tap()
        XCTAssertTrue(app.staticTexts["おまかせ"].waitForExistence(timeout: 20),
                      "the recorder's own reservations were not marked おまかせ")
        let clashing = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ひなたスポーツ特集"))
            .firstMatch
        scroll(app, to: clashing)
        clashing.tap()

        XCTAssertTrue(app.staticTexts["時間が重なる予約"].waitForExistence(timeout: 10),
                      "the sheet did not list the reservations at the same time")
        let named = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                         "サンプル放送　みほんスポーツ中継「サンプルリーグ」"))
        XCTAssertTrue(named.firstMatch.exists, "the reservation at the same time was not named")
        let delete = app.buttons["予約を削除"]
        scroll(app, to: delete)
        XCTAssertTrue(delete.exists, "the sheet did not offer 予約を削除")

        app.buttons["閉じる"].firstMatch.tap()
        endTheDemo(app)
    }

    /// An episode opened from a programme's recordings comes up over them, and closing it goes back to them
    /// rather than to the list of programmes, where the programme had to be found again for the next one.
    func testAnEpisodeOpensOverItsProgrammeAndClosesBackToIt() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.recordings).tap()
        let mode = app.buttons["表示を変える"]
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "the recordings screen had no display menu")
        mode.tap()
        let groups = app.buttons["まとめ"]
        XCTAssertTrue(groups.waitForExistence(timeout: 10), "the menu did not offer まとめ")
        groups.tap()

        let programme = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ひかりの街")).firstMatch
        XCTAssertTrue(programme.waitForExistence(timeout: 20), "the programmes did not list the drama")
        programme.tap()
        let select = app.buttons["選択"]
        XCTAssertTrue(select.waitForExistence(timeout: 10), "the programme's sheet did not open")

        let episode = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第４話")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10), "the programme's sheet did not list the episode")
        episode.tap()
        let recording = app.navigationBars["録画"]
        XCTAssertTrue(recording.waitForExistence(timeout: 10), "the episode did not open")
        recording.buttons["閉じる"].tap()

        XCTAssertTrue(select.waitForExistence(timeout: 10), "closing the episode closed its programme too")
        XCTAssertTrue(episode.exists, "the programme's episodes were gone")

        app.buttons["閉じる"].firstMatch.tap()
        endTheDemo(app)
    }

    /// The demo's recorder has a USB disk, and its recordings are in the one list, the disk named on their rows
    /// and on their sheets. The filter menu narrows the list to the disk, and the title bar's free space and the
    /// count under it follow; すべて puts both back.
    func testTheRecordingsOfTheUSBDiskAreInTheOneList() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.recordings).tap()
        // The flat list, whichever way the last test left this kept choice.
        let mode = app.buttons["表示を変える"]
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "the recordings screen had no display menu")
        mode.tap()
        let flat = app.buttons["一覧"]
        XCTAssertTrue(flat.waitForExistence(timeout: 10), "the menu did not offer 一覧")
        flat.tap()
        let filter = app.buttons["録画先・ジャンル・並び順・視聴状態で絞り込む"]
        XCTAssertTrue(filter.waitForExistence(timeout: 20), "the recordings screen offered no choice of disk")
        let everything = app.staticTexts["27 件"]
        XCTAssertTrue(everything.waitForExistence(timeout: 20), "the list was not both disks': \(app.debugDescription)")
        let free = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "残り")).firstMatch
        let internalFree = free.label

        filter.tap()
        let disk = app.buttons["サンプルディスク"]
        XCTAssertTrue(disk.waitForExistence(timeout: 10), "the menu did not offer the disk by its name")
        disk.tap()
        XCTAssertTrue(app.staticTexts["サンプルディスク · 5 件"].waitForExistence(timeout: 10),
                      "the list was not narrowed to the disk")
        XCTAssertNotEqual(free.label, internalFree, "the free space did not follow the disk")

        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "BS名画サンプル")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the list did not hold the disk's recording")
        row.tap()
        let sheet = opened(app, "録画")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the recording did not open")
        XCTAssertTrue(app.staticTexts["録画先"].waitForExistence(timeout: 10), "the sheet did not name the disk")
        closeOf(app, "録画").tap()

        filter.tap()
        let all = app.buttons["すべて"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), "the menu offered no way back")
        all.tap()
        XCTAssertTrue(everything.waitForExistence(timeout: 10), "すべて did not put the list back")
        XCTAssertEqual(free.label, internalFree, "the free space did not come back to the internal disk's")

        endTheDemo(app)
    }

    /// The demo's television, once added, has recordings of its own in the one list, テレビ named on their rows and
    /// offered in the filter, which the list and the title bar's free space follow. A row's sheet says what the row
    /// says and offers no playing; its protection holds its delete; and its delete takes it off the list. They go
    /// with the demo.
    func testTheTelevisionsRecordingsAreInTheOneList() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.settings).tap()
        searchForTheDemosTelevision(app).tap()
        let number = app.textFields["4 桁の番号"]
        XCTAssertTrue(number.waitForExistence(timeout: 20), "the sheet did not go straight to the number")
        number.tap()
        number.typeText("1234")
        app.buttons["登録する"].tap()
        XCTAssertTrue(app.navigationBars["テレビを追加"].waitForNonExistence(timeout: 20), "the sheet did not close")

        app.tab(.recordings).tap()
        let mode = app.buttons["表示を変える"]
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "the recordings screen had no display menu")
        mode.tap()
        let flat = app.buttons["一覧"]
        XCTAssertTrue(flat.waitForExistence(timeout: 10), "the menu did not offer 一覧")
        flat.tap()
        let everything = app.staticTexts["31 件"]
        XCTAssertTrue(everything.waitForExistence(timeout: 20), "the list was not both devices': \(app.debugDescription)")
        let free = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "残り")).firstMatch
        let internalFree = free.label

        let filter = app.buttons["録画先・ジャンル・並び順・視聴状態で絞り込む"]
        filter.tap()
        let television = app.buttons["テレビ"]
        XCTAssertTrue(television.waitForExistence(timeout: 10), "the menu did not offer the television")
        television.tap()
        XCTAssertTrue(app.staticTexts["テレビ · 4 件"].waitForExistence(timeout: 10),
                      "the list was not narrowed to the television")
        XCTAssertNotEqual(free.label, internalFree, "the free space did not follow the television")

        let row = app.staticTexts.matching(labelContains("サンプルクイズ王")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the list did not hold the television's recording")
        XCTAssertTrue(app.staticTexts.matching(labelContains("  テレビ  ")).firstMatch.exists,
                      "no row named テレビ: \(app.debugDescription)")
        row.tap()
        let sheet = opened(app, "録画")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the recording did not open")
        XCTAssertTrue(app.staticTexts["全国のサンプル名人が集まる大会。"].waitForExistence(timeout: 10),
                      "the sheet did not say the row's text")
        XCTAssertFalse(app.staticTexts["テレビで再生"].exists, "a television's row offered playing")

        let protection = app.switches["保護"]
        XCTAssertTrue(protection.waitForExistence(timeout: 10), "the sheet offered no protection")
        let delete = app.buttons["この録画を削除"]
        XCTAssertTrue(delete.isEnabled, "a recording that can go could not be deleted")
        protection.switches.firstMatch.tap()
        let held = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: delete)
        wait(for: [held], timeout: 10)
        protection.switches.firstMatch.tap()
        let free2 = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: delete)
        wait(for: [free2], timeout: 10)
        delete.tap()
        let confirm = app.alerts.buttons["削除する"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "この録画を削除 asked nothing")
        XCTAssertTrue(app.alerts.staticTexts.matching(labelContains("テレビから削除され")).firstMatch.exists,
                      "the question did not name the television")
        confirm.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 20), "the sheet did not close once deleted")
        XCTAssertTrue(app.staticTexts["テレビ · 3 件"].waitForExistence(timeout: 10), "the row stayed in the list")

        endTheDemo(app)
    }

    /// The mode a new reservation starts at is the one in the settings, and choosing another on a programme
    /// is for that reservation only. The sheet used to be bound to the setting, so trying a mode changed it.
    func testChoosingAModeOnAProgrammeLeavesTheDefaultAlone() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.settings).tap()
        let setting = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "既定の録画モード")).firstMatch
        scroll(app, to: setting)
        XCTAssertTrue(setting.exists, "the settings had no default recording mode")
        setting.tap()
        let dr = app.buttons["DR(高画質)"]
        XCTAssertTrue(dr.waitForExistence(timeout: 10), "the default mode offered no DR")
        dr.tap()
        XCTAssertTrue(says(setting, "DR(高画質)"), "the default was \(setting.debugDescription)")

        // A programme's sheet starts at it, and another mode chosen there stays there.
        app.tab(.search).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("遠い灯台")
        let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "遠い灯台")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "the search found nothing")
        result.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "録画モード")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the programme's sheet had no mode")
        XCTAssertTrue(says(picker, "DR(高画質)"), "the sheet started at \(picker.debugDescription)")
        picker.tap()
        let eer = app.buttons["EER(長時間)"]
        XCTAssertTrue(eer.waitForExistence(timeout: 10), "the sheet's mode offered no EER")
        eer.tap()
        XCTAssertTrue(says(picker, "EER(長時間)"), "the sheet's mode was \(picker.debugDescription)")
        closeOf(app, "番組").tap()

        // Opened again, it starts from the default, which the choice above has not touched. Asked here rather
        // than on the settings screen: the tab bar is under the search's keyboard.
        result.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the programme's sheet did not open again")
        XCTAssertTrue(says(picker, "DR(高画質)"), "choosing on the programme changed the default: "
                      + picker.debugDescription)
        closeOf(app, "番組").tap()

        endTheDemo(app)
    }

    /// The demo's television, added and used as a reader would, and gone with the demo. The demo's search lists
    /// it beside the demo's recorder; tapped, its sheet goes straight to the number, says the number, and stays
    /// up -- a sheet hung on the television's section went by itself at the first press, as the section turned
    /// from one form to the other under it; registered with that number, the section says it is connected. Its
    /// own recording is on the reservations tab as the television's. A programme reserved on it from its sheet
    /// is marked in the search and listed as the television's, its repeat changed, and deleted. Ended, the demo
    /// takes the television with it, and started again it has none.
    func testTheDemosTelevisionIsFoundReservedAndGoesWithTheDemo() {
        let app = launchWithoutARecorder()
        startTheDemo(app)

        // The television's section is there in the demo, saying that a television can be tried there.
        app.tab(.settings).tap()
        let add = app.buttons["アドレスを入力して追加"]
        scroll(app, to: add)
        XCTAssertTrue(add.exists, "the demo had no television's section")
        XCTAssertTrue(app.staticTexts.matching(labelContains("架空のテレビを追加して試せます")).firstMatch.exists,
                      "the television's section did not say what the demo has")
        let found = searchForTheDemosTelevision(app)
        let recorder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.demoHost)).firstMatch
        XCTAssertTrue(recorder.label.contains("使用中"), "the demo's recorder was \(recorder.label)")
        found.tap()
        let number = app.textFields["4 桁の番号"]
        XCTAssertTrue(number.waitForExistence(timeout: 20), "the sheet did not go straight to the number")
        XCTAssertTrue(app.staticTexts.matching(labelContains("サンプルのテレビの番号は 1234 です。")).firstMatch.exists,
                      "the sheet did not say the demo's number")
        XCTAssertFalse(app.navigationBars["テレビを追加"].waitForNonExistence(timeout: 2), "the sheet went by itself")
        number.tap()
        number.typeText("1234")
        app.buttons["登録する"].tap()
        XCTAssertTrue(app.navigationBars["テレビを追加"].waitForNonExistence(timeout: 20), "the sheet did not close")
        // A row of a form reads as its name and its value, joined.
        let connected = app.staticTexts["状態、接続済み"]
        scroll(app, to: connected)
        XCTAssertTrue(connected.exists, "the demo's television was not said to be connected")
        XCTAssertTrue(app.staticTexts["機種、KJ-SAMPLE"].exists, "the section did not say which television")
        XCTAssertFalse(app.buttons["アドレスを入力して追加"].exists, "the section still offered to add one")

        // What it holds from the start, as the television's.
        app.tab(.reservations).tap()
        let held = app.staticTexts.matching(labelContains("テレビ", "みほんBS")).firstMatch
        scroll(app, to: held)
        XCTAssertTrue(held.exists, "the television's own recording was not listed as the television's")

        // A programme of the guide reserved on it, ahead of now: one under way could not have its repeat changed.
        app.tab(.search).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        // The return key puts the keyboard away, which otherwise covers the tab bar.
        field.typeText("みほん自然紀行\n")
        let ahead = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@",
                                                         "サンプル教育", "放送中")).firstMatch
        XCTAssertTrue(ahead.waitForExistence(timeout: 20), "the search found nothing ahead")
        ahead.tap()
        let destination = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "予約先")).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 20), "the programme's sheet offered no 予約先")
        destination.tap()
        let television = app.buttons["テレビ"]
        XCTAssertTrue(television.waitForExistence(timeout: 10), "予約先 offered no television")
        television.tap()
        XCTAssertTrue(says(destination, "テレビ"), "予約先 was \(destination.debugDescription)")
        app.buttons["録画予約する"].tap()
        let reserve = app.alerts.buttons["予約する"]
        XCTAssertTrue(reserve.waitForExistence(timeout: 10), "録画予約する asked nothing")
        reserve.tap()
        if onAnIPad {
            // An iPad's column stays, and shows what became of the programme: the television's reservation of it.
            XCTAssertTrue(app.buttons["予約を削除"].waitForExistence(timeout: 20), "the column did not show what was made")
        } else {
            XCTAssertTrue(app.navigationBars["番組"].waitForNonExistence(timeout: 20), "the sheet did not close once made")
        }
        XCTAssertTrue(app.staticTexts.matching(labelContains("サンプル教育", "予約")).firstMatch.waitForExistence(timeout: 10),
                      "the search did not mark the programme reserved")
        if app.keyboards.firstMatch.exists { field.typeText("\n") }
        clearTheSearchOnAnIPad(app)

        // On the reservations tab as the television's: its repeat changed, and then deleted.
        app.tab(.reservations).tap()
        let row = app.staticTexts.matching(labelContains("テレビ", "サンプル教育")).firstMatch
        find(app, row)
        XCTAssertTrue(row.exists, "the reservation was not listed as the television's")
        row.tap()
        let repeating = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "毎回録画")).firstMatch
        XCTAssertTrue(repeating.waitForExistence(timeout: 20), "the reservation's sheet offered no repeat")
        repeating.tap()
        let daily = app.buttons["毎日"]
        XCTAssertTrue(daily.waitForExistence(timeout: 10), "the repeat offered no 毎日")
        daily.tap()
        app.buttons["変更をテレビに送る"].tap()
        XCTAssertTrue(opened(app, "予約").waitForNonExistence(timeout: 20), "the sheet did not close once changed")
        find(app, row)
        row.tap()
        XCTAssertTrue(repeating.waitForExistence(timeout: 20), "the reservation's sheet did not open again")
        XCTAssertTrue(says(repeating, "毎日"), "the change was not kept: \(repeating.debugDescription)")
        app.buttons["予約を削除"].tap()
        let delete = app.alerts.buttons["削除する"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "予約を削除 asked nothing")
        delete.tap()
        XCTAssertTrue(opened(app, "予約").waitForNonExistence(timeout: 20), "the sheet did not close once deleted")
        XCTAssertTrue(row.waitForNonExistence(timeout: 20), "the reservation was still listed")

        // Gone with the demo, and not there when it starts again.
        endTheDemo(app)
        app.tab(.settings).tap()
        find(app, add)
        XCTAssertTrue(add.exists, "the television's section did not go back to adding one")
        XCTAssertFalse(app.staticTexts["機種、KJ-SAMPLE"].exists, "the demo's television stayed after the demo")
        // Held back while anything is under way with the recorder in play, as entering the demo is.
        let tryAgain = app.buttons["サンプルデータで試す"]
        scroll(app, to: tryAgain)
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: tryAgain)
        wait(for: [enabled], timeout: 30)
        tryAgain.tap()
        // The settings have no strip of their own: the button says the demo is on. An iPad's form reaches it without
        // a scroll, and the demo's recorder's rows coming in above it then push it out of view.
        let endDemo = app.buttons["サンプルデータを終了する"]
        if onAnIPad { scroll(app, to: endDemo) }
        XCTAssertTrue(endDemo.waitForExistence(timeout: 30), "the demo did not start again: \(tryAgain.debugDescription)")
        let again = searchForTheDemosTelevision(app)
        XCTAssertFalse(again.label.contains("使用中"), "the demo's television was kept for the next demo")
        app.tab(.guide).tap()
        endTheDemo(app)
    }

    // MARK: - an iPad's column

    /// On an iPad a programme of the guide opens in the column beside it, where an iPhone has a sheet over it. Another
    /// programme tapped takes its place there, and its close closes it, leaving the guide as it was.
    func testOnAnIPadAProgrammeOpensBesideTheGuide() throws {
        try XCTSkipUnless(onAnIPad, "an iPhone opens a programme in a sheet")
        let app = launchWithoutARecorder()
        startTheDemo(app)

        inView(app, "サンプルテレビ").tap()
        let close = columnsClose(app)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the programme did not open")
        XCTAssertTrue(isBesideTheList(app, close), "the programme was not beside the guide: \(close.frame)")
        XCTAssertTrue(app.staticTexts["放送、サンプルテレビ"].waitForExistence(timeout: 10), "the column was not the programme's")

        let another = inView(app, "テレビみほん")
        another.tap()
        XCTAssertTrue(app.staticTexts["放送、テレビみほん"].waitForExistence(timeout: 10),
                      "the programme tapped next did not take the column")
        XCTAssertFalse(app.staticTexts["放送、サンプルテレビ"].exists, "the first programme stayed in the column")

        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "the column did not close")
        XCTAssertTrue(another.isHittable, "the guide did not stay as it was")

        endTheDemo(app)
    }

    /// On an iPad a reservation made in a programme's column is said there, where an iPhone's sheet closes: the column
    /// stays, and shows the programme reserved.
    func testOnAnIPadAReservationMadeInTheColumnIsShownThere() throws {
        try XCTSkipUnless(onAnIPad, "an iPhone's sheet closes once the reservation is made")
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.search).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("みほん自然紀行\n")
        let ahead = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@",
                                                         "サンプル教育", "放送中")).firstMatch
        XCTAssertTrue(ahead.waitForExistence(timeout: 20), "the search found nothing ahead")
        ahead.tap()
        let close = columnsClose(app)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the programme did not open")
        let reserve = app.buttons["録画予約する"]
        XCTAssertTrue(reserve.waitForExistence(timeout: 20), "the column offered no reservation")
        reserve.tap()
        let confirm = app.alerts.buttons["予約する"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "録画予約する asked nothing")
        confirm.tap()

        XCTAssertTrue(app.staticTexts["この番組は予約済みです"].waitForExistence(timeout: 20),
                      "the column did not say the programme was reserved")
        XCTAssertTrue(app.buttons["予約を削除"].exists, "the column did not offer the reservation's delete")
        XCTAssertFalse(reserve.exists, "the column still offered to reserve it")
        XCTAssertTrue(close.exists, "the column closed")

        clearTheSearchOnAnIPad(app)
        endTheDemo(app)
    }

    /// On an iPad a reservation opens in the column beside the list, and its delete closes the column and takes the row
    /// off the list.
    func testOnAnIPadAReservationOpensBesideTheListAndItsDeleteClosesIt() throws {
        try XCTSkipUnless(onAnIPad, "an iPhone opens a reservation in a sheet")
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.reservations).tap()
        let row = app.staticTexts.matching(labelContains("みほんスポーツ中継")).firstMatch
        find(app, row)
        row.tap()
        let close = columnsClose(app)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the reservation did not open")
        XCTAssertTrue(isBesideTheList(app, close), "the reservation was not beside the list: \(close.frame)")

        let delete = app.buttons["予約を削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "the column offered no delete")
        delete.tap()
        let confirm = app.alerts.buttons["削除する"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "予約を削除 asked nothing")
        confirm.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 20), "the column did not close once deleted")
        XCTAssertTrue(row.waitForNonExistence(timeout: 20), "the reservation was still listed")

        endTheDemo(app)
    }

    /// On an iPad a recording opens in the column beside the list, and its delete closes the column and takes the row
    /// off the list.
    func testOnAnIPadARecordingOpensBesideTheListAndItsDeleteClosesIt() throws {
        try XCTSkipUnless(onAnIPad, "an iPhone opens a recording in a sheet")
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.recordings).tap()
        let mode = app.buttons["表示を変える"]
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "the recordings screen had no display menu")
        mode.tap()
        let flat = app.buttons["一覧"]
        XCTAssertTrue(flat.waitForExistence(timeout: 10), "the menu did not offer 一覧")
        flat.tap()
        let row = app.staticTexts.matching(labelContains("みほんクラシック館")).firstMatch
        find(app, row)
        row.tap()
        let close = columnsClose(app)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the recording did not open")
        XCTAssertTrue(isBesideTheList(app, close), "the recording was not beside the list: \(close.frame)")

        let delete = app.buttons["この録画を削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "the column offered no delete")
        delete.tap()
        let confirm = app.alerts.buttons["削除する"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "この録画を削除 asked nothing")
        confirm.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 20), "the column did not close once deleted")
        XCTAssertTrue(row.waitForNonExistence(timeout: 20), "the recording was still listed")

        endTheDemo(app)
    }

    /// On an iPad the search's results open in one column, whichever of the three kinds they are: a programme, a
    /// reservation and a recording, each in its scope. Another scope closes it, and so do other words.
    func testOnAnIPadTheSearchOpensEachKindInTheOneColumn() throws {
        try XCTSkipUnless(onAnIPad, "an iPhone opens a result in a sheet")
        let app = launchWithoutARecorder()
        startTheDemo(app)

        app.tab(.search).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("ひかりの街\n")
        let close = columnsClose(app)
        for (scope, title) in [("番組表", "番組"), ("予約", "予約"), ("録画", "録画")] {
            let chosen = app.segmentedControls.buttons[scope]
            XCTAssertTrue(chosen.waitForExistence(timeout: 10), "the search offered no \(scope)")
            chosen.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 10), "\(scope): the scope left the column open")
            let result = app.staticTexts.matching(labelContains("ひかりの街")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 20), "\(scope): the search found nothing")
            result.tap()
            XCTAssertTrue(close.waitForExistence(timeout: 10), "\(scope): the result did not open")
            XCTAssertTrue(isBesideTheList(app, close), "\(scope): the result was not beside the list: \(close.frame)")
            XCTAssertTrue(app.staticTexts[title].exists, "\(scope): the column was not titled \(title)")
            XCTAssertEqual(app.buttons.matching(identifier: "sheet-close").count, 1, "\(scope): more than one column")
        }

        field.tap()
        field.typeText("　第")
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "other words left the column open")

        clearTheSearchOnAnIPad(app)
        endTheDemo(app)
    }

    // MARK: - steps

    /// The close of the column beside a list on an iPad, which is the one close on the screen while the column is open.
    private func columnsClose(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "sheet-close").firstMatch
    }

    /// Whether a close is the column's at the window's right edge, beside the list, and not a sheet's over it.
    private func isBesideTheList(_ app: XCUIApplication, _ close: XCUIElement) -> Bool {
        close.frame.maxX > app.windows.firstMatch.frame.maxX - 60
    }

    /// The first row of the guide's list on the screen whose line under the title names this channel.
    private func inView(_ app: XCUIApplication, _ channel: String) -> XCUIElement {
        let lines = app.staticTexts.matching(labelContains(channel))
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 20), "the guide had no programme on \(channel)")
        let shown = lines.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(shown, "no programme on \(channel) was on the screen")
        return shown ?? lines.firstMatch
    }

    /// What says that the sheet a row opened is up, by its title: on an iPhone its bar. On an iPad's regular width the
    /// row opens in the column beside its list instead, which has no bar of its own: its close, the one on the screen
    /// (`columnTitle`).
    private func opened(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        onAnIPad ? closeOf(app, title) : app.navigationBars[title]
    }

    /// The close of that sheet, or of that column.
    private func closeOf(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        onAnIPad ? app.buttons.matching(identifier: "sheet-close").firstMatch : app.navigationBars[title].buttons["閉じる"]
    }

    /// On an iPad the search field, while it holds words, stands in the window's bar where the tabs were (iPadOS 27),
    /// and clearing it with its own button brings them back. An iPhone's tab bar stays under it.
    private func clearTheSearchOnAnIPad(_ app: XCUIApplication) {
        guard onAnIPad else { return }
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "the search field had nothing to clear it with")
        clear.tap()
    }

    /// Whether a picker's row shows this choice, which it gives as its label or as its value.
    private func says(_ picker: XCUIElement, _ choice: String) -> Bool {
        picker.label.contains(choice) || (picker.value as? String)?.contains(choice) == true
    }

    /// The line under a programme's title in the guide's list, by the channel it starts with. It is one text
    /// with the marks and the genre, so the channel's name is not a text of its own there.
    private func channelLine(_ app: XCUIApplication, _ channel: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", channel)).firstMatch
    }

    /// A row further down a form is not there to find until it has been scrolled into view.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<8 where !element.waitForExistence(timeout: 2) || !element.isHittable {
            app.swipeUp()
        }
    }

    /// The same for a row further up, once a form has been scrolled down.
    private func scrollBack(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<8 where !element.waitForExistence(timeout: 2) || !element.isHittable {
            app.swipeDown()
        }
    }

    /// A row of a list that was left scrolled somewhere earlier: looked for back up the list first, then down it.
    private func find(_ app: XCUIApplication, _ element: XCUIElement) {
        scrollBack(app, to: element)
        scroll(app, to: element)
    }

    /// Presses レコーダーとテレビを探す in the settings, once it can be pressed -- the demo's own connect holds it
    /// back -- and hands back the demo's television's row, which says its model and its address.
    private func searchForTheDemosTelevision(_ app: XCUIApplication) -> XCUIElement {
        let search = app.buttons["レコーダーとテレビを探す"]
        find(app, search)
        XCTAssertTrue(search.exists, "the settings had no search")
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: search)
        wait(for: [enabled], timeout: 30)
        search.tap()
        let found = app.buttons.matching(labelContains(Self.demoTVHost)).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 20), "the demo's search did not list its television")
        XCTAssertTrue(found.label.contains("KJ-SAMPLE"), "the demo's television's row was \(found.label)")
        return found
    }

    /// The guide's broadcasting type and channel menu, by what its title says.
    private func guideMenu(_ app: XCUIApplication, _ heading: String) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", heading)).firstMatch
    }

    /// No recorder, no MAC and no television, so the tutorial is the first thing up: a television saved on this
    /// simulator would keep it down, and ending the demo would connect to that television on the Mac's LAN.
    /// `-demoData` is deliberately not passed: the argument domain outranks what the app writes, and the app has
    /// to be able to turn the demo on itself. The broadcasting type and the orders are pinned, since the app
    /// keeps them between launches and a test that switched to CS would otherwise start the next one there.
    /// `textSize` is a content size category's name, for the reader's text size.
    private func launchWithoutARecorder(textSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-recorderHost", "", "-recorderMac", "", "-tvHost", "", "-tvMac", "",
                               "-startTab", "guide", "-guideMode", "list"]
            + ScreenshotTests.pinned
            + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        // A previous run on this simulator may have left the demo on. The tutorial comes up only at launch,
        // so once the demo is over the app is launched again.
        if demoStrip(app).waitForExistence(timeout: 10) {
            endTheDemo(app)
            _ = app.staticTexts["レコーダーが追加されていません"].waitForExistence(timeout: 30)
            app.terminate()
            app.launch()
        }
        return app
    }

    private func startTheDemo(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["RecBridge"].waitForExistence(timeout: 20), "the tutorial did not come up")
        // At a large text size it is further down the tutorial's list than the screen reaches, and a list row
        // is not there to find until it has been scrolled to. Waiting for the tutorial first rather than for
        // the button: the button's own wait would run its full length there before the scroll began.
        let tryDemo = app.buttons["サンプルデータで試す"]
        scroll(app, to: tryDemo)
        XCTAssertTrue(tryDemo.exists, "the tutorial did not offer the demo")
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
