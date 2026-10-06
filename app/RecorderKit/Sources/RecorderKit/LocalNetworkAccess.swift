import Foundation
import Network

/// Whether iOS lets this app reach the local network, which it asks the reader about the first time the app
/// tries.
///
/// Nothing reports that permission, nor the reader answering the system's question: "There's no general API
/// that returns whether the current process has local network access" (Apple's TN3179, "Understanding local
/// network privacy"). What the technote gives is a sign to read off a connection: "If your goal is to make a
/// TCP connection to a local network address, manage that connection with NWConnection. If your program
/// doesn't have local network access, the connection enters the NWConnection.State.waiting(_:) state and the
/// current path lists an unsatisfied reason of NWPath.UnsatisfiedReason.localNetworkDenied." And for the
/// answer arriving: "If the user subsequently changes the Local Network privilege to grant your program local
/// network access, the system automatically retries the connection." So a connection is opened towards the
/// address in question, to watch what it comes to.
///
/// The wait (`waitForAccess`) reads that sign where the technote reads it, in a state the connection has come
/// to, and nowhere sooner. A connection is handed its first path before it has tried anything, and on a Wi-Fi
/// that path is satisfied whatever the permission: a wait that took it for the answer let a search go ahead
/// behind the system's question, which said it had found nobody while the question was still up.
///
/// The one look (`access`) still reads the path as soon as there is one, and is left as it was: it can take a
/// permission still to be given for given (`docs/porting.md`, ローカルネットワークの許可).
///
/// None of this is seen off a phone: "The simulator doesn't support local network privacy", and a Mac lets
/// what is run from a terminal through unasked.
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

    /// Waits for the local network to be reachable, on one connection towards `host`. `.allowed` as soon as
    /// it is. `.unavailable` when the path turns out to be missing for some other reason than the permission,
    /// or the task is cancelled. `.blocked` when the wait has given up with the permission still in the way,
    /// which only the retrying below comes to. `blocked` is called while local network privacy is holding the
    /// app back -- during the system's question and after a "no" alike, possibly more than once -- so that the
    /// caller can say so and offer the Settings app.
    ///
    /// There is no time limit while the connection waits: the reader may take as long as they like over the
    /// question, or go to the Settings app and back. A connection the system keeps waiting sends nothing, and
    /// the system tries it again by itself once the reader allows it, which is the one event there is for the
    /// answer. So the connection is kept, and not replaced by a fresh one every few seconds as it once was.
    ///
    /// A connection that has failed outright is another matter: nothing tries that one again. With the
    /// permission in the way, the wait makes another a second later, which is the technote's "appropriate
    /// retry logic". That does not go on without end. The loop is a `for` over `turnsAllowed`, each turn of
    /// it makes one connection and goes round again only when that connection has gone without an answer,
    /// and after the last the wait gives up, two minutes on. A connection that waits is one turn however
    /// long it waits.
    ///
    /// What each connection came to and what ended the wait go to the log (`ScanLog`), in the system's words
    /// and numbers: what the system does behind its question is seen nowhere but on a phone, and the log is
    /// how it is seen there.
    public static func waitForAccess(probing host: String,
                                     blocked: @Sendable () async -> Void) async -> Access {
        await waitForAccess(connecting: { WaitConnection(host: host) },
                            pause: { try? await Task.sleep(for: $0) },
                            note: { ScanLog.note($0) }, blocked: blocked)
    }

    /// How many connections a wait may see go without an answer before it gives up.
    static let turnsAllowed = 120

    /// How long the wait's connection gives an address to answer its handshake. An address where nothing
    /// lives is silent, and a connection left to itself goes on trying it, in a state that says nothing of
    /// the permission, for longer than a reader would wait. With "the number of seconds that TCP waits before
    /// timing out its handshake" set, the connection comes to waiting when they are up, and can be read.
    static let handshakeSeconds = 2

    /// The wait itself, with what it reaches handed in: how a connection is made, how the wait pauses, and
    /// where it writes.
    static func waitForAccess(connecting: () -> any WatchedConnection, turns: Int = turnsAllowed,
                              pause: (Duration) async -> Void, note: (String) -> Void,
                              blocked: @Sendable () async -> Void) async -> Access {
        let began = ContinuousClock.now
        var written: Set<String> = []
        var readings = 0
        var denied = false
        func ended(_ how: String, after connections: Int, _ access: Access) -> Access {
            let seconds = String(format: "%.2f", (ContinuousClock.now - began) / .seconds(1))
            note("wait: ended, \(how), after \(readings) readings of \(connections) connections in \(seconds) s")
            return access
        }

        for turn in 1...max(1, turns) {
            guard !Task.isCancelled else { return ended("cancelled", after: turn - 1, .unavailable) }
            let connection = connecting()
            var answer: Access?
            denied = false
            for await sighting in connection.sightings {
                let taken = settled(sighting)
                readings += 1
                // A connection can come to the same thing many times over: a line is written the first time.
                let line = reading(status: sighting.status, reason: sighting.reason, connection: sighting.state,
                                   verdict: taken)
                if written.insert(line).inserted { note("wait: \(line)") }
                if taken == .blocked {
                    denied = true
                    await blocked()
                } else if let taken {
                    answer = taken
                    break
                }
            }
            connection.stop()
            guard !Task.isCancelled else { return ended("cancelled", after: turn, .unavailable) }
            switch answer {
            case .allowed?: return ended("allowed", after: turn, .allowed)
            case .some: return ended("no path, and not for the permission", after: turn, .unavailable)
            case nil: break
            }
            // The connection has gone without an answer.
            if turn < turns { await pause(.seconds(1)) }
        }
        return denied ? ended("blocked still, and given up on", after: turns, .blocked)
            : ended("no connection came to anything, and given up on", after: turns, .unavailable)
    }

    /// What a connection had come to when it said so: its state, and its path at that moment.
    struct Sighting: Sendable, Equatable {
        var state: NWConnection.State
        var status: NWPath.Status?
        var reason: NWPath.UnsatisfiedReason?
    }

    /// What a connection says of the permission once it has come to something, or nil where it says nothing.
    ///
    /// Ready, it has been answered. Waiting, or failed, it has tried and "will indicate the reason that the
    /// connection couldn't be established": there the path is read, as the technote's own check reads it. A
    /// path that is satisfied then is an address that refused the connection or let its handshake run out,
    /// and either way something of it left this device. Before that -- set up, or "in the process of being
    /// established" -- the path says only that there is a network to try on.
    static func settled(_ sighting: Sighting) -> Access? {
        switch sighting.state {
        case .ready: .allowed
        case .waiting: verdict(status: sighting.status, reason: sighting.reason, ended: false)
        case .failed: verdict(status: sighting.status, reason: sighting.reason, ended: true)
        default: nil
        }
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

    /// What a wait's connection came to, in the log's words: the path's status, with the reason when it is
    /// unsatisfied, how the connection stands, with the code of what stopped it, and what the two are taken
    /// for. Words of the system's and numbers, and nothing of the address the connection was aimed at.
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

/// A connection for a wait to watch (`LocalNetwork.waitForAccess`): each state it comes to, until it has
/// gone. A test hands the wait one it plays itself.
protocol WatchedConnection: Sendable {
    var sightings: AsyncStream<LocalNetwork.Sighting> { get }
    /// Ends the connection, and with it `sightings`.
    func stop()
}

/// One TCP connection towards the address, kept for as long as the wait watches it. `sightings` yields each
/// state it comes to, with its path at that moment, and finishes when the connection has gone. Which of those
/// states say anything of the permission is not decided here (`LocalNetwork.settled`). Not private, so that
/// a test can make one towards this machine's loopback and look at it.
final class WaitConnection: WatchedConnection {
    let sightings: AsyncStream<LocalNetwork.Sighting>
    let connection: NWConnection

    init(host: String, port: UInt16 = 9) {
        // Port 9 is discard, which nothing on a home network is expected to listen on. At most a connection
        // attempt goes out, and nothing is sent on a connection that is made.
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = LocalNetwork.handshakeSeconds
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Never by the mobile network: "A list of interface types that connections, listeners, and browsers
        // will not use" (Apple, `NWParameters.prohibitedInterfaceTypes`). Without it, with the Wi-Fi gone, the
        // address could be tried that way, where there is no local network to be allowed onto -- "Such
        // interfaces include Wi-Fi and Ethernet, but not cellular (WWAN) or VPN" (TN3179) -- and a handshake
        // that ran out there would be taken for the local network reached. Barred from it, the connection is
        // taken to have no path then, which the wait answers as no path for another reason than the
        // permission. Neither the one nor the other has been seen on a phone.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 9,
                                      using: parameters)
        self.connection = connection
        let (sightings, continuation) = AsyncStream.makeStream(of: LocalNetwork.Sighting.self)
        self.sightings = sightings

        connection.stateUpdateHandler = { [weak connection] state in
            if case .cancelled = state { return continuation.finish() }
            let path = connection?.currentPath
            continuation.yield(LocalNetwork.Sighting(state: state, status: path?.status,
                                                     reason: path?.unsatisfiedReason))
            // A connection that has failed says nothing more, and nothing tries it again.
            if case .failed = state { connection?.cancel() }
        }
        // The consumer stopping early -- a cancelled task -- ends the connection too.
        continuation.onTermination = { _ in connection.cancel() }
        connection.start(queue: DispatchQueue(label: "RecorderKit.LocalNetwork.wait"))
    }

    func stop() {
        connection.cancel()
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
