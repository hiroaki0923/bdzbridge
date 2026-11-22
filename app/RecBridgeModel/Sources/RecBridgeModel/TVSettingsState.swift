import Foundation
import Observation
import RecorderKit

/// The television's part of the settings as the reader works it, once one is added: what the television says of
/// itself, how its link stands and what is offered to bring it back, the helper's registration, and テレビを外す with
/// its question; with none, the way to add one. The screen lays it out in the part's words, and hands this what is
/// pressed.
@MainActor
@Observable
public final class TVSettingsState {
    @ObservationIgnored private let model: AppModel

    /// Whether 外す's question is up.
    public private(set) var asksToRemove = false
    /// How many reservations wait for the television, read as the question goes up, for it to say and for 外す to be
    /// held to. Nil when they could not be counted.
    private var waiting: Int?

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: - the part's words

    /// The section's heading, the labels of what the television says of itself and of how its link stands, the way to
    /// what it speaks, and the buttons. Where the recorder's part has the same label or button in the same place, the
    /// word is the recorder's part's.
    public static let heading = "テレビ"
    public static let productLabel = RecorderSettingsState.productLabel
    public static let hostLabel = RecorderSettingsState.hostLabel
    public static let standingLabel = RecorderSettingsState.standingLabel
    public static let capabilitiesLabel = "対応状況を調べる"
    public static let storageLabel = "USB ハードディスク"
    public static let registerLabel = "登録する"
    public static let reconnectLabel = RecorderSettingsState.reconnectLabel
    public static let helperLabel = "番組表（ヘルパー）"
    public static let forgetHelperLabel = "ヘルパーの登録を解除"
    public static let registerHelperLabel = "ヘルパーに登録"
    public static let removeLabel = "テレビを外す"

    /// With no television, the way to add one by its address.
    public static let addLabel = "アドレスを入力して追加"

    /// What is said under the part with no television: in the demo, that the invented one can be added and goes with
    /// the demo.
    public static func noTelevisionFooter(inDemo: Bool) -> String {
        inDemo
            ? "サンプルデータでは、架空のテレビを追加して試せます。"
                + "サンプルを終了すると、架空のテレビも消えます。"
            : "テレビは、「レコーダーとテレビを探す」で探せます。見つからないときは、テレビの IP アドレスを"
                + "入力して追加できます。登録のときに、テレビの画面に表示される 4 桁の番号を入力します。"
    }

    // MARK: - what the television says of itself

    /// 機種: the model, as the television gave it; nil until it has said.
    public var productName: String? { model.tvDriver?.facts.model }

    /// USB ハードディスク: the disk it records to, as `Format.storage` words a disk -- how full, or whether it is
    /// there --; nil while the television has not said, as an older one never does.
    public var storageLine: String? {
        model.tvDriver?.facts.storage.map {
            Format.storage(mounted: $0.mounted, freeBytes: $0.freeBytes, totalBytes: $0.totalBytes, on: .tv)
        }
    }

    // MARK: - the link

    /// 状態: how the link to the television stands, in the words the recorder's part uses for its own.
    public var standing: String? {
        model.tv.map { $0.session.standing(needsPairing: needsPairing) }
    }

    /// 登録する, for a television that answers but wants the app registered with it again: nothing can be asked of it
    /// until it is. It opens the sheet that registers, for the television's own address.
    public var offersRegistering: Bool { needsPairing }

    /// 再接続, in its place, for a television the app is not connected to.
    public var offersReconnect: Bool { !needsPairing && model.tv?.session.connected == false }

    /// 再接続 is held while a connect is under way.
    public var holdsReconnect: Bool { model.tv?.session.connecting ?? true }

    /// 再接続.
    public func reconnect() async {
        await model.tv?.connect()
    }

    private var needsPairing: Bool { model.tvDriver?.facts.needsPairing == true }

    // MARK: - the helper

    /// Whether there is a helper to register with: one goes with a television added outside the demo.
    public var offersTheHelper: Bool { model.tvHelper != nil }

    /// Whether the app holds a registration with it: ヘルパーの登録を解除 then, ヘルパーに登録 otherwise.
    public var helperRegistered: Bool { model.helperRegistered }

    /// 番組表（ヘルパー） as a value: whether the app holds a registration with it.
    public var helperShown: String { helperRegistered ? "登録済み" : "未登録" }

    /// ヘルパーの登録を解除.
    public func forgetHelper() {
        model.forgetHelper()
    }

    // MARK: - テレビを外す

    /// テレビを外す is held while the television works: a sending that is out may be making a reservation that the
    /// question would say is deleted unsent.
    public var holdsRemoving: Bool { model.isBusy(for: .tv) }

    /// テレビを外す: what waits for the television is counted, and the question goes up.
    public func remove() async {
        waiting = await model.waitingForTheTelevision()
        asksToRemove = true
    }

    /// The question, and the button under it that takes the television away.
    public static let removalQuestion = "テレビを外しますか？"
    public static let confirmRemovingLabel = "外す"

    /// What the question says: what goes from this phone and what stays on the television, and what goes with it of
    /// the reservations waiting for the television -- how many are deleted unsent, and nothing with none. With no count
    /// to give it says as much without one, and not nothing: there may be some, and 外す deletes them if they can be
    /// deleted by then.
    public var removalMessage: String {
        let goes: String
        if let waiting {
            goes = waiting > 0 ? "\nこのテレビ宛の送信待ちの予約 \(waiting) 件は、送らずに削除します。" : ""
        } else {
            goes = "\nこのテレビ宛の送信待ちの予約は、送らずに削除します。"
        }
        return "この端末から、テレビのアドレスと登録を消します。テレビ側の登録済みの機器の一覧には残るので、"
            + "テレビの設定から消してください。" + goes
    }

    /// 外す, under the question: handed the count the question gave, so that nothing is taken away over another. Why
    /// it could not be taken away is said under the section (`footer`).
    public func confirmRemoving() async {
        asksToRemove = false
        _ = await model.takeTheTelevisionAway(counted: waiting)
    }

    /// The question has been closed without 外す.
    public func removalClosed() {
        asksToRemove = false
    }

    // MARK: - what is said under it

    /// Why 外す left the television in place, above what went wrong with the television: both when both stand.
    public var footer: String? {
        let lines = [model.whyTheTelevisionStays, model.problem(for: .tv)].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n").asABody
    }
}
