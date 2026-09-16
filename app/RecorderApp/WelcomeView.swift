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
                            Button { Task { await model.use(recorder) } } label: { FoundRecorderRow(recorder: recorder) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    if typing {
                        TextField("192.168.1.10", text: $typedHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                        Button("このアドレスに接続") {
                            model.host = typedHost.trimmingCharacters(in: .whitespaces)
                            Task { await model.connect() }
                        }
                        .disabled(typedHost.trimmingCharacters(in: .whitespaces).isEmpty || model.busy != nil)
                    } else {
                        Button("IP アドレスを直接入力") { typing = true }
                    }
                } footer: {
                    Text("見つからない場合は、レコーダーの設定画面で確認できる IP アドレスを直接入力できます。")
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
                ToolbarItem(placement: .cancellationAction) { Button("あとで設定") { dismiss() } }
            }
            // the recorder answering is the end of the tutorial; nothing to read after that
            .onChange(of: model.connected) { if model.connected { dismiss() } }
        }
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
