import Foundation
import Network

/// Whether iOS lets this app reach the local network, which it asks the reader about the first time the app
/// tries.
///
/// Nothing reports that permission directly. URLSession, which everything else here uses, fails a request
/// that local network privacy stopped with the same -1009 as having no network at all, and can fail it at
/// once, while the system's question is still on screen. That is how the first scan came back empty behind
/// the dialog, and the reader had to tap a second time. The Network framework does say: a connection's
/// path is unsatisfied with `localNetworkDenied`, and once the reader allows it the system tries the
/// connection again by itself (TN3179, "Understanding local network privacy"). So a connection is opened
/// towards the address in question, only to watch its path; what answers there, if anything, does not
/// matter.
///
/// Not for the overnight run: a background process touching the local network while the question is
/// undecided is refused without a word, and nothing records that it was.
extension LocalNetwork {
    public enum Access: Sendable, Equatable {
        /// The path is there: the address can be reached, or answered, or refused the connection.
        case allowed
        /// Local network privacy is in the way: the reader has not answered the system's question yet, or
        /// said no to it. Nothing documents a difference between the two, so this does not try to tell them
        /// apart.
        case blocked
        /// No path for a reason that has nothing to do with permission, such as no network at all.
        case unavailable
    }

    /// One look at the permission, for when the answer is wanted now and waiting is not an option: nil when
    /// the probe said nothing within `limit`. Aimed at a recorder's own address, it tells a recorder that
    /// is asleep (`.allowed`, so a magic packet is worth sending) from one the app is not allowed to reach.
    public static func access(probing host: String, within limit: Duration = .seconds(2)) async -> Access? {
        let probe = AccessProbe(host: host, lifetime: limit)
        defer { probe.stop() }
        for await verdict in probe.verdicts { return verdict }
        return nil
    }

    /// Waits for the local network to be reachable: returns true as soon as it is, and false if the path
    /// turns out to be missing for some other reason or the task is cancelled. `blocked` is called while
    /// local network privacy is holding the app back -- during the system's question and after a "no" alike,
    /// possibly more than once -- so that the caller can say so and offer the Settings app.
    ///
    /// There is no time limit: the reader may take as long as they like over the question, or go to the
    /// Settings app and back. The probe is replaced every few seconds all the same. The system is meant to
    /// retry it when the permission changes, but nothing documents what a connection says while the
    /// question is still up, and a fresh one reads the path afresh whatever the old one was told.
    public static func waitForAccess(probing host: String,
                                     blocked: @Sendable () async -> Void) async -> Bool {
        while !Task.isCancelled {
            let probe = AccessProbe(host: host, lifetime: .seconds(3))
            defer { probe.stop() }
            for await verdict in probe.verdicts {
                switch verdict {
                case .allowed: return true
                case .unavailable: return false
                case .blocked: await blocked()
                }
            }
        }
        return false
    }

    /// What a probe's path says about the permission, or nil while it says nothing yet. `ended` is set once
    /// the connection has failed, when a missing path is an answer rather than a path still to come.
    ///
    /// A satisfied path means allowed whatever became of the connection: a router refusing port 9 has
    /// answered from the local network, which is all this needs to know.
    static func verdict(status: NWPath.Status?, reason: NWPath.UnsatisfiedReason?, ended: Bool) -> Access? {
        switch status {
        case .satisfied?:
            return .allowed
        case .unsatisfied?:
            return reason == .localNetworkDenied ? .blocked : .unavailable
        default:
            // not evaluated yet, or waiting on something such as a VPN that comes up on demand
            return ended ? .unavailable : nil
        }
    }
}

/// One TCP connection towards the address, watched for what its path says and cancelled after `lifetime`
/// at the latest. `verdicts` yields each change of verdict and finishes when the connection has gone.
private final class AccessProbe: Sendable {
    let verdicts: AsyncStream<LocalNetwork.Access>
    private let connection: NWConnection

    init(host: String, port: UInt16 = 9, lifetime: Duration) {
        // Port 9 is discard, which nothing on a home network is expected to listen on. At most a connection
        // attempt goes out, and it is cancelled as soon as the path has been read.
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 9,
                                      using: .tcp)
        self.connection = connection
        let (verdicts, continuation) = AsyncStream.makeStream(of: LocalNetwork.Access.self)
        self.verdicts = verdicts

        // Both handlers run on this one queue, which is what makes the last verdict safe to keep here.
        let queue = DispatchQueue(label: "RecorderKit.LocalNetwork.access")
        let last = LastVerdict()
        let report: @Sendable (LocalNetwork.Access?) -> Void = { verdict in
            guard let verdict, verdict != last.value else { return }
            last.value = verdict
            continuation.yield(verdict)
        }
        connection.pathUpdateHandler = { path in
            report(LocalNetwork.verdict(status: path.status, reason: path.unsatisfiedReason, ended: false))
        }
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                report(.allowed)
            case .preparing, .waiting, .failed:
                // The path handler is called with the first path before the connection is even preparing;
                // reading it here as well is for whichever of the two a system version calls first.
                var ended = false
                if case .failed = state { ended = true }
                let path = connection?.currentPath
                report(LocalNetwork.verdict(status: path?.status, reason: path?.unsatisfiedReason, ended: ended))
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        // The consumer stopping early -- a cancelled task -- ends the connection too.
        continuation.onTermination = { _ in connection.cancel() }
        let (seconds, attoseconds) = lifetime.components
        queue.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18) {
            connection.cancel()
        }
        connection.start(queue: queue)
    }

    func stop() {
        connection.cancel()
    }
}

/// The last verdict a probe reported, so that it reports changes only. Touched on the probe's queue alone.
private final class LastVerdict: @unchecked Sendable {
    var value: LocalNetwork.Access?
}
