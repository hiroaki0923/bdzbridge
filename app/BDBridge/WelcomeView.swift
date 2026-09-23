import RecorderKit
import SwiftUI

/// The first screen, shown until a recorder has been chosen, and reachable again from the settings. Its one
/// job is to walk the reader through the only step the app cannot do for them: the recorder has to be awake
/// for the first meeting, because the address that wakes it later comes from the recorder itself.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typing = false
    @State private var typedHost = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BD Bridge").font(.largeTitle.bold())
                        Text("レコーダーの番組表を iPhone で見て、録画予約や録画した番組の整理ができます。"
                             + "まず、お使いのレコーダーを登録しましょう。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                Section("セットアップ") {
                    step(1, "レコーダーの電源を入れる",
                         "電源が入っている必要があるのは最初の登録のときだけです。次回からはアプリがレコーダーを自動で起動します。")
                    step(2, "iPhone をレコーダーと同じ Wi-Fi につなぐ",
                         "同じネットワーク上にあるレコーダーだけが見つかります。")
                    step(3, "「レコーダーを探す」をタップする",
                         "「ローカルネットワークへのアクセス」の確認が表示されたら「許可」を選んでください。")
                }
                Section {
                    Button {
                        Task { await model.scanForRecorders() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.scanning != nil { ProgressView().controlSize(.small).padding(.trailing, 6) }
                            Text("レコーダーを探す").bold()
                            Spacer()
                        }
                    }
                    .disabled(model.scanning != nil || model.busy != nil)
                    if let scanning = model.scanning {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(scanning.done), total: Double(max(1, scanning.total)))
                            Text("検索中 \(scanning.done) / \(scanning.total)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.found.isEmpty {
                    Section("見つかったレコーダー") {
                        ForEach(model.found, id: \.host) { recorder in
                            Button { Task { await take(recorder) } } label: { FoundRecorderRow(recorder: recorder) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    if typing {
                        let typed = RecorderAddress.tidy(typedHost)
                        TextField("192.168.1.10", text: $typedHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                        AddressNote(typed: typed)
                        Button("このアドレスに接続") {
                            // the field shows what is saved, so that what was taken off can be seen to be gone
                            typedHost = typed.host
                            model.host = typed.host
                            Task {
                                await model.connect()
                                if model.connected { dismiss() }
                            }
                        }
                        .disabled(!RecorderAddress.isUsable(typed.host) || model.busy != nil)
                    } else {
                        Button("IP アドレスを直接入力") { typing = true }
                    }
                } footer: {
                    Text("見つからない場合は、レコーダーの設定画面で確認できる IP アドレスを直接入力できます。")
                }
                Section {
                    Button("サンプルデータで試す") {
                        Task {
                            await model.enterDemo()
                            dismiss()
                        }
                    }
                    .disabled(model.busy != nil)
                } footer: {
                    Text("レコーダーが無くても、架空の番組表と録画一覧でアプリの動きを確かめられます。"
                         + "実在の放送局・番組ではありません。いつでも設定から終了できます。")
                }
                if let busy = model.busy {
                    Section { HStack { ProgressView().controlSize(.small); Text(busy) } }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // opened again from the settings there is nothing to put off, only a screen to leave
                    Button(model.host.isEmpty ? "あとで設定" : "閉じる") { dismiss() }
                }
            }
        }
    }

    /// Choosing a recorder ends the tutorial as soon as it answers. Watching `connected` flip would miss the
    /// case where the screen was opened from the settings with a recorder already on the line, so the
    /// leaving is tied to the tap that did it.
    private func take(_ recorder: RecorderDescription) async {
        await model.use(recorder)
        if model.connected { dismiss() }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What the address field says back about what was typed, under the field in both the tutorial and the
/// settings. Tidying takes off only what is plainly not part of an address and does it without a word; a
/// port is different, because somebody typed it on purpose, so it is said out loud that it will not be used.
/// Nothing is said while the field is empty or the address is fine.
struct AddressNote: View {
    let typed: RecorderAddress.Typed

    var body: some View {
        if typed.host.isEmpty {
            EmptyView()
        } else if !RecorderAddress.isUsable(typed.host) {
            Text("アドレスの形式が正しくありません。192.168.1.10 のような IP アドレスを入力してください。")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let port = typed.port {
            Text("ポート番号は不要です。「:\(port)」は使わずに \(typed.host) に接続します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One recorder the scan turned up, as both the tutorial and the settings list it.
struct FoundRecorderRow: View {
    let recorder: RecorderDescription

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recorder.product).font(.subheadline)
            Text("\(recorder.host) · \(recorder.friendlyName)" + (recorder.epgCapable ? " · 番組表あり" : " · 番組表なし"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .rowHitArea()
    }
}
