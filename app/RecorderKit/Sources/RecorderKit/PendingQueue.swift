import Foundation

/// Sending the reservations that were made while the recorder could not be reached.
///
/// One implementation for both callers: the app does this whenever the recorder answers, and the overnight
/// run does it with no screen behind it. The rules are the same either way, which is the point of it living
/// here rather than in the app.
public enum PendingQueue {
    public struct Outcome: Sendable, Equatable {
        /// Sent to the recorder, and gone from the queue.
        public var sent: [PendingReservation] = []
        /// Dropped because the programme had already finished.
        public var expired: [PendingReservation] = []
        /// Still waiting: the recorder refused them, and each keeps the reason.
        public var refused: [PendingReservation] = []
        /// True when the recorder stopped answering part way through, so the rest were left alone.
        public var interrupted = false

        public var isEmpty: Bool { sent.isEmpty && expired.isEmpty && refused.isEmpty }
    }

    /// A programme already over is dropped rather than sent; one on air is still sent, because the recorder
    /// records what is left of it. A recorder that goes away mid-flush leaves the rest queued; one that
    /// refuses a reservation keeps that reason on it instead of being asked again and again.
    public static func flush(client: RecorderClient, store: GuideStore,
                             now: Date = Date()) async -> Outcome {
        var outcome = Outcome()
        let waiting = (try? await store.pendingReservations()) ?? []
        for pending in waiting {
            if pending.request.end < now {
                try? await store.removePending(pending.id)
                outcome.expired.append(pending)
                continue
            }
            do {
                _ = try await client.createReservation(pending.request)
                try? await store.removePending(pending.id)
                outcome.sent.append(pending)
            } catch let error as RecorderError where error.unreachable {
                outcome.interrupted = true
                break
            } catch {
                let reason = (error as? RecorderError)?.explanation ?? String(describing: error)
                try? await store.setPendingProblem(pending.id, reason)
                var refused = pending
                refused.problem = reason
                outcome.refused.append(refused)
            }
        }
        return outcome
    }
}
