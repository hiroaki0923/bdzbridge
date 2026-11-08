import Foundation
import Observation
import RecBridgeModel
import RecorderKit

/// The settings, as the iOS app's settings screen has them, of what Android has yet: the recorder -- what it says of
/// itself, how the link stands, its address and MAC --, the mode a new reservation starts at, the search and the
/// recorders it found, the guide kept on the phone, the demo, and the app. The television's section, the televisions
/// the search found and the guide's source come with the television's screens; the notifications and the Shortcuts
/// action are the iOS app's own.
public struct SettingsScreen: Sendable {
    /// What the recorder says of itself once connected: 機種, 名前, ファームウェア, 番組表, and its disks.
    public var facts: [Fact]
    /// 状態, once there is an address.
    public var standing: String
    /// The fields as the model has them, and how many times the model has set each itself, rather than taken what was
    /// typed: the screen keeps what the reader types as they type it, and takes the model's when the count moves.
    public var typedHost: String
    public var hostSet: Int64
    public var typedMac: String
    public var macSet: Int64
    /// What is said under the address field, `addressWarning` in red.
    public var addressNote: String
    public var addressWarning: Bool
    /// このアドレスに接続, or 再接続 in its place, and whether each is held.
    public var offersConnect: Bool
    public var connectHeld: Bool
    public var offersReconnect: Bool
    public var reconnectHeld: Bool
    /// 既定の録画モード.
    public var qualities: [Labelled]
    public var quality: String
    /// レコーダーとテレビを探す, whether it is held, and how far the search has got (`searched` of `toSearch`, both 0
    /// when none runs); what it came to, `outcomeFailed` in red, with the line and the causes under it.
    public var searchHeld: Bool
    public var searched: Int64
    public var toSearch: Int64
    public var outcome: String
    public var outcomeFailed: Bool
    public var outcomeNote: String
    public var causes: [String]
    public var recorders: [FoundRecorder]
    /// Whether the recorder in play may be changed now (`AppModel.canChangeRecorder`): what the rows and the demo wait
    /// for.
    public var canChoose: Bool
    /// 保存されている番組表: each broadcasting type's stations and programmes, and when the guide was last fetched.
    public var guide: [Fact]
    public var refreshHeld: Bool
    public var demo: Bool
    public var version: String
    /// The recorder's line while the app works on it, what went wrong with it, and what went wrong with the phone's
    /// own cache.
    public var busy: String
    public var problem: String
    public var phoneProblem: String
}

/// A label and what is said beside it.
public struct Fact: Sendable {
    public var label: String
    public var value: String
}

/// How many times the model has set each of the settings' fields to something else itself, rather than taken what was
/// typed (`SettingsScreen.hostSet`, `macSet`).
@MainActor @Observable
final class Typing {
    var hostSet: Int64 = 0
    var macSet: Int64 = 0

    nonisolated init() {}

    /// Does `change`, which may set the fields, and counts each it set to something else, in the same turn: a keystroke
    /// then never comes between the setting and the count, to be kept over what the model set.
    func counting(_ recorder: RecorderSettingsState, _ change: () -> Void) {
        let host = recorder.typedHost, mac = recorder.typedMac
        change()
        if recorder.typedHost != host { hostSet += 1 }
        if recorder.typedMac != mac { macSet += 1 }
    }
}

/// The mode the settings hold for a new reservation, kept where the iOS screen keeps it, under its key in the model's
/// settings (`DefaultsKey.defaultQuality`), which are touched on the main actor alone, as the model touches them; and
/// here for the screen to be told when it changes.
@MainActor @Observable
final class ChosenQuality {
    @ObservationIgnored let defaults: WrittenDefaults
    private(set) var code: String

    init(_ defaults: WrittenDefaults) {
        self.defaults = defaults
        code = DefaultQuality.current(in: defaults)
    }

    /// One the recorder records in.
    func choose(_ code: String) {
        guard RecorderDriver.recordsIn.contains(code) else { return }
        defaults.set(code, forKey: DefaultsKey.defaultQuality)
        self.code = code
    }
}

