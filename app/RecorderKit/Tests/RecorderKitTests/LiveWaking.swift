import Foundation
import RecorderKit

/// What the live recorder tests do first when RECORDER_MAC is given as well as RECORDER_HOST: wake the recorder as
/// the app does, with its magic packet to the addresses the app sends one to, then ask the recorder who it is
/// (`describe`, through the app's own wait, which sends the packet again as it goes) until it answers or a minute
/// has passed, and print how long that took. A recorder that has left the network answers nothing, and a test run
/// against it would only meet silence. Without RECORDER_MAC nothing is sent and nothing is waited for.
///
///     RECORDER_HOST=192.0.2.63 RECORDER_MAC=<the recorder's MAC> swift test --filter LiveRecorderTests
///
/// The MAC is taken from the environment only, and is never printed or written down: it is the recorder's own.
enum LiveWaking {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Hands back when the recorder answered after the packet, for a test that times what it reads from there;
    /// nil when nothing was sent.
    @discardableResult
    static func wakeTheRecorderIfAsked() async throws -> ContinuousClock.Instant? {
        let environment = ProcessInfo.processInfo.environment
        guard let mac = environment["RECORDER_MAC"], !mac.isEmpty,
              let host = environment["RECORDER_HOST"], !host.isEmpty else { return nil }
        guard WakeOnLan.normalise(mac) != nil else { throw Failure(description: "RECORDER_MAC is not a MAC address") }
        let addresses = WakeOnLan.addresses(forRecorderAt: host)
        let began = ContinuousClock.now
        guard WakeOnLan.wake(mac, addresses: addresses) > 0 else {
            throw Failure(description: "the magic packet did not go out")
        }
        // As long as the overnight run waits for it, which is a minute.
        let outcome = await Waking.waitForAnswer(from: RecorderClient(host: host), limit: Waking.backgroundLimit,
                                                 resend: { _ = WakeOnLan.wake(mac, addresses: addresses) })
        let answered = ContinuousClock.now
        let took = String(format: "%.2f s", (answered - began) / .seconds(1))
        guard outcome == .answered else {
            throw Failure(description: "no answer \(took) after the magic packet (\(outcome))")
        }
        print("woken: the recorder answered \(took) after the magic packet")
        return answered
    }
}
