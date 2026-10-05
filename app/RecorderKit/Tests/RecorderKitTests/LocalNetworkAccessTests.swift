import Network
import XCTest
@testable import RecorderKit

/// The permission itself cannot be tested here: the Mac running the tests answers the question for the
/// terminal, not for the app, and the simulator does not implement it at all. What can be held still is how
/// a path is read, and that a probe ends.
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

        let allowed = await LocalNetwork.waitForAccess(probing: "127.0.0.1") {
            XCTFail("loopback is never held back by local network privacy")
        }
        XCTAssertTrue(allowed)
    }

    /// Leaving the tutorial or turning to the demo cancels the scan that is waiting, and the scan must then
    /// stop rather than take the wait's end for a yes. Cancelled before it starts, so that loopback's
    /// immediate answer cannot win a race with the cancelling.
    func testACancelledWaitIsNotAYes() async {
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LocalNetwork.waitForAccess(probing: "127.0.0.1") {}
        }
        expectFalse(await waiting.value)
    }
}
