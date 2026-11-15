import RecBridgeModel
import RecorderKit
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// The recorder's address and MAC as typed, and what connecting offers.
    @State private var recorder: RecorderSettingsState
    @State private var showingGuide = false
    @State private var showingDisclaimer = false
    /// The television's sheet: its section asks for it (`TVSection`), and so does a television the search
    /// found, tapped (`FoundTelevisionsSection`); this screen puts it up.
    @State private var tvSheet: TVSheetRequest?
    /// What the last press of 番組表を更新 had to say (`AppModel.refreshGuideByHand`), until it is dismissed.
    @State private var guideFailure: String?
    @AppStorage(DefaultsKey.defaultQuality) private var defaultQuality = DefaultQuality.fallback

    init(model: AppModel) {
        _recorder = State(initialValue: RecorderSettingsState(model: model))
    }

    /// What the store calls the version, and the build behind it: `0.2 (12)`. The build number comes from
    /// Xcode Cloud, so it is the only thing that tells two TestFlight builds of one version apart.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return SettingsWords.version(release: release, build: build)
    }

    var body: some View {
        @Bindable var recorder = recorder
        NavigationStack {
            Form {
                Section {
                    // What the recorder says of itself once connected, then how the link stands and where it is,
                    // in the order the television's section gives its own.
                    if let info = model.info {
                        LabeledContent(RecorderSettingsState.productLabel, value: info.product)
                        LabeledContent(RecorderSettingsState.nameLabel, value: info.friendlyName)
                        // empty when the recorder would not say, which another model may not
                        if !model.firmware.isEmpty {
                            LabeledContent(RecorderSettingsState.firmwareLabel, value: model.firmware)
                        }
                        LabeledContent(RecorderSettingsState.guideLabel,
                                       value: RecorderSettingsState.guideShown(info.epgCapable))
                        // By position: a disk the owner named HDD on the recorder would share the internal one's label.
                        ForEach(Array(AppModel.storageRows(storage: model.storage, usb: model.usbDisk).enumerated()),
                                id: \.offset) { _, row in
                            LabeledContent(row.label, value: row.value)
                        }
                    }
                    if let standing = recorder.standing {
                        LabeledContent(RecorderSettingsState.standingLabel, value: standing)
                    }
                    LabeledContent(RecorderSettingsState.hostLabel) {
                        TextField(RecorderSettingsState.hostPlaceholder, text: $recorder.typedHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                    }
                    AddressNote(typed: recorder.tidied)
                    LabeledContent(RecorderSettingsState.macLabel) {
                        TextField(RecorderSettingsState.macPlaceholder, text: $recorder.typedMac)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                    }
                    .onChange(of: model.mac, initial: true) { recorder.macMoved() }
                    if recorder.offersConnect {
                        Button(RecorderSettingsState.connectLabel) { Task { await recorder.connect() } }
                            .disabled(recorder.holdsConnect)
                    } else if recorder.offersReconnect {
                        Button(RecorderSettingsState.reconnectLabel) { Task { await recorder.reconnect() } }
                            .disabled(recorder.holdsReconnect)
                    }
                } header: {
                    Text(RecorderSettingsState.heading)
                } footer: {
                    Text(RecorderSettingsState.footer)
                }

                Section {
                    Picker(SettingsWords.defaultQualityLabel, selection: $defaultQuality) {
                        ForEach(RecorderDriver.recordsIn, id: \.self) { code in
                            Text(SheetWords.qualityLabel(code)).tag(code)
                        }
                    }
                } footer: {
                    Text(SettingsWords.defaultQualityFooter)
                }

                TVSection(model: model, sheet: $tvSheet)

                Section {
                    Button(SettingsWords.searchLabel) {
                        model.scanForDevices()
                    }
                    .disabled(model.holdsTheSearchButton)
                    // This screen has no activity strip, so a connect held up by the permission is said here
                    // as well as a scan.
                    if model.lanBlocked {
                        LocalNetworkNotice()
                        OpenSettingsButton()
                    }
                    if let scanning = model.searchProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(SettingsWords.searchingLine(scanning))
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
                    Text(SettingsWords.searchFooter(inDemo: model.demo))
                }

                if !model.found.isEmpty {
                    Section(SettingsWords.foundRecordersHeading) {
                        ForEach(model.found, id: \.host) { found in
                            Button {
                                Task { await recorder.choose(found.host) }
                            } label: {
                                FoundRecorderRow(recorder: found, inUse: model.inUse(found))
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canChangeRecorder)
                        }
                    }
                }
                FoundTelevisionsSection(sheet: $tvSheet)

                Section {
                    NavigationLink(SettingsWords.channelsLabel) {
                        ChannelsScreen(broadcasting: model.broadcasting, model: model)
                    }
                } footer: {
                    Text(SettingsWords.channelsFooter)
                }

                guideSection

                notificationsSection
                arrivingHomeSection

                Section {
                    // Not while a connect, a load or a job is under way: see `canChangeRecorder`.
                    if model.demo {
                        Button(SettingsWords.leaveDemoLabel, role: .destructive) {
                            Task { await model.leaveDemo() }
                        }
                        .disabled(!model.canChangeRecorder)
                    } else {
                        Button(SettingsWords.enterDemoLabel) { Task { await model.enterDemo() } }
                            .disabled(!model.canChangeRecorder)
                    }
                } footer: {
                    Text(SettingsWords.demoFooter(inDemo: model.demo))
                }

                Section {
                    Button(Tutorial.reviewRow) { showingGuide = true }
                }

                Section(SettingsWords.appHeading) {
                    // Before the version, because it is the one thing in this section worth reading: what
                    // this app writes to the recorder, it writes for real.
                    Button(Disclaimer.title) { showingDisclaimer = true }
                    // Selectable, so that it can be copied into a report rather than read off a screen.
                    LabeledContent(SettingsWords.versionLabel, value: Self.version)
                        .textSelection(.enabled)
                }

                if let busy = model.busy {
                    Section { HStack { ProgressView().controlSize(.small); Text(busy) } }
                }
                if let problem = model.problem(for: .recorder) {
                    Section { Text(problem.asABody).foregroundStyle(.red).font(.callout) }
                }
                // The phone's own, under the recorder's: its cache, which no device said anything of.
                if let problem = model.phoneProblem {
                    Section { Text(problem.asABody).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle(SettingsWords.title)
            .onAppear { recorder.appeared() }
            .onChange(of: model.host) { recorder.hostMoved() }
            // Read on the way in, and again on coming back, since the switch is in the Settings app.
            .task { await model.readNotifications() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.readNotifications() } }
            }
            .sheet(isPresented: $showingGuide) { WelcomeView(model: model) }
            .sheet(isPresented: $showingDisclaimer) { DisclaimerView() }
            // On the form and not on the television's section: one presenter, on a view that is still there
            // when the section turns from one form to the other as a registration is made.
            .sheet(item: $tvSheet) {
                TVRegisterSheet(model: model, host: $0.host, connectAtOnce: $0.connectAtOnce, again: $0.again)
            }
            .alert(AppModel.refreshFailedTitle,
                   isPresented: Binding(get: { guideFailure != nil }, set: { if !$0 { guideFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(guideFailure?.asABody ?? "")
            }
        }
    }

    /// Whether the overnight run can say anything, and the way to change it. The provisional permission the
    /// app takes after the first connect happens without a word, and somebody who only uses the app at home
    /// never queues a reservation and never sees the dialog, so this is the one place it shows.
    /// The guide held on the phone: where it is fetched from, what it holds, and 番組表を更新.
    private var guideSection: some View {
        Section {
            if model.guideSourceIsChoosable {
                Picker(SettingsWords.guideSourceLabel, selection: Binding(
                    get: { model.guideSourcePreference },
                    set: { choice in Task { await model.setGuideSourcePreference(choice) } })) {
                    Text(SettingsWords.guideSourceName(.recorder)).tag(GuideSourceChoice.recorder)
                    Text(SettingsWords.guideSourceName(.tv)).tag(GuideSourceChoice.tv)
                }
            } else if let alone = model.guideSourceAlone {
                LabeledContent(SettingsWords.guideSourceLabel, value: alone)
            }
            ForEach(GuideRefresh.offeredTypes(model.counts), id: \.self) { broadcasting in
                LabeledContent(Codes.broadcastingLabel[broadcasting] ?? broadcasting) {
                    Text(SettingsWords.countsLine(model.counts[broadcasting]))
                        .foregroundStyle(.secondary)
                }
            }
            if let refreshed = model.lastGuideRefresh {
                LabeledContent(SettingsWords.lastRefreshLabel, value: refreshed)
            }
            if let overnight = model.lastOvernightRefresh {
                LabeledContent(SettingsWords.lastOvernightRefreshLabel, value: overnight)
            }
            Button(AppModel.refreshGuideLabel) {
                Task { guideFailure = await model.refreshGuideByHandFromSource() }
            }
            .disabled(!model.canRefreshGuideByHand)
        } header: {
            Text(SettingsWords.keptGuideHeading)
        } footer: {
            if model.guideSourceIsChoosable {
                Text(SettingsWords.guideSourceFooter(helperProblem: model.helperProblem))
            } else if let problem = model.helperProblem {
                Text(problem.asABody).foregroundStyle(.red).font(.callout)
            }
        }
    }

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
            // What the runs with no screen post (`Notify`): what became of the queue, reservations not yet at a
            // device as they are about to start, and each of the recorder's disks falling below the line.
            if model.tv == nil {
                Text("送信待ちの予約をレコーダーに送ったときと、レコーダーへの予約が届かないまま始まりそうなときと、"
                     + "レコーダーの残り容量が \(Int(Notify.lowSpaceGB)) GB を下回ったときにお知らせします。"
                     + "どれも夜間の自動更新などで起きることなので、音は鳴りません。")
            } else {
                Text("送信待ちの予約をレコーダーやテレビに送ったときと、予約が届かないまま始まりそうなときと、"
                     + "レコーダーの残り容量が \(Int(Notify.lowSpaceGB)) GB を下回ったときにお知らせします。"
                     + "どれも夜間の自動更新などで起きることなので、音は鳴りません。")
            }
        }
    }

    /// How to have the queue sent on arriving home. Only the reader can set it up, in the Shortcuts app, and
    /// nothing else in the app would tell them it can be done: see `SendWaitingIntent`.
    private var arrivingHomeSection: some View {
        Section {
            Button("ショートカットを開く") {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            }
        } header: {
            Text("帰宅したときに送る")
        } footer: {
            if model.tv == nil {
                Text("送信待ちの予約は、アプリを開いたときか夜間の自動更新で送られます。家に着いてすぐ送るには、"
                     + "ショートカット App のオートメーションで、自宅の Wi-Fi に接続したときにすぐに実行するものを作り、"
                     + "アクションに RecBridge の「送信待ちの予約を送る」を選んでください。送るものがないときは、"
                     + "レコーダーには何もしません。")
            } else {
                Text("送信待ちの予約は、アプリを開いたときか夜間の自動更新で、レコーダーやテレビに送られます。"
                     + "家に着いてすぐ送るには、ショートカット App のオートメーションで、"
                     + "自宅の Wi-Fi に接続したときにすぐに実行するものを作り、"
                     + "アクションに RecBridge の「送信待ちの予約を送る」を選んでください。送るものがないときは、"
                     + "レコーダーにもテレビにも何もしません。")
            }
        }
    }

    private static func permissionLabel(_ status: NotificationPermission) -> String {
        switch status {
        case .authorized, .ephemeral: "オン"
        case .provisional: "通知センターのみ"
        case .denied: "オフ"
        case .notDetermined: "未設定"
        case .unknown: ""
        }
    }
}
