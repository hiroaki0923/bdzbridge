import Network
import XCTest
@testable import RecorderKit

/// The permission itself cannot be tested here: the Mac running the tests answers the question for the
/// terminal, not for the app, and the simulator does not implement it at all. What can be held still is how
/// a path is read and where, what a wait does with what its connection comes to -- on connections the tests
/// play -- and what a real connection comes to on this machine's loopback.
final class LocalNetworkAccessTests: XCTestCase {
    func testAPathIsReadAsThePermission() {
        XCTAssertEqual(LocalNetwork.verdict(status: .satisfied, reason: .notAvailable, ended: false), .allowed)
        XCTAssertEqual(LocalNetwork.verdict(status: .satisfied, reason: .notAvailable, ended: true), .allowed,
                       "a connection that was refused still reached the local network")
        XCTAssertEqual(LocalNetwork.verdict(status: .unsatisfied, reason: .localNetworkDenied, ended: false),
                       .blocked)
        XCTAssertEqual(LocalNetwork.verdict(status: .unsatisfied, reason: .localNetworkDenied, ended: true),
                       .blocked)
        XCTAssertEqual(LocalNetwork.verdict(status: .unsatisfied, reason: .notAvailable, ended: false),
                       .unavailable, "no network is not a question of permission")
    }

    func testNoPathYetIsNoAnswerYet() {
        XCTAssertNil(LocalNetwork.verdict(status: nil, reason: nil, ended: false))
        XCTAssertNil(LocalNetwork.verdict(status: .requiresConnection, reason: .notAvailable, ended: false))
        XCTAssertEqual(LocalNetwork.verdict(status: nil, reason: nil, ended: true), .unavailable)
    }

    /// What a wait writes to the log of each reading (`ScanLog`): the system's words for the path and for why
    /// it is unsatisfied, how the connection stands with the number of what stopped it, and what the two were
    /// taken for. Nothing of where the probe was aimed is handed to it.
    func testAReadingIsWrittenInTheSystemsWordsAndNumbers() {
        XCTAssertEqual(LocalNetwork.reading(status: .unsatisfied, reason: .localNetworkDenied,
                                            connection: .waiting(.posix(.ENETDOWN)), verdict: .blocked),
                       "path unsatisfied (localNetworkDenied), connection waiting (posix 50), taken for blocked")
        XCTAssertEqual(LocalNetwork.reading(status: .unsatisfied, reason: .notAvailable,
                                            connection: .preparing, verdict: .unavailable),
                       "path unsatisfied (notAvailable), connection preparing, taken for unavailable")
        XCTAssertEqual(LocalNetwork.reading(status: .satisfied, reason: .notAvailable,
                                            connection: .failed(.posix(.ECONNREFUSED)), verdict: .allowed),
                       "path satisfied, connection failed (posix 61), taken for allowed")
        XCTAssertEqual(LocalNetwork.reading(status: .requiresConnection, reason: nil, connection: .setup,
                                            verdict: nil),
                       "path requires a connection, connection setup, taken for nothing yet")
        XCTAssertEqual(LocalNetwork.reading(status: nil, reason: nil, connection: nil, verdict: .unavailable),
                       "path none yet, connection gone, taken for unavailable")
    }

    /// Loopback, so that nothing leaves this machine: nothing listens on port 9, the connection is refused,
    /// and the path was there all along.
    func testAProbeOfThisMachineIsAllowedAtOnce() async {
        let started = Date()
        expectEqual(await LocalNetwork.access(probing: "127.0.0.1", within: .seconds(5)), .allowed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "answered by the path, not by the time limit")

        let waiting = Task {
            await LocalNetwork.waitForAccess(probing: "127.0.0.1") {
                XCTFail("loopback is never held back by local network privacy")
            }
        }
        expectEqual(await outcome(of: waiting), .allowed)
    }

