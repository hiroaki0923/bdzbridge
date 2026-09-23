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
        /// Refused by the recorder this time, each keeping the reason. Still in the queue, and not sent again
        /// until the reader asks. Only the ones refused now: those refused before are in `held`.
        public var refused: [PendingReservation] = []
        /// Not sent this time for a reason that passes -- the recorder busy with another request, an answer
        /// with no reason in it -- and still waiting, as they were, to go at the next chance.
        public var deferred: [PendingReservation] = []
        /// Refused on an earlier try and not sent this time: see `flush`.
        public var held: [PendingReservation] = []
        /// True when the recorder stopped answering part way through, so the rest were left alone.
        public var interrupted = false

        /// Whether anything happened that the reader has not been told about. `deferred` and `held` are not
        /// news: the first are waiting as they were, the second were reported when they were refused.
        public var isEmpty: Bool { sent.isEmpty && expired.isEmpty && refused.isEmpty }
    }

    /// A programme already over is dropped rather than sent; one on air is still sent, because the recorder
    /// records what is left of it. A recorder that goes away mid-flush leaves the rest queued.
    ///
    /// One the recorder refused with a reason of its own (`RecorderError.refusal`) keeps that reason and is
    /// not sent again: the answer would be the same, and the overnight run asked every night and said every
    /// morning that the recorder had not taken it. It waits for the reader, who can clear the reason to send
    /// it again (`GuideStore.setPendingProblem(_:nil)`) or cancel it. A failure that says nothing about the
    /// reservation -- a 503, an answer with no code -- leaves it waiting as it was, to be sent next time.
    ///
    /// One flush at a time in the process, whoever asks: a second waits for the first to finish and then
    /// reads the queue afresh. The screens and the overnight run each have a client and a connection of their
    /// own, and the system can start the one while the reader has the other open, so the two could read the
    /// same waiting reservation and both send it -- and a reservation sent twice is made twice.
    public static func flush(client: RecorderClient, store: GuideStore,
                             now: Date = Date()) async -> Outcome {
        // Nothing in it throws, so neither does running it.
        (try? await oneAtATime.run { await send(client: client, store: store, now: now) }) ?? Outcome()
    }

    private static let oneAtATime = SerialQueue()

    private static func send(client: RecorderClient, store: GuideStore, now: Date) async -> Outcome {
        var outcome = Outcome()
        let waiting = (try? await store.pendingReservations()) ?? []
        for pending in waiting {
            if pending.request.end < now {
                try? await store.removePending(pending.id)
                outcome.expired.append(pending)
                continue
            }
            if pending.problem != nil {
                outcome.held.append(pending)
                continue
            }
            do {
                _ = try await client.createReservation(pending.request)
                try? await store.removePending(pending.id)
                outcome.sent.append(pending)
            } catch let error as RecorderError where error.unreachable {
                outcome.interrupted = true
                break
            } catch let error as RecorderError where error.refusal {
                try? await store.setPendingProblem(pending.id, error.explanation)
                var refused = pending
                refused.problem = error.explanation
                outcome.refused.append(refused)
            } catch {
                // Nothing written on it: a reason on the row is what holds a reservation back, and nothing
                // here says this one is wrong.
                outcome.deferred.append(pending)
            }
        }
        return outcome
    }
}
