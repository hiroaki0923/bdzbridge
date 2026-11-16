import RecBridgeModel
import RecorderKit
import SwiftUI

/// The first screen, shown until a recorder or a television has been set up, and reachable again from the
/// settings. Its one job is to walk the reader through the only step the app cannot do for them: the recorder
/// has to be awake for the first meeting, because the address that wakes it later comes from the recorder
/// itself, and the television has to be showing a broadcast, because that is when it shows its number.
///
/// One search finds both. A recorder chosen here closes the tutorial once it answers; a television tapped
/// here is registered over it, the search going on behind, and the tutorial stays up for the recorder, or
/// for the reader to close.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// What the reader has typed and chosen here, and what holds the buttons.
    @State private var welcome: WelcomeState
    /// The television's sheet, for a television the search found, tapped.
    @State private var tvSheet: TVSheetRequest?

    init(model: AppModel) {
        _welcome = State(initialValue: WelcomeState(model: model))
    }

    var body: some View {
        @Bindable var welcome = welcome
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RecBridge").font(.largeTitle.bold())
                        // Which recorders first: somebody with another maker's would otherwise go through the
                        // steps below and learn it only from a scan that found nothing. The television is
                        // somewhere to send a reservation, not a guide.
                        Text("ソニーのブルーレイディスクレコーダー（BDZ シリーズ）用のアプリです。"
                             + "レコーダーの番組表を iPhone で見て、録画予約や録画した番組の整理ができます。"
                             + "USB ハードディスクに録画できるソニーのテレビにも、録画予約を送れます。"
                             + "まず、お使いのレコーダーとテレビを追加しましょう。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                Section(Tutorial.heading) {
                    step(1, Tutorial.step1Title, Tutorial.step1Detail)
                    step(2, "iPhone をレコーダーやテレビと同じ Wi-Fi につなぐ", Tutorial.step2Detail)
                    step(3, Tutorial.step3Title,
                         "「ローカルネットワークへのアクセス」の確認が表示されたら「許可」を選んでください。"
                         + "そのまま検索が始まります。")
                    step(4, Tutorial.step4Title, Tutorial.step4Detail)
                }
                Section {
                    Button {
                        welcome.search()
                    } label: {
                        HStack {
                            Spacer()
                            if welcome.searching { ProgressView().controlSize(.small).padding(.trailing, 6) }
                            Text(SettingsWords.searchLabel).bold()
                            Spacer()
                        }
                    }
                    .disabled(welcome.holdsSearch)
                    // Right under the button, which is where the reader is looking: the foot of this list is
                    // below the fold on most iPhones.
                    if welcome.showsPermissionNotice {
                        LocalNetworkNotice()
                        OpenSettingsButton()
                    }
                    if let scanning = welcome.progress {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(scanning.done), total: Double(max(1, scanning.total)))
                            Text(SettingsWords.searchingLine(scanning))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let outcome = model.scanOutcome {
                        ScanOutcomeText(outcome: outcome)
                    }
                    // The connect to a recorder chosen below, here for the same reason. Choosing one takes the
                    // list it was chosen from away, so this is also the nearest place to where the tap was.
                    if let busy = model.busy {
                        HStack { ProgressView().controlSize(.small); Text(busy) }
                    }
                    if let problem = model.problem(for: .recorder) {
                        Text(problem.asABody).foregroundStyle(.red).font(.callout)
                    }
                }
                if !model.found.isEmpty {
                    Section(SettingsWords.foundRecordersHeading) {
                        ForEach(model.found, id: \.host) { recorder in
                            Button { Task { await welcome.take(recorder.host) } } label: {
                                FoundRecorderRow(recorder: recorder, inUse: model.inUse(recorder))
                            }
                            .buttonStyle(.plain)
                            .disabled(welcome.holdsRecorders)
                        }
                    }
                }
                // Not while a recorder chosen here is being connected to: its answer closes the tutorial, which
                // would take a television's registration with it, its number left on the panel for nobody.
                FoundTelevisionsSection(sheet: $tvSheet)
                    .disabled(welcome.holdsTelevisions)
                Section {
                    if welcome.typing {
                        TextField(RecorderSettingsState.hostPlaceholder, text: $welcome.typedHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                        AddressNote(typed: welcome.tidied)
                        Button(RecorderSettingsState.connectLabel) { welcome.connectTyped() }
                        .disabled(welcome.holdsConnect)
                    } else {
                        Button("IP アドレスを直接入力") { welcome.typing = true }
                    }
                } footer: {
                    Text(Tutorial.addressFooter)
                }
                Section {
                    Button(SettingsWords.enterDemoLabel) {
                        Task {
                            await welcome.enterDemo()
                            dismiss()
                        }
                    }
                    .disabled(welcome.holdsDemo)
                } footer: {
                    Text(Tutorial.demoFooter)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            // A scan waiting on the system's question must not outlive the screen that asked it. A sheet over
            // this one is not its going: the search goes on behind the television's.
            .onDisappear { welcome.closed() }
            .sheet(item: $tvSheet) {
                TVRegisterSheet(model: model, host: $0.host, connectAtOnce: $0.connectAtOnce, again: $0.again)
            }
            .onChange(of: welcome.done) { if $1 { dismiss() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Opened again from the settings, or once a television is registered here, there is nothing
                    // to put off, only a screen to leave.
                    Button(welcome.closeLabel) { dismiss() }
                }
            }
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

/// What the address field says back about what was typed (`RecorderAddress.Typed.note`), under the field in
/// both the tutorial and the settings.
struct AddressNote: View {
    let typed: RecorderAddress.Typed

    var body: some View {
        if let note = typed.note, note.warning {
            Text(note.text).font(.caption).foregroundStyle(.red)
        } else if let note = typed.note {
            Text(note.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What a scan came to, under the button in both the tutorial and the settings. When it found nothing, the
/// likely reasons follow, one to a line, for the reader to go down; when it found a television alone, what a
/// recorder that did not answer wants.
struct ScanOutcomeText: View {
    let outcome: AppModel.ScanOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(outcome.text)
                .font(.callout)
                .foregroundStyle(outcome.failed ? Color.red : Color.secondary)
            if let line = outcome.noRecorderBeside {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            if !outcome.causes.isEmpty {
                Text("考えられる原因").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(outcome.causes, id: \.self) { cause in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("・").accessibilityHidden(true)
                        Text(cause)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .rowLinesInFull()
    }
}

/// 見つかったテレビ, under the recorders a scan found, in the tutorial and the settings alike. A row is a button
/// while no television is saved, and opens the television's sheet going straight on to テレビに接続; the search
/// goes on behind it. The row and the foot say so: the tap puts a number on the television's panel, and nothing
/// but the tap does, so the row waits for it and does not open by itself. With one saved the rows are only
/// listed, the saved one in use, and the foot says why.
struct FoundTelevisionsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: TVSheetRequest?

    var body: some View {
        if !model.foundTelevisions.isEmpty {
            Section {
                ForEach(model.foundTelevisions, id: \.host) { television in
                    let row = FoundTelevisionRow(television: television, inUse: model.inUse(television),
                                                 registers: model.canAddAFoundTelevision)
                    if model.canAddAFoundTelevision {
                        Button { sheet = TVSheetRequest(host: television.host, connectAtOnce: true) } label: { row }
                            .buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            } header: {
                Text(SettingsWords.foundTelevisionsHeading)
            } footer: {
                Text(SettingsWords.foundTelevisionsFooter(registers: model.canAddAFoundTelevision))
            }
        }
    }
}

/// What tapping a found device's row does, at the row's end: a row looks like any other, and nothing else on it
/// says that it can be tapped.
private struct FoundRowAction: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.tint)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

/// One television the scan turned up: the model it gave, and its address. The one saved says so; one that
/// can be added says that a tap registers it.
struct FoundTelevisionRow: View {
    let television: TVSighting
    var inUse = false
    var registers = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsWords.foundTelevisionName(television.model)).font(.subheadline)
                Text(television.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if inUse {
                Spacer()
                Label(SettingsWords.inUseLabel, systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } else if registers {
                Spacer()
                FoundRowAction(title: SettingsWords.registerFoundLabel)
            }
        }
        .rowHitArea()
        .accessibilityAddTraits(inUse ? .isSelected : [])
    }
}

/// One recorder the scan turned up, as both the tutorial and the settings list it. The one the app is set to
/// says so: a scan from the settings finds it as well, beside any second one on the same network. Any other
/// says that a tap connects to it.
struct FoundRecorderRow: View {
    let recorder: RecorderDescription
    var inUse = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.product).font(.subheadline)
                Text("\(recorder.host) · \(recorder.friendlyName)"
                     + (recorder.epgCapable ? " · 番組表あり" : " · 番組表なし"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inUse {
                Label(SettingsWords.inUseLabel, systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } else {
                FoundRowAction(title: "接続する")
            }
        }
        .rowHitArea()
        .accessibilityAddTraits(inUse ? .isSelected : [])
    }
}