public final class SettingsWindow: Sendable {
    let model: AppModel
    let recorder: RecorderSettingsState
    private let quality: ChosenQuality
    private let typing = Typing()
    private let shown: Watched<SettingsScreen>
    private let follows = Follows()

    @MainActor
    init(_ model: AppModel, quality: ChosenQuality, version: String) {
        self.model = model
        let recorder = RecorderSettingsState(model: model)
        let typing = typing
        self.recorder = recorder
        self.quality = quality
        shown = Watched { SettingsWindow.screen(model, recorder, quality, typing, version) }
        // As the iOS screen follows them: `onChange(of: model.mac, initial: true)` and `onChange(of: model.host)`.
        typing.counting(recorder) { recorder.macMoved() }
        follows.add(onChange(of: { model.mac }) { _ in typing.counting(recorder) { recorder.macMoved() } })
        follows.add(onChange(of: { model.host }) { _ in typing.counting(recorder) { recorder.hostMoved() } })
    }

    public func read() async -> SettingsScreen { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    /// The settings have come on screen: an empty address field starts at the saved address.
    public func appeared() async {
        await MainActor.run { typing.counting(recorder) { recorder.appeared() } }
    }

    /// What the reader typed into the address field, and into the MAC field, where the MAC is kept as it is typed:
    /// `seen` is the field's count (`hostSet`, `macSet`) the screen had taken when it was typed. Typed over a value the
    /// model has replaced since, it is dropped, as the screen drops it for the model's when the count moves; kept, the
    /// screen would show the model's value and the model hold the keystroke.
    public func typeHost(_ text: String, seen: Int64) async {
        await MainActor.run { if seen == typing.hostSet { recorder.typedHost = text } }
    }

    public func typeMac(_ text: String, seen: Int64) async {
        await MainActor.run { if seen == typing.macSet { recorder.typedMac = text } }
    }

    // Each press does nothing while the model holds its button back, as the iOS screen's disabled button does, and is
    // begun in the turn that checks it (`pressed`): what Compose shows comes a turn after the model.

    /// このアドレスに接続, and 再接続, which go by what was typed and so come after the keystrokes before them. Each
    /// answers once begun, as the iOS button's task goes on by itself: the connect goes on in the model, and the
    /// keystrokes after it are not held back behind it. The model holds a second press back meanwhile.
    public func connect() async {
        await MainActor.run {
            typing.counting(recorder) {
                _ = pressed(recorder.offersConnect && !recorder.holdsConnect) { await self.recorder.connect() }
            }
        }
    }

    public func reconnect() async {
        await MainActor.run {
            _ = pressed(recorder.offersReconnect && !recorder.holdsReconnect) { await self.recorder.reconnect() }
        }
    }

    /// A recorder the search found, tapped.
    public func choose(_ host: String) async {
        let choosing = await MainActor.run { () -> Task<Void, Never>? in
            var choosing: Task<Void, Never>?
            typing.counting(recorder) { choosing = pressed(model.canChangeRecorder) { await self.recorder.choose(host) } }
            return choosing
        }
        await choosing?.value
    }

    /// 既定の録画モード, one the recorder records in.
    public func chooseQuality(_ code: String) async {
        await MainActor.run { quality.choose(code) }
    }

    /// レコーダーとテレビを探す.
    public func search() async {
        await MainActor.run { if !(model.scanHoldsTheButton || model.busy != nil) { model.scanForDevices() } }
    }

    /// 番組表を更新: what it had to say, for the question that says it, or nothing.
    public func refreshGuide() async -> String {
        let refreshing = await MainActor.run { () -> Task<String?, Never>? in
            guard model.canRefreshGuideByHand else { return nil }
            return Task.immediate { await self.model.refreshGuideByHandFromSource() }
        }
        return (await refreshing?.value ?? nil)?.asABody ?? ""
    }

    /// サンプルデータで試す, and サンプルデータを終了する.
    public func enterDemo() async {
        await MainActor.run { pressed(model.canChangeRecorder && !model.demo) { await self.model.enterDemo() } }?.value
    }

    public func leaveDemo() async {
        await MainActor.run { pressed(model.canChangeRecorder && model.demo) { await self.model.leaveDemo() } }?.value
    }

    /// ご利用上の注意 (`Disclaimer`): its title, what it opens with, its sections -- each heading as the label and its
    /// text as the value --, and the link to the source.
    public func disclaimer() -> DisclaimerText {
        DisclaimerText(title: Disclaimer.title, opening: Disclaimer.opening,
                       sections: Disclaimer.sections.map { Fact(label: $0.heading, value: $0.body) },
                       link: Disclaimer.sourceLink, url: Disclaimer.sourceURL)
    }

    @MainActor
    private static func screen(_ model: AppModel, _ recorder: RecorderSettingsState, _ quality: ChosenQuality,
                               _ typing: Typing, _ version: String) -> SettingsScreen {
        var facts: [Fact] = []
        if let info = model.info {
            facts.append(Fact(label: "機種", value: info.product))
            facts.append(Fact(label: "名前", value: info.friendlyName))
            // empty when the recorder would not say, which another model may not
            if !model.firmware.isEmpty { facts.append(Fact(label: "ファームウェア", value: model.firmware)) }
            facts.append(Fact(label: "番組表", value: info.epgCapable ? "あり" : "なし"))
            facts += AppModel.storageRows(storage: model.storage, usb: model.usbDisk)
                .map { Fact(label: $0.label, value: $0.value) }
        }
        var guide = GuideRefresh.offeredTypes(model.counts).map { broadcasting in
            let counts = model.counts[broadcasting]
            return Fact(label: Codes.broadcastingLabel[broadcasting] ?? broadcasting,
                        value: "\(counts?.channels ?? 0) 局 · \(counts?.programs ?? 0) 番組")
        }
        // Stored the way the recorder writes a time; what the reader wants to know is whether the guide is fresh.
        if let refreshed = model.counts["td"]?.refreshed {
            guide.append(Fact(label: "最終更新", value: RecorderTime.parse(refreshed).map { Format.when($0) } ?? refreshed))
        }
        let note = recorder.tidied.note
        let outcome = model.scanOutcome
        let scanning = model.scanBlocked ? nil : model.scanning
        return SettingsScreen(
            facts: facts, standing: recorder.standing ?? "",
            typedHost: recorder.typedHost, hostSet: typing.hostSet, typedMac: recorder.typedMac, macSet: typing.macSet,
            addressNote: note?.text ?? "", addressWarning: note?.warning ?? false,
            offersConnect: recorder.offersConnect, connectHeld: recorder.holdsConnect,
            offersReconnect: recorder.offersReconnect, reconnectHeld: recorder.holdsReconnect,
            qualities: RecorderDriver.recordsIn.map { Labelled(code: $0, label: Codes.qualityLabel[$0] ?? $0) },
            quality: quality.code,
            searchHeld: model.scanHoldsTheButton || model.busy != nil,
            searched: Int64(scanning?.done ?? 0), toSearch: Int64(scanning?.total ?? 0),
            outcome: outcome?.text ?? "", outcomeFailed: outcome?.failed ?? false,
            outcomeNote: outcome?.noRecorderBeside ?? "", causes: outcome?.causes ?? [],
            recorders: model.found.map { FoundRecorder($0, inUse: model.inUse($0)) },
            canChoose: model.canChangeRecorder,
            guide: guide, refreshHeld: !model.canRefreshGuideByHand, demo: model.demo, version: version,
            busy: model.busy ?? "", problem: model.problem(for: .recorder)?.asABody ?? "",
            phoneProblem: model.phoneProblem?.asABody ?? "")
    }
}

public struct DisclaimerText: Sendable {
    public var title: String
    public var opening: String
    public var sections: [Fact]
    public var link: String
    public var url: String
}

/// Begins `work` now, on the main actor and up to its first wait, if `may` lets it: a press checked and begun in one
/// turn, so that a second press checks what the first has held by then -- a connect under way, a host changed.
@MainActor
func pressed(_ may: Bool, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
    may ? Task.immediate { await work() } : nil
}
