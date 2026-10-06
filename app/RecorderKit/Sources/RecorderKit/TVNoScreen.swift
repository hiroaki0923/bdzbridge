import Foundation

/// What sending what waits for the television came to in a run with no screen -- the overnight run, the
/// Shortcuts action -- which has no link: it asks once, as far as it can, and the app says what it found.
public enum NoScreenSending: Sendable, Equatable {
    /// Nothing waits that the television could be sent: no row of its, or only rows with a reason on them, or
    /// only rows whose programme is over. It was not asked, and nothing was dropped.
    case nothingWaiting
    /// Nothing answered the first request at its address, or nothing that reads. No round was opened.
    case unreachable
    /// A television answered whose MAC is not the one saved. Its cookie was not sent, and nothing was.
    case anotherAnswered
    /// The round ran, as far as it went. With no registration kept on the phone it stops at its first read
    /// that needs one, before that is sent, as the screens' attach does.
    case sent(PendingQueue.Outcome)
}

public extension NoScreenSending {
    /// What kept the round from going, of the kinds told once (`TVTold`): another television answered, a
    /// registration wanted (a round stopped for want of one), the disk away. Nil for anything else: silence
    /// and answers that say nothing are no state the television is known to be in.
    var stop: TVTold.Stop? {
        switch self {
        case .anotherAnswered:
            return .another
        case .sent(let outcome):
            switch outcome.stopped {
            case .needsPairing?: return .registration
            case .cannotRecord?: return .disk
            case .silent?, .saysNothing?, nil: return nil
            }
        case .nothingWaiting, .unreachable:
            return nil
        }
    }
}

extension NoScreenSending {
    /// What stands in the way of what still waits, as this run found it, in a sentence; nil when nothing
    /// known does.
    ///  - a stop: its sentence (`TVTold.Stop.said`);
    ///  - nothing heard, or silence before any row was sent, found there, turned down or passed over:
    ///    `notAnsweringWithNoScreen`;
    ///  - silence at a create, or at the list read after one the television took: `createMetSilence`;
    ///  - answers that say nothing before any such row: `unreadWithNoScreen`.
    /// Silence or answers that say nothing after such a row are the queue's own to say (`Outcome.says`).
    var inTheWay: String? {
        if let stop { return stop.said }
        if metSilenceAtACreate { return TVDriver.createMetSilence }
        guard learntNothing else { return nil }
        if case .sent(let outcome) = self, outcome.stopped == .saysNothing { return TVDriver.unreadWithNoScreen }
        return TVDriver.notAnsweringWithNoScreen
    }

    /// Whether the run heard nothing of the state the television is in: nothing answered, or silence or
    /// answers that say nothing before any row was sent, found there, turned down or passed over.
    var learntNothing: Bool {
        switch self {
        case .unreachable:
            return true
        case .sent(let outcome):
            guard outcome.stopped == .silent(afterSending: false) || outcome.stopped == .saysNothing else {
                return false
            }
            return (outcome.sent + outcome.alreadyThere + outcome.refused + outcome.deferred).isEmpty
        case .nothingWaiting, .anotherAnswered:
            return false
        }
    }

    /// Whether the round stopped at silence where a reservation may have been made: at a create, or at the
    /// list read after one the television took.
    var metSilenceAtACreate: Bool {
        if case .sent(let outcome) = self { outcome.stopped == .silent(afterSending: true) } else { false }
    }
}

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
        let waiting = (try? await store.pendingReservations()) ?? []
        guard PendingQueue.hasSomethingToSend(waiting, for: ScalarClient.slot, now: now) else {
            return .nothingWaiting
        }
        let identity: String
        do {
            identity = (try await client.wakeOnLANAddress(timeout: 5)).flatMap(WakeOnLan.normalise) ?? ""
        } catch {
            return .unreachable
        }
        // Its cookie would not be good there, and what waits was made for the television registered.
        guard SessionState.recognition(of: identity, knownAs: mac) != .another else { return .anotherAnswered }
        return .sent(await PendingQueue.flush(client: client, store: store, now: now))
    }

    /// What it came to, in words, for the Shortcuts action's answer: every time, nothing told once. Nil when
    /// there is nothing to say: nothing waiting, or a round that found nothing left to send (another sending
    /// had it). For a round: what the queue says of it naming `device`, then what stands in the way
    /// (`inTheWay`) -- silence at a create only when the queue said nothing, since the queue's own sentence
    /// for a round cut short says it then. Joined with 。.
    nonisolated static func says(_ sending: NoScreenSending, naming device: String) -> String? {
        var lines: [String] = []
        if case .sent(let outcome) = sending, let said = outcome.says(naming: device) { lines.append(said) }
        if let inTheWay = sending.inTheWay, lines.isEmpty || !sending.metSilenceAtACreate {
            lines.append(inTheWay)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "。")
    }

    /// Said when the television did not answer a run with no screen.
    nonisolated static let notAnsweringWithNoScreen = "テレビが応答しないため送っていません。次にテレビが答えたときに送ります"
    /// Said when the television's answers to a run with no screen said nothing that reads, before any row.
    nonisolated static let unreadWithNoScreen = "テレビの応答を読み取れなかったため、テレビへの予約は送っていません"
    /// What a notice of reservations that have not reached the television in time ends with, when nothing
    /// known stands in their way.
    nonisolated static let opensToSend = "アプリを開くと送ります"

    /// The notice's first sentence: the first of `rows` by its title and its start in Japan, and how many
    /// more. The start is written out here and not by a formatter, as `ScalarClient.said` writes one, so that
    /// nothing of the phone's clock style gets in.
    nonisolated static func notYetAtTheTelevision(_ rows: [PendingReservation]) -> String {
        guard let first = rows.first else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: first.request.start)
        let start = String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let more = rows.count > 1 ? "、ほか \(rows.count - 1) 件" : ""
        return "テレビにまだ届いていない予約があります（「\(first.request.title)」\(start) から\(more)）"
    }
}

