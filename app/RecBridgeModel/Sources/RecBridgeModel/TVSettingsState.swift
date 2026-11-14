import Foundation
import Observation
import RecorderKit

/// The television's part of the settings as the reader works it, once one is added: how its link stands and what is
/// offered to bring it back, the helper's registration, and テレビを外す with its question. The screen lays it out,
/// with what the television says of itself (`AppModel.tvDriver`), and hands this what is pressed.
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

    /// The question.
    public static let removalQuestion = "テレビを外しますか？"

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
