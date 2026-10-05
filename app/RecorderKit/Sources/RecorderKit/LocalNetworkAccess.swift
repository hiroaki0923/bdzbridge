import Foundation
import Network

/// Whether iOS lets this app reach the local network, which it asks the reader about the first time the app
/// tries.
///
/// Nothing reports that permission directly. URLSession fails a request that local network privacy stopped with
/// the same -1009 as having no network at all, and can fail it at once, while the system's question is still on
/// screen. The Network framework does say: a connection's path is unsatisfied with `localNetworkDenied`, and
/// once the reader allows it the system tries the connection again by itself (TN3179, "Understanding local
/// network privacy"). So a connection is opened towards the address in question, only to watch its path.
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
    /// Settings app and back. The probe is replaced every few seconds all the same: nothing documents what a
    /// connection says while the question is still up, and a fresh one reads the path afresh.
    ///
    /// What each probe read and what ended the wait go to the log (`ScanLog`): this reading of the path has
    /// not been seen to work on a phone, and the log is how it is seen.
    public static func waitForAccess(probing host: String,
                                     blocked: @Sendable () async -> Void) async -> Bool {
        let log = WaitLog()
        while !Task.isCancelled {
            let probe = AccessProbe(host: host, lifetime: .seconds(3), log: log)
            defer { probe.stop() }
            for await verdict in probe.verdicts {
                switch verdict {
                case .allowed:
                    log.ended("allowed")
                    return true
                case .unavailable:
                    log.ended("no path, and not for the permission")
                    return false
                case .blocked:
                    await blocked()
                }
            }
        }
        log.ended("cancelled")
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

    /// What a probe read, in the log's words: the path's status, with the reason when it is unsatisfied, how
    /// the connection stands, with the code of what stopped it, and what the two are taken for. Words of the
    /// system's and numbers, and nothing of the address the probe was aimed at.
    static func reading(status: NWPath.Status?, reason: NWPath.UnsatisfiedReason?,
                        connection: NWConnection.State?, verdict: Access?) -> String {
        let path = switch status {
        case .satisfied?: "satisfied"
        case .unsatisfied?: "unsatisfied (\(reason.map { "\($0)" } ?? "no reason"))"
        case .requiresConnection?: "requires a connection"
        case nil: "none yet"
        default: "unknown"
        }
        let state = switch connection {
        case .setup?: "setup"
        case .preparing?: "preparing"
        case .ready?: "ready"
        case .waiting(let error)?: "waiting (\(code(of: error)))"
        case .failed(let error)?: "failed (\(code(of: error)))"
        case .cancelled?: "cancelled"
        case nil: "gone"
        default: "unknown"
        }
        let taken = switch verdict {
        case .allowed?: "allowed"
        case .blocked?: "blocked"
        case .unavailable?: "unavailable"
        case nil: "nothing yet"
        }
        return "path \(path), connection \(state), taken for \(taken)"
    }

    /// The number of what stopped a connection, by the kind of error it is. Not the error's own text.
    private static func code(of error: NWError) -> String {
        switch error {
        case .posix(let code): "posix \(code.rawValue)"
        case .dns(let code): "dns \(code)"
        case .tls(let status): "tls \(status)"
        default: "another kind"
        }
    }
}

/// One TCP connection towards the address, watched for what its path says and cancelled after `lifetime`
/// at the latest. `verdicts` yields each change of verdict and finishes when the connection has gone. A wait's
/// probes write what they read to its `log`; a single look writes nothing.
private final class AccessProbe: Sendable {
    let verdicts: AsyncStream<LocalNetwork.Access>
    private let connection: NWConnection

    init(host: String, port: UInt16 = 9, lifetime: Duration, log: WaitLog? = nil) {
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
        // One reading of the path, beside how the connection stood: written to the wait's log, then reported.
        typealias Reading = @Sendable (NWPath?, NWConnection.State?, LocalNetwork.Access?) -> Void
        let read: Reading = { path, state, verdict in
            log?.read(LocalNetwork.reading(status: path?.status, reason: path?.unsatisfiedReason,
                                           connection: state, verdict: verdict))
            report(verdict)
        }
        connection.pathUpdateHandler = { [weak connection] path in
            read(path, connection?.state,
                 LocalNetwork.verdict(status: path.status, reason: path.unsatisfiedReason, ended: false))
        }
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                read(connection?.currentPath, state, .allowed)
            case .preparing, .waiting, .failed:
                // The path handler is called with the first path before the connection is even preparing;
                // reading it here as well is for whichever of the two a system version calls first.
                var ended = false
                if case .failed = state { ended = true }
                let path = connection?.currentPath
                read(path, state,
                     LocalNetwork.verdict(status: path?.status, reason: path?.unsatisfiedReason, ended: ended))
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

/// What one wait for the permission read, for the log (`ScanLog`): each reading the first time it is read, and
/// what ended the wait. A wait lasts for as long as the reader leaves the question unanswered, or the answer
/// at no, with a new probe every few seconds that reads what the last one did: a reading already written is
/// not written again, so a wait writes a handful of lines however long it lasts. Its probes each have a queue
/// of their own, and one being replaced can still be reading: so a lock.
private final class WaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var written: Set<String> = []
    private var readings = 0
    private let began = ContinuousClock.now

    func read(_ reading: String) {
        let new = lock.withLock {
            readings += 1
            return written.insert(reading).inserted
        }
        if new { ScanLog.note("wait: \(reading)") }
    }

    func ended(_ how: String) {
        let readings = lock.withLock { self.readings }
        let seconds = (ContinuousClock.now - began) / .seconds(1)
        ScanLog.note("wait: ended, \(how), after \(readings) readings in \(String(format: "%.2f", seconds)) s")
    }
}