/// What the runs with no screen have told the reader of the television, kept between runs by the app: the
/// stop told last, and the rows told of as not having reached it in time.
public struct TVTold: Codable, Sendable, Equatable {
    public enum Stop: String, Codable, Sendable {
        case another, registration, disk

        /// Its sentence, the one the screens say for it.
        public var said: String {
            switch self {
            case .another: TVDriver.anotherAnswered
            case .registration: ScalarError.notRegistered.explanation
            case .disk: ScalarClient.diskNotFound
            }
        }
    }

    public var stop: Stop?
    /// The ids of the rows told of, while they still wait, are not over and are due before the next run.
    public var rows: Set<String>

    public init(stop: Stop? = nil, rows: Set<String> = []) {
        self.stop = stop
        self.rows = rows
    }

    /// What to tell after a run that came to `sending`, and what is told from then on. `waiting` is the
    /// phone's queue read after the run (nil when it could not be read); `nextRun` is when the next overnight
    /// run is asked for; `device` the word for the television in a sentence.
    ///
    /// A row is late when it waits for the television with no reason on it, is not over, starts before the
    /// next run and is not one this round made or found there -- whose removal from the queue can fail
    /// behind another writer and leave it read as waiting. One on air is late as well: it is still sent, and
    /// records what is left. A late row is told once, in a notice of its own, with what stands in its way or,
    /// where nothing known does, that opening the app sends it. The notice is about every late row, those told
    /// before included: it takes the place of the last one, and one about the new rows alone would take the
    /// warning of an earlier row away while that row is still late. It is taken away once none of the rows it
    /// told of waits to go.
    ///
    /// What became of the queue is told when it is news, as the recorder's run tells it, and so is a stop the
    /// reader was not told last, unless the late notice carries it already, and silence at a create when
    /// the queue said nothing. A television that does not answer, or answers with nothing that reads, is no
    /// state it is known to be in, and is never told here on its own: the recorder's run says nothing of a
    /// recorder that does not answer either.
    ///
    /// The stop told last is forgotten once nothing waits, and after a round that got as far as a row; a run
    /// that learnt nothing of the television leaves it as it was. Silence at a create is no lasting state: it
    /// is said each time and never kept.
    public func after(_ sending: NoScreenSending, waiting: [PendingReservation]?, before nextRun: Date,
                      now: Date, naming device: String) -> (notices: TVNotices, told: TVTold) {
        var outcome: PendingQueue.Outcome?
        if case .sent(let round) = sending { outcome = round }
        let settled = Set(((outcome?.sent ?? []) + (outcome?.alreadyThere ?? [])).map(\.id))
        let late = waiting?.filter { row in
            row.target == ScalarClient.slot && row.problem == nil && row.request.end >= now
                && row.request.start < nextRun && !settled.contains(row.id)
        }
        let new = late?.filter { !rows.contains($0.id) } ?? []

        var notices = TVNotices()
        if let late, !new.isEmpty {
            notices.notYet = TVDriver.notYetAtTheTelevision(late) + "。"
                + (sending.inTheWay ?? TVDriver.opensToSend)
        }
        var queue: [String] = []
        if let outcome, !outcome.isEmpty, let said = outcome.says(naming: device) { queue.append(said) }
        if notices.notYet == nil {
            if let stop = sending.stop, stop != self.stop { queue.append(stop.said) }
            if sending.metSilenceAtACreate, queue.isEmpty { queue.append(TVDriver.createMetSilence) }
        }
        notices.queue = queue.isEmpty ? nil : queue.joined(separator: "。")

        var told = self
        if sending == .nothingWaiting {
            told.stop = nil
        } else if !sending.learntNothing {
            told.stop = sending.stop
        }
        if let late {
            told.rows = Set(late.map(\.id))
            // A notice of this run's has rows, so it never comes with a withdrawal.
            notices.withdrawsNotYet = !rows.isEmpty && told.rows.isEmpty
        }
        return (notices, told)
    }
}

/// What a run with no screen has to tell of the television, as notifications.
public struct TVNotices: Sendable, Equatable {
    /// What became of what waited for it, and why it could not go when that is news. Nil for nothing.
    public var queue: String?
    /// The rows that start before the next overnight run and have not reached it, all of them whenever one is
    /// new, and what stands in their way. Nil for nothing.
    public var notYet: String?
    /// None of the rows the last such notice told of waits to go any more: it is to be taken away. Never with
    /// a `notYet` of this run, which takes its place.
    public var withdrawsNotYet: Bool

    public init(queue: String? = nil, notYet: String? = nil, withdrawsNotYet: Bool = false) {
        self.queue = queue
        self.notYet = notYet
        self.withdrawsNotYet = withdrawsNotYet
    }
}
