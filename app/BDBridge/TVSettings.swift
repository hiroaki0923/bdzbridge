import RecorderKit
import SwiftUI

/// What the television's sheet is put up for: the address it opens on, and whether it goes straight on to
/// テレビに接続 -- a television a scan found, tapped -- or waits for the reader's tap, for an address to be typed
/// or a registration again. One value, so that the one presenter on a screen can be handed either.
struct TVSheetRequest: Identifiable {
    let id = UUID()
    var host: String
    var connectAtOnce: Bool
    /// A registration again with the television already added, which the sheet's title says.
    var again = false
}

/// The television in the settings: a way to add one by its address, and once added, what is known of it and
/// the ways to reconnect, register again or take it away. A television is found by the search above it; this
/// is the way in for one the search did not find. In the demo it is the demo's television, which the demo's
/// search finds and which goes with the demo.
struct TVSection: View {
    @Environment(AppModel.self) private var model
    /// The sheet that adds a television, or registers with it again, asked for. Only set here: the sheet is
    /// the settings screen's, hung on its form. Hung on this section it was hung on each of the section's rows
    /// -- a modifier on a group goes to each of its children, and a section in a form hands it on to each of
    /// its rows -- and with several presenters on the one state the sheet went by itself at the first press,
    /// and again as a registration turned the section from one form to the other under it.
    @Binding var sheet: TVSheetRequest?
    @State private var removing = false
    /// Whether the sheet that registers with the helper on the television is up, hung on its own button.
    @State private var registeringHelper = false
    /// How many reservations wait for the television, read as the question goes up, for it to say and for
    /// 外す to be held to. Nil when they could not be counted.
    @State private var waiting: Int?

    var body: some View {
        Group {
            if let tv = model.tv {
                Section {
                    if let name = model.tvDriver?.facts.model {
                        LabeledContent("機種", value: name)
                    }
                    LabeledContent("IP アドレス", value: tv.host)
                    LabeledContent("状態", value: state(of: tv))
                    NavigationLink("対応状況を調べる") { TVCapabilitiesScreen(host: tv.host) }
                    if let storage = model.tvDriver?.facts.storage {
                        // The television's MB taken as a million bytes, as the recorder's are.
                        LabeledContent("USB ハードディスク",
                                       value: Format.storage(mounted: storage.mounted, freeBytes: storage.freeBytes,
                                                             totalBytes: storage.totalBytes))
                    }
                    if model.tvDriver?.facts.needsPairing == true {
                        Button("登録する") { sheet = TVSheetRequest(host: tv.host, connectAtOnce: false, again: true) }
                    } else if !tv.session.connected {
                        Button("再接続") { Task { await tv.connect() } }
                            .disabled(tv.session.connecting)
                    }
                    if model.tvHelper != nil {
                        LabeledContent("番組表（ヘルパー）", value: model.helperRegistered ? "登録済み" : "未登録")
                        if model.helperRegistered {
                            Button("ヘルパーの登録を解除", role: .destructive) { model.forgetHelper() }
                        } else {
                            Button("ヘルパーに登録") { registeringHelper = true }
                                .sheet(isPresented: $registeringHelper) { HelperRegisterSheet() }
                        }
                    }
                    // Not while the television works: a sending that is out may be making a reservation
                    // that the question would say is deleted unsent.
                    Button("テレビを外す", role: .destructive) {
                        Task {
                            waiting = await model.waitingForTheTelevision()
                            removing = true
                        }
                    }
                    .disabled(model.isBusy(for: .tv))
                } header: {
                    Text("テレビ")
                } footer: {
                    // Why 外す left the television in place, above what went wrong with the television: both
                    // when both stand.
                    let lines = [model.whyTheTelevisionStays, model.problem(for: .tv)].compactMap { $0 }
                    if !lines.isEmpty { Text(lines.joined(separator: "\n").asABody).foregroundStyle(.red).font(.callout) }
                }
                .confirmationDialog("テレビを外しますか？", isPresented: $removing, titleVisibility: .visible) {
                    // Why it could not be taken away is said in the footer above (`whyTheTelevisionStays`).
                    // Handed the count the message below gave: nothing is taken away over another.
                    Button("外す", role: .destructive) {
                        Task { await model.takeTheTelevisionAway(counted: waiting) }
                    }
                } message: {
                    Text("この端末から、テレビのアドレスと登録を消します。テレビ側の登録済みの機器の一覧には残るので、"
                         + "テレビの設定から消してください。" + whatGoesWithIt)
                }
            } else {
                Section {
                    Button("アドレスを入力して追加") { sheet = TVSheetRequest(host: "", connectAtOnce: false) }
                } header: {
                    Text("テレビ")
                } footer: {
                    Text(model.demo
                         ? "サンプルデータでは、架空のテレビを追加して試せます。"
                           + "サンプルを終了すると、架空のテレビも消えます。"
                         : "テレビは、「レコーダーとテレビを探す」で探せます。見つからないときは、テレビの IP アドレスを"
                           + "入力して追加できます。登録のときに、テレビの画面に表示される 4 桁の番号を入力します。")
                }
            }
        }
    }

