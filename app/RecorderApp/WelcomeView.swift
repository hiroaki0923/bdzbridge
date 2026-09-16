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
                        Text("レコーダーの番組表を iPhone に持ち、予約と録画をここから扱います。"
                             + "はじめにレコーダーを見つけます。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                Section("はじめかた") {
                    step(1, "レコーダーの電源を入れる",
                         "リモコンで入れてください。必要なのは初回だけで、以後はアプリが起こします。")
                    step(2, "iPhone を同じ Wi-Fi につなぐ",
                         "レコーダーと同じネットワークにいるときだけ見つけられます。")
                    step(3, "「LAN から探す」を押す",
                         "初回は iOS がローカルネットワークへのアクセスを尋ねるので、許可してください。")
                }
                Section {
                    Button {
                        Task { await model.scanForRecorders() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.scanning != nil { ProgressView().controlSize(.small).padding(.trailing, 6) }
                            Text("LAN から探す").bold()
                            Spacer()
                        }
                    }
                    .disabled(model.scanning != nil || model.busy != nil)
                    if let scanning = model.scanning {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(scanning.done), total: Double(max(1, scanning.total)))
                            Text("探しています \(scanning.done) / \(scanning.total)")
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
                        Button("このアドレスにつなぐ") {
                            model.host = typedHost.trimmingCharacters(in: .whitespaces)
                            Task { await model.connect() }
                        }
                        .disabled(typedHost.trimmingCharacters(in: .whitespaces).isEmpty || model.busy != nil)
                    } else {
                        Button("アドレスを直接入れる") { typing = true }
                    }
                } footer: {
                    Text("探しても見つからないときは、レコーダーの設定画面に出るアドレスを入れられます。")
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
                ToolbarItem(placement: .cancellationAction) { Button("あとで") { dismiss() } }
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
