import Foundation

/// Sending the reservations that were made while the recorder could not be reached. It lives here rather than
/// in the app so that the screens and the overnight run follow the same rules.
///
/// What it sends is what waits for the recorder (`PendingReservation.target`). A reservation waiting for
/// another device is left as it is: not sent, not dropped, no reason written on it.
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
    /// One the recorder refused with a reason of its own (`DeviceFailure.turnsTheRequestDown`) keeps that reason
    /// and is not sent again, since the answer would be the same: it waits for the reader to clear the reason
    /// (`GuideStore.setPendingProblem`) or cancel it. A failure that says nothing about the reservation -- a
    /// 503, an answer with no code -- leaves it as it was.
    ///
    /// One flush at a time in the process, whoever asks: a second waits for the first and then reads the queue
    /// afresh. The screens and the overnight run each have a client and a connection of their own and can run
    /// at once: both could read the same waiting reservation and send it, and one sent twice is made twice.
    public static func flush(client: some ReservationTarget, store: GuideStore,
                             now: Date = Date()) async -> Outcome {
        // Nothing in it throws, so neither does running it.
        (try? await oneAtATime.run { await send(client: client, store: store, now: now) }) ?? Outcome()
    }

    /// Whether a flush would send anything: one that waits for the recorder, has not been refused and whose
    /// programme is not over. What is worth asking before the recorder is woken for the queue's sake. The rest
    /// of what waits for it needs no recorder: the refused ones wait for the reader, and the finished ones are
    /// dropped whenever a flush runs. What waits for another device is not the recorder's to be woken for.
    public static func hasSomethingToSend(_ waiting: [PendingReservation], now: Date = Date()) -> Bool {
        waiting.contains { $0.target == .recorder && $0.problem == nil && $0.request.end >= now }
    }

    private static let oneAtATime = SerialQueue()

    private static func send(client: some ReservationTarget, store: GuideStore, now: Date) async -> Outcome {
        var outcome = Outcome()
        let waiting = ((try? await store.pendingReservations()) ?? []).filter { $0.target == .recorder }
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
                try await client.create(pending.request)
                try? await store.removePending(pending.id)
                outcome.sent.append(pending)
            } catch let error as any DeviceError where error.failure == .silent {
                outcome.interrupted = true
                break
            } catch let error as any DeviceError where error.failure.turnsTheRequestDown {
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
