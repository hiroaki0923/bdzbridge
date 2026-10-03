import Foundation
import Observation

/// What the app knows of a device and of its link to it, for the screens to read.
///
/// Nothing sets a field of it: it changes by what happened. A device described itself, it went silent, an
/// attempt ended, the permission was missing -- each is one call, which puts every field it bears on where that
/// event leaves it, so that no event is half put down. The order of the calls is still the caller's, and some
/// pairs of fields disagree for a while by design: a device that has described itself is connected at once and
/// stays marked unreachable from before until `answered()`, once the rest has been read, and having given up
/// stands through the next connect until `finishedTrying`.
///
/// The client, the tasks under way and what is said on screen are the caller's, so this can be tried without a
/// device. A class bound to the main actor, the one type in the package that is: the screens read it field by
/// field as they draw (`@Observable`), and a screen is told of the field it reads and not of the rest.
@MainActor
@Observable
public final class SessionState {
    /// What the device said of itself the last time it was asked, while it is answering. Nil once it has
    /// stopped: nothing answered, so the app is not connected, whatever a description read earlier says.
    public private(set) var info: RecorderDescription?
    /// Set while a device that says who it is by an identity alone -- a television, by the MAC it wakes on,
    /// having no recorder's description to give -- is answering (`identified(as:)`). It stands for such a
    /// device where `info` stands for a recorder, and goes wherever `info` goes.
    public private(set) var named = false
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
    /// Which device this is all about: the UDN of the last one that described itself. The firmware, the free
    /// space and the wish for power above are its own, and so are the lists the caller holds, so it stands
    /// through silence, until another device describes itself (`described`) or the caller lets go of it
    /// (`forgotTheDevice`). Nil before any has, and for a device that gives no UDN.
    public private(set) var device: String?

    /// `mac` is what was saved, as it was saved.
    public init(mac: String? = nil) {
        self.mac = mac
    }

    public var connected: Bool { info != nil || named }
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

    /// Who `description` is to this session, with nothing changed: for an answer that is not an attach, such
    /// as the check before an operation, and for a device a scan has heard from before it is chosen.
    public func recognises(_ description: RecorderDescription) -> Recognition {
        description.recognised(as: device)
    }

    /// The device said who it is. That alone decides that the app is connected; the rest is read after, and
    /// having been unreachable stands until `answered()`. Who it is is measured against the device known
    /// before, by its UDN and not by its address (`Recognition`): when it is another one, what the last one
    /// said of itself goes before this one's description is put down, and the caller is told, since the lists
    /// it holds are the other one's as well.
    @discardableResult
    public func described(_ description: RecorderDescription) -> Recognition {
        let who = recognises(description)
        if who == .another {
            firmware = ""
            storage = nil
            needsPower = false
        }
        info = description
        // Written as it was first given: the same device spelling its UDN another way is still that one, to
        // a caller that keeps `device` to compare later.
        if who != .same, !description.udn.isEmpty { device = description.udn }
        return who
    }
    /// Who a device that gives an identity rather than a description is, measured as `recognises` measures a
    /// recorder: against `device`, and an empty identity is taken for the one known.
    public func recognises(identity: String) -> Recognition {
        guard let device, !device.isEmpty else { return .first }
        return identity.isEmpty || identity.caseInsensitiveCompare(device) == .orderedSame ? .same : .another
    }

    /// `described`, for such a device: it said who it is, and the app is connected. Another one forgets what
    /// the last said of itself, as `described` does.
    @discardableResult
    public func identified(as identity: String) -> Recognition {
        let who = recognises(identity: identity)
        if who == .another {
            firmware = ""
            storage = nil
            needsPower = false
        }
        named = true
        if who != .same, !identity.isEmpty { device = identity }
        return who
    }

    /// Something answered at the address that is not the device the app knows, and nothing of it is taken up:
    /// not connected, and not unreachable either, since something answered.
    public func strangerAnswered() {
        info = nil
        named = false
    }

    public func learned(firmware: String) { self.firmware = firmware }
    public func learned(storage: (free: Int, total: Int)?) { self.storage = storage }
    /// It answered everything asked of it so far.
    public func answered() { unreachable = false }
    /// The attach is through.
    public func attached() { timesAttached += 1 }

    /// An attach failed, with `failure` when a device's error says which kind and nil when it does not. Silence
    /// leaves the device unreachable and no longer described. An address that is not one leaves it undescribed
    /// too, or the app would look connected to a device it is no longer set to. Anything else answered, so the
    /// device is there and what is known of it stands -- which is nothing when another has just been chosen:
    /// the caller forgets the last one at the choice (`forgotTheDevice`).
    public func attachFailed(_ failure: DeviceFailure?) {
        unreachable = failure == .silent
        if failure == .silent || failure == .badAddress {
            info = nil
            named = false
        }
    }

    // MARK: - silence

    /// The check before an operation met silence, on the network it was asked on. Where a connect's first
    /// probe leaves things too, and what waking starts from: not given up yet.
    public func wentSilent(on network: String) {
        unreachable = true
        info = nil
        named = false
        link.tried(on: network)
    }

    /// A request met silence and nothing brought the device back: not connected, and given up until the network
    /// changes or the reader asks. Where it was tried is left as it was, where the attempt began: a Wi-Fi that
    /// went and came back while the request was out must not be put down as tried.
    public func lost() {
        unreachable = true
        info = nil
        named = false
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

    /// Another device is in play, or may be: the reader has pointed the app at another address, or the demo
    /// was entered or left. What the last one said of itself is forgotten -- that it wanted powering on among
    /// it -- and so is having given up on it, and which device it was: the next to describe itself is the
    /// first. The MAC and where the app last tried are the caller's to change.
    public func forgotTheDevice() {
        device = nil
        info = nil
        named = false
        firmware = ""
        storage = nil
        unreachable = false
        gaveUp = false
        connectBlocked = false
        needsPower = false
    }
}
