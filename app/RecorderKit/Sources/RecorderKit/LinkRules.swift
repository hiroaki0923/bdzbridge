import Foundation

/// Where a device was last tried, and whether the phone has been anywhere else since.
///
/// A device that says nothing is given up on until the network under the phone changes or the reader asks
/// (docs/porting.md, 諦めたら諦めたままにする). This is what "changes" is measured against. Kept apart from
/// the screens' state, and changed only through the three things that happen to it, so that nothing can set a
/// network as tried without a try having been made on it.
public struct LinkState: Sendable, Equatable {
    /// The network the last try was made on. Nil until there has been one.
    public private(set) var triedOn: String?
    /// How many tries there have been, so that a look after a network report can tell whether it set one
    /// going: a connect returns without trying while another is under way, and a look that took that for a
    /// try would stop looking with nothing tried.
    public private(set) var tries = 0
    /// Set when a look at the network since the last try found the phone somewhere else, even if it is back
    /// where it tried by now. The Wi-Fi going and coming back while a request was out is how a request meets
    /// silence at home, and the network before and after it is the same one.
    public private(set) var sawAnotherNetwork = false

    public init() {}

    /// A try is being made, on this network.
    public mutating func tried(on network: String) {
        triedOn = network
        sawAnotherNetwork = false
        tries += 1
    }

    /// A look at the network, which remembers it when it is not the one last tried on.
    public mutating func noted(network: String) {
        if network != triedOn { sawAnotherNetwork = true }
    }

    /// Whether the phone, now on `network`, is on a network the last try was not made on, or has been since.
    public func changed(now network: String) -> Bool {
        sawAnotherNetwork || network != triedOn
    }
}

/// The decisions about a device that may have stopped answering, with nothing in them but the decision: what to
/// do is the caller's, which has the client, the screen and the clock. They are set out in docs/porting.md
/// (端末側の設計メモ), and can be tried here without a phone or a recorder.
public enum LinkRules {
    /// How long a device may say nothing before it is worth making sure it is still up, ahead of something
    /// the reader asked for. A BDZ-FBT4100 leaves the network after a quarter of an hour or so with nothing
    /// asked of it, and has been seen awake for as little as two minutes at a time; a minute and a half is
    /// well inside both, and a recorder that is up answers the check in milliseconds.
    public static let dozeAfter: TimeInterval = 90

    /// How lately a device must have answered for a return to the app not to ask it again. Without this a
    /// glance at something else and back would send a magic packet each time.
    public static let freshAnswer: TimeInterval = 60

    /// The looks at the network that follow a report of it, as pauses in seconds, over the half minute an
    /// address can take to arrive: the report comes as soon as the path can be used, before the phone has
    /// its address on it, and nothing more is said when the address arrives.
    public static let looksAfterAReport: [Double] = [0, 1, 1, 1, 2, 3, 4, 8, 10]

    /// Whether a connect that has ended leaves the device given up on. Only silence does: a device that
    /// answered, if only to refuse -- a 503 because something else was talking to it, a fault from a model
    /// without one of the calls -- is there, and has said what is wrong already.
    public static func givesUp(reached: Bool, silent: Bool) -> Bool {
        !reached && silent
    }

    /// Whether a connect that got nowhere tries once more, because the network it started on is no longer
    /// the one under the phone. The caller asks once per connect: a network still changing after that is left
    /// to the next return to the app.
    public static func triesOnceMore(reached: Bool, networkChanged: Bool) -> Bool {
        !reached && networkChanged
    }

    /// Whether the device should be made sure of before an operation is sent to it. `evenIfRecent` is for when
    /// its last answer no longer says anything: the network under the phone has changed since.
    public static func needsCheck(lastAnswer: Date?, now: Date, evenIfRecent: Bool = false) -> Bool {
        if evenIfRecent { return true }
        guard let lastAnswer else { return true }
        return now.timeIntervalSince(lastAnswer) >= dozeAfter
    }

    public enum OnReturn: Sendable, Equatable {
        case nothing
        /// Do not connect, but look at the network over the next half minute (`looksAfterAReport`): it may
        /// have moved while the app was away, or be about to.
        case lookAtTheNetwork
        case connect
    }

    /// What the app becoming active is worth. Nothing, unless it has really been away: Control Centre, a
    /// notification pulled down and a system alert take an app out of being active without it going anywhere.
    /// Nothing with no device set. While something is under way (`busy`) or the device is being made sure of
    /// (`checking`), connecting would make a second client beside the one at work, so the network is only
    /// looked at. A device that is connected and answered within `freshAnswer` is left alone. One given up on,
    /// on the network it was given up on, is not news either, though it may be a moment from now. Otherwise,
    /// connect.
    public static func onReturn(wasAway: Bool, hasAddress: Bool, busy: Bool, checking: Bool, connected: Bool,
                                lastAnswer: Date?, now: Date, gaveUp: Bool, networkChanged: Bool) -> OnReturn {
        guard wasAway, hasAddress else { return .nothing }
        if busy || checking { return .lookAtTheNetwork }
        if connected, let lastAnswer, now.timeIntervalSince(lastAnswer) < freshAnswer { return .nothing }
        if gaveUp, !networkChanged { return .lookAtTheNetwork }
        return .connect
    }

    public enum OnNetworkChange: Sendable, Equatable {
        case nothing
        /// Not connected: another network is worth a connect.
        case connect
        /// Connected: the last answer is worth nothing any more, so make sure of the device with the client
        /// in hand, as before an operation.
        case makeSure
    }

    /// What a look at the network is worth while the app is open. A different network is the one thing that
    /// makes another try worth making without being asked, and nothing is done about it while the app is
    /// busy: the look comes again.
    public static func onNetworkChange(hasAddress: Bool, busy: Bool, networkChanged: Bool,
                                       connected: Bool) -> OnNetworkChange {
        guard hasAddress, !busy, networkChanged else { return .nothing }
        return connected ? .makeSure : .connect
    }
}
