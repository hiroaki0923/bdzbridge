import RecorderKit
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var typedHost = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("レコーダー") {
                    TextField("192.168.0.63", text: $typedHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    Button("接続する") {
                        model.host = typedHost.trimmingCharacters(in: .whitespaces)
                        Task { await model.connect() }
                    }
                    .disabled(typedHost.isEmpty || model.busy != nil)

                    Button("LAN から探す") {
                        Task { await model.scanForRecorders() }
                    }
                    .disabled(model.scanning != nil || model.busy != nil)

                    // For the state below network standby, where the recorder answers nothing at all. Its
                    // own MAC, read while it was awake, is the only address a magic packet can go to.
                    if model.canWake {
                        Button("レコーダーを起こす") { Task { await model.wake() } }
                            .disabled(model.busy != nil)
                    }

                    if let scanning = model.scanning {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("探しています \(scanning.done) / \(scanning.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(scanning.done),
                                         total: Double(max(1, scanning.total)))
                        }
                    }
                }

                if !model.found.isEmpty {
                    Section("見つかったレコーダー") {
                        ForEach(model.found, id: \.host) { recorder in
                            Button {
                                typedHost = recorder.host
                                Task { await model.use(recorder) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recorder.product).font(.subheadline)
                                    Text("\(recorder.host) · \(recorder.friendlyName)"
                                         + (recorder.epgCapable ? " · 番組表あり" : " · 番組表なし"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let info = model.info {
                    Section("つながっているレコーダー") {
                        LabeledContent("機種", value: info.product)
                        LabeledContent("名前", value: info.friendlyName)
                        LabeledContent("ファームウェア", value: model.firmware)
                        LabeledContent("番組表", value: info.epgCapable ? "対応" : "非対応")
                        if let storage = model.storage {
                            LabeledContent("残り容量",
                                           value: "\(Format.gigabytes(storage.free)) / \(Format.gigabytes(storage.total))")
                        }
                    }
                }

                Section("端末内の番組表") {
                    ForEach(["td", "bs", "cs", "bs4k"], id: \.self) { broadcasting in
                        let counts = model.counts[broadcasting]
                        LabeledContent(Codes.broadcastingLabel[broadcasting] ?? broadcasting) {
                            Text("\(counts?.channels ?? 0) 局 · \(counts?.programs ?? 0) 番組")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let refreshed = model.counts["td"]?.refreshed {
                        LabeledContent("最後の取得", value: refreshed)
                    }
                    if let overnight = UserDefaults.standard.string(forKey: BackgroundWork.lastRefreshKey) {
                        LabeledContent("最後の自動取得", value: overnight)
                    }
                    Button("番組表を取得する") {
                        Task { await model.refreshGuide() }
                    }
                    .disabled(!model.connected || model.busy != nil)
                }

                if let busy = model.busy {
                    Section { HStack { ProgressView().controlSize(.small); Text(busy) } }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("設定")
            .onAppear { if typedHost.isEmpty { typedHost = model.host } }
        }
    }
}