    /// Leaving the tutorial or turning to the demo cancels the scan that is waiting, and the scan must then
    /// stop rather than take the wait's end for a yes. Cancelled before it starts, so that loopback's
    /// immediate answer cannot win a race with the cancelling.
    func testACancelledWaitIsNotAYes() async {
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LocalNetwork.waitForAccess(probing: "127.0.0.1") {}
        }
        expectEqual(await outcome(of: waiting), .unavailable)
    }

    // MARK: - where the wait reads the path

    /// The wait reads a connection's path once the connection has come to something, and not before. A
    /// connection has a path before it has tried anything, satisfied on any network there is, and that says
    /// nothing of the permission: the system's question comes up when the connection tries.
    func testAPathSaysNothingBeforeItsConnectionHasComeToAnything() {
        func settled(_ state: NWConnection.State, _ status: NWPath.Status?,
                     _ reason: NWPath.UnsatisfiedReason? = .notAvailable) -> LocalNetwork.Access? {
            LocalNetwork.settled(LocalNetwork.Sighting(state: state, status: status, reason: reason))
        }
        XCTAssertNil(settled(.setup, .satisfied), "a path was read before the connection had started")
        XCTAssertNil(settled(.preparing, .satisfied), "a path was read while the connection was still on its way")
        XCTAssertNil(settled(.preparing, .unsatisfied, .localNetworkDenied))
        XCTAssertNil(settled(.cancelled, .satisfied))

        XCTAssertEqual(settled(.ready, .satisfied), .allowed)
        XCTAssertEqual(settled(.waiting(.posix(.ECONNREFUSED)), .satisfied), .allowed,
                       "an address that refused the connection was reached")
        XCTAssertEqual(settled(.waiting(.posix(.ETIMEDOUT)), .satisfied), .allowed,
                       "a handshake that ran out of time was sent")
        XCTAssertEqual(settled(.waiting(.posix(.ENETDOWN)), .unsatisfied, .localNetworkDenied), .blocked)
        XCTAssertEqual(settled(.waiting(.posix(.ENETDOWN)), .unsatisfied, .notAvailable), .unavailable)
        XCTAssertNil(settled(.waiting(.posix(.ENETDOWN)), nil, nil), "waiting with no path yet is still to come")
        XCTAssertEqual(settled(.failed(.posix(.ENETDOWN)), .unsatisfied, .localNetworkDenied), .blocked)
        XCTAssertEqual(settled(.failed(.posix(.ECONNRESET)), .satisfied), .allowed)
        XCTAssertEqual(settled(.failed(.posix(.ENETDOWN)), nil, nil), .unavailable)
    }

    // MARK: - the wait, on connections the tests play

    /// A connection that is answered, refused, or left unanswered until its handshake ran out has reached the
    /// local network: the wait is over at once, nothing was said of the permission, and the connection is
    /// ended.
    func testAConnectionThatGotOutIsAllowedAndNothingIsSaidOfThePermission() async {
        for outcome in [Sighting.answered, .refused, .unanswered] {
            let played = Played([PlayedConnection([.onItsWay, outcome], thenGoes: true)])

            let access = await self.outcome(of: Task { await played.wait() })

            XCTAssertEqual(access, .allowed, "\(outcome.state)")
            XCTAssertEqual(played.timesBlocked, 0, "\(outcome.state): the permission was said to be in the way")
            XCTAssertEqual(played.pauses, [])
            XCTAssertEqual(played.made.count, 1)
            XCTAssertTrue(played.made[0].stopped, "\(outcome.state): the connection was left open")
        }
    }

    /// The system's question is up: the connection waits, with the permission as the reason. The wait says
    /// so and goes on waiting on that one connection, however long: it is not over, and no other connection
    /// is made. When the system tries the connection again, as it does once the reader allows it, what the
    /// connection comes to then is the answer.
    func testAConnectionKeptWaitingSaysSoAndIsTheAnswerWhenTheSystemTriesItAgain() async throws {
        let connection = PlayedConnection([.onItsWay, .denied])
        let played = Played([connection])
        let waiting = Task { await played.wait() }

        try await until("the wait never said the permission was in the way") { played.timesBlocked == 1 }
        // Long enough for a wait that did not stay on its connection to have ended or made another.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(played.over, "the wait ended with the permission still in the way")
        XCTAssertEqual(played.made.count, 1, "another connection was made while the system kept the first")
        XCTAssertFalse(connection.stopped)

        connection.comes(to: .onItsWay)
        connection.comes(to: .refused)
        expectEqual(await outcome(of: waiting), .allowed)

        XCTAssertEqual(played.timesBlocked, 1)
        XCTAssertEqual(played.pauses, [], "nothing is tried again by the wait while the system tries for it")
        XCTAssertEqual(played.made.count, 1)
        XCTAssertTrue(connection.stopped)
    }

    /// A connection that fails outright with the permission in the way is one the system will not try again,
    /// so the wait makes another a second later: three times here, and the fourth is refused by the address,
    /// which is the local network reached.
    func testAConnectionThatFailsOutrightIsMadeAgainASecondLater() async {
        let played = Played([PlayedConnection([.failedDenied], thenGoes: true),
                             PlayedConnection([.failedDenied], thenGoes: true),
                             PlayedConnection([.failedDenied], thenGoes: true),
                             PlayedConnection([.refused])])

        let access = await outcome(of: Task { await played.wait() })

        XCTAssertEqual(access, .allowed)
        XCTAssertEqual(played.timesBlocked, 3, "each connection the permission stopped is said")
        XCTAssertEqual(played.pauses, [.seconds(1), .seconds(1), .seconds(1)])
        XCTAssertEqual(played.made.count, 4)
        XCTAssertTrue(played.made.allSatisfy(\.stopped))
    }

    /// And that is not done without end. Every connection fails outright, the permission in the way: after
    /// as many as the wait allows it gives up, saying the permission is still in the way, and makes no more.
    func testTheWaitGivesUpBlockedWhenEveryConnectionItIsAllowedHasFailed() async {
        let played = Played(thenAlways: { PlayedConnection([.failedDenied], thenGoes: true) })

        let access = await outcome(of: Task { await played.wait() })

        XCTAssertEqual(access, .blocked)
        XCTAssertEqual(LocalNetwork.turnsAllowed, 120)
        XCTAssertEqual(played.made.count, 120, "more connections were made than the wait allows, or fewer")
        XCTAssertEqual(played.timesBlocked, 120)
        XCTAssertEqual(played.pauses, Array(repeating: .seconds(1), count: 119),
                       "a pause between one connection and the next, and none after the last")
    }

    /// Nor when every connection it makes has gone without coming to anything at all: after as many as the
    /// wait allows it gives up, not with a yes, and with nothing said of the permission.
    func testTheWaitGivesUpWithNoYesWhenNoConnectionCameToAnything() async {
        let played = Played()

        let access = await outcome(of: Task { await played.wait() })

        XCTAssertEqual(access, .unavailable)
        XCTAssertEqual(played.timesBlocked, 0, "the permission was said to be in the way")
        XCTAssertEqual(played.made.count, 120, "more connections were made than the wait allows, or fewer")
        XCTAssertEqual(played.pauses.count, 119)
    }

    /// The screen that asked goes away while the connection waits: the wait's task is cancelled. The wait is
    /// over, not with a yes, and its connection is ended.
    func testAWaitCancelledWhileItsConnectionWaitsEndsTheConnection() async throws {
        let connection = PlayedConnection([.denied])
        let played = Played([connection])
        let waiting = Task { await played.wait() }

        try await until("the wait never said the permission was in the way") { played.timesBlocked == 1 }
        waiting.cancel()

        expectEqual(await outcome(of: waiting), .unavailable)
        XCTAssertTrue(connection.stopped, "the connection was left waiting after the wait was cancelled")
        XCTAssertEqual(played.made.count, 1, "another connection was made after the wait was cancelled")
        XCTAssertEqual(played.pauses, [])
    }

    /// No path for another reason than the permission, the Wi-Fi gone above all: the wait is over without a
    /// yes, and without a word of the permission.
    func testNoPathForAnotherReasonEndsTheWaitWithNothingSaidOfThePermission() async {
        let played = Played([PlayedConnection([.onItsWay, .noNetwork])])

        let access = await outcome(of: Task { await played.wait() })

        XCTAssertEqual(access, .unavailable)
        XCTAssertEqual(played.timesBlocked, 0)
        XCTAssertEqual(played.made.count, 1)
        XCTAssertTrue(played.made[0].stopped)
    }

    /// What a wait leaves in the log: each thing its connection came to, the first time it came to it, in the
    /// system's words and numbers, and what ended the wait, after how many readings of how many connections.
    func testAWaitWritesWhatItsConnectionCameToAndWhatEndedIt() async {
        let played = Played([PlayedConnection([.failedDenied], thenGoes: true),
                             PlayedConnection([.onItsWay, .denied, .denied, .onItsWay, .refused])])

        let access = await outcome(of: Task { await played.wait() })

        XCTAssertEqual(access, .allowed)
        XCTAssertEqual(played.timesBlocked, 3)
        // How long the wait took is the one thing in a line that is not the same at every run.
        XCTAssertEqual(played.lines.map { $0.replacing(/in \d+\.\d\d s$/, with: "in some s") }, [
            "wait: path unsatisfied (localNetworkDenied), connection failed (posix 50), taken for blocked",
            "wait: path satisfied, connection preparing, taken for nothing yet",
            "wait: path unsatisfied (localNetworkDenied), connection waiting (posix 50), taken for blocked",
            "wait: path satisfied, connection waiting (posix 61), taken for allowed",
            "wait: ended, allowed, after 6 readings of 2 connections in some s",
        ])
    }

    // MARK: - the wait, on this machine's loopback

    /// The wait's own connection, towards an address where nothing answers: 127.0.0.2 is the loopback
    /// network's and nobody's, so what is sent there never leaves this machine and is never answered. The
    /// connection has a satisfied path from the start and is on its way for as long as its handshake is given,
    /// and the wait does not take that path for an answer: it is over when the two seconds are, the handshake
    /// having run out, and not before. Stopped by the test if it is not over long after that.
    func testTheWaitDoesNotAnswerBeforeItsConnectionHasComeToAnything() async {
        let began = ContinuousClock.now
        let waiting = Task {
            await LocalNetwork.waitForAccess(probing: "127.0.0.2") {
                XCTFail("loopback is never held back by local network privacy")
            }
        }
        let patience = Task {
            try? await Task.sleep(for: .seconds(10))
            waiting.cancel()
        }
        let access = await waiting.value
        patience.cancel()

        XCTAssertEqual(access, .allowed, "silence was not an answer once the handshake had run out")
        let took = ContinuousClock.now - began
        XCTAssertGreaterThan(took, .milliseconds(1500), "answered before the connection had come to anything")
        XCTAssertLessThan(took, .seconds(6), "the handshake was given more than its two seconds")
    }

    /// The wait's own connection is never made over the mobile network, where there is no local network to
    /// be allowed onto and a handshake that ran out would be taken for one reached. Aimed at this machine's
    /// loopback, and stopped at once.
    func testTheWaitsConnectionIsNeverMadeOverTheMobileNetwork() {
        let made = WaitConnection(host: "127.0.0.1")
        defer { made.stop() }

        XCTAssertEqual(made.connection.parameters.prohibitedInterfaceTypes, [.cellular])
    }

    /// The wait's own connection, towards this machine, where nothing listens on port 9: it is refused and
    /// comes to something the wait reads, and stopped then, it ends, and what it reports with it. A wait
    /// stops its connection once it has its answer; one left going would be tried again by the system.
    func testTheWaitsOwnConnectionEndsWhenItIsStopped() async {
        let made = WaitConnection(host: "127.0.0.1")
        let watched = Task { () -> Bool in
            var stopped = false
            for await sighting in made.sightings where !stopped && LocalNetwork.settled(sighting) != nil {
                made.stop()
                stopped = true
            }
            return stopped
        }

        let ended = await outcome(of: watched, within: 3, "the connection, stopped,")

        XCTAssertEqual(ended, true, "the connection had come to nothing the wait reads when it ended")
    }

    // MARK: - what the tests do

    private typealias Sighting = LocalNetwork.Sighting

    /// What a task of the test's came to, or nil, with the test failed, if it had not come to anything within
    /// `seconds`: it is cancelled then, which ends a wait. Every wait the tests await is awaited through this,
    /// so that a fault of the wait fails a test instead of leaving `swift test` waiting for good, and with it
    /// the pre-commit hook and the archive.
    private func outcome<T: Sendable>(of task: Task<T, Never>, within seconds: Double = 5,
                                      _ what: String = "the wait", file: StaticString = #filePath,
                                      line: UInt = #line) async -> T? {
        let limit = Task { () -> Bool in
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return false }
            task.cancel()
            return true
        }
        let value = await task.value
        limit.cancel()
        let ranOut = await limit.value
        guard !ranOut else {
            XCTFail("\(what) was still going after \(Int(seconds)) seconds", file: file, line: line)
            return nil
        }
        return value
    }

    /// Waits for `condition`, a few seconds at most: for what a wait in a task of its own gets round to.
    private func until(_ what: String, within seconds: Double = 3, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail(what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// What a played connection comes to, in the words of the tests. The number given for the permission is
/// invented: nothing documents which the system gives.
private extension LocalNetwork.Sighting {
    /// Started and not yet anywhere, with the path any connection has on a network.
    static let onItsWay = Self(state: .preparing, status: .satisfied, reason: .notAvailable)
    static let answered = Self(state: .ready, status: .satisfied, reason: .notAvailable)
    static let refused = Self(state: .waiting(.posix(.ECONNREFUSED)), status: .satisfied, reason: .notAvailable)
    static let unanswered = Self(state: .waiting(.posix(.ETIMEDOUT)), status: .satisfied, reason: .notAvailable)
    /// Kept waiting by the system for want of the permission, as the technote has it.
    static let denied = Self(state: .waiting(.posix(.ENETDOWN)), status: .unsatisfied,
                             reason: .localNetworkDenied)
    static let failedDenied = Self(state: .failed(.posix(.ENETDOWN)), status: .unsatisfied,
                                   reason: .localNetworkDenied)
    static let noNetwork = Self(state: .waiting(.posix(.ENETDOWN)), status: .unsatisfied, reason: .notAvailable)
}

/// A connection the test plays: it comes to what the test says, when the test says, and has gone once the
/// wait ends it or, `thenGoes`, by itself after the last of what it was made with.
private final class PlayedConnection: WatchedConnection, @unchecked Sendable {
    let sightings: AsyncStream<LocalNetwork.Sighting>
    private let continuation: AsyncStream<LocalNetwork.Sighting>.Continuation
    private let lock = NSLock()
    private var ended = false

    init(_ comesTo: [LocalNetwork.Sighting], thenGoes: Bool = false) {
        (sightings, continuation) = AsyncStream.makeStream(of: LocalNetwork.Sighting.self)
        for sighting in comesTo { continuation.yield(sighting) }
        if thenGoes { continuation.finish() }
    }

    func comes(to sighting: LocalNetwork.Sighting) {
        continuation.yield(sighting)
    }

    func stop() {
        lock.withLock { ended = true }
        continuation.finish()
    }

    var stopped: Bool { lock.withLock { ended } }
}

/// What a wait under test reaches: the connections it is handed, in order, and what it did meanwhile -- how
/// often it said the permission was in the way, each pause it asked for, each line it wrote, and whether it
/// is over. Behind a lock: the wait runs in a task of its own while the test looks.
private final class Played: @unchecked Sendable {
    private let lock = NSLock()
    private var lined: [PlayedConnection]
    private let rest: (@Sendable () -> PlayedConnection)?
    private var connections: [PlayedConnection] = []
    private var blocked = 0
    private var paused: [Duration] = []
    private var written: [String] = []
    private var isOver = false

    init(_ lined: [PlayedConnection] = [], thenAlways rest: (@Sendable () -> PlayedConnection)? = nil) {
        self.lined = lined
        self.rest = rest
    }

    /// The wait, on the connections this hands out, pausing for no time at all.
    func wait() async -> LocalNetwork.Access {
        let access = await LocalNetwork.waitForAccess(connecting: { self.connect() },
                                                      pause: { self.paused(for: $0) },
                                                      note: { self.wrote($0) }) { self.saidBlocked() }
        lock.withLock { isOver = true }
        return access
    }

    /// The next connection: one that has already gone, when the test lined up no more.
    func connect() -> PlayedConnection {
        lock.withLock {
            let next = lined.isEmpty ? rest?() ?? PlayedConnection([], thenGoes: true) : lined.removeFirst()
            connections.append(next)
            return next
        }
    }

    func saidBlocked() { lock.withLock { blocked += 1 } }
    func paused(for time: Duration) { lock.withLock { paused.append(time) } }
    func wrote(_ line: String) { lock.withLock { written.append(line) } }

    var made: [PlayedConnection] { lock.withLock { connections } }
    var timesBlocked: Int { lock.withLock { blocked } }
    var pauses: [Duration] { lock.withLock { paused } }
    var lines: [String] { lock.withLock { written } }
    var over: Bool { lock.withLock { isOver } }
}
