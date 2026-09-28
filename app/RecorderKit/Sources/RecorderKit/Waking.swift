import Foundation

/// Waiting for the recorder to come back after a magic packet: asking it who it is, again and again, until it
/// answers or the time is up.
///
/// One implementation for everything that wakes the recorder -- the screens, connecting and making sure of it
/// before an operation, and the overnight run and the Shortcuts action -- for the reason `PendingQueue` and
/// `GuideRefresh` live here. The two loops this replaced had drifted apart: in the order they asked, slept and
/// sent the packet again, in how long they waited, and in what a cancelled task did, and what was learnt in
/// one of them did not reach the other.
///
/// Sending the packet is the caller's. The first goes before the caller's first probe (docs/porting.md), so
/// that a recorder that is asleep is already on its way up while the probe waits; `resend` sends the rest.
/// Nothing here puts anything on the LAN by itself: the app keeps packets off it in the sample-data mode and
/// in its tests, and a port to another platform sends them its own way.
public enum Waking {
    public enum Outcome: Sendable, Equatable {
        /// The recorder described itself.
        case answered
        /// The limit passed with no answer. An error is no answer either: a 503 is the recorder busy with
        /// somebody else, and one still starting up may answer anything.
        case silent
        /// The caller's task was cancelled. A request already under way was finished first (`SerialQueue`).
        case cancelled
    }

    /// For the screens, where the reader watches the seconds count up. A BDZ-FBT4100 answers six to eleven
    /// seconds after the packet, so half a minute is generous.
    public static let screenLimit: TimeInterval = 30
    /// For the overnight run and the Shortcuts action, which nobody watches.
    public static let backgroundLimit: TimeInterval = 60

    /// Asks the recorder for its description every `interval` until it answers or `limit` has passed, and has
    /// `resend` send the packet again whenever `resendEvery` has gone by since the last one, the first of which
    /// went at `packetSentAt`. `waited` is told the whole seconds waited so far before each ask, for a line on
    /// screen that counts them.
    ///
    /// Bounded by the clock rather than by a count of asks, so that the line on screen and the wait behind it
    /// are the same length. Each ask is a short one (`RecorderClient.wakeProbeTimeout`), for the identity only:
    /// asking for everything is for after the recorder has shown it is listening. There is no default limit;
    /// the caller says whose wait it is.
    public static func waitForAnswer(from client: RecorderClient, limit: TimeInterval,
                                     interval: Duration = .seconds(1),
                                     resendEvery: TimeInterval = WakeOnLan.resendInterval,
                                     packetSentAt: Date = Date(),
                                     resend: @Sendable () async -> Void,
                                     waited: @Sendable (Int) async -> Void = { _ in }) async -> Outcome {
        let started = Date()
        // From the packet, not from the start of the wait: a caller that probed before waiting sent its packet
        // five seconds earlier, and counting from here had the second one go ten seconds after the first.
        var sent = packetSentAt
        while Date().timeIntervalSince(started) < limit {
            if Task.isCancelled { return .cancelled }
            await waited(Int(Date().timeIntervalSince(started)))
            if (try? await client.describe(timeout: RecorderClient.wakeProbeTimeout)) != nil { return .answered }
            // A cancelled sleep throws at once. Passed over with `try?`, a cancelled wait went round without
            // sleeping, a probe after a probe, with the overnight task already completed.
            do {
                try await Task.sleep(for: interval)
            } catch {
                return .cancelled
            }
            if Date().timeIntervalSince(sent) >= resendEvery {
                await resend()
                sent = Date()
            }
        }
        return .silent
    }
}
