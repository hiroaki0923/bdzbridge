import Foundation
import Observation
import RecBridgeModel
import RecorderKit

// The television's screens, as the iOS app has them: the sheet that adds a television or registers with it again, the
// helper's sheet, the television's part of the settings, and the televisions a search found. What each offers, holds
// back and says is the model's (`TVRegisterState`, `HelperRegisterState`, `TVSettingsState`, and `SettingsWords` for
// the televisions found), and each window hands over its screen's own words with what it reads.

/// The sheet that adds a television, or registers with it again (`TVRegisterSheet` on iOS).
public struct TVRegisterScreen: Sendable {
    /// テレビを追加, or テレビを登録 for a registration again.
    public var title: String
    /// The address field's label, what it shows while empty, and what is said under it; and what the PIN field shows
    /// while empty (`TVRegisterState.hostLabel` and the rest).
    public var hostLabel: String
    public var hostPlaceholder: String
    public var hostNote: String
    public var pinPlaceholder: String
    /// The address field as the state has it, which the screen's field starts at: the state never sets it itself.
    public var typedHost: String
    /// Whether the address field is held: once the PIN is asked for, and while a step is under way.
    public var addressHeld: Bool
    /// Whether the PIN is asked for, the field as the model has it, and how many times the model has set it itself
    /// -- emptied it, a PIN turned down -- for the screen to take the model's when the count moves.
    public var askingForPIN: Bool
    public var pin: String
    public var pinSet: Int64
    public var pinNote: String
    /// What keeps the app off the local network at the address, said in place of a wait; or what the last step said.
    public var turnedAway: String
    public var message: String
    /// テレビに接続 or 登録する, whether it is held, and whether a step is shown under way.
    public var pressLabel: String
    public var pressHeld: Bool
    public var working: Bool
    /// Registered: the sheet closes.
    public var done: Bool
}

/// A field of a sheet's state as typed on Android, beside the state, for one the state may set itself while the reader
/// types: how many times it has. The state's value is looked at as each keystroke comes and as the screen is made, and
/// one that is not what was last typed is the state's own: counted then, in the turn it is seen, so that a keystroke
/// typed over the value before it is dropped, as the screen drops it for the state's when the count moves. The
/// settings count their fields around the calls that set them (`Typing`); the PIN is emptied inside the state's own
/// step, which no call of the window's wraps, so it is counted as it is seen.
@MainActor
final class SetByTheState {
    private var last: String
    private(set) var count: Int64 = 0

    init(_ value: String) {
        last = value
    }

    /// The state's value now.
    func look(at value: String) {
        if value != last {
            last = value
            count += 1
        }
    }

    /// Whether a keystroke typed over the count `seen` is to be taken: once taken, it is what was last typed.
    func takes(_ typed: String, seen: Int64, now value: String) -> Bool {
        look(at: value)
        guard seen == count else { return false }
        last = typed
        return true
    }
}

public final class TVRegisterWindow: Sendable {
    let register: TVRegisterState
    private let pin: SetByTheState
    private let shown: Watched<TVRegisterScreen>
    private let follows = Follows()

    @MainActor
    init(_ register: TVRegisterState) {
        self.register = register
        let pin = SetByTheState(register.pin)
        self.pin = pin
        shown = Watched { TVRegisterWindow.screen(register, pin) }
    }

    public func read() async -> TVRegisterScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { follows.add(shown.watch(listener)) }

    /// The sheet is up: opened for a television a search found, it goes on to it, once.
    public func appeared() async {
        await MainActor.run { register.appeared() }
    }

    /// What the reader typed into the address field, while it is not held. The state never sets it itself.
    public func typeHost(_ text: String) async {
        await MainActor.run { if !register.holdsTheAddress { register.typedHost = text } }
    }

    /// What the reader typed into the PIN field, over the count `seen` (`TVRegisterScreen.pinSet`).
    public func typePIN(_ text: String, seen: Int64) async {
        await MainActor.run { if pin.takes(text, seen: seen, now: register.pin) { register.pin = text } }
    }

