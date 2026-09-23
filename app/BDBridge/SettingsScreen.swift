import RecorderKit
import SwiftUI
import UserNotifications

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var typedHost = ""
    @State private var typedMac = ""
    @State private var showingGuide = false
    @State private var showingDisclaimer = false
    @AppStorage(DefaultsKey.defaultQuality) private var defaultQuality = DefaultQuality.fallback

    /// The address field, tidied: what connecting would use.
    private var tidied: RecorderAddress.Typed { RecorderAddress.tidy(typedHost) }

    /// What the store calls the version, and the build behind it: `0.2 (12)`. The build number comes from
    /// Xcode Cloud, so it is the only thing that tells two TestFlight builds of one version apart.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(release) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("IP アドレス") {
                        TextField("192.168.1.10", text: $typedHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                    }
                    AddressNote(typed: tidied)
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
                    // Following the model when it forgets the MAC as well: ending the demo can leave none, and
                    // the field went on showing the demo's, which is nobody's. A half-typed MAC is left alone,
                    // since it is no MAC and so already agrees with none.
                    .onChange(of: model.mac, initial: true) {
                        if WakeOnLan.normalise(typedMac) != model.mac { typedMac = model.mac ?? "" }
                    }
                    // Connecting happens by itself at launch and after a scan, so a button is only for an
                    // address typed by hand, or for trying the saved one again after it failed. The field is
                    // compared both as typed and tidied, because the saved address can be untidy itself: an
                    // older version saved `192.168.1.10:64220` just as it was typed, and 再接続 would only
                    // try that again.
                    if tidied.host != model.host || typedHost != model.host {
                        Button("このアドレスに接続") {
                            // the field shows what is saved, so that what was taken off can be seen to be gone
                            let host = tidied.host
                            typedHost = host
                            Task { await model.adopt(host: host) }
                        }
                        .disabled(!RecorderAddress.isUsable(tidied.host) || !model.canChangeRecorder)
                    } else if !model.connected, !model.host.isEmpty {
                        Button("再接続") { Task { await model.connect() } }
                            .disabled(model.busy != nil || model.jobRunning)
                    }
                } header: {
                    Text("レコーダー")
                } footer: {
                    Text("MAC アドレスは、スリープ中のレコーダーを起動するために使います。接続時に自動で記録されるので、通常は入力不要です。")
                }

                Section {
                    // Not while a connect, a load or a job is under way: see `canChangeRecorder`.
                    if model.demo {
                        Button("サンプルデータを終了する", role: .destructive) {
                            Task { await model.leaveDemo() }
                        }
                        .disabled(!model.canChangeRecorder)
                    } else {
                        Button("サンプルデータで試す") { Task { await model.enterDemo() } }
                            .disabled(!model.canChangeRecorder)
                    }
                } footer: {
                    Text(model.demo
                         ? "架空のレコーダーを表示しています。終了すると、サンプルの番組表は削除され、"
                           + "元のレコーダーの設定に戻ります。レコーダーを選んで接続したときも、サンプルは終了します。"
                         : "レコーダーが無いときに、架空の番組表と録画一覧でアプリの動きを確かめられます。")
                }

                Section {
                    Button("レコーダーを探す") {
                        model.scanForRecorders()
                    }
                    .disabled(model.scanning != nil || model.busy != nil)
                    // This screen has no activity strip, so a connect held up by the permission is said here
                    // as well as a scan.
                    if model.lanBlocked {
                        LocalNetworkNotice()
                        OpenSettingsButton()
                    }
                    if let scanning = model.scanning, !model.scanBlocked {
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
                    if let outcome = model.scanOutcome {
                        ScanOutcomeText(outcome: outcome)
                    }
                } footer: {
                    Text("同じ Wi-Fi 上のレコーダーを探します。見つかったものを選ぶと、そのレコーダーに切り替わります。")
                }

                if !model.found.isEmpty {
                    Section("見つかったレコーダー") {
                        ForEach(model.found, id: \.host) { recorder in
                            Button {
                                typedHost = recorder.host
                                Task { await model.adopt(host: recorder.host) }
                            } label: {
                                FoundRecorderRow(recorder: recorder, inUse: model.inUse(recorder))
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canChangeRecorder)
                        }
                    }
                }

                if let info = model.info {
                    Section("接続中のレコーダー") {
                        LabeledContent("機種", value: info.product)
                        LabeledContent("名前", value: info.friendlyName)
                        // empty when the recorder would not say, which another model may not
                        if !model.firmware.isEmpty {
                            LabeledContent("ファームウェア", value: model.firmware)
                        }
                        LabeledContent("番組表", value: info.epgCapable ? "対応" : "非対応")
                        if let storage = model.storage {
                            LabeledContent("残り容量",
                                           value: "\(Format.gigabytes(storage.free)) / \(Format.gigabytes(storage.total))")
                        }
                    }
                }

                Section {
                    NavigationLink("チャンネルの表示と並び順") {
                        ChannelsScreen(broadcasting: model.broadcasting)
                    }
                } footer: {
                    Text("番組表に出す局と、その並び順を放送ごとに選べます。この iPhone の番組表だけが変わり、"
                         + "レコーダーの録画には影響しません。")
                }

                Section {
                    Picker("既定の録画モード", selection: $defaultQuality) {
                        ForEach(Codes.qualityOrder, id: \.self) { code in
                            Text(Codes.qualityLabel[code] ?? code).tag(code)
                        }
                    }
                } footer: {
                    Text("録画予約とおまかせ・まる録の条件を追加するときに、最初に選ばれている録画モードです。"
                         + "予約するときに変えても、ここは変わりません。")
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
                        LabeledContent("最終更新", value: Self.readable(refreshed))
                    }
                    if let overnight = UserDefaults.standard.string(forKey: DefaultsKey.lastBackgroundRefresh) {
                        LabeledContent("最終自動更新", value: Self.readable(overnight))
                    }
                    Button("番組表を更新") {
                        Task { await model.refreshGuide() }
                    }
                    .disabled(!model.connected || model.busy != nil || model.info?.epgCapable == false)
                }

                notificationsSection

                Section {
                    Button("セットアップ手順を見る") { showingGuide = true }
                }

                Section("このアプリ") {
                    // Before the version, because it is the one thing in this section worth reading: what
                    // this app writes to the recorder, it writes for real.
                    Button("ご利用上の注意") { showingDisclaimer = true }
                    // Which build is on the phone is the first question behind "is that the one with the
                    // fix?", and TestFlight hands out several builds of one version. Selectable, so it can
                    // be copied into a report rather than read off a screen.
                    LabeledContent("バージョン", value: Self.version)
                        .textSelection(.enabled)
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
            // The app moves the address by itself when it finds the recorder somewhere else, and a field still
            // showing the old one would offer このアドレスに接続 to take it back there.
            .onChange(of: model.host) { typedHost = model.host }
            // Read on the way in, and again on coming back, since the switch is in the Settings app.
            .task { await model.readNotifications() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.readNotifications() } }
            }
            .sheet(isPresented: $showingGuide) { WelcomeView() }
            .sheet(isPresented: $showingDisclaimer) { DisclaimerView() }
        }
    }

    /// Whether the overnight run can say anything, and the way to change it. The provisional permission the
    /// app takes after the first connect happens without a word, and somebody who only uses the app at home
    /// never queues a reservation and never sees the dialog, so this is the one place it shows.
    @ViewBuilder
    private var notificationsSection: some View {
        let status = model.notifications
        Section {
            LabeledContent("通知") {
                Text(status.map(Self.permissionLabel) ?? "")
                    .foregroundStyle(.secondary)
            }
            // Until the reader has answered the dialog. Provisional permission is no answer: it was taken
            // without asking.
            if status == .notDetermined || status == .provisional {
                Button("通知を許可する") { Task { await model.askForNotifications() } }
            }
            // Before the app has asked for anything, the Settings app has no notification switches for it.
            if let status, status != .notDetermined {
                Button("通知の設定を開く") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            }
        } footer: {
            Text("送信待ちの予約をレコーダーに送ったときと、レコーダーの残り容量が \(Int(Notify.lowSpaceGB)) GB を"
                 + "下回ったときにお知らせします。どちらも夜間の自動更新で起きることなので、音は鳴りません。")
        }
    }

    private static func permissionLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .ephemeral: "オン"
        case .provisional: "通知センターのみ"
        case .denied: "オフ"
        case .notDetermined: "未設定"
        @unknown default: ""
        }
    }

    /// Both of these are stored the way the recorder writes a time, `2026-09-20T18:27:36+09:00`. Nobody
    /// reads that; what they want to know is whether the guide is fresh.
    private static func readable(_ stored: String) -> String {
        RecorderTime.parse(stored).map { Format.when($0) } ?? stored
    }
}

/// The recording mode a new reservation and a new keyword condition start at. Chosen here and only here: the
/// sheets start their own picker from it and leave it alone, where they used to be bound to it, so that
/// trying a mode on one programme quietly changed the next one's.
enum DefaultQuality {
    static let fallback = "LSR"

    static var current: String {
        let saved = UserDefaults.standard.string(forKey: DefaultsKey.defaultQuality) ?? fallback
        return Codes.qualityOrder.contains(saved) ? saved : fallback
    }
}