    /// What the question adds about the reservations waiting for the television: how many are deleted
    /// unsent, and nothing with none. With no count to give it says as much without one, and not nothing:
    /// there may be some, and 外す deletes them if they can be deleted by then.
    private var whatGoesWithIt: String {
        guard let waiting else { return "\nこのテレビ宛の送信待ちの予約は、送らずに削除します。" }
        return waiting > 0 ? "\nこのテレビ宛の送信待ちの予約 \(waiting) 件は、送らずに削除します。" : ""
    }

    private func state(of tv: DeviceLink) -> String {
        tv.session.standing(needsPairing: model.tvDriver?.facts.needsPairing == true)
    }

}

/// Registering with the helper on the television, by the six-digit code its screen shows for five minutes
/// (`AppModel.registerHelper`). The television has been added already; the helper is at its address.
struct HelperRegisterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6 桁の番号", text: $code)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("テレビで「RecBridge ヘルパー」を開き、「登録の番号を出す」で表示された 6 桁の番号を入力してください。"
                         + "番号は 5 分で消えます。ヘルパーを入れる手順は、アプリの説明書にあります。")
                }
                if let message {
                    Section { Text(message.asABody).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button("登録する") { start() }
                        .disabled(working || code.count != 6 || !code.allSatisfy(\.isNumber))
                    if working { ProgressView() }
                }
            }
            .navigationTitle("テレビの番組表に登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    private func start() {
        guard !working else { return }
        working = true
        message = nil
        Task {
            let said = await model.registerHelper(code: code)
            working = false
            if let said {
                message = said
            } else {
                dismiss()
            }
        }
    }
}

