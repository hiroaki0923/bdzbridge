import Foundation

public extension TVDriver {
    /// One attempt at the television for a run with no screen. In this order, each once:
    ///  1. The queue: unless a row of the television's goes by itself and is not over, `nothingWaiting`, and
    ///     nothing is asked.
    ///  2. The MAC it wakes on (`getSystemSupportedFunction`, no cookie, five seconds as a registration waits
    ///     for it), normalised as an attach normalises it and held against `mac` by the rule a connect holds
    ///     it by (`SessionState.recognition(of:knownAs:)`): no MAC saved, or none given, is not another. Any
    ///     failure of the read: `unreachable`. Another: `anotherAnswered`.
    ///  3. The queue's flush for the television, with no consent and no row named.
    /// It is asked in standby. Nothing here can wake it -- there is no packet to send -- and nothing renews
    /// the registration, reads the power, mounts the disk, deletes or turns anything on: after the MAC read,
    /// what goes is the round's own -- the disk and the list, then for each row the stations of its kind
    /// once, the question, the create and the list again.
    nonisolated static func sendWithNoScreen(_ client: ScalarClient, store: GuideStore, knownAs mac: String?,
                                             now: Date = Date()) async -> NoScreenSending {
        await sendWithNoScreen(client, store: store, knownAs: mac, now: now, then: { _ in }).sending
    }

    /// The same, and `then` inside the queue's turn, handed what the sending came to: after the round, in the
    /// round's own turn (`PendingQueue.flush(client:store:consenting:only:now:then:)`), or, with no round, in a
    /// turn of its own. For what the run tells once, decided from what is kept as the turn has it and posted
    /// and kept there (`ToldOnce.after`). What `then` hands back is handed back beside what the sending came to.
    nonisolated static func sendWithNoScreen<After: Sendable>(
        _ client: ScalarClient, store: GuideStore, knownAs mac: String?, now: Date = Date(),
        then: @escaping @Sendable (NoScreenSending) async -> After
    ) async -> (sending: NoScreenSending, after: After) {
        func alone(_ sending: NoScreenSending) async -> (sending: NoScreenSending, after: After) {
            (sending, await PendingQueue.inATurnOfItsOwn { await then(sending) })
        }
        let waiting = (try? await store.pendingReservations()) ?? []
        guard PendingQueue.hasSomethingToSend(waiting, for: ScalarClient.slot, now: now) else {
            return await alone(.nothingWaiting)
        }
        let identity: String
        do {
            identity = (try await client.wakeOnLANAddress(timeout: 5)).flatMap(WakeOnLan.normalise) ?? ""
        } catch {
            return await alone(.unreachable)
        }
        // Its cookie would not be good there, and what waits was made for the television registered.
        guard SessionState.recognition(of: identity, knownAs: mac) != .another else {
            return await alone(.anotherAnswered)
        }
        let (outcome, after) = await PendingQueue.flush(client: client, store: store, now: now) { round in
            await then(.sent(round))
        }
        return (.sent(outcome), after)
    }

    /// What it came to, in words, for the Shortcuts action's answer: every time, nothing told once. Nil when
    /// there is nothing to say: nothing waiting, or a round that found nothing left to send (another sending
    /// had it). For a round: what the queue says of it naming `device`, then what stands in the way
    /// (`inTheWay(after:)`) -- silence at a create only when the queue said nothing, since the queue's own
    /// sentence for a round cut short says it then. Joined with 。.
    nonisolated static func says(_ sending: NoScreenSending, naming device: String) -> String? {
        var lines: [String] = []
        if case .sent(let outcome) = sending, let said = outcome.says(naming: device) { lines.append(said) }
        if let inTheWay = inTheWay(after: sending), lines.isEmpty || !sending.metSilenceAtACreate {
            lines.append(inTheWay)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "。")
    }

    /// What is said of a waiting row the reader asked to delete when a sending whose turn came first made it
    /// (`PendingQueue.betweenFlushes`) -- above all one with no screen, which the screens do not see -- or
    /// when the television lists its programme though the row still waited: a create the television took
    /// whose answer was lost. The queue's own sentence for a row it sent, naming `device`, as the strip and
    /// the notifications say it: the row was made as any sending makes one, and has no sentence of its own.
    nonisolated static func madeBeforeItsDelete(_ row: PendingReservation, naming device: String) -> String {
        PendingQueue.Outcome(slot: ScalarClient.slot, sent: [row]).says(naming: device) ?? ""
    }

    /// Said when the television did not answer a run with no screen.
    nonisolated static let notAnsweringWithNoScreen = "テレビが応答しないため送っていません。次にテレビが答えたときに送ります"
    /// Said when the television's answers to a run with no screen said nothing that reads, before any row.
    nonisolated static let unreadWithNoScreen = "テレビの応答を読み取れなかったため、テレビへの予約は送っていません"
    /// What a notice of reservations that have not reached the television in time ends with, when nothing
    /// known stands in their way.
    nonisolated static let opensToSend = "アプリを開くと送ります"

    /// The notice's first sentence: the first of `rows` by its title and its start in Japan, and how many
    /// more (`ToldOnce.named`).
    nonisolated static func notYetAtTheTelevision(_ rows: [PendingReservation]) -> String {
        rows.isEmpty ? "" : "テレビにまだ届いていない予約があります（\(ToldOnce.named(rows))）"
    }

    /// A stop's sentence for the television (`ToldOnce.Stop`), the one the screens say for it.
    nonisolated static func says(_ stop: ToldOnce.Stop) -> String {
        switch stop {
        case .another: anotherAnswered
        case .registration: ScalarError.notRegistered.explanation
        case .disk: ScalarClient.diskNotFound
        }
    }
}

extension TVDriver {
    /// What stands in the way of what still waits, as a run with no screen that came to `sending` found it,
    /// in a sentence; nil when nothing known does.
    ///  - a stop: its sentence (`says`);
    ///  - nothing heard, or silence before any row was sent, found there, turned down or passed over:
    ///    `notAnsweringWithNoScreen`;
    ///  - silence at a create, or at the list read after one the television took: `createMetSilence`;
    ///  - answers that say nothing before any such row: `unreadWithNoScreen`.
    /// Silence or answers that say nothing after such a row are the queue's own to say (`Outcome.says`).
    nonisolated static func inTheWay(after sending: NoScreenSending) -> String? {
        if let stop = sending.stop { return says(stop) }
        if sending.metSilenceAtACreate { return createMetSilence }
        guard sending.learntNothing else { return nil }
        if case .sent(let outcome) = sending, outcome.stopped == .saysNothing { return unreadWithNoScreen }
        return notAnsweringWithNoScreen
    }
}

public extension NoScreenWords {
    /// The television's. Of a round: what the queue says of it when it is news, and silence at a create, in
    /// its own sentence, only when the queue said nothing and no late notice carries it.
    static let television = NoScreenWords(
        slot: ScalarClient.slot,
        notYet: { TVDriver.notYetAtTheTelevision($0) },
        inTheWay: { TVDriver.inTheWay(after: $0) },
        stop: { TVDriver.says($0) },
        round: { outcome, device, late in
            if !outcome.isEmpty, let said = outcome.says(naming: device) { return said }
            return !late && outcome.stopped == .silent(afterSending: true) ? TVDriver.createMetSilence : nil
        })
}