    /// テレビに接続, or 登録する: nothing while it is held, as the iOS button is drawn disabled.
    public func press() async {
        await MainActor.run { if !register.holdsThePress { register.press() } }
    }

    /// The sheet has gone: its step ends, and what the window follows for it.
    public func closed() async {
        await MainActor.run { register.closed() }
        follows.end()
    }

    @MainActor
    private static func screen(_ register: TVRegisterState, _ pin: SetByTheState) -> TVRegisterScreen {
        pin.look(at: register.pin)
        return TVRegisterScreen(
            title: register.title, hostLabel: TVRegisterState.hostLabel,
            hostPlaceholder: TVRegisterState.hostPlaceholder, hostNote: TVRegisterState.hostNote,
            pinPlaceholder: TVRegisterState.pinPlaceholder,
            typedHost: register.typedHost, addressHeld: register.holdsTheAddress, askingForPIN: register.askingForPIN,
            pin: register.pin, pinSet: pin.count, pinNote: register.pinNote,
            // Android's way to the permission comes with the permission itself.
            turnedAway: register.turnedAway ? LocalNetwork.accessNotAllowed : "",
            message: register.message?.asABody ?? "", pressLabel: register.pressLabel,
            pressHeld: register.holdsThePress, working: register.showsWorking, done: register.done)
    }
}

/// The sheet that registers with the helper on the television (`HelperRegisterSheet` on iOS).
public struct HelperRegisterScreen: Sendable {
    /// The sheet's words (`HelperRegisterState.title` and the rest): its title, what the code field shows while empty,
    /// the two sentences under it, the link with where it goes, and the button.
    public var title: String
    public var codePlaceholder: String
    public var codeNote: String
    public var instructionsNote: String
    public var instructionsLink: String
    public var instructionsURL: String
    public var pressLabel: String
    public var pressHeld: Bool
    public var working: Bool
    public var message: String
    public var done: Bool
}

public final class HelperRegisterWindow: Sendable {
    let helper: HelperRegisterState
    private let shown: Watched<HelperRegisterScreen>
    private let follows = Follows()

    @MainActor
    init(_ helper: HelperRegisterState) {
        self.helper = helper
        shown = Watched {
            HelperRegisterScreen(title: HelperRegisterState.title, codePlaceholder: HelperRegisterState.codePlaceholder,
                                 codeNote: HelperRegisterState.codeNote,
                                 instructionsNote: HelperRegisterState.instructionsNote,
                                 instructionsLink: HelperRegisterState.instructionsLink,
                                 instructionsURL: HelperRegisterState.instructionsURL,
                                 pressLabel: HelperRegisterState.pressLabel, pressHeld: helper.holdsThePress,
                                 working: helper.working, message: helper.message?.asABody ?? "", done: helper.done)
        }
    }

    public func read() async -> HelperRegisterScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { follows.add(shown.watch(listener)) }

    /// What the reader typed. The state never sets it itself.
    public func typeCode(_ text: String) async {
        await MainActor.run { helper.code = text }
    }

    /// 登録する: nothing while it is held.
    public func press() async {
        await MainActor.run { if !helper.holdsThePress { helper.press() } }
    }

    public func closed() async {
        follows.end()
    }
}

