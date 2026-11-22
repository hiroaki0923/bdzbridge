import Foundation
import Observation
import RecBridgeModel
import RecorderKit

/// The screen where a recorder is chosen, as the iOS app's tutorial chooses one: the steps, レコーダーとテレビを探す, a
/// recorder the search found, an address typed, or the demo; and a television the search found, registered over it.
/// What it holds back and when it is over are the model's (`WelcomeState`); its words, but three, are `Tutorial`'s.
public struct DevicesScreen: Sendable {
    /// Whether no recorder or television has been set up: the app opens on this screen then.
    public var welcomes: Bool
    /// The close button's words: あとで設定 while nothing is set up, 閉じる after.
    public var closeLabel: String
    /// Whether the search holds its button with its spinner (`searching`), whether it is held at all (`searchHeld`),
    /// and how far it has got (`searched` of `toSearch`, both 0 when none runs), as the settings say it
    /// (`searchingLine`, `SettingsWords.searchingLine`).
    public var searching: Bool
    public var searchHeld: Bool
    public var searched: Int64
    public var toSearch: Int64
    public var searchingLine: String
    /// What is said under the button while local network privacy stands in the way of what the reader wants, or
    /// nothing.
    public var permissionNotice: String
    /// What the search came to, `failed` in red, then the line and the causes the iOS app puts under it.
    public var outcome: String
    public var outcomeFailed: Bool
    public var outcomeNote: String
    public var causes: [String]
    /// The recorder's line while the app works on it, and what went wrong with it.
    public var busy: String
    public var problem: String
    public var recorders: [FoundRecorder]
    /// The televisions the search found, which wait while a recorder chosen here is being connected to (`choosing`),
    /// and what is said under them, as the settings say it (`FoundTelevision.footer`).
    public var televisions: [FoundTelevision]
    public var televisionsFooter: String
    public var choosing: Bool
    /// Whether the recorder in play may be changed now: what the rows wait for.
    public var canChoose: Bool
    /// Whether the address field is shown, what is in it, how many times the model has set it to something else
    /// itself (`hostSet`: the screen takes the model's text when the count moves), and what is said under it
    /// (`addressWarning` in red).
    public var typing: Bool
    public var typedHost: String
    public var hostSet: Int64
    public var addressNote: String
    public var addressWarning: Bool
    /// このアドレスに接続 and サンプルデータで試す are held.
    public var connectHeld: Bool
    public var demoHeld: Bool
    /// The demo is on.
    public var demo: Bool
    /// A recorder chosen here has answered: the screen has done its work and closes, as the tutorial does.
    public var done: Bool
    /// The tutorial's words that name no device and no system question (`Tutorial`).
    public var tutorial: TutorialText
}

/// What `Tutorial` says, for the screen to lay out beside its own three sentences.
public struct TutorialText: Sendable {
    public var heading: String
    public var step1Title: String
    public var step1Detail: String
    public var step2Detail: String
    public var step3Title: String
    public var step4Title: String
    public var step4Detail: String
    public var addressFooter: String
    /// The button that shows the address field.
    public var typeAddressLabel: String
    public var demoFooter: String

    static let all = TutorialText(
        heading: Tutorial.heading, step1Title: Tutorial.step1Title,
        step1Detail: Tutorial.step1Detail, step2Detail: Tutorial.step2Detail, step3Title: Tutorial.step3Title,
        step4Title: Tutorial.step4Title, step4Detail: Tutorial.step4Detail, addressFooter: Tutorial.addressFooter,
        typeAddressLabel: Tutorial.typeAddressLabel, demoFooter: Tutorial.demoFooter)
}

public struct FoundRecorder: Sendable {
    public var host: String
    /// The product, as the row's first line.
    public var name: String
    /// `192.0.2.10 · BDZ-FBT4100 · 番組表あり`.
    public var details: String
    public var inUse: Bool

    /// As the tutorial and the settings list it (`FoundRecorderRow`).
    init(_ found: RecorderDescription, inUse: Bool) {
        host = found.host
        name = found.product
        details = SettingsWords.foundRecorderDetails(found)
        self.inUse = inUse
    }
}

/// The tutorial's state and how many times the model has set its address field to something else itself, in a box the
/// screen is read through, so that a state replaced as the screen closes is read like any change.
@MainActor @Observable
final class Opening {
    private(set) var state: WelcomeState
    private(set) var hostSet: Int64 = 0
    let model: AppModel

