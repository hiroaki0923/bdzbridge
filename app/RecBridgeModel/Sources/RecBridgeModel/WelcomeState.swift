import Foundation
import Observation
import RecorderKit

/// The tutorial as the reader works it: the search and what holds its button, the address typed, the recorder chosen
/// and whether it has answered, and the demo. The screen lays it out, hands this what is typed and pressed, and
/// tells it when it closes; what the buttons wait for and when the tutorial is over are here, where a test can
/// hold them. Its words are `Tutorial`'s.
///
/// Choosing a recorder ends the tutorial as soon as it answers, which is in the middle of the connect. The
/// reservations and the guide are still to be read, the longest wait in the app on a first run, and the screens
/// behind this one can show them arriving.
///
/// The connect is not split to get there: the reservations and the lists are read inside it, with `connecting` on,
/// so that no second connect starts beside them, and the guide is fetched after it, by a refresh that holds a
/// second connect off in its own right (`RecorderHost.holdsOffConnect`). It says instead that it has reached the
/// recorder (`timesAttached`), and the count taken at the press tells that answer from a connection that was
/// already up, as it is when the tutorial is opened again from the settings.
@MainActor
@Observable
public final class WelcomeState {
    @ObservationIgnored private let model: AppModel

    /// Whether the address field is shown.
    public var typing = false
    /// The address field, as typed.
    public var typedHost = ""
    /// The model's `timesAttached` when a recorder was chosen here, kept while that choice has yet to be answered.
    private var chosenAt: Int?

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: - what the screen shows

    /// The address field, tidied: what connecting would use, and what is said under the field (`note`).
    public var tidied: RecorderAddress.Typed { RecorderAddress.tidy(typedHost) }

    /// レコーダーとテレビを探す is held while a scan is under way and while the recorder works.
    public var holdsSearch: Bool { model.holdsTheSearchButton }

    /// The search holds its button, with its small spinner.
    public var searching: Bool { model.scanHoldsTheButton }

    /// How far the search has got, none while it is held up by the local network permission.
    public var progress: (done: Int, total: Int)? { model.searchProgress }

    /// Whether local network privacy stands between the reader and what they want: the screen says so under the
    /// button.
    public var showsPermissionNotice: Bool { model.lanBlocked }

    /// The recorders found wait while the recorder in play may not be changed (`AppModel.canChangeRecorder`).
    public var holdsRecorders: Bool { !model.canChangeRecorder }

    /// The televisions found wait while a recorder chosen here is out: its answer closes the tutorial, which would
    /// take a television's registration with it, its number left on the panel for nobody.
    public var holdsTelevisions: Bool { chosenAt != nil }

    /// このアドレスに接続 is held for an address no URL can be built on, and while the recorder in play may not be
    /// changed.
    public var holdsConnect: Bool { !RecorderAddress.isUsable(tidied.host) || !model.canChangeRecorder }

    /// サンプルデータで試す is held while the recorder in play may not be changed.
    public var holdsDemo: Bool { !model.canChangeRecorder }

    /// あとで設定 while nothing is set up; opened again from the settings, or once a television is registered here,
    /// there is nothing to put off, only a screen to leave. Read live, since it changes under the reader when a
    /// television is registered from here.
    public var closeLabel: String { model.welcomes ? "あとで設定" : "閉じる" }

    /// A recorder chosen here has answered: the tutorial has done its work and closes.
    public var done: Bool { chosenAt.map { model.timesAttached > $0 } ?? false }

    // MARK: - the reader's presses

    /// レコーダーとテレビを探す, once, while nothing holds the button.
    public func search() {
        guard !holdsSearch else { return }
        model.scanForDevices()
    }

    /// A recorder the search found, tapped, or an address typed: the app connects to it.
    ///
    /// A connect held up by the local network permission answers later, when the reader allows it; the screen waits
    /// for that. Any other that returns without an answer is over, and the choice with it.
    public func take(_ host: String) async {
        let before = model.timesAttached
        chosenAt = before
        await model.adopt(host: host)
        if model.timesAttached == before, !model.connectBlocked { chosenAt = nil }
    }

    /// このアドレスに接続. The field shows what is saved, so that what was taken off can be seen to be gone: it is
    /// written back at the press, and the connect goes on in the task handed back.
    @discardableResult
    public func connectTyped() -> Task<Void, Never> {
        let host = tidied.host
        typedHost = host
        return Task { await take(host) }
    }

    /// サンプルデータで試す.
    public func enterDemo() async {
        await model.enterDemo()
    }

    /// The tutorial has closed: a scan waiting on the system's question must not outlive the screen that asked it.
    /// A sheet over the tutorial is not its going: the search goes on behind the television's.
    public func closed() {
        model.stopScanning()
    }
}
