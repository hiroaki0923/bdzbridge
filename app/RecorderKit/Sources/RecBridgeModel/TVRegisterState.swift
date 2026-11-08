import Foundation
import Observation
import RecorderKit

/// The sheet that adds a television, or registers with it again, as the reader works it: its address, and then the PIN
/// the television shows on its screen, the one button that goes on to the next step, and what the sheet says. The
/// screen lays it out, hands this what is typed and pressed, and tells it when it appears and when it closes; the steps
/// themselves are the package's (`TVDriver.register`).
///
/// The PIN appears only when the television is on and showing something -- in standby it says nothing to look at, and
/// once it did not appear while the television was on either -- so a television in standby is asked to be turned on
/// first, and the PIN step says what to do when none appears.
///
/// Opened for a television a scan found (`connectAtOnce`), it goes straight on to テレビに接続 as it appears: the reader
/// tapped the television, and a second tap would only stand between them and its number.
///
/// An address that says nothing because the system keeps the app off the local network is not said to answer nothing:
/// the sheet says what is in the way, as the screens do for the recorder, and goes on by itself once the permission
/// comes (`AppModel.findTV`).
@MainActor
@Observable
public final class TVRegisterState {
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let connectAtOnce: Bool
    /// Opened to register with the television already added, not to add one.
    public let again: Bool

    /// The address field, as typed.
    public var typedHost: String
    /// The PIN field, once the television has been asked to show its PIN.
    public var pin = ""
    /// Whether the television has been asked to put its PIN on its screen, and the sheet asks for it.
    public private(set) var askingForPIN = false
    /// Whether a step is under way.
    public private(set) var working = false
    /// What the last step had to say, under the fields.
    public private(set) var message: String?
    /// The television is registered: the sheet's work is done, and it closes.
    public private(set) var done = false

    /// The step under way, from the button or from the sheet's appearing, kept so that closing the sheet ends it: a
    /// registration is not asked for, nor a number put on a panel, for a sheet that is no longer there. A wait for the
    /// local network permission at the address ends with it (`AppModel.stopFindingTV`).
    @ObservationIgnored private var step: Task<Void, Never>?
    /// Whether the step the sheet's appearing starts has been started: nothing promises that a view appears once, and
    /// the step is not to be sent twice.
    @ObservationIgnored private var begun = false

    /// `host`, the address the field opens on; `connectAtOnce` for a television a scan found, tapped; `again` for a
    /// registration with the television already added.
    public init(model: AppModel, host: String, connectAtOnce: Bool = false, again: Bool = false) {
        self.model = model
        typedHost = host
        self.connectAtOnce = connectAtOnce
        self.again = again
    }

    // MARK: - what the screen shows

    /// テレビを登録 for a registration again, テレビを追加 for a television to add.
    public var title: String { again ? "テレビを登録" : "テレビを追加" }

    /// The address the steps go to: the field, tidied.
    public var tidied: String { RecorderAddress.tidy(typedHost).host }

    /// The address field is held once the PIN is asked for, and while a step is under way, which may wait for the
    /// permission for as long as the reader takes: the PIN goes to the address the field shows, which is to be the one
    /// asked.
    public var holdsTheAddress: Bool { askingForPIN || working }

    /// 登録する once the PIN is asked for, テレビに接続 before.
    public var pressLabel: String { askingForPIN ? "登録する" : "テレビに接続" }

    /// The button is held while a step is under way, for an address no URL can be built on, and for a PIN that is not
    /// four long.
    public var holdsThePress: Bool {
        working || !RecorderAddress.isUsable(tidied) || (askingForPIN && pin.count != 4)
    }

    /// What is said under the PIN field. The demo's television has no panel to show its number on, so the sheet says it.
    public var pinNote: String {
        "テレビの画面に表示された 4 桁の番号を入力してください。番号が表示されないときは、"
            + "テレビで放送を映してから、最初からやり直してください。"
            + (model.demo ? "サンプルのテレビの番号は \(DemoTV.pin) です。" : "")
    }

    /// Whether the system keeps the app off the local network at the address: said in place of the address not
    /// answering, and the sheet goes on by itself once it is allowed.
    public var turnedAway: Bool { model.tvAddressTurnedAway }

    /// Whether the sheet shows that a step is under way: not while it waits for the permission, which the notice says.
    public var showsWorking: Bool { working && !model.tvAddressTurnedAway }

    // MARK: - what the screen tells it

    /// The sheet has appeared: opened for a television a scan found, it goes on to テレビに接続, once.
    public func appeared() {
        guard connectAtOnce, !begun else { return }
        begun = true
        press()
    }

    /// テレビに接続, or 登録する once the PIN is asked for. Held from the press on, in the same turn: a second press
    /// before the step has begun would otherwise start one of its own and take the first's place as the one closing
    /// the sheet ends, leaving the first to go on to the registration -- a number put on the panel for nobody.
    public func press() {
        guard !working else { return }
        working = true
        message = nil
        step = Task { await next() }
    }

    /// The sheet has closed, whichever way: the step under way ends, and so does a wait for the permission.
    public func closed() {
        step?.cancel()
        model.stopFindingTV()
    }

    private func next() async {
        defer { working = false }
        let host = tidied
        let model = model
        // The steps are the package's; closing the sheet cancels the step, after which nothing is registered.
        switch await TVDriver.register(askingForPIN: askingForPIN, pin: pin,
                                       find: { await model.findTV(at: host) },
                                       register: { await model.registerTV(at: host, pin: $0) },
                                       closed: { Task.isCancelled }) {
        case .askForThePIN: askingForPIN = true
        case .askForThePINAgain(let saying):
            pin = ""
            message = saying
        case .registered: done = true
        case .say(let text): message = text
        case .nothing: break
        }
    }
}

/// Registering with the helper on the television, by the six-digit code its screen shows for five minutes, as the reader
/// works the sheet (`AppModel.registerHelper`). The television has been added already; the helper is at its address.
@MainActor
@Observable
public final class HelperRegisterState {
    @ObservationIgnored private let model: AppModel

    /// The code field, as typed.
    public var code = ""
    /// Whether the registration is out.
    public private(set) var working = false
    /// What went wrong with the last, under the field.
    public private(set) var message: String?
    /// Registered: the sheet's work is done, and it closes.
    public private(set) var done = false

    public init(model: AppModel) {
        self.model = model
    }

    /// 登録する is held while the registration is out, and for a code that is not six figures.
    public var holdsThePress: Bool { working || code.count != 6 || !code.allSatisfy(\.isNumber) }

    /// 登録する.
    public func press() {
        guard !working else { return }
        working = true
        message = nil
        Task {
            let said = await model.registerHelper(code: code)
            working = false
            if let said {
                message = said
            } else {
                done = true
            }
        }
    }
}
