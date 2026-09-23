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
                        // steps below and learn it only from a scan that found nothing.
                        Text("ソニーのブルーレイディスクレコーダー（BDZ シリーズ）用のアプリです。"
                             + "レコーダーの番組表を iPhone で見て、録画予約や録画した番組の整理ができます。"
                             + "まず、お使いのレコーダーを登録しましょう。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                Section("セットアップ") {
                    step(1, "レコーダーの電源を入れる",
                         "電源が入っている必要があるのは最初の登録のときだけです。次回からはアプリがレコーダーを自動で起動します。")
                    step(2, "iPhone をレコーダーと同じ Wi-Fi につなぐ",
                         "同じネットワーク上にあるレコーダーだけが見つかります。")
                    step(3, "「レコーダーを探す」をタップする",
                         "「ローカルネットワークへのアクセス」の確認が表示されたら「許可」を選んでください。"
                         + "そのまま検索が始まります。")
                }
                Section {
                    Button {
                        model.scanForRecorders()
                    } label: {
                        HStack {
                            Spacer()
                            if model.scanning != nil { ProgressView().controlSize(.small).padding(.trailing, 6) }
                            Text("レコーダーを探す").bold()
                            Spacer()
                        }
                    }
                    .disabled(model.scanning != nil || model.busy != nil)
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
                    Text("見つからない場合は、レコーダーの設定画面で確認できる IP アドレスを直接入力できます。")
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
            // A scan waiting on the system's question must not outlive the screen that asked it.
            .onDisappear { model.stopScanning() }
            .onChange(of: model.timesAttached) {
                if let chosenAt, model.timesAttached > chosenAt { dismiss() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // opened again from the settings there is nothing to put off, only a screen to leave
                    Button(model.host.isEmpty ? "あとで設定" : "閉じる") { dismiss() }
                }
            }
        }
    }

    /// Choosing a recorder ends the tutorial as soon as it answers, which is in the middle of the connect.
    /// Waiting for the connect to return kept the tutorial up while it went on to read the reservations and
    /// then the whole guide, every broadcasting type and its logos, with the row that was tapped gone and
    /// nothing but a line on screen: on a first run, the longest wait in the app, spent on the one screen
    /// that cannot show what is arriving. The screens behind it can, and say how the rest is going.
    ///
    /// The connect is not split to get there. Returning from it early would take its guard with it: the rest
    /// would run with `connecting` off, and a second connect -- the network changing, the app coming back to
    /// the front -- could start beside it with a client of its own. It says instead that it has reached the
    /// recorder (`timesAttached`), and the screen goes on that. The count taken here tells that answer from a
    /// connection that was already up, as it is when the tutorial is opened again from the settings, which
    /// watching `connected` would miss.
    ///
    /// A connect held up by the local network permission answers later, on its own, when the reader allows
    /// it; the screen waits for that rather than for another tap. Any other connect that returns without an
    /// answer is over, and the choice with it.
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
/// settings. Tidying takes off only what is plainly not part of an address and does it without a word; a
/// port is different, because somebody typed it on purpose, so it is said out loud that it will not be used.
/// Nothing is said while the field is empty or the address is fine.
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

/// One recorder the scan turned up, as both the tutorial and the settings list it. The one the app is set to
/// says so: from the settings, a scan finds the recorder already in use as well, and nothing told it apart from
/// a second one on the same network.
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
