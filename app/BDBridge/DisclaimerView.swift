import SwiftUI

/// What the reader should know before this app writes to their recorder.
///
/// The one that matters is the deletion: a recording deleted here is gone from the recorder, and the
/// recorder has no undo. The rest is the honest surroundings -- this is not Sony's app, the lists are what
/// was read a moment ago rather than what is true now, and one model is all this has been tried on.
///
/// The same words are in `docs/disclaimer.md`, which is where the store links to. Change both.
struct DisclaimerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("BD Bridge は、ソニー製ブルーレイディスクレコーダー（BDZ シリーズ）を家庭内ネットワーク"
                         + "越しに操作する、個人が作った非公式のアプリです。ソニーグループとは関係がなく、"
                         + "同社の公式アプリではありません。")

                    section("操作はレコーダー本体に届きます",
                            "録画予約、予約の変更と削除、録画の削除と保護、おまかせ・まる録の条件の追加と削除は、"
                            + "いずれもレコーダー本体に対する操作です。アプリの中だけの話ではありません。\n\n"
                            + "とくに録画の削除は取り消せません。レコーダーにごみ箱のような仕組みはなく、"
                            + "削除した録画は戻りません。まとめての削除や重複の削除では、消す対象をよく確かめてから"
                            + "実行してください。")

                    section("表示は「その時点で読み取った内容」です",
                            "番組表は端末に保存したものを表示しています。予約一覧や録画一覧も、最後にレコーダーから"
                            + "読み取った内容です。レコーダー本体やほかのアプリで操作されたことは、次に読み直すまで"
                            + "反映されません。\n\n"
                            + "予約が入ったか、録画が成功したかは、最終的にレコーダー本体でご確認ください。")

                    section("動作を保証するものではありません",
                            "BDZ-FBT4100 で開発・確認しています。同じ系列の機種でも、機種や本体ソフトウェアの版に"
                            + "よっては、一部またはすべての機能が動作しないことがあります。\n\n"
                            + "録画の失敗、録画内容の消失、予約の取りこぼしなど、本アプリの利用によって生じた損害に"
                            + "ついて、作者は責任を負いかねます。ご自身の環境でご判断のうえ、ご利用ください。")

                    section("ソースコード",
                            "本アプリのソースコードは公開しており、MIT ライセンス（無保証）で提供しています。")
                    Link("github.com/hiroaki0923/bdzbridge",
                         destination: URL(string: "https://github.com/hiroaki0923/bdzbridge")!)
                        .font(.callout)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("ご利用上の注意")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton() }
        }
    }

    private func section(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}
