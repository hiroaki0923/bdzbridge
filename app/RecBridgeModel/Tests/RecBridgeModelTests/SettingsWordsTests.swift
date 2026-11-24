import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// An Int as a screen's own text shows it when it is put into the text, `Text("\(n)")`: `%lld` in the reader's locale,
/// the digits grouped as it groups them. For every test of a count the model puts into a sentence.
func asATextShowsIt(_ number: Int) -> String {
    String(format: "%lld", locale: Locale.current, number)
}

/// The settings' words as the screen has always said them, byte for byte (`SettingsWords`, the recorder's part's on
/// `RecorderSettingsState`, the press of 番組表を更新's on `AppModel`), and the small rules of what they say: the
/// counts and the search's progress with the digits grouped as a screen's own text groups them, the footers in and out
/// of the demo, what the search found, where the guide comes from said alone, and when the search is held.
@MainActor
final class SettingsWordsTests: XCTestCase {
    func testTheRecordersPartSaysWhatTheScreenSaid() {
        XCTAssertEqual(RecorderSettingsState.heading, "レコーダー")
        XCTAssertEqual(RecorderSettingsState.footer,
                       "MAC アドレスは、スリープ中のレコーダーを起動するために使います。接続時に自動で記録されるので、通常は入力不要です。")
        XCTAssertEqual(RecorderSettingsState.productLabel, "機種")
        XCTAssertEqual(RecorderSettingsState.nameLabel, "名前")
        XCTAssertEqual(RecorderSettingsState.firmwareLabel, "ファームウェア")
        XCTAssertEqual(RecorderSettingsState.guideLabel, "番組表")
        XCTAssertEqual(RecorderSettingsState.standingLabel, "状態")
        XCTAssertEqual(RecorderSettingsState.hostLabel, "IP アドレス")
        XCTAssertEqual(RecorderSettingsState.hostPlaceholder, "192.168.1.10")
        XCTAssertEqual(RecorderSettingsState.macLabel, "MAC アドレス")
        XCTAssertEqual(RecorderSettingsState.macPlaceholder, "接続時に自動で記録")
        XCTAssertEqual(RecorderSettingsState.connectLabel, "このアドレスに接続")
        XCTAssertEqual(RecorderSettingsState.reconnectLabel, "再接続")
        XCTAssertEqual(RecorderSettingsState.guideShown(true), "あり")
        XCTAssertEqual(RecorderSettingsState.guideShown(false), "なし")
    }

    func testTheRestOfTheScreenSaysWhatItSaid() {
        XCTAssertEqual(SettingsWords.title, "設定")
        XCTAssertEqual(SettingsWords.defaultQualityLabel, "既定の録画モード")
        XCTAssertEqual(SettingsWords.defaultQualityFooter,
                       "録画予約とおまかせ・まる録の条件を追加するときに、最初に選ばれている録画モードです。"
                       + "予約するときに変えても、ここは変わりません。")
        XCTAssertEqual(SettingsWords.searchLabel, "レコーダーとテレビを探す")
        XCTAssertEqual(SettingsWords.foundRecordersHeading, "見つかったレコーダー")
        XCTAssertEqual(SettingsWords.channelsLabel, "チャンネルの表示と並び順")
        XCTAssertEqual(SettingsWords.channelsFooter,
                       "番組表に出す局と、その並び順を放送ごとに選べます。この端末の番組表だけが変わり、"
                       + "レコーダーの録画には影響しません。")
        XCTAssertEqual(SettingsWords.keptGuideHeading, "保存されている番組表")
        XCTAssertEqual(SettingsWords.guideSourceLabel, "番組表の取得元")
        XCTAssertEqual(SettingsWords.guideSourceName(.recorder), "レコーダー")
        XCTAssertEqual(SettingsWords.guideSourceName(.tv), "テレビ")
        XCTAssertEqual(SettingsWords.lastRefreshLabel, "最終更新")
        XCTAssertEqual(SettingsWords.lastOvernightRefreshLabel, "最終自動更新")
        XCTAssertEqual(AppModel.refreshGuideLabel, "番組表を更新")
        XCTAssertEqual(AppModel.refreshFailedTitle, "番組表を取得できませんでした")
        XCTAssertEqual(SettingsWords.enterDemoLabel, "サンプルデータで試す")
        XCTAssertEqual(SettingsWords.leaveDemoLabel, "サンプルデータを終了する")
        XCTAssertEqual(SettingsWords.appHeading, "このアプリ")
        XCTAssertEqual(Disclaimer.title, "ご利用上の注意")
        // What it opens with names both kinds of device the app works, as the page the store links to does.
        XCTAssertEqual(Disclaimer.opening,
                       "RecBridge は、ソニー製のブルーレイディスクレコーダー（BDZ シリーズ）とテレビを家庭内ネットワーク越しに操作する、"
                       + "個人が作った非公式のアプリです。ソニーグループとは関係がなく、同社の公式アプリではありません。")
        XCTAssertEqual(SettingsWords.versionLabel, "バージョン")
        XCTAssertEqual(SettingsWords.version(release: "0.2", build: "12"), "0.2 (12)")
    }

