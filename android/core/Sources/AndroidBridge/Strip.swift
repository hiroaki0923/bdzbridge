import Foundation
import RecBridgeModel
import RecorderKit

/// The strip at the top of every screen: what the app is doing with a device, or what the reader is to know of
/// now, one thing at a time, chosen and worded by the model with its button (`AppModel.strip`, `Strip.says`,
/// `Strip.offer`), as the iOS strip draws it (`RecorderActivityBar`). The way to the switch that the iOS strip has
/// beside the local network's line is the system's there: Android's way to the permission comes with the permission
/// itself.
public struct StripLine: Sendable {
    /// Which, for its icon: `busy`, `anotherTookOver`, `report`, `demo`, `blocked`, `recorderGaveUp`, `tvNeedsPairing`,
    /// `tvGaveUp` or `tvDiskAway`; nothing when the strip has nothing to say.
    public var kind: String
    public var text: String
    /// Said whole, not cut at three lines: what a sending to a television says can end with what it did to the
    /// other device, the last thing a cut would leave.
    public var inFull: Bool
    /// What its button does (`AppModel.Offer`) -- `close` (the line stays until it is closed), `leaveDemo`,
    /// `reconnect`, `registerTV` (the sheet that registers with the television again, `RecBridgeApp.registerTVAgain`),
    /// `reconnectTV` -- or nothing; its word, and whether it may be pressed now (`AppModel.holds`).
    public var action: String
    public var actionLabel: String
    public var actionEnabled: Bool
}

/// `inSheet` is a sheet's own strip, which leaves out the demo's line, as `recorderActivity(inSheet:)` does on iOS.
public final class StripWindow: Sendable {
    let model: AppModel
    private let inSheet: Bool
    private let shown: Watched<StripLine>

    init(_ model: AppModel, inSheet: Bool = false) {
        self.model = model
        self.inSheet = inSheet
        shown = Watched { StripWindow.line(model, inSheet: inSheet) }
    }

    public func read() async -> StripLine { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// 閉じる: takes down the line this strip shows, when it is one that stays until it is closed (`AppModel.close`).
    public func close() async {
        await MainActor.run {
            if let line = model.strip(inSheet: inSheet) { model.close(line) }
        }
    }

    /// The line's button in words, 終了 or 再接続 to either device, as the model answers it (`AppModel.act(on:)`).
    /// `action` is the one the screen showed: nothing is done once the line offers another, nor while it is held, as
    /// the iOS button is pressed only while it is there and not held. 登録 is a sheet of Kotlin's.
    public func press(_ action: String) async {
        let model = self.model
        let inSheet = self.inSheet
        await MainActor.run { () -> Task<Void, Never>? in
            guard let offer = model.strip(inSheet: inSheet)?.offer, Self.code(offer) == action else { return nil }
            return pressed(!model.holds(offer)) { await model.act(on: offer) }
        }?.value
    }

    /// What a button is called to Kotlin. Written out, as the lines' kinds are below: a name changed in the model
    /// changes nothing Kotlin goes by, and a button added there does not build until it has a name here.
    private static func code(_ offer: AppModel.Offer) -> String {
        switch offer {
        case .close: "close"
        case .leaveDemo: "leaveDemo"
        case .reconnect: "reconnect"
        case .search: "search"
        case .registerTV: "registerTV"
        case .reconnectTV: "reconnectTV"
        }
    }

    @MainActor
    private static func line(_ model: AppModel, inSheet: Bool) -> StripLine {
        guard let chosen = model.strip(inSheet: inSheet) else {
            return StripLine(kind: "", text: "", inFull: false, action: "", actionLabel: "", actionEnabled: true)
        }
        let offer = chosen.offer
        return StripLine(kind: kind(chosen), text: chosen.says, inFull: inFull(chosen), action: offer.map(code) ?? "",
                         actionLabel: offer?.label ?? "", actionEnabled: offer.map { !model.holds($0) } ?? true)
    }

    private static func kind(_ line: AppModel.Strip) -> String {
        switch line {
        case .busy: "busy"
        case .anotherTookOver: "anotherTookOver"
        case .report: "report"
        case .demo: "demo"
        case .blocked: "blocked"
        case .recorderGaveUp: "recorderGaveUp"
        case .tvNeedsPairing: "tvNeedsPairing"
        case .tvGaveUp: "tvGaveUp"
        case .tvDiskAway: "tvDiskAway"
        }
    }

    private static func inFull(_ line: AppModel.Strip) -> Bool {
        if case .report(_, let inFull) = line { return inFull }
        return false
    }
}
