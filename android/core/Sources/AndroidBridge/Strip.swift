import Foundation
import RecBridgeModel
import RecorderKit

/// The strip at the top of every screen: what the app is doing with a device, or what the reader is to know of
/// now, one thing at a time, chosen by the model (`AppModel.strip`) and worded as the iOS strip words it
/// (`RecorderActivityBar`).
public struct StripLine: Sendable {
    /// Which: `busy`, `anotherTookOver`, `report`, `demo`, `blocked`, `recorderGaveUp`, `tvNeedsPairing`, `tvGaveUp`
    /// or `tvDiskAway`; nothing when the strip has nothing to say.
    public var kind: String
    public var text: String
    /// Said whole, not cut at three lines: what a sending to a television says can end with what it did to the
    /// other device, the last thing a cut would leave.
    public var inFull: Bool
    /// What its button does -- `close` (the line stays until it is closed), `leaveDemo`, `reconnect`,
    /// `registerTV` (the sheet that registers with the television again, `RecBridgeApp.registerTVAgain`),
    /// `reconnectTV` -- or nothing; and whether it may be pressed now.
    public var action: String
    public var actionEnabled: Bool
}

public final class StripWindow: Sendable {
    let model: AppModel
    private let shown: Watched<StripLine>

    init(_ model: AppModel) {
        self.model = model
        shown = Watched { StripWindow.line(model) }
    }

    public func read() async -> StripLine { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// Closes the line that stays until it is closed: that another recorder took over, or what became of what was
    /// waiting.
    public func close() async {
        await MainActor.run {
            switch model.strip() {
            case .anotherTookOver: model.anotherTookOver = false
            case .report: model.closeQueueReport()
            default: break
            }
        }
    }

    /// 再接続, for the recorder given up on.
    public func reconnect() async {
        await model.connect()
    }

    /// 再接続, for the television given up on.
    public func reconnectTV() async {
        await model.tv?.connect()
    }

    @MainActor
    private static func line(_ model: AppModel) -> StripLine {
        func line(_ kind: String, _ text: String, inFull: Bool = false, action: String = "", enabled: Bool = true)
            -> StripLine {
            StripLine(kind: kind, text: text, inFull: inFull, action: action, actionEnabled: enabled)
        }
        switch model.strip() {
        case nil: return line("", "")
        case .busy(let busy): return line("busy", busy)
        case .anotherTookOver: return line("anotherTookOver", AppModel.anotherTookOverLine, action: "close")
        case .report(let text, let inFull): return line("report", text, inFull: inFull, action: "close")
        // Not while a connect or a job is under way, which `busy` alone does not always show.
        case .demo: return line("demo", "サンプルデータを表示しています", action: "leaveDemo", enabled: model.canChangeRecorder)
        // Android's way to the permission comes with the permission itself.
        case .blocked: return line("blocked", LocalNetwork.accessNotAllowed)
        // Not while a bulk job runs, when a connect is only owed until it ends.
        case .recorderGaveUp:
            return line("recorderGaveUp", "レコーダーの応答がありません", action: "reconnect", enabled: !model.jobRunning)
        // It answers, so it is there; nothing can be asked of it until the app is registered with it again.
        case .tvNeedsPairing: return line("tvNeedsPairing", "テレビの登録が必要です", action: "registerTV")
        case .tvGaveUp: return line("tvGaveUp", "テレビの応答がありません", action: "reconnectTV")
        case .tvDiskAway: return line("tvDiskAway", TVDriver.diskNotFound)
        }
    }
}
