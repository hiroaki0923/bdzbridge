import Foundation
import Observation

/// What the app knows of a device and of its link to it, for the screens to read.
///
/// The screens read it and nothing sets a field of it: it changes by what happened. A device described
/// itself, it went silent, an attempt ended, the permission was missing -- each is one call, and puts every
/// field it bears on where that event leaves it. Set a field at a time, from a dozen places, an event could
/// be half put down: a device that went silent left described, a wait for the permission not given up.
/// Which calls there are is the list of what can happen to a session.
///
/// The order of the calls is still the caller's, and some pairs of fields disagree for a while by design. A
/// device that has described itself is connected at once, and stays marked unreachable from before until
/// `answered()`, once the rest has been read. Having given up stands through the next connect until
/// `finishedTrying`.
///
/// The client, the tasks under way and what is said on screen are the caller's. This is the part that can be
/// said without them, and so tried without a device.
///
/// A class bound to the main actor, and the one type in the package that is: it is the screens' state, read
/// field by field as they draw (`@Observable`), so that a screen is told of the field it reads and not of the
/// rest. The other shared state here is values and actors.
@MainActor
@Observable
public final class SessionState {
    /// What the device said of itself the last time it was asked, while it is answering. Nil once it has
    /// stopped: nothing answered, so the app is not connected, whatever a description read earlier says.
    public private(set) var info: RecorderDescription?
    /// Empty, and `storage` nil, when the device would not say. Both are only shown.
    public private(set) var firmware = ""
    public private(set) var storage: (free: Int, total: Int)?
    /// Set when the last ask got no answer at all, which is the only case worth sending a magic packet for.
    public private(set) var unreachable = false
    /// Set once the device has been given every chance and did not answer, or while the local network
    /// permission is what is in the way (`waitingForPermission`). Nothing is asked of it again until the
    /// network under the phone changes or the reader asks.
    public private(set) var gaveUp = false
    /// Set while the app is only waiting for the device to come back from a magic packet, or looking for it
    /// at another address after that.
    public private(set) var waking = false
    public private(set) var connecting = false
    /// Set while the local network permission is why the device cannot be reached, and the app is waiting
    /// for it rather than for the device.
    public private(set) var connectBlocked = false
    /// Set when the device answered that it is in standby, so that the screen can offer to turn it on.
    public private(set) var needsPower = false
    /// Bumped each time an attach goes through. A count rather than a flag, so that a screen where a device
    /// has just been chosen can tell the answer to that choice from a connection that was already up.
    public private(set) var timesAttached = 0
    /// The MAC a magic packet is sent to. Read from the device itself while it answers, or typed by the
    /// reader for one that has never been reached (`remember(mac:)`), and kept.
    public private(set) var mac: String?
    /// Where the device was last tried, and whether the phone has been elsewhere since (`LinkState`).
    public private(set) var link = LinkState()

    /// `mac` is what was saved, as it was saved.
    public init(mac: String? = nil) {
        self.mac = mac
    }

    public var connected: Bool { info != nil }
    /// True once a MAC is known, which is what a magic packet needs.
    public var canWake: Bool { mac != nil }

    /// Whether the phone, now on `network`, is on a network the last try was not made on, or has been since.
    public func networkChanged(now network: String) -> Bool { link.changed(now: network) }

    // MARK: - an attempt

    public func beginConnecting() { connecting = true }
    public func endConnecting() { connecting = false }

    /// A try is being made, on this network.
    public func tried(on network: String) { link.tried(on: network) }

    /// A look at the network, which remembers it when it is not the one last tried on.
    public func noted(network: String) { link.noted(network: network) }

    /// A connect has made its attempts. Only silence is given up on (`LinkRules.givesUp`), and one that
    /// reached the device, or was refused by it, is no longer given up. An attempt that ended waiting for the
    /// permission does not come here: the caller returns first, and stays given up.
    public func finishedTrying(reached: Bool) {
        gaveUp = LinkRules.givesUp(reached: reached, silent: unreachable)
    }

    // MARK: - an attach, a step at a time

    /// The device said who it is. That alone decides that the app is connected; the rest is read after, and
    /// having been unreachable stands until `answered()`.
    public func described(_ description: RecorderDescription) { info = description }
    public func learned(firmware: String) { self.firmware = firmware }
    public func learned(storage: (free: Int, total: Int)?) { self.storage = storage }
    /// It answered everything asked of it so far.
    public func answered() { unreachable = false }
    /// The attach is through.
    public func attached() { timesAttached += 1 }

    /// An attach failed, with `failure` when a device's error says which kind and nil when it does not.
    /// Silence leaves the device unreachable and no longer described. An address that is not one leaves it
    /// undescribed too: the last device's description standing would have the app look connected, to a device
    /// it is no longer set to. Anything else answered, so the device is there and what is known of it stands.
    public func attachFailed(_ failure: DeviceFailure?) {
        unreachable = failure == .silent
        if failure == .silent || failure == .badAddress { info = nil }
    }

    // MARK: - silence

    /// The check before an operation met silence, on the network it was asked on. Where a connect's first
    /// probe leaves things too, and what waking starts from: not given up yet.
    public func wentSilent(on network: String) {
        unreachable = true
        info = nil
        link.tried(on: network)
    }

    /// A request met silence and nothing brought the device back: not connected, and given up until the
    /// network changes or the reader asks. Where it was tried is left as it was, which is where the attempt
    /// began: a Wi-Fi that went while the request was out and came back before it timed out must not be put
    /// down as tried.
    public func lost() {
        unreachable = true
        info = nil
        gaveUp = true
    }

    // MARK: - the local network permission

    /// Silence because the system stopped the app asking. The app waits for the permission instead, and is
    /// given up until it comes.
    public func waitingForPermission() {
        connectBlocked = true
        gaveUp = true
    }

    /// The permission is not what is in the way: allowed, or not asked about.
    public func permissionCleared() { connectBlocked = false }

    // MARK: - the rest

    public func beginWaking() { waking = true }
    public func endWaking() { waking = false }
    public func powerNeeded(_ needed: Bool) { needsPower = needed }

    /// Keeps a MAC for waking the device. Anything that is not one is ignored rather than kept, so a
    /// half-typed address never replaces a good one. Returns whether it was kept. Kept here only: writing it
    /// down for the next launch is the caller's.
    @discardableResult
    public func remember(mac text: String) -> Bool {
        guard let normalised = WakeOnLan.normalise(text) else { return false }
        mac = normalised
        return true
    }

    public func forgetMac() { mac = nil }

    /// Another device is in play: what the last one said of itself is forgotten, and so is having given up on
    /// it. The MAC and where the app last tried are the caller's to change.
    public func forgotTheDevice() {
        info = nil
        firmware = ""
        storage = nil
        unreachable = false
        gaveUp = false
        connectBlocked = false
    }
}