    init(_ model: AppModel) {
        self.model = model
        state = WelcomeState(model: model)
    }

    /// Does `change`, which may set the field, and counts it if it did, in the same turn: a keystroke then never comes
    /// between the setting and the count, to be kept over what the model set.
    func counting(_ change: () -> Void) {
        let host = state.typedHost
        change()
        if state.typedHost != host { hostSet += 1 }
    }

    /// Each opening starts clean, as each iOS presentation does; the old one ends its search.
    func renew() {
        state.closed()
        state = WelcomeState(model: model)
        hostSet += 1
    }
}

public final class DevicesWindow: Sendable {
    let model: AppModel
    private let opening: Opening
    private let shown: Watched<DevicesScreen>

    @MainActor
    init(_ model: AppModel) {
        self.model = model
        let opening = Opening(model)
        self.opening = opening
        shown = Watched { DevicesWindow.screen(model, opening) }
    }

    public func read() async -> DevicesScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// Looks through the subnet for a recorder and a television, both kinds at once, unless something holds the button.
    public func search() async {
        await MainActor.run { opening.state.search() }
    }

    /// Connects to `host`, a recorder the search found. The screen closes once the recorder has answered, in the middle
    /// of the connect: the reservations and the guide are read after that, and the screens behind can show them coming
    /// (`WelcomeState.take`). Nothing while the model holds the recorder.
    public func choose(_ host: String) async {
        let state = await MainActor.run { opening.model.canChangeRecorder ? opening.state : nil }
        await state?.take(host)
    }

    /// IP アドレスを直接入力.
    public func showAddress() async {
        await MainActor.run { opening.state.typing = true }
    }

    /// What the reader typed into the address field: `seen` is the field's count (`hostSet`) the screen had taken when
    /// it was typed. Typed over a value the model has replaced since, it is dropped, as the screen drops it for the
    /// model's when the count moves.
    public func typeHost(_ text: String, seen: Int64) async {
        await MainActor.run { if seen == opening.hostSet { opening.state.typedHost = text } }
    }

    /// このアドレスに接続, which goes by what was typed and so comes after the keystrokes before it. Answers once the
    /// field is written back, as the iOS button's task goes on by itself; nothing while the button is held.
    public func connectTyped() async {
        await MainActor.run {
            let state = opening.state
            guard !state.holdsConnect else { return }
            opening.counting { state.connectTyped() }
        }
    }

    /// The screen has closed: a search under way ends with it, and the next opening starts clean.
    public func closed() async {
        await MainActor.run { opening.renew() }
    }

    /// The demo's invented recorder and guide, in a database of their own; nothing while the button is held.
    public func enterDemo() async {
        let state = await MainActor.run { opening.state.holdsDemo ? nil : opening.state }
        await state?.enterDemo()
    }

    /// Puts back what was there before the demo, and deletes the demo's guide.
    public func leaveDemo() async {
        await model.leaveDemo()
    }

    @MainActor
    private static func screen(_ model: AppModel, _ opening: Opening) -> DevicesScreen {
        let state = opening.state
        let outcome = model.scanOutcome
        let progress = state.progress
        let note = state.tidied.note
        return DevicesScreen(
            welcomes: model.welcomes, closeLabel: state.closeLabel, searching: state.searching,
            searchHeld: state.holdsSearch, searched: Int64(progress?.done ?? 0), toSearch: Int64(progress?.total ?? 0),
            searchingLine: progress.map(SettingsWords.searchingLine) ?? "",
            permissionNotice: state.showsPermissionNotice ? LocalNetwork.accessNotAllowed : "",
            outcome: outcome?.text ?? "", outcomeFailed: outcome?.failed ?? false,
            outcomeNote: outcome?.noRecorderBeside ?? "", causes: outcome?.causes ?? [],
            busy: model.busy ?? "", problem: model.problem(for: .recorder)?.asABody ?? "",
            recorders: model.found.map { FoundRecorder($0, inUse: model.inUse($0)) },
            televisions: FoundTelevision.all(model), televisionsFooter: FoundTelevision.footer(model),
            choosing: state.holdsTelevisions,
            canChoose: !state.holdsRecorders, typing: state.typing, typedHost: state.typedHost,
            hostSet: opening.hostSet, addressNote: note?.text ?? "", addressWarning: note?.warning ?? false,
            connectHeld: state.holdsConnect, demoHeld: state.holdsDemo, demo: model.demo, done: state.done,
            tutorial: TutorialText.all)
    }
}
