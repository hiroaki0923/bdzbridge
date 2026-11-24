import Foundation
import RecorderKit

/// The settings' words, for the screen to lay out: its title, the mode a new reservation starts at, the search, the
/// stations shown, the guide kept on the phone, the demo and the app. The recorder's part says its own
/// (`RecorderSettingsState`), the television's part its own (`TVSettingsState`), and 番組表を更新 is the press's
/// (`AppModel.refreshGuideLabel`). The tutorial says the search's button, its progress, the causes it lists, the
/// recorders and the televisions it found and the demo's button in the same words.
public enum SettingsWords {
    public static let title = "設定"

    /// 既定の録画モード, and what is said under it.
    public static let defaultQualityLabel = "既定の録画モード"
    public static let defaultQualityFooter = "録画予約とおまかせ・まる録の条件を追加するときに、最初に選ばれている録画モードです。"
        + "予約するときに変えても、ここは変わりません。"

    // MARK: - the search

    public static let searchLabel = "レコーダーとテレビを探す"

    /// How far the search has got, under its button, with the reader's grouping of digits as a screen's own text
    /// writes a number put into it.
    public static func searchingLine(_ progress: (done: Int, total: Int)) -> String {
        "検索中 \(Format.count(progress.done)) / \(Format.count(progress.total))"
    }

    /// What is said under the search: in the demo, that it finds the invented recorder and television alone, and
    /// nothing real.
    public static func searchFooter(inDemo: Bool) -> String {
        inDemo
            ? "サンプルデータの表示中は、架空のレコーダーとテレビだけが見つかります。"
                + "実際の機器を探すときは、先にサンプルを終了してください。"
            : "同じ Wi-Fi 上のレコーダーとテレビを探します。レコーダーを選ぶとそのレコーダーに切り替わり、"
                + "テレビを選ぶとテレビの登録を始めます。"
    }

    // MARK: - what the search found

    /// The headings of the recorders and of the televisions found, and what a found device's row says at its end when
    /// it is the one in use, a recorder's and a television's alike.
    public static let foundRecordersHeading = "見つかったレコーダー"
    public static let foundTelevisionsHeading = "見つかったテレビ"
    public static let inUseLabel = "使用中"

    /// What a found television's row says at its end while a tap registers it.
    public static let registerFoundLabel = "登録する"

    /// What a found recorder's row says at its end while a tap connects to it.
    public static let connectFoundLabel = "接続する"

    /// The heading over the likely causes a search that found nothing, or failed, lists.
    public static let causesHeading = "考えられる原因"

    /// A found recorder's second line: its address and the name it gave, and whether it serves a guide.
    public static func foundRecorderDetails(_ found: RecorderDescription) -> String {
        "\(found.host) · \(found.friendlyName)" + (found.epgCapable ? " · 番組表あり" : " · 番組表なし")
    }

    /// A found television's name: the model it gave, テレビ where it gave none.
    public static func foundTelevisionName(_ model: String) -> String { model.isEmpty ? "テレビ" : model }

    /// What is said under the televisions found: while a tap registers one, what the tap does; with one added, why
    /// the rows are only listed.
    public static func foundTelevisionsFooter(registers: Bool) -> String {
        registers
            ? "タップすると登録を始めます。テレビの画面に 4 桁の番号が出るので、その番号を入力してください。"
            : "使えるテレビは 1 台です。別のテレビを使うときは、設定の「テレビ」でいまのテレビを外してから、"
                + "もう一度探してください。"
    }

    // MARK: - the stations

    /// The way to which stations the guide shows and in what order, and what is said under it.
    public static let channelsLabel = "チャンネルの表示と並び順"
    public static let channelsFooter = "番組表に出す局と、その並び順を放送ごとに選べます。この端末の番組表だけが変わり、"
        + "レコーダーの録画には影響しません。"

    // MARK: - the guide kept

    public static let keptGuideHeading = "保存されている番組表"
    public static let guideSourceLabel = "番組表の取得元"
    public static let lastRefreshLabel = "最終更新"
    public static let lastOvernightRefreshLabel = "最終自動更新"

    /// Each device the guide can be fetched from, as 番組表の取得元 names it.
    public static func guideSourceName(_ choice: GuideSourceChoice) -> String {
        switch choice {
        case .recorder: "レコーダー"
        case .tv: "テレビ"
        }
    }

    /// A broadcasting type's stations and programmes kept, with the reader's grouping of digits as a screen's own text
    /// writes a number put into it.
    static func countsLine(channels: Int, programs: Int) -> String {
        "\(Format.count(channels)) 局 · \(Format.count(programs)) 番組"
    }

    /// The same of what the cache counts for a type: none of either where it counts nothing.
    public static func countsLine(_ counts: GuideCounts?) -> String {
        countsLine(channels: counts?.channels ?? 0, programs: counts?.programs ?? 0)
    }

    /// What is said under the guide where there is a source to choose: what the television's guide looks like and
    /// what the choice leaves alone. The stations' logos are not among that: each type's are those of the device
    /// that last gave its guide. What the helper's last fetch said (`AppModel.helperProblem`) is no part of it:
    /// a line of its own under it, in red and as a body says it, as what any device said is shown in the settings,
    /// with a source to choose or none.
    public static let guideSourceFooter = "テレビの番組表は、番組名などが半角で表示されます。"
        + "予約と局の設定は、どちらを選んでも変わりません。"

    // MARK: - the demo

    public static let enterDemoLabel = "サンプルデータで試す"
    public static let leaveDemoLabel = "サンプルデータを終了する"

    /// What is said under the demo's button: in the demo, what ending it takes away and puts back.
    public static func demoFooter(inDemo: Bool) -> String {
        inDemo
            ? "架空のレコーダーを表示しています。終了すると、サンプルの番組表と、追加した架空のテレビは削除され、"
                + "元のレコーダーとテレビの設定に戻ります。レコーダーを選んで接続したときも、サンプルは終了します。"
            : "レコーダーが無いときに、架空の番組表と録画一覧でアプリの動きを確かめられます。"
    }

    // MARK: - the app

    /// The app's section, and the label of its version. The way to ご利用上の注意 is the disclaimer's own title
    /// (`Disclaimer.title`).
    public static let appHeading = "このアプリ"
    public static let versionLabel = "バージョン"

    /// The version as the settings say it: what the store calls it, and the build behind it, `0.2 (12)`.
    public static func version(release: String, build: String) -> String { "\(release) (\(build))" }
}