/// Adding a television, or registering with it again: its address, and then the PIN it shows on its screen.
///
/// The PIN appears only when the television is on and showing something -- in standby it says nothing to look
/// at, and once it did not appear while the television was on either -- so a television in standby is asked to be
/// turned on first, and the PIN step says what to do when none appears.
///
/// Opened for a television a scan found (`connectAtOnce`), it goes straight on to テレビに接続 as it appears:
/// the reader tapped the television, and a second tap would only stand between them and its number.
///
/// An address that says nothing because the system keeps the app off the local network is not said to answer
/// nothing: the sheet says what is in the way, as the screens do for the recorder, and goes on by itself once
/// the permission comes (`AppModel.findTV`).
struct TVRegisterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    private let connectAtOnce: Bool
    /// Opened to register with the television already added, not to add one: テレビを登録, not テレビを追加.
    private let again: Bool
    @State private var askingForPIN = false
    @State private var pin = ""
    @State private var working = false
    @State private var message: String?
    /// The step under way, from a button or from the sheet's appearing, kept so that closing the sheet ends
    /// it: a registration is not asked for, nor a number put on a panel, for a sheet that is no longer there.
    /// A wait for the local network permission at the address ends with it (`AppModel.stopFindingTV`).
    @State private var step: Task<Void, Never>?
    /// Whether the step the sheet's appearing starts has been started: nothing promises that a view appears
    /// once, and the step is not to be sent twice.
    @State private var begun = false

    init(host: String, connectAtOnce: Bool = false, again: Bool = false) {
        _host = State(initialValue: host)
        self.connectAtOnce = connectAtOnce
        self.again = again
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("IP アドレス") {
                        TextField("192.168.1.20", text: $host)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                    }
                    // Nor while a step is under way, which may wait for the permission for as long as the reader
                    // takes: the PIN goes to the address the field shows, which is to be the one asked.
                    .disabled(askingForPIN || working)
                } footer: {
                    Text("テレビと同じ Wi-Fi につないだこの端末から登録します。")
                }
                if askingForPIN {
                    Section {
                        TextField("4 桁の番号", text: $pin)
                            .keyboardType(.numberPad)
                    } footer: {
                        // The demo's television has no panel to show its number on, so the sheet says it.
                        Text("テレビの画面に表示された 4 桁の番号を入力してください。番号が表示されないときは、"
                             + "テレビで放送を映してから、最初からやり直してください。"
                             + (model.demo ? "サンプルのテレビの番号は \(DemoTV.pin) です。" : ""))
                    }
                }
                if model.tvAddressTurnedAway {
                    // In place of the address not answering: the sheet goes on by itself once it is allowed.
                    Section {
                        LocalNetworkNotice(aboutAConnect: true)
                        OpenSettingsButton()
                    }
                } else if let message {
                    Section { Text(message.asABody).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button(askingForPIN ? "登録する" : "テレビに接続") { start() }
                        .disabled(working || !RecorderAddress.isUsable(tidied) || (askingForPIN && pin.count != 4))
                    if working && !model.tvAddressTurnedAway { ProgressView() }
                }
            }
            .navigationTitle(again ? "テレビを登録" : "テレビを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .onAppear {
                guard connectAtOnce, !begun else { return }
                begun = true
                start()
            }
            .onDisappear {
                step?.cancel()
                model.stopFindingTV()
            }
        }
    }

    private var tidied: String { RecorderAddress.tidy(host).host }

    private func start() {
        guard !working else { return }
        step = Task { await next() }
    }

    private func next() async {
        // A second tap before the button is drawn disabled would send the whole of it again.
        guard !working else { return }
        working = true
        defer { working = false }
        message = nil
        let host = tidied
        // The steps are the package's; closing the sheet cancels the step, after which nothing is registered.
        switch await TVDriver.register(askingForPIN: askingForPIN, pin: pin,
                                       find: { await model.findTV(at: host) },
                                       register: { await model.registerTV(at: host, pin: $0) },
                                       closed: { Task.isCancelled }) {
        case .askForThePIN: askingForPIN = true
        case .askForThePINAgain(let saying):
            pin = ""
            message = saying
        case .registered: dismiss()
        case .say(let text): message = text
        case .nothing: break
        }
    }
}

/// What the television says it speaks, for the reader to copy and send on when the app does not work with it: an
/// older television answers an error to a version the app speaks (`TVCapabilities`). With the registration, the
/// app's reads are tried too, and what their rows are made of said, never what they say. Nothing on the
/// television changes.
struct TVCapabilitiesScreen: View {
    @Environment(AppModel.self) private var model
    let host: String
    @State private var report: String?
    @State private var reading = false

    var body: some View {
        List {
            Section {
                Button("調べる") {
                    reading = true
                    Task {
                        report = await model.tvCapabilities(at: host)
                        reading = false
                    }
                }
                .disabled(reading)
            } footer: {
                Text("テレビが対応している機能と、予約や録画の一覧を読めるかを調べます。読むだけで、"
                     + "テレビの予約や設定は変わりません。結果に番組名や局名は含まれません。"
                     + "うまく動かないときは、結果をコピーして、お問い合わせの際にお送りください。"
                     + "テレビに予約と録画が 1 件ずつあると、より詳しく分かります。")
            }
            if reading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let report {
                Section {
                    Button("コピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = report }
                    Text(report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("テレビの対応状況")
        .navigationBarTitleDisplayMode(.inline)
    }
}
