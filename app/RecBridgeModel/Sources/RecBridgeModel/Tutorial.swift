import Foundation

/// The words of the tutorial that name no device and no system dialog, for the screens to lay out beside it: the steps
/// the reader goes through, the two footers, and the settings' row that opens it again. What names the device the app
/// runs on, the introduction and step 2's title, and what describes the system's own question, step 3's detail, are
/// each platform's.
public enum Tutorial {
    public static let heading = "セットアップ"

    /// The settings' row that opens the tutorial again.
    public static let reviewRow = "セットアップ手順を見る"

    public static let step1Title = "レコーダーとテレビの電源を入れる"
    public static let step1Detail = "レコーダーの電源が入っている必要があるのは最初に追加するときだけです。"
        + "次回からはアプリがレコーダーを自動で起動します。"
        + "レコーダーは、電源を入れた直後は見つからないことがあるので、少し待ってから探してください。"
        + "テレビは、登録のときに画面に番号が出るので、放送を映しておいてください。"

    public static let step2Detail = "同じネットワーク上にある機器だけが見つかります。"

    public static let step3Title = "「レコーダーとテレビを探す」をタップする"

    public static let step4Title = "見つかったレコーダーやテレビをタップする"
    public static let step4Detail = "レコーダーはそのまま接続します。テレビは登録を始めるので、テレビの画面に出る 4 桁の番号を"
        + "入力してください。"

    /// Under the address field.
    public static let addressFooter = "見つからない場合は、レコーダーの設定画面で確認できる IP アドレスを直接入力できます。"
        + "テレビは、あとで設定の「テレビ」からアドレスを入力して追加できます。"

    /// Under the demo's button.
    public static let demoFooter = "レコーダーが無くても、架空の番組表と録画一覧でアプリの動きを確かめられます。"
        + "実在の放送局・番組ではありません。いつでも設定から終了できます。"
}
