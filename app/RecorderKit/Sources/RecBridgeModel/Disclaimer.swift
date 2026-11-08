import Foundation

/// What the reader should know before this app writes to their recorder: above all that a recording deleted here is
/// gone from the recorder, which has no undo. The screens lay it out.
///
/// The same words are in `docs/disclaimer.md`, which is where the store links to. Change both.
public enum Disclaimer {
    public static let title = "ご利用上の注意"

    public static let opening = "RecBridge は、ソニー製ブルーレイディスクレコーダー（BDZ シリーズ）を家庭内ネットワーク"
        + "越しに操作する、個人が作った非公式のアプリです。ソニーグループとは関係がなく、"
        + "同社の公式アプリではありません。"

    public struct Section: Sendable {
        public let heading: String
        public let body: String
    }

    public static let sections = [
        Section(heading: "操作はレコーダーやテレビの本体に届きます",
                body: "録画予約、予約の変更と削除、録画の削除と保護、おまかせ・まる録の条件の追加と削除は、"
                    + "いずれもレコーダー本体に対する操作です。テレビへの録画予約、その予約の変更と削除、テレビの"
                    + "録画の削除と保護も、テレビ本体に対する操作です。アプリの中だけの話ではありません。\n\n"
                    + "とくに録画の削除は取り消せません。レコーダーの録画もテレビの録画も、削除すると元に戻せません。"
                    + "まとめての削除や重複の削除では、消す対象をよく確かめてから実行してください。"),
        Section(heading: "表示は「その時点で読み取った内容」です",
                body: "番組表はこの端末に保存したものを表示しています。予約一覧や録画一覧も、最後にレコーダーやテレビから"
                    + "読み取った内容です。レコーダーやテレビの本体、ほかのアプリで操作されたことは、次に読み直すまで"
                    + "反映されません。\n\n"
                    + "予約が入ったか、録画が成功したかは、最終的にレコーダーやテレビの本体でご確認ください。"),
        Section(heading: "動作を保証するものではありません",
                body: "BDZ-FBT4100 で開発・確認しています。同じ系列の機種でも、機種や本体ソフトウェアの版に"
                    + "よっては、一部またはすべての機能が動作しないことがあります。\n\n"
                    + "録画の失敗、録画内容の消失、予約の取りこぼしなど、本アプリの利用によって生じた損害に"
                    + "ついて、作者は責任を負いかねます。ご自身の環境でご判断のうえ、ご利用ください。"),
        Section(heading: "ソースコード",
                body: "本アプリのソースコードは公開しており、MIT ライセンス（無保証）で提供しています。"),
    ]

    /// Where the source is, after the last section: the link's words and its address.
    public static let sourceLink = "github.com/hiroaki0923/bdzbridge"
    public static let sourceURL = "https://github.com/hiroaki0923/bdzbridge"
}
