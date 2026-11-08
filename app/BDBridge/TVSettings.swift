import RecBridgeModel
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
    /// How the link stands, the helper, and テレビを外す with its question.
    @State private var television: TVSettingsState
    /// Whether the sheet that registers with the helper on the television is up, hung on its own button.
    @State private var registeringHelper = false

    init(model: AppModel, sheet: Binding<TVSheetRequest?>) {
        _sheet = sheet
        _television = State(initialValue: TVSettingsState(model: model))
    }

    var body: some View {
        Group {
            if let tv = model.tv {
                Section {
                    if let name = model.tvDriver?.facts.model {
                        LabeledContent("機種", value: name)
                    }
                    LabeledContent("IP アドレス", value: tv.host)
                    if let standing = television.standing {
                        LabeledContent("状態", value: standing)
                    }
                    NavigationLink("対応状況を調べる") { TVCapabilitiesScreen(host: tv.host) }
                    if let storage = model.tvDriver?.facts.storage {
                        LabeledContent("USB ハードディスク",
                                       value: Format.storage(mounted: storage.mounted, freeBytes: storage.freeBytes,
                                                             totalBytes: storage.totalBytes, on: .tv))
                    }
                    if television.offersRegistering {
                        Button("登録する") { sheet = TVSheetRequest(host: tv.host, connectAtOnce: false, again: true) }
                    } else if television.offersReconnect {
                        Button("再接続") { Task { await television.reconnect() } }
                            .disabled(television.holdsReconnect)
                    }
                    if television.offersTheHelper {
                        LabeledContent("番組表（ヘルパー）", value: television.helperRegistered ? "登録済み" : "未登録")
                        if television.helperRegistered {
                            Button("ヘルパーの登録を解除", role: .destructive) { television.forgetHelper() }
                        } else {
                            Button("ヘルパーに登録") { registeringHelper = true }
                                .sheet(isPresented: $registeringHelper) { HelperRegisterSheet(model: model) }
                        }
                    }
                    Button("テレビを外す", role: .destructive) { Task { await television.remove() } }
                        .disabled(television.holdsRemoving)
                } header: {
                    Text("テレビ")
                } footer: {
                    if let footer = television.footer { Text(footer).foregroundStyle(.red).font(.callout) }
                }
                .confirmationDialog(TVSettingsState.removalQuestion,
                                    isPresented: Binding(get: { television.asksToRemove },
                                                         set: { if !$0 { television.removalClosed() } }),
                                    titleVisibility: .visible) {
                    Button("外す", role: .destructive) { Task { await television.confirmRemoving() } }
                } message: {
                    Text(television.removalMessage)
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
}

/// Registering with the helper on the television, by the six-digit code its screen shows for five minutes
/// (`AppModel.registerHelper`). The television has been added already; the helper is at its address.
struct HelperRegisterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var helper: HelperRegisterState

    init(model: AppModel) {
        _helper = State(initialValue: HelperRegisterState(model: model))
    }

    var body: some View {
        @Bindable var helper = helper
        NavigationStack {
            Form {
                Section {
                    TextField("6 桁の番号", text: $helper.code)
                        .keyboardType(.numberPad)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("テレビで「RecBridge ヘルパー」を開き、「登録の番号を出す」で表示された 6 桁の番号を入力してください。"
                             + "番号は 5 分で消えます。")
                        Text("ヘルパーをテレビに入れる手順は、GitHub の説明書にあります。")
                        Link("github.com/hiroaki0923/bdzbridge/helper",
                             destination: URL(string: "https://github.com/hiroaki0923/bdzbridge/blob/main/helper/README.md")!)
                    }
                }
                if let message = helper.message {
                    Section { Text(message.asABody).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button("登録する") { helper.press() }
                        .disabled(helper.holdsThePress)
                    if helper.working { ProgressView() }
                }
            }
            .navigationTitle("テレビの番組表に登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .onChange(of: helper.done) { if $1 { dismiss() } }
        }
    }
}

/// Adding a television, or registering with it again: its address, and then the PIN it shows on its screen
/// (`TVRegisterState`, which says what the sheet goes by).
struct TVRegisterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var register: TVRegisterState

    init(model: AppModel, host: String, connectAtOnce: Bool = false, again: Bool = false) {
        _register = State(initialValue: TVRegisterState(model: model, host: host, connectAtOnce: connectAtOnce,
                                                        again: again))
    }

    var body: some View {
        @Bindable var register = register
        NavigationStack {
            Form {
                Section {
                    LabeledContent("IP アドレス") {
                        TextField("192.168.1.20", text: $register.typedHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                    }
                    .disabled(register.holdsTheAddress)
                } footer: {
                    Text("テレビと同じ Wi-Fi につないだこの端末から登録します。")
                }
                if register.askingForPIN {
                    Section {
                        TextField("4 桁の番号", text: $register.pin)
                            .keyboardType(.numberPad)
                    } footer: {
                        Text(register.pinNote)
                    }
                }
                if register.turnedAway {
                    // In place of the address not answering: the sheet goes on by itself once it is allowed.
                    Section {
                        LocalNetworkNotice(aboutAConnect: true)
                        OpenSettingsButton()
                    }
                } else if let message = register.message {
                    Section { Text(message.asABody).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button(register.pressLabel) { register.press() }
                        .disabled(register.holdsThePress)
                    if register.showsWorking { ProgressView() }
                }
            }
            .navigationTitle(register.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .onAppear { register.appeared() }
            .onDisappear { register.closed() }
            .onChange(of: register.done) { if $1 { dismiss() } }
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
