import Foundation
import Network

/// Whether iOS lets this app reach the local network, which it asks the reader about the first time the app
/// tries.
///
/// Nothing reports that permission: "There's no general API that returns whether the current process has
/// local network access" (Apple's TN3179, "Understanding local network privacy"). Nor does the technote name
/// an event for the reader answering the system's question. What it gives is a sign to read off a connection:
/// "If your goal is to make a TCP connection to a local network address, manage that connection with
/// NWConnection. If your program doesn't have local network access, the connection enters the
/// NWConnection.State.waiting(_:) state and the current path lists an unsatisfied reason of
/// NWPath.UnsatisfiedReason.localNetworkDenied." And for the answer arriving: "If the user subsequently
/// changes the Local Network privilege to grant your program local network access, the system automatically
/// retries the connection." So a connection is opened towards the address in question, to watch what it
/// comes to.
///
/// The wait (`waitForAccess`) and the one look (`access`) read that sign where the technote reads it, in a
/// state the connection has come to, and nowhere sooner (`settled`). A connection is handed its first path
/// before it has tried anything -- satisfied, on a Mac's loopback, while the connection is still being set up
/// -- and a wait that took that path for the answer let a search go ahead behind the system's question on a
/// phone, which said it had found nobody while the question was still up. That the first path is satisfied on
/// a phone's Wi-Fi whatever the permission is taken from those two and has not been seen; the old wait
/// answering no path for another reason would have let the search through as well (`docs/porting.md`). The one
/// look was built as that wait was, and reads as the wait now does.
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

    /// One look at the permission, for when the answer is wanted now and waiting is not an option. Aimed at a
    /// recorder's or a television's own address after it was silent, it tells one that is asleep (`.allowed`,
    /// so a magic packet is worth sending) from one the app is not allowed to reach (`.blocked`).
    ///
    /// The look makes one connection of the kind the wait makes (`WaitConnection`) and reads it as the wait
    /// does: the first state the connection comes to that says anything of the permission (`settled`) is the
    /// answer, and nil when none has within `limit`, or the task was cancelled. The connection is stopped
    /// whichever way the look ends. `limit` is `secondsALookIsGiven` unless the caller says otherwise.
    ///
    /// What a connection to a device's own address comes to while the system's question is up, or after the
    /// reader said no, has not been seen on a phone. The technote says that without the permission "the
    /// connection enters the NWConnection.State.waiting(_:) state and the current path lists an unsatisfied
    /// reason of NWPath.UnsatisfiedReason.localNetworkDenied", which `settled` takes for `.blocked`. So what the
    /// look read goes to the log (`ScanLog`) as the wait's readings do: a phone is where it is to be seen, and
    /// there a look that was not `.blocked` shows the same on the screen whatever it read, the device woken.
    public static func access(probing host: String,
                              within limit: Duration = .seconds(secondsALookIsGiven)) async -> Access? {
        await access(on: WaitConnection(host: host), within: limit,
                     timeGiven: { try? await Task.sleep(for: $0) }, note: { ScanLog.note($0) })
    }

    /// How long the one look gives its connection when nothing else is said: a second longer than the
    /// connection's handshake. A device that is asleep says nothing, and a connection to it comes to something
    /// only when its handshake runs out (`handshakeSeconds`) -- as seen on a Mac's loopback, at an address where
    /// nobody answers, and not yet on a phone -- so that a look given no longer than the handshake would race
    /// it, and could have nothing to say of the very device it is asked about after silence. Usable from inline
    /// because the public look's default names it. That the default names this, and not a number of its own, is
    /// held by reading only: the loopback's handshake was seen to run out just inside a look of two seconds, so
    /// no test there tells such a look from this one.
    @usableFromInline static let secondsALookIsGiven = handshakeSeconds + 1

    /// The one look itself, on the connection it is handed, letting the time it is given go by as it is told,
    /// and writing where it is told: one line when it ends, in the words of a wait's reading (`reading`) for
    /// the first thing its connection came to that says anything, or that it came to nothing -- in its time,
    /// before its connection had gone, or before its task was cancelled -- with how long it took. It is never
    /// handed the address, so no line can hold it.
    static func access(on connection: any WatchedConnection, within limit: Duration,
                       timeGiven: @escaping @Sendable (Duration) async -> Void,
                       note: (String) -> Void) async -> Access? {
        let began = ContinuousClock.now
        // What the connection comes to, raced against the time given, as a turn of the wait races them. Both are
        // children of the look, which ends them once it has what it waited for, so that nothing outlives it.
        let (events, heard) = AsyncStream.makeStream(of: Watched.self)
        let (answer, read) = await withTaskGroup(of: Void.self, returning: (Access?, String).self) { looksOwn in
            looksOwn.addTask {
                for await sighting in connection.sightings { heard.yield(.cameTo(sighting)) }
                heard.finish()
            }
            looksOwn.addTask {
                await timeGiven(limit)
                heard.yield(.timeUp)
            }
            var answer: Access?
            var read = "its connection gone without coming to anything, no answer"
            for await event in events {
                guard case .cameTo(let sighting) = event else {
                    read = "come to nothing in \(String(format: "%g", limit / .seconds(1))) s, no answer"
                    break
                }
                if let taken = settled(sighting) {
                    answer = taken
                    read = reading(status: sighting.status, reason: sighting.reason, connection: sighting.state,
                                   verdict: taken)
                    break
                }
            }
            connection.stop()
            looksOwn.cancelAll()
            return (answer, read)
        }
        // A look whose task was cancelled was not wanted any more, whatever its connection had come to.
        let cancelled = Task.isCancelled
        let seconds = String(format: "%.2f", (ContinuousClock.now - began) / .seconds(1))
        note("look: \(cancelled ? "cancelled, no answer" : read), after \(seconds) s")
        return cancelled ? nil : answer
    }

    /// Waits for the local network to be reachable, on one connection towards `host`. `.allowed` as soon as
    /// it is. `.unavailable` when the path turns out to be missing for some other reason than the permission,
    /// or the task is cancelled. `.blocked` when the wait has given up with the permission still in the way,
    /// which only the retrying below comes to. `blocked` is called while local network privacy is holding the
    /// app back -- during the system's question and after a "no" alike, possibly more than once -- so that the
    /// caller can say so and offer the Settings app; and once for a connection that has come to nothing in the
    /// time it is given (below).
    ///
    /// Aimed at the device in question, and never at an address the system lets through without the
    /// permission -- the DNS server, or a proxy, on the local network (TN3179) -- which answers or refuses with
    /// the permission or without it, so that a wait aimed at it reads `.allowed` whatever the permission. On
    /// one phone, on 2026-10-06, a wait aimed at the subnet's first address was refused within ten milliseconds
    /// behind the system's question, and read the local network reached.
    ///
    /// There is no time limit while the connection waits: the reader may take as long as they like over the
    /// question, or go to the Settings app and back. A connection the system keeps waiting sends nothing, and
    /// the system tries it again by itself once the reader allows it, which is the nearest thing to an event
    /// for the answer that the technote gives. So the connection is kept, and not replaced by a fresh one every
    /// few seconds as it once was. The technote's sign is all it says of the time before the answer; a
    /// session of WWDC20 (10110) adds "Local connections that use NWConnection will stay in the waiting state
    /// until your app gets permission".
    ///
    /// A connection that has come to nothing the wait reads by the time its handshake's seconds and two more
    /// are up -- still being set up, or still on its way -- is another matter. Whether the permission is what
    /// holds it is not known: nothing of Apple's that has been read (TN3179, `Network/connection.h`,
    /// `Network/path.h`, WWDC20 10110) says what a connection is while the question is up, and nobody has seen
    /// one held there. So `blocked` is called then, once for that connection, and the wait goes on watching
    /// it; whatever the connection comes to afterwards is still the answer. It was written for the search for
    /// a recorder, which waited here before it asked anybody and would otherwise have stood on the screen as
    /// 検索中 0 / 253, frozen, with no word of why. The search no longer waits (`docs/porting.md`). The link's
    /// watchers, which do, hear of the permission from the link and give `blocked` nothing to do, so for them
    /// it is a line in the log.
    ///
    /// A connection that has failed outright is another matter: "The connection has irrecoverably closed or
    /// failed" (`Network/connection.h`), and nothing tries it again. With the permission in the way, the wait
    /// makes another a second later: a retry of the app's own, in the spirit of the "appropriate retry logic"
    /// the technote asks of what cannot wait. Nothing documents a connection failing outright for want of the
    /// permission. That does not go on without end. The loop is a `for` over `turnsAllowed`, each turn of
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
                            timeGiven: { try? await Task.sleep(for: $0) },
                            note: { ScanLog.note($0) }, blocked: blocked)
    }

    /// How many connections a wait may see go without an answer before it gives up.
    static let turnsAllowed = 120

    /// How long the wait's connection gives an address to answer its handshake. An address where nothing
    /// lives is silent, and a connection left to itself goes on trying it, in a state that says nothing of
    /// the permission, for longer than a reader would wait. With "the number of seconds that TCP waits before
    /// timing out its handshake" set, the connection comes to waiting when they are up, and can be read. Both
    /// as seen on a Mac's loopback (`LocalNetworkAccessTests`), at an address where nobody answers.
    static let handshakeSeconds = 2

    /// How long a connection of the wait's is given to come to something before the wait says the permission
    /// may be in the way: its handshake's seconds and two more, so that an address that refuses, or one that
    /// is silent until the handshake runs out, has been read well before.
    static let secondsToComeToSomething = handshakeSeconds + 2

    /// The wait itself, with what it reaches handed in: how a connection is made, how the wait pauses between
    /// connections, how it lets the time a connection is given go by, and where it writes.
    static func waitForAccess(connecting: () -> any WatchedConnection, turns: Int = turnsAllowed,
                              pause: (Duration) async -> Void,
                              timeGiven: @escaping @Sendable (Duration) async -> Void,
                              note: (String) -> Void,
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
            // What the connection comes to, raced against the time it is given, in the order they come. Both
            // are children of this turn: the turn does not end before they have, and it ends them itself once
            // it has what it waited for, so nothing of a turn outlives it, whichever way it ended.
            let (events, heard) = AsyncStream.makeStream(of: Watched.self)
            let given = Duration.seconds(secondsToComeToSomething)
            await withTaskGroup(of: Void.self) { turnsOwn in
                turnsOwn.addTask {
                    for await sighting in connection.sightings { heard.yield(.cameTo(sighting)) }
                    heard.finish()
                }
                turnsOwn.addTask {
                    await timeGiven(given)
                    if !Task.isCancelled { heard.yield(.timeUp) }
                }
                var cameToSomething = false
                for await event in events {
                    guard case .cameTo(let sighting) = event else {
                        // One time given for each connection, so this is said at most once for it.
                        guard !cameToSomething, !Task.isCancelled else { continue }
                        note("wait: come to nothing in \(secondsToComeToSomething) s, taken for blocked, still watched")
                        await blocked()
                        continue
                    }
                    let taken = settled(sighting)
                    readings += 1
                    // A connection can come to the same thing many times over: a line is written the first time.
                    let line = reading(status: sighting.status, reason: sighting.reason,
                                       connection: sighting.state, verdict: taken)
                    if written.insert(line).inserted { note("wait: \(line)") }
                    if taken != nil { cameToSomething = true }
                    if taken == .blocked {
                        denied = true
                        await blocked()
                    } else if let taken {
                        answer = taken
                        break
                    }
                }
                connection.stop()
                turnsOwn.cancelAll()
            }
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

    /// What a turn of the wait, or the one look, hears: what its connection came to, or that the time it was
    /// given is up.
    private enum Watched: Sendable {
        case cameTo(Sighting)
        case timeUp
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
    /// path that is satisfied then is an address that refused the connection, which is an answer from the
    /// local network, or one that let its handshake run out. That is taken for the local network reached too,
    /// since nothing tells it from an address where nobody lives; whether the system can hold a connection
    /// behind its question until the handshake runs out has not been seen (`docs/porting.md`). Before that --
    /// set up, or "in the process of being established" -- the path says only that there is a network to try
    /// on.
    static func settled(_ sighting: Sighting) -> Access? {
        switch sighting.state {
        case .ready: .allowed
        case .waiting: verdict(status: sighting.status, reason: sighting.reason, ended: false)
        case .failed: verdict(status: sighting.status, reason: sighting.reason, ended: true)
        default: nil
        }
    }

    /// What a settled connection's path says about the permission (`settled`, for the wait and the look alike,
    /// both aimed at the device), or nil while it says nothing yet. `ended` is set once the connection has
    /// failed, when a missing path is an answer rather than a path still to come.
    ///
    /// A satisfied path means allowed whatever became of the connection: a device refusing port 9 has
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

    /// What a wait's connection, or the look's, came to, in the log's words: the path's status, with the reason
    /// when it is unsatisfied, how the connection stands, with the code of what stopped it, and what the two are
    /// taken for. Words of the system's and numbers, and nothing of the address the connection was aimed at.
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

/// A connection for a wait, or the one look, to watch (`LocalNetwork.waitForAccess`, `LocalNetwork.access`):
/// each state it comes to, until it has gone. A test hands them one it plays itself.
protocol WatchedConnection: Sendable {
    var sightings: AsyncStream<LocalNetwork.Sighting> { get }
    /// Ends the connection, and with it `sightings`.
    func stop()
}

/// One TCP connection towards the address, kept for as long as the wait, or the one look, watches it.
/// `sightings` yields each state it comes to, with its path at that moment, and finishes when the connection
/// has gone. Which of those states say anything of the permission is not decided here (`LocalNetwork.settled`).
/// Not private, so that a test can make one towards this machine's loopback and look at it.
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
        // taken to have no path then, which the wait and the look answer as no path for another reason than the
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
