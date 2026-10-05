import RecorderKit
import SwiftUI

/// The television in the settings: a way to add one, and once added, what is known of it and the ways to
/// reconnect, register again or take it away. Not in the demo, whose recorder is invented.
struct TVSection: View {
    @Environment(AppModel.self) private var model
    @State private var registering = false
    @State private var removing = false
    /// How many reservations wait for the television, read as the question goes up, for it to say.
    @State private var waiting = 0

    var body: some View {
        Group {
            if let tv = model.tv {
                Section {
                    if let name = model.tvDriver?.facts.model {
                        LabeledContent("機種", value: name)
                    }
                    LabeledContent("IP アドレス", value: tv.host)
                    LabeledContent("状態", value: state(of: tv))
                    if let storage = model.tvDriver?.facts.storage {
                        LabeledContent("USB ハードディスク", value: Self.describe(storage))
                    }
                    if model.tvDriver?.facts.needsPairing == true {
                        Button("登録する") { registering = true }
                    } else if !tv.session.connected {
                        Button("再接続") { Task { await tv.connect() } }
                            .disabled(tv.session.connecting)
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
                    if let problem = model.tvHost?.problem { Text(problem) }
                }
                .confirmationDialog("テレビを外しますか？", isPresented: $removing, titleVisibility: .visible) {
                    // What could not be taken away is said in the footer above, which reads the television's
                    // line.
                    Button("外す", role: .destructive) { Task { await model.takeTheTelevisionAway() } }
                } message: {
                    Text("この iPhone から、テレビのアドレスと登録を消します。テレビ側の登録済みの機器の一覧には残るので、"
                         + "テレビの設定から消してください。"
                         + (waiting > 0 ? "\nこのテレビ宛の送信待ちの予約 \(waiting) 件は、送らずに削除します。" : ""))
                }
            } else if !model.demo {
                Section {
                    Button("テレビを追加") { registering = true }
                } header: {
                    Text("テレビ")
                } footer: {
                    Text("ソニーのテレビを登録します。登録のときに、テレビの画面に表示される 4 桁の番号を入力します。")
                }
            }
        }
        .sheet(isPresented: $registering) { TVRegisterSheet(host: model.tv?.host ?? "") }
    }

    private func state(of tv: DeviceLink) -> String {
        if model.tvDriver?.facts.needsPairing == true { return "登録が必要です" }
        if tv.session.connecting { return "接続しています" }
        if tv.session.connected { return "接続済み" }
        return tv.session.gaveUp ? "応答がありません" : "接続していません"
    }

    private static func describe(_ storage: TVStorage) -> String {
        guard storage.mounted else { return "つながっていません" }
        guard let free = storage.freeMB, let total = storage.totalMB else { return "つながっています" }
        return "残り \(Format.gigabytes(free * 1_000_000)) / \(Format.gigabytes(total * 1_000_000))"
    }
}

/// Adding a television, or registering with it again: its address, and then the PIN it shows on its screen.
///
/// The PIN appears only when the television is on and showing something -- in standby it says nothing to look
/// at, and once it did not appear while the television was on either -- so a television in standby is asked to be
/// turned on first, and the PIN step says what to do when none appears.
struct TVRegisterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: String
    @State private var askingForPIN = false
    @State private var pin = ""
    @State private var working = false
    @State private var message: String?

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
                    .disabled(askingForPIN)
                } footer: {
                    Text("テレビと同じ Wi-Fi につないだ iPhone から登録します。")
                }
                if askingForPIN {
                    Section {
                        TextField("4 桁の番号", text: $pin)
                            .keyboardType(.numberPad)
                    } footer: {
                        Text("テレビの画面に表示された 4 桁の番号を入力してください。番号が表示されないときは、"
                             + "テレビで放送を映してから、最初からやり直してください。")
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button(askingForPIN ? "登録する" : "テレビに接続") { Task { await next() } }
                        .disabled(working || !RecorderAddress.isUsable(tidied) || (askingForPIN && pin.count != 4))
                    if working { ProgressView() }
                }
            }
            .navigationTitle("テレビを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    private var tidied: String { RecorderAddress.tidy(host).host }

    private func next() async {
        // A second tap before the button is drawn disabled would send the whole of it again.
        guard !working else { return }
        working = true
        defer { working = false }
        message = nil
        if askingForPIN {
            switch await model.registerTV(at: tidied, pin: pin) {
            case .registered: dismiss()
            case .pinNeeded:
                pin = ""
                message = "登録できませんでした。テレビの画面の番号を確かめて、もう一度入力してください。"
            case .failed(let text): message = text
            }
            return
        }
        switch await model.findTV(at: tidied) {
        case .nothing:
            message = "応答がありません。アドレスと、テレビがネットワークにつながっていることを確かめてください。"
        case .notATelevision:
            message = "このアドレスの機器は、テレビとして応答しませんでした。"
        case .standby:
            message = "テレビの電源が切れています。テレビの電源を入れて、放送を映してから、もう一度お試しください。"
        case .on:
            switch await model.registerTV(at: tidied, pin: nil) {
            case .pinNeeded: askingForPIN = true
            case .registered: dismiss()
            case .failed(let text): message = text
            }
        }
    }
}
