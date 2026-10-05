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
        /// The device the round was for: the one whose rows were taken (`QueueTarget.slot`).
        public var slot: DeviceSlot
        /// Sent to the device, and gone from the queue.
        public var sent: [PendingReservation] = []
        /// What making those did beyond the rows themselves: the sentences the device handed back with the
        /// rows it made (`RowSent.made`), in the order they were made. None from a device that has nothing
        /// to add, which the recorder is.
        public var remarks: [String] = []
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
    /// every row that is not over as it was. A row the opening found on the device leaves the queue unsent,
    /// whether or not a reason is on it.
    ///
    /// One the device refused with a reason of its own keeps that reason and is not sent again, since the
    /// answer would be the same: it waits for the reader to clear the reason (`GuideStore.setPendingProblem`)
    /// or cancel it. A failure that says nothing about the reservation -- a 503, an answer with no code --
    /// leaves it as it was.
    ///
    /// `consenting`: the rows the reader has said to make though they stop another reservation from
    /// recording, each by its id with the reason the reader consented to, letter for letter. A consent is
    /// given to a sentence: a row is consented only while the reason it carries, in the turn it is sent, is
    /// that one. Then it is sent though a reason is on it: the device is told of the consent, and what it
    /// makes of it is the device's. A row whose reason has been written anew since the reader saw it is held
    /// as any row with a reason is, so that two sendings begun on one sentence cannot make what a second
    /// sentence names. A consented row that is passed over keeps its reason here: what becomes of the reason
    /// once the round is over is for whoever handed the consent in (`TVDriver.resend`).
    ///
    /// `only`: the id of the one row to send, when the reader asked for that reservation and no other. The
    /// round is then for that row alone, and so is the reading of the device for it. Everything else that
    /// waits for the device is left exactly as it is: not sent, not dropped though its programme is over,
    /// nothing written on it. With none, as whatever sends what waits passes it, every row of the device
    /// is gone through.
    ///
    /// One flush at a time in the process, whoever asks and whichever device it is for: a second waits for the
    /// first and then reads the queue afresh. The screens and the overnight run each have a client and a
    /// connection of their own and can run at once: both could read the same waiting reservation and send it,
    /// and one sent twice is made twice.
    public static func flush<Target: QueueTarget>(client: Target, store: GuideStore,
                                                  consenting: [String: String] = [:], only: String? = nil,
                                                  now: Date = Date()) async -> Outcome {
        // Nothing in it throws, so neither does running it.
        (try? await oneAtATime.run {
            await oneRound(client: client, store: store, consenting: consenting, only: only, now: now)
        }) ?? Outcome(slot: Target.slot)
    }

    /// Whether a flush for `slot` would send anything: one that waits for that device, has not been refused
    /// and whose programme is not over. What is worth asking before a recorder is woken for the queue's sake.
    /// The rest of what waits for it needs no device: the refused ones wait for the reader, and the finished
    /// ones are dropped whenever a flush runs. What waits for another device is not this one's to be woken
    /// for. There is no client here to say which device is meant, so it is named: the recorder, unless said.
    public static func hasSomethingToSend(_ waiting: [PendingReservation], for slot: DeviceSlot = .recorder,
                                          now: Date = Date()) -> Bool {
        waiting.contains { $0.target == slot && $0.problem == nil && $0.request.end >= now }
    }

    private static let oneAtATime = SerialQueue()

    private static func oneRound<Target: QueueTarget>(client: Target, store: GuideStore,
                                                      consenting: [String: String], only: String?,
                                                      now: Date) async -> Outcome {
        var outcome = Outcome(slot: Target.slot)
        let waiting = ((try? await store.pendingReservations()) ?? [])
            .filter { $0.target == Target.slot && (only == nil || $0.id == only) }
        var round: Target.Round?
        // The rows the opening found on the device, by id.
        var found: Set<String> = []
        sending: for pending in waiting {
            if pending.request.end < now {
                try? await store.removePending(pending.id)
                outcome.expired.append(pending)
                continue
            }
            // Against the reason as the queue has it in this turn, not as it was when the reader was asked.
            let consented = consenting[pending.id].map { $0 == pending.problem } == true
            let isToGo = pending.problem == nil || consented
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
            let (came, next) = await client.send(pending, consented: consented, in: opened)
            round = next
            switch came {
            case .made(let remark):
                try? await store.removePending(pending.id)
                outcome.sent.append(pending)
                if let remark { outcome.remarks.append(remark) }
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

public extension PendingQueue {
    /// Said when a reservation could not be kept on the phone because its cache could not be opened. No
    /// device's failure, so no device's sentence.
    static let noCache = "予約を端末に保存できませんでした（端末内のデータベースを開けませんでした）"

    /// Said when a reservation could not be kept on the phone because writing it failed, with the error as
    /// Swift describes it.
    static func couldNotBeKept(_ error: any Error) -> String { "予約を端末に保存できませんでした: \(error)" }
}

public extension PendingQueue.Outcome {
    /// What became of the queue, where the home has one device: the sentences as they have always read. The
    /// body of the overnight notification, and the line the app shows when it sent the queue itself. nil when
    /// there is nothing to say.
    var summary: String? { says(naming: nil) }

    /// What became of the queue, in a few short sentences: one for each way a row went, in the order sent,
    /// found there already, over, refused now, passed over, joined with 。; about the first row by its title,
    /// and how many more went that way. nil when there is nothing to say.
    ///
    /// What the device said of the rows it made (`remarks`) comes straight after the sentence for what was
    /// sent, each as the device worded it, in the order made: it is about those rows, and each names its
    /// own. With none, nothing is added and every sentence reads as it did before a device could say one.
    ///
    /// `device` is the word for the device the round was for, where the home has two and a sentence has to
    /// say which. With none, the sentences are the ones a home with a recorder alone has always read.
    func says(naming device: String?) -> String? {
        var lines: [String] = []
        if !sent.isEmpty {
            lines.append(device.map { "送信待ちだった\(Self.titled(sent))を\($0)に登録しました" }
                ?? "送信待ちだった\(Self.titled(sent))を登録しました")
        }
        lines += remarks
        if !alreadyThere.isEmpty {
            lines.append(device.map { "\(Self.titled(alreadyThere))は\($0)にすでに予約がありました" }
                ?? "\(Self.titled(alreadyThere))はすでに予約されていました")
        }
        if !expired.isEmpty {
            lines.append(device.map { "\($0)宛の\(Self.titled(expired))は放送が終わっていたため、送らずに削除しました" }
                ?? "\(Self.titled(expired))は放送が終わっていたため、送らずに削除しました")
        }
        if !refused.isEmpty {
            lines.append(device.map { "\(Self.titled(refused))は\($0)に登録できませんでした。理由は予約タブにあります" }
                ?? "\(Self.titled(refused))はレコーダーが受け付けませんでした。理由は予約タブにあります")
        }
        if !deferred.isEmpty {
            lines.append(device.map { "\(Self.titled(deferred))は\($0)に送れなかったため、次の機会にもう一度送ります" }
                ?? "\(Self.titled(deferred))は送れなかったため、次の機会にもう一度送ります")
        }
        // Only as the end of something else: an interruption before anything went is the app going offline,
        // which the strip already says. No other stop is said here: each is something about the device, not
        // about the queue.
        if interrupted, !lines.isEmpty {
            lines.append(device.map { "途中で\($0)の応答がなくなったため、残りは次につながったときに送ります" }
                ?? "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "。")
    }

    /// The first by its title, and how many more. "ほか" counts the others, not all of them.
    private static func titled(_ reservations: [PendingReservation]) -> String {
        guard let first = reservations.first else { return "" }
        return reservations.count == 1 ? "「\(first.request.title)」"
            : "「\(first.request.title)」ほか \(reservations.count - 1) 件"
    }
}
