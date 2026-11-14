import Foundation
import Observation
import RecorderKit

/// The recorder's part of the settings as the reader works it: its address and its MAC as typed, what connecting
/// offers, and how the link stands. The screen lays it out and hands this what is typed and pressed, and tells it when
/// it appears and when the model moves the address or the MAC by itself; what the fields follow and what the buttons
/// offer are here, where a test can hold them.
@MainActor
@Observable
public final class RecorderSettingsState {
    @ObservationIgnored private let model: AppModel

    /// The address field, as typed.
    public var typedHost = ""

    /// The MAC field, as typed. Kept as the reader types rather than on the return key, because the next thing they do
    /// is tap the connect button, and a MAC that was only half committed cannot wake anything.
    public var typedMac = "" {
        didSet { if typedMac != oldValue { macTyped() } }
    }

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: - what the screen tells it

    /// The screen has appeared: an empty address field starts at the saved address.
    public func appeared() {
        if typedHost.isEmpty { typedHost = model.host }
    }

    /// The app has moved the address by itself, finding the recorder somewhere else, and a field still showing the old
    /// one would offer このアドレスに接続 to take it back there.
    public func hostMoved() {
        typedHost = model.host
    }

    /// The model's MAC has changed, and the field follows it: ending the demo can leave none. A half-typed MAC is left
    /// alone, since it is no MAC and so already agrees with none. Told as the screen first appears as well, which is
    /// how the field starts at the saved MAC.
    public func macMoved() {
        if WakeOnLan.normalise(typedMac) != model.mac { typedMac = model.mac ?? "" }
    }

    private func macTyped() {
        let typed = typedMac.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty { model.forgetMac() } else { model.remember(mac: typed) }
    }

    // MARK: - what the screen shows

    /// 状態: how the link to the recorder stands, in the words the television's section uses for its own; once there
    /// is an address.
    public var standing: String? {
        model.host.isEmpty ? nil : model.session.standing()
    }

    /// The address field, tidied: what connecting would use, and what is said under the field (`note`).
    public var tidied: RecorderAddress.Typed { RecorderAddress.tidy(typedHost) }

    /// このアドレスに接続. Connecting happens by itself at launch and after a scan, so a button is only for an address
    /// typed by hand, or for trying the saved one again after it failed. The field is compared both as typed and
    /// tidied, because the saved address can be untidy itself: an older version saved `192.168.1.10:64220` as typed,
    /// and 再接続 would only try that again.
    public var offersConnect: Bool { tidied.host != model.host || typedHost != model.host }

    /// このアドレスに接続 is held for an address no URL can be built on, and while the recorder in play may not be
    /// changed (`AppModel.canChangeRecorder`).
    public var holdsConnect: Bool { !RecorderAddress.isUsable(tidied.host) || !model.canChangeRecorder }

    /// 再接続, in the connect button's place, for the saved address while the app is not connected to it.
    public var offersReconnect: Bool { !offersConnect && !model.connected && !model.host.isEmpty }

    /// 再接続 is held while the recorder works, and while a run is under way, when a connect is only owed until it
    /// ends, and dropped if it meets silence first (`DeviceLink.connect`); by nothing the television does.
    public var holdsReconnect: Bool { model.isBusy(for: .recorder) || model.jobRunning }

    // MARK: - the reader's presses

    /// このアドレスに接続. The field shows what is saved, so that what was taken off can be seen to be gone.
    public func connect() async {
        let host = tidied.host
        typedHost = host
        await model.adopt(host: host)
    }

    /// 再接続.
    public func reconnect() async {
        await model.connect()
    }

    /// A recorder the search found, tapped: the field shows its address, and the app connects to it.
    public func choose(_ host: String) async {
        typedHost = host
        await model.adopt(host: host)
    }
}

public extension RecorderAddress.Typed {
    /// What the address field says back about what was typed, under the field in both the tutorial and the settings,
    /// `warning` for an address no URL can be built on. Tidying is done without a word, except for a port: somebody
    /// typed it on purpose, so it is said that it will not be used. Nothing is said while the field is empty or the
    /// address is fine.
    var note: (text: String, warning: Bool)? {
        if host.isEmpty { return nil }
        if !RecorderAddress.isUsable(host) {
            return ("アドレスの形式が正しくありません。192.168.1.10 のような IP アドレスを入力してください。", true)
        }
        if let port { return ("ポート番号は不要です。「:\(port)」は使わずに \(host) に接続します。", false) }
        return nil
    }
}
