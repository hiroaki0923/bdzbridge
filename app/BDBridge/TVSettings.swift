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
    /// What the television says of itself, how the link stands, the helper, and テレビを外す with its question, in
    /// the part's words.
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
                    if let name = television.productName {
                        LabeledContent(TVSettingsState.productLabel, value: name)
                    }
                    LabeledContent(TVSettingsState.hostLabel, value: tv.host)
                    if let standing = television.standing {
                        LabeledContent(TVSettingsState.standingLabel, value: standing)
                    }
                    NavigationLink(TVSettingsState.capabilitiesLabel) { TVCapabilitiesScreen(host: tv.host) }
                    if let storage = television.storageLine {
                        LabeledContent(TVSettingsState.storageLabel, value: storage)
                    }
                    if television.offersRegistering {
                        Button(TVSettingsState.registerLabel) {
                            sheet = TVSheetRequest(host: tv.host, connectAtOnce: false, again: true)
                        }
                    } else if television.offersReconnect {
                        Button(TVSettingsState.reconnectLabel) { Task { await television.reconnect() } }
                            .disabled(television.holdsReconnect)
                    }
                    if television.offersTheHelper {
                        LabeledContent(TVSettingsState.helperLabel, value: television.helperShown)
                        if television.helperRegistered {
                            Button(TVSettingsState.forgetHelperLabel, role: .destructive) { television.forgetHelper() }
                        } else {
                            Button(TVSettingsState.registerHelperLabel) { registeringHelper = true }
                                .sheet(isPresented: $registeringHelper) { HelperRegisterSheet(model: model) }
                        }
                    }
                    Button(TVSettingsState.removeLabel, role: .destructive) { Task { await television.remove() } }
                        .disabled(television.holdsRemoving)
                } header: {
                    Text(TVSettingsState.heading)
                } footer: {
                    if let footer = television.footer { Text(footer).foregroundStyle(.red).font(.callout) }
                }
                .confirmationDialog(TVSettingsState.removalQuestion,
                                    isPresented: Binding(get: { television.asksToRemove },
                                                         set: { if !$0 { television.removalClosed() } }),
                                    titleVisibility: .visible) {
                    Button(TVSettingsState.confirmRemovingLabel, role: .destructive) {
                        Task { await television.confirmRemoving() }
                    }
                } message: {
                    Text(television.removalMessage)
                }
            } else {
                Section {
                    Button(TVSettingsState.addLabel) { sheet = TVSheetRequest(host: "", connectAtOnce: false) }
                } header: {
                    Text(TVSettingsState.heading)
                } footer: {
                    Text(TVSettingsState.noTelevisionFooter(inDemo: model.demo))
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
                    TextField(HelperRegisterState.codePlaceholder, text: $helper.code)
                        .keyboardType(.numberPad)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(HelperRegisterState.codeNote)
                        Text(HelperRegisterState.instructionsNote)
                        Link(HelperRegisterState.instructionsLink,
                             destination: URL(string: HelperRegisterState.instructionsURL)!)
                    }
                }
                if let message = helper.message {
                    Section { Text(message.asABody).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button(HelperRegisterState.pressLabel) { helper.press() }
                        .disabled(helper.holdsThePress)
                    if helper.working { ProgressView() }
                }
            }
            .navigationTitle(HelperRegisterState.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SheetWords.cancelLabel) { dismiss() }
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
                    LabeledContent(TVRegisterState.hostLabel) {
                        TextField(TVRegisterState.hostPlaceholder, text: $register.typedHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                    }
                    .disabled(register.holdsTheAddress)
                } footer: {
                    Text(TVRegisterState.hostNote)
                }
                if register.askingForPIN {
                    Section {
                        TextField(TVRegisterState.pinPlaceholder, text: $register.pin)
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
                    Button(SheetWords.cancelLabel) { dismiss() }
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
                Button(TVCapabilitiesWords.checkLabel) {
                    reading = true
                    Task {
                        report = await model.tvCapabilities(at: host)
                        reading = false
                    }
                }
                .disabled(reading)
            } footer: {
                Text(TVCapabilitiesWords.footer)
            }
            if reading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let report {
                Section {
                    Button(TVCapabilitiesWords.copyLabel, systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = report
                    }
                    Text(report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(TVCapabilitiesWords.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
