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
    @State private var typing = false
    @State private var typedHost = ""
    /// The television's sheet, for a television the search found, tapped.
    @State private var tvSheet: TVSheetRequest?
    /// The model's `timesAttached` when a recorder was chosen here, kept while that choice has yet to be
    /// answered. See `take`.
    @State private var chosenAt: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BD Bridge").font(.largeTitle.bold())
                        // Which recorders first: somebody with another maker's would otherwise go through the
                        // steps below and learn it only from a scan that found nothing. The television is
                        // somewhere to send a reservation, not a guide.
                        Text("ソニーのブルーレイディスクレコーダー（BDZ シリーズ）用のアプリです。"
                             + "レコーダーの番組表を iPhone で見て、録画予約や録画した番組の整理ができます。"
                             + "USB ハードディスクに録画できるソニーのテレビにも、録画予約を送れます。"
                             + "まず、お使いのレコーダーとテレビを登録しましょう。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                Section("セットアップ") {
                    step(1, "レコーダーとテレビの電源を入れる",
                         "レコーダーの電源が入っている必要があるのは最初の登録のときだけです。"
                         + "次回からはアプリがレコーダーを自動で起動します。"
                         + "テレビは、登録のときに画面に番号が出るので、放送を映しておいてください。")
                    step(2, "iPhone をレコーダーやテレビと同じ Wi-Fi につなぐ",
                         "同じネットワーク上にある機器だけが見つかります。")
                    step(3, "「レコーダーとテレビを探す」をタップする",
                         "「ローカルネットワークへのアクセス」の確認が表示されたら「許可」を選んでください。"
                         + "そのまま検索が始まります。")
                }
                Section {
                    Button {
                        model.scanForDevices()
                    } label: {
                        HStack {
                            Spacer()
                            if model.scanHoldsTheButton { ProgressView().controlSize(.small).padding(.trailing, 6) }
                            Text("レコーダーとテレビを探す").bold()
                            Spacer()
                        }
                    }
                    .disabled(model.scanHoldsTheButton || model.busy != nil)
                    // Right under the button, which is where the reader is looking: the foot of this list is
                    // below the fold on most iPhones.
                    if model.lanBlocked {
                        LocalNetworkNotice()
                        OpenSettingsButton()
                    }
                    if let scanning = model.scanning, !model.scanBlocked {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(scanning.done), total: Double(max(1, scanning.total)))
                            Text("検索中 \(scanning.done) / \(scanning.total)")
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
                    if let problem = model.problem {
                        Text(problem).foregroundStyle(.red).font(.callout)
                    }
                }
                if !model.found.isEmpty {
                    Section("見つかったレコーダー") {
                        ForEach(model.found, id: \.host) { recorder in
                            Button { Task { await take(recorder.host) } } label: {
                                FoundRecorderRow(recorder: recorder, inUse: model.inUse(recorder))
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canChangeRecorder)
                        }
                    }
                }
                FoundTelevisionsSection(sheet: $tvSheet)
                Section {
                    if typing {
                        let typed = RecorderAddress.tidy(typedHost)
                        TextField("192.168.1.10", text: $typedHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                        AddressNote(typed: typed)
                        Button("このアドレスに接続") {
                            // the field shows what is saved, so that what was taken off can be seen to be gone
                            typedHost = typed.host
                            Task { await take(typed.host) }
                        }
                        .disabled(!RecorderAddress.isUsable(typed.host) || !model.canChangeRecorder)
                    } else {
                        Button("IP アドレスを直接入力") { typing = true }
                    }
                } footer: {
                    Text("見つからない場合は、レコーダーの設定画面で確認できる IP アドレスを直接入力できます。"
                         + "テレビは、あとで設定の「テレビ」からアドレスを入力して追加できます。")
                }
                Section {
                    Button("サンプルデータで試す") {
                        Task {
                            await model.enterDemo()
                            dismiss()
                        }
                    }
                    .disabled(!model.canChangeRecorder)
                } footer: {
                    Text("レコーダーが無くても、架空の番組表と録画一覧でアプリの動きを確かめられます。"
                         + "実在の放送局・番組ではありません。いつでも設定から終了できます。")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            // A scan waiting on the system's question must not outlive the screen that asked it. A sheet over
            // this one is not its going: the search goes on behind the television's.
            .onDisappear { model.stopScanning() }
            .sheet(item: $tvSheet) { TVRegisterSheet(host: $0.host, connectAtOnce: $0.connectAtOnce) }
            .onChange(of: model.timesAttached) {
                if let chosenAt, model.timesAttached > chosenAt { dismiss() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Opened again from the settings, or once a television is registered here, there is nothing
                    // to put off, only a screen to leave.
                    Button(model.welcomes ? "あとで設定" : "閉じる") { dismiss() }
                }
            }
        }
    }

    /// Choosing a recorder ends the tutorial as soon as it answers, which is in the middle of the connect.
    /// The reservations and the guide are still to be read, the longest wait in the app on a first run, and
    /// the screens behind this one can show them arriving.
    ///
    /// The connect is not split to get there, since the rest would run with `connecting` off and a second
    /// connect could start beside it. It says instead that it has reached the recorder (`timesAttached`), and
    /// the count taken here tells that answer from a connection that was already up, as it is when the
    /// tutorial is opened again from the settings.
    ///
    /// A connect held up by the local network permission answers later, when the reader allows it; the
    /// screen waits for that. Any other that returns without an answer is over, and the choice with it.
    private func take(_ host: String) async {
        let before = model.timesAttached
        chosenAt = before
        await model.adopt(host: host)
        if model.timesAttached == before, !model.connectBlocked { chosenAt = nil }
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

/// What the address field says back about what was typed, under the field in both the tutorial and the
/// settings. Tidying is done without a word, except for a port: somebody typed it on purpose, so it is
/// said that it will not be used. Nothing is said while the field is empty or the address is fine.
struct AddressNote: View {
    let typed: RecorderAddress.Typed

    var body: some View {
        if typed.host.isEmpty {
            EmptyView()
        } else if !RecorderAddress.isUsable(typed.host) {
            Text("アドレスの形式が正しくありません。192.168.1.10 のような IP アドレスを入力してください。")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let port = typed.port {
            Text("ポート番号は不要です。「:\(port)」は使わずに \(typed.host) に接続します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// What a scan came to, under the button in both the tutorial and the settings. When it found nothing, the
/// likely reasons follow, one to a line, for the reader to go down.
struct ScanOutcomeText: View {
    let outcome: AppModel.ScanOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(outcome.text)
                .font(.callout)
                .foregroundStyle(outcome.failed ? Color.red : Color.secondary)
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
/// goes on behind it. With one saved the rows are only listed, the saved one in use, and the foot says why.
struct FoundTelevisionsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: TVSheetRequest?

    var body: some View {
        if !model.foundTelevisions.isEmpty {
            Section {
                ForEach(model.foundTelevisions, id: \.host) { television in
                    let row = FoundTelevisionRow(television: television, inUse: model.inUse(television))
                    if model.canAddAFoundTelevision {
                        Button { sheet = TVSheetRequest(host: television.host, connectAtOnce: true) } label: { row }
                            .buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            } header: {
                Text("見つかったテレビ")
            } footer: {
                if !model.canAddAFoundTelevision {
                    Text("使えるテレビは 1 台です。別のテレビを使うときは、設定の「テレビ」で今のテレビを外してから、"
                         + "もう一度探してください。")
                }
            }
        }
    }
}

/// One television the scan turned up: the model it gave, and its address. The one saved says so.
struct FoundTelevisionRow: View {
    let television: TVSighting
    var inUse = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(television.model.isEmpty ? "テレビ" : television.model).font(.subheadline)
                Text(television.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if inUse {
                Spacer()
                Label("使用中", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .rowHitArea()
        .accessibilityAddTraits(inUse ? .isSelected : [])
    }
}

/// One recorder the scan turned up, as both the tutorial and the settings list it. The one the app is set to
/// says so: a scan from the settings finds it as well, beside any second one on the same network.
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
            if inUse {
                Spacer()
                Label("使用中", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .rowHitArea()
        .accessibilityAddTraits(inUse ? .isSelected : [])
    }
}