    /// A found recorder's second line, as its row has always built it: the address, the name it gave and whether it
    /// serves a guide, with the middle dot between.
    func testAFoundRecordersDetailsAreSaidAsTheRowSaidThem() throws {
        func recorder(epg: String) throws -> RecorderDescription {
            let xml = """
                <root xmlns:av="urn:schemas-sony-com:av"><device>
                <friendlyName>サンプルレコーダー</friendlyName><manufacturer>Sony Corporation</manufacturer>
                <UDN>uuid:sample</UDN>
                <av:X_ScalarWebAPI_DeviceInfo><av:EPG_CAP>\(epg)</av:EPG_CAP></av:X_ScalarWebAPI_DeviceInfo>
                <serviceList><service>
                <serviceType>urn:schemas-xsrs-org:service:X_ScheduledRecording:2</serviceType>
                </service></serviceList></device></root>
                """
            return try XCTUnwrap(Discovery.parseDescription(xml, host: "192.0.2.10", location: "", via: "scan"))
        }
        XCTAssertEqual(SettingsWords.foundRecorderDetails(try recorder(epg: "03")),
                       "192.0.2.10 \u{B7} サンプルレコーダー \u{B7} 番組表あり")
        XCTAssertEqual(SettingsWords.foundRecorderDetails(try recorder(epg: "00")),
                       "192.0.2.10 \u{B7} サンプルレコーダー \u{B7} 番組表なし")
    }

    /// What the search found, as the tutorial and the settings have always said it: the televisions' heading, 使用中 at
    /// the end of a recorder's row and of a television's, a recorder's row's 接続する, the television's row's 登録する,
    /// its name where it gave none, and what is said under the televisions while a tap registers one and with one
    /// added.
    func testWhatTheSearchFoundIsSaidAsItWas() {
        XCTAssertEqual(SettingsWords.causesHeading, "考えられる原因")
        XCTAssertEqual(SettingsWords.foundTelevisionsHeading, "見つかったテレビ")
        XCTAssertEqual(SettingsWords.inUseLabel, "使用中")
        XCTAssertEqual(SettingsWords.registerFoundLabel, "登録する")
        XCTAssertEqual(SettingsWords.connectFoundLabel, "接続する")
        XCTAssertEqual(SettingsWords.foundTelevisionName(""), "テレビ")
        XCTAssertEqual(SettingsWords.foundTelevisionName(DemoTV.model), DemoTV.model)
        XCTAssertEqual(SettingsWords.foundTelevisionsFooter(registers: true),
                       "タップすると登録を始めます。テレビの画面に 4 桁の番号が出るので、その番号を入力してください。")
        XCTAssertEqual(SettingsWords.foundTelevisionsFooter(registers: false),
                       "使えるテレビは 1 台です。別のテレビを使うときは、設定の「テレビ」でいまのテレビを外してから、"
                       + "もう一度探してください。")
    }

    /// The footers in the demo and out of it, and the guide's where there is a source to choose, which says nothing
    /// of the stations' logos and has nothing of what the helper's last fetch said: that is a line of the screen's
    /// own, in red and as a body says it (`AppModel.helperProblem`).
    func testTheFootersFollowTheDemoAndTheHelper() {
        XCTAssertEqual(SettingsWords.searchFooter(inDemo: true),
                       "サンプルデータの表示中は、架空のレコーダーとテレビだけが見つかります。"
                       + "実際の機器を探すときは、先にサンプルを終了してください。")
        XCTAssertEqual(SettingsWords.searchFooter(inDemo: false),
                       "同じ Wi-Fi 上のレコーダーとテレビを探します。レコーダーを選ぶとそのレコーダーに切り替わり、"
                       + "テレビを選ぶとテレビの登録を始めます。")
        XCTAssertEqual(SettingsWords.demoFooter(inDemo: true),
                       "架空のレコーダーを表示しています。終了すると、サンプルの番組表と、追加した架空のテレビは削除され、"
                       + "元のレコーダーとテレビの設定に戻ります。レコーダーを選んで接続したときも、サンプルは終了します。")
        XCTAssertEqual(SettingsWords.demoFooter(inDemo: false),
                       "レコーダーが無いときに、架空の番組表と録画一覧でアプリの動きを確かめられます。")
        XCTAssertEqual(SettingsWords.guideSourceFooter,
                       "テレビの番組表は、番組名などが半角で表示されます。予約と局の設定は、どちらを選んでも変わりません。")
        XCTAssertEqual(TVHelperError.transport("").explanation.asABody, "テレビのヘルパーが応答しません。")
    }