/// The television's part of the settings (`TVSection` on iOS): with one added, what it says of itself, how its link
/// stands, what brings it back, the helper, and テレビを外す with its question; with none, the way to add one. In the
/// part's words (`TVSettingsState.heading` and the rest), which come with each read of the settings.
public struct TelevisionPart: Sendable {
    public var heading: String
    public var added: Bool
    /// 機種, IP アドレス, 状態 and the USB disk, as far as the television has said them.
    public var facts: [Fact]
    /// 対応状況を調べる.
    public var capabilitiesLabel: String
    /// 登録する, or 再接続 in its place and whether it is held.
    public var registerLabel: String
    public var offersRegistering: Bool
    public var reconnectLabel: String
    public var offersReconnect: Bool
    public var reconnectHeld: Bool
    /// The helper's registration, where there is a helper to register with: the label and its value, and the button
    /// that forgets it or the one that registers.
    public var offersTheHelper: Bool
    public var helperLabel: String
    public var helperShown: String
    public var helperRegistered: Bool
    public var forgetHelperLabel: String
    public var registerHelperLabel: String
    /// テレビを外す, whether it is held, and its question while it is up, with its two buttons: 外す, and the one that
    /// closes it, which the iOS question has of the system.
    public var removeLabel: String
    public var removeHeld: Bool
    public var asksToRemove: Bool
    public var removalQuestion: String
    public var removalMessage: String
    public var confirmRemovingLabel: String
    public var cancelRemovingLabel: String
    /// Why 外す left the television in place, and what went wrong with it, in red under the part.
    public var footer: String
    /// With none added, the way to add one by its address, and what is said under it, in the demo or out of it.
    public var addLabel: String
    public var noTelevisionFooter: String
}

extension TelevisionPart {
    @MainActor init(_ model: AppModel, _ television: TVSettingsState) {
        var facts: [Fact] = []
        if let tv = model.tv {
            if let name = television.modelName { facts.append(Fact(label: TVSettingsState.modelLabel, value: name)) }
            facts.append(Fact(label: TVSettingsState.hostLabel, value: tv.host))
            if let standing = television.standing {
                facts.append(Fact(label: TVSettingsState.standingLabel, value: standing))
            }
            if let storage = television.storageLine {
                facts.append(Fact(label: TVSettingsState.storageLabel, value: storage))
            }
        }
        self.init(heading: TVSettingsState.heading, added: model.tv != nil, facts: facts,
                  capabilitiesLabel: TVSettingsState.capabilitiesLabel, registerLabel: TVSettingsState.registerLabel,
                  offersRegistering: television.offersRegistering, reconnectLabel: TVSettingsState.reconnectLabel,
                  offersReconnect: television.offersReconnect, reconnectHeld: television.holdsReconnect,
                  offersTheHelper: television.offersTheHelper, helperLabel: TVSettingsState.helperLabel,
                  helperShown: television.helperShown, helperRegistered: television.helperRegistered,
                  forgetHelperLabel: TVSettingsState.forgetHelperLabel,
                  registerHelperLabel: TVSettingsState.registerHelperLabel, removeLabel: TVSettingsState.removeLabel,
                  removeHeld: television.holdsRemoving, asksToRemove: television.asksToRemove,
                  removalQuestion: TVSettingsState.removalQuestion, removalMessage: television.removalMessage,
                  confirmRemovingLabel: TVSettingsState.confirmRemovingLabel,
                  cancelRemovingLabel: SheetWords.cancelLabel, footer: television.footer ?? "",
                  addLabel: TVSettingsState.addLabel,
                  noTelevisionFooter: TVSettingsState.noTelevisionFooter(inDemo: model.demo))
    }
}

/// One television a search found (`FoundTelevisionRow` on iOS): its name (`SettingsWords.foundTelevisionName`), its
/// address, whether it is the one added, and whether a tap registers it -- while no television is added. The card's
/// heading and what a row says at its end are kept from the model's start (`SettingsWordsText`); what is said under
/// the card comes with the read of the screen it is on (`televisionsFooter`).
public struct FoundTelevision: Sendable {
    public var host: String
    public var name: String
    public var inUse: Bool
    public var registers: Bool
}

extension FoundTelevision {
    @MainActor static func all(_ model: AppModel) -> [FoundTelevision] {
        model.foundTelevisions.map {
            FoundTelevision(host: $0.host, name: SettingsWords.foundTelevisionName($0.model), inUse: model.inUse($0),
                            registers: model.canAddAFoundTelevision)
        }
    }

    /// What is said under the televisions found, in the tutorial and the settings alike.
    @MainActor static func footer(_ model: AppModel) -> String {
        SettingsWords.foundTelevisionsFooter(registers: model.canAddAFoundTelevision)
    }
}
