import Foundation

/// Sending the reservations that were made while their device could not be reached. It lives here rather than
/// in the app so that the screens and the overnight run follow the same rules.
///
/// How a reservation is sent is the device's own (`QueueTarget`): the queue asks the device it is handed to
/// send one waiting row, and reads what that came to. What it sends is what waits for that device
/// (`PendingReservation.target`, `QueueTarget.slot`). A reservation waiting for another device is left as it
/// is: not sent, not dropped, no reason written on it.
public enum PendingQueue {
    public struct Outcome: Sendable, Equatable {
        /// Sent to the device, and gone from the queue.
        public var sent: [PendingReservation] = []
        /// Dropped because the programme had already finished.
        public var expired: [PendingReservation] = []
        /// Refused by the device this time, each keeping the reason. Still in the queue, and not sent again
        /// until the reader asks. Only the ones refused now: those refused before are in `held`.
        public var refused: [PendingReservation] = []
        /// Not sent this time for a reason that passes -- the device busy with another request, an answer
        /// with no reason in it -- and still waiting, as they were, to go at the next chance.
        public var deferred: [PendingReservation] = []
        /// Refused on an earlier try and not sent this time: see `flush`.
        public var held: [PendingReservation] = []
        /// Found on the device already, and gone from the queue: nothing was made for them.
        public var alreadyThere: [PendingReservation] = []
        /// Why the round ended before its rows did, or nil when it went through them all.
        public var stopped: SendingStop?

        /// True when the device stopped answering part way through, so the rest were left alone. Read from
        /// `stopped`: a round that ended for another reason ended with the device still answering.
        public var interrupted: Bool {
            if case .silent = stopped { true } else { false }
        }

        /// Whether anything happened that the reader has not been told about. `deferred` and `held` are not
        /// news: the first are waiting as they were, the second were reported when they were refused. One
        /// found there already is: the reader made the reservation, and it is no longer waiting.
        public var isEmpty: Bool { sent.isEmpty && expired.isEmpty && refused.isEmpty && alreadyThere.isEmpty }
    }

    /// Sends what waits for `client`'s device, in the order it starts. A programme already over is dropped
    /// rather than sent, and nothing is asked of the device for it; one on air is still sent, because the
    /// device records what is left of it. A device that goes away mid-flush leaves the rest queued.
    ///
    /// The device is read for the round (`QueueTarget.openRound`) at the first row that is to go, and only
    /// then: a queue with nothing to send asks it nothing. A round that cannot be opened ends the flush with
    /// every row as it was. A row the opening found on the device leaves the queue unsent, whether or not a
    /// reason is on it.
    ///
    /// One the device refused with a reason of its own keeps that reason and is not sent again, since the
    /// answer would be the same: it waits for the reader to clear the reason (`GuideStore.setPendingProblem`)
    /// or cancel it. A failure that says nothing about the reservation -- a 503, an answer with no code --
    /// leaves it as it was.
    ///
    /// One flush at a time in the process, whoever asks and whichever device it is for: a second waits for the
    /// first and then reads the queue afresh. The screens and the overnight run each have a client and a
    /// connection of their own and can run at once: both could read the same waiting reservation and send it,
    /// and one sent twice is made twice.
    public static func flush<Target: QueueTarget>(client: Target, store: GuideStore,
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

    private static func send<Target: QueueTarget>(client: Target, store: GuideStore, now: Date) async -> Outcome {
        var outcome = Outcome()
        let waiting = ((try? await store.pendingReservations()) ?? []).filter { $0.target == Target.slot }
        var round: Target.Round?
        // The rows the opening found on the device, by id.
        var found: Set<String> = []
        sending: for pending in waiting {
            if pending.request.end < now {
                try? await store.removePending(pending.id)
                outcome.expired.append(pending)
                continue
            }
            let isToGo = pending.problem == nil
            if round == nil, isToGo {
                switch await client.openRound(for: waiting.filter { $0.request.end >= now }) {
                case .stopped(let stop):
                    outcome.stopped = stop
                    break sending
                case .open(let opened, let alreadyThere):
                    round = opened
                    found = alreadyThere
                    // The rows with a reason on them that were passed on the way here are looked up as well.
                    for passed in outcome.held where found.contains(passed.id) {
                        try? await store.removePending(passed.id)
                        outcome.alreadyThere.append(passed)
                    }
                    outcome.held.removeAll { found.contains($0.id) }
                }
            }
            if found.contains(pending.id) {
                try? await store.removePending(pending.id)
                outcome.alreadyThere.append(pending)
                continue
            }
            guard isToGo, let opened = round else {
                outcome.held.append(pending)
                continue
            }
            let (sent, next) = await client.send(pending, consented: false, in: opened)
            round = next
            switch sent {
            case .made:
                try? await store.removePending(pending.id)
                outcome.sent.append(pending)
            case .alreadyThere:
                try? await store.removePending(pending.id)
                outcome.alreadyThere.append(pending)
            case .refused(let reason):
                try? await store.setPendingProblem(pending.id, reason)
                var refused = pending
                refused.problem = reason
                outcome.refused.append(refused)
            case .passedOver:
                outcome.deferred.append(pending)
            case .stopped(let stop, let passedOver):
                if passedOver { outcome.deferred.append(pending) }
                outcome.stopped = stop
                break sending
            }
        }
        return outcome
    }
}