    /// The counts and the search's progress group their digits as the screen's text grouped them: with four figures
    /// and five, where the reader's locale puts a separator.
    func testTheCountsAndTheProgressGroupTheirDigitsAsTheScreenDid() {
        XCTAssertEqual(SettingsWords.countsLine(channels: 1234, programs: 12345),
                       "\(asATextShowsIt(1234)) 局 · \(asATextShowsIt(12345)) 番組")
        XCTAssertEqual(SettingsWords.countsLine(nil), "0 局 · 0 番組")
        XCTAssertEqual(SettingsWords.searchingLine((done: 12, total: 1024)), "検索中 12 / \(asATextShowsIt(1024))")
        if let separator = Locale.current.groupingSeparator, !separator.isEmpty, asATextShowsIt(1234) != "1234" {
            XCTAssertEqual(SettingsWords.countsLine(channels: 1234, programs: 12345),
                           "1\(separator)234 局 · 12\(separator)345 番組")
        }
    }

    /// The demo's counts, as the cache counts them for a type, and its last refresh, said as the settings say a time
    /// stored; none before there is a guide.
    func testTheGuidesCountsAndLastRefreshAreTheCaches() async throws {
        let bench = try aBench()
        let model = bench.modelWithNoRecorder()
        await model.start()
        XCTAssertNil(model.lastGuideRefresh, "a refresh was said with no guide kept")

        await model.enterDemo()
        let counts = try XCTUnwrap(model.counts["td"], "the demo's guide was not counted")
        XCTAssertEqual(SettingsWords.countsLine(counts), SettingsWords.countsLine(channels: counts.channels,
                                                                                    programs: counts.programs))
        let refreshed = try XCTUnwrap(counts.refreshed, "the demo's guide has no refresh noted")
        XCTAssertEqual(model.lastGuideRefresh, Format.when(stored: refreshed))
    }

    /// レコーダーとテレビを探す is held while a scan holds it and while the recorder works; the progress is not said
    /// while the scan waits for the local network permission.
    func testTheSearchIsHeldWhileItRunsOrTheRecorderWorks() async throws {
        let bench = try aBench()
        let model = bench.modelWithNoRecorder()
        await model.start()
        XCTAssertFalse(model.holdsTheSearchButton)
        XCTAssertNil(model.searchProgress)

        model.scanning = (done: 3, total: 253)
        XCTAssertTrue(model.holdsTheSearchButton)
        XCTAssertEqual(model.searchProgress?.done, 3)
        XCTAssertEqual(model.searchProgress?.total, 253)

        model.scanBlocked = true
        XCTAssertFalse(model.holdsTheSearchButton, "the button was held behind the permission's notice")
        XCTAssertNil(model.searchProgress, "the progress was said behind the permission's notice")

        model.scanning = nil
        model.scanBlocked = false
        let working = model.activities.begin("レコーダーに接続中…")
        XCTAssertTrue(model.holdsTheSearchButton, "the button was not held while the recorder worked")
        model.activities.end(working)
        XCTAssertFalse(model.holdsTheSearchButton)
    }

    /// Where the guide comes from is said alone, テレビ, where a helper gives it and there is no recorder to choose,
    /// none being saved or the one saved giving no guide; nothing where there is a choice, whichever of the two is
    /// chosen, and nothing where the recorder gives it with no helper.
    func testWhereTheGuideComesFromIsSaidAloneOnlyForTheTelevision() async throws {
        let bench = try aBench()
        let alone = bench.modelWithNoRecorder()
        XCTAssertNil(alone.guideSourceAlone, "a source was said with no helper")
        alone.tvHelper = registeredHelper()
        XCTAssertEqual(alone.guideSourceAlone, "テレビ")

        let other = try aBench()
        let both = other.model(recorders: [:])
        XCTAssertNil(both.guideSourceAlone, "the recorder's guide was said to be the only one")
        both.tvHelper = registeredHelper()
        XCTAssertTrue(both.guideSourceIsChoosable)
        XCTAssertNil(both.guideSourceAlone, "a source was said alone where there is a choice")
        both.defaults.set(GuideSourceChoice.tv.rawValue, forKey: DefaultsKey.guideSource)
        XCTAssertEqual(both.guideSource, .tv)
        XCTAssertNil(both.guideSourceAlone, "the television chosen was said alone where there is a choice")

        let third = try aBench()
        third.defaults.set(false, forKey: DefaultsKey.recorderGivesAGuide)
        let noGuide = third.model(recorders: [:])
        XCTAssertNil(noGuide.guideSourceAlone, "a source was said with no helper")
        noGuide.tvHelper = registeredHelper()
        XCTAssertFalse(noGuide.guideSourceIsChoosable, "a choice was offered beside a recorder that gives no guide")
        XCTAssertEqual(noGuide.guideSourceAlone, "テレビ")
    }

    /// A helper the app is registered with, at an address reserved for documentation, which nothing here asks.
    private func registeredHelper() -> TVHelperGuide {
        TVHelperGuide(client: TVHelperClient(host: Bench.tvHost, transport: SilentRecorder(),
                                             tokens: MemoryTVHelperToken("token")))
    }
}
