import RecorderKit
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var typedHost = ""
    @State private var typedMac = ""
    @State private var showingGuide = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.10", text: $typedHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    // Connecting happens by itself at launch and after a scan, so a button is only for an
                    // address typed by hand, or for trying the saved one again after it failed.
                    if typedHost.trimmingCharacters(in: .whitespaces) != model.host {
                        Button("このアドレスに接続") {
                            model.host = typedHost.trimmingCharacters(in: .whitespaces)
                            Task { await model.connect() }
                        }
                        .disabled(typedHost.trimmingCharacters(in: .whitespaces).isEmpty || model.busy != nil)
                    } else if !model.connected, !model.host.isEmpty {
                        Button("再接続") { Task { await model.connect() } }
                            .disabled(model.busy != nil)
                    }

                    Button("レコーダーを探す") {
                        Task { await model.scanForRecorders() }
                    }
                    .disabled(model.scanning != nil || model.busy != nil)

                    LabeledContent("MAC アドレス") {
                        TextField("接続時に自動で記録", text: $typedMac)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                    }
                    // Kept as the reader types rather than on the return key, because the next thing they do
                    // is tap the connect button, and a MAC that was only half committed cannot wake anything.
                    .onChange(of: typedMac) {
                        let typed = typedMac.trimmingCharacters(in: .whitespaces)
                        if typed.isEmpty { model.forgetMac() } else { model.remember(mac: typed) }
                    }
                    .onChange(of: model.mac, initial: true) {
                        if let mac = model.mac, WakeOnLan.normalise(typedMac) != mac { typedMac = mac }
                    }


                    if let scanning = model.scanning {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("検索中 \(scanning.done) / \(scanning.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(scanning.done),
                                         total: Double(max(1, scanning.total)))
                        }
                    }
                } header: {
                    Text("レコーダー")
                } footer: {
                    Text("MAC アドレスは、スリープ中のレコーダーを起動するために使います。接続時に自動で記録されるので、通常は入力不要です。")
                }

                if !model.found.isEmpty {
                    Section("見つかったレコーダー") {
                        ForEach(model.found, id: \.host) { recorder in
                            Button {
                                typedHost = recorder.host
                                Task { await model.use(recorder) }
                            } label: {
                                FoundRecorderRow(recorder: recorder)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let info = model.info {
                    Section("接続中のレコーダー") {
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

                Section("保存されている番組表") {
                    ForEach(["td", "bs", "cs", "bs4k"], id: \.self) { broadcasting in
                        let counts = model.counts[broadcasting]
                        LabeledContent(Codes.broadcastingLabel[broadcasting] ?? broadcasting) {
                            Text("\(counts?.channels ?? 0) 局 · \(counts?.programs ?? 0) 番組")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let refreshed = model.counts["td"]?.refreshed {
                        LabeledContent("最終更新", value: refreshed)
                    }
                    if let overnight = UserDefaults.standard.string(forKey: BackgroundWork.lastRefreshKey) {
                        LabeledContent("最終自動更新", value: overnight)
                    }
                    Button("番組表を更新") {
                        Task { await model.refreshGuide() }
                    }
                    .disabled(!model.connected || model.busy != nil)
                }

                Section {
                    Button("セットアップ手順を見る") { showingGuide = true }
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
            .sheet(isPresented: $showingGuide) { WelcomeView() }
        }
    }
}
