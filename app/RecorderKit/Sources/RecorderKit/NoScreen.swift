import Foundation

/// What sending what waits came to in a run with no screen -- the overnight run, the Shortcuts action -- which
/// has no link: it asks once, as far as it can, and the app says what it found. The same four for either
/// device (`RecorderDriver.sendWithNoScreen`, `TVDriver.sendWithNoScreen`): nothing waits that the device
/// could be sent, it was not reached or could not be told from the one the cache is of, another device than
/// that one answered, or the round ran. What is said of each is the device's own: the recorder's is
/// `RecorderDriver.says`, the television's `TVDriver.says` and `TVDriver.inTheWay(after:)`. `stop` and
/// `learntNothing` are read by the rule of what is told once (`ToldOnce.after`) for either device: a recorder
/// has the one stop, another recorder answering, and its run has learnt nothing where nobody was reached or
/// its round met silence before any reservation was sent, found there, turned down or passed over.
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
    /// What kept the round from going, of the kinds told once (`ToldOnce`): another television answered, a
    /// registration wanted (a round stopped for want of one), the disk away. Nil for anything else: silence
    /// and answers that say nothing are no state the television is known to be in.
    var stop: ToldOnce.Stop? {
        switch self {
        case .anotherAnswered:
            return .another
        case .sent(let outcome):
            switch outcome.stopped {
            case .needsPairing?: return .registration
            case .cannotRecord?: return .disk
            case .silent?, .saysNothing?, .notKnownThere?, .letGo?, nil: return nil
            }
        case .nothingWaiting, .unreachable:
            return nil
        }
    }
}

extension NoScreenSending {
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

/// What in the rule of what is told once (`ToldOnce.after`) is a device's own, in one value: whose rows it is
/// about and the device's words for them. The television's is `television` (`TVNoScreen.swift`), which the
/// rule takes unless it is handed another; the recorder's is `recorder` (`RecorderNoScreen.swift`).
public struct NoScreenWords: Sendable {
    /// The device whose rows are told of.
    let slot: DeviceSlot
    /// The first sentence of the notice of reservations that have not reached the device in time.
    let notYet: @Sendable (_ rows: [PendingReservation]) -> String
    /// What stands in the way of what still waits after a run that came to this; nil when nothing known does.
    let inTheWay: @Sendable (NoScreenSending) -> String?
    /// A stop's sentence.
    let stop: @Sendable (ToldOnce.Stop) -> String
    /// What is told of a round that ran, naming the device where a word for it is handed in; nil for nothing.
    /// `late` when the same run posts a notice of reservations that have not reached the device in time.
    let round: @Sendable (_ outcome: PendingQueue.Outcome, _ device: String?, _ late: Bool) -> String?
}

/// What the runs with no screen have told the reader of a device, kept between runs by the app: the stop told
/// last, and the rows told of as not having reached it in time. The television's and the recorder's are kept
/// apart (`TVDriver.sendWithNoScreen`, `RecorderDriver.refreshWithNoScreen`).
public struct ToldOnce: Codable, Sendable, Equatable {
    /// What kept a round from going, of the kinds told once. The recorder has the first of the three alone.
    /// Each device says them in its own words (`TVDriver.says`, `NoScreenWords.recorder`).
    public enum Stop: String, Codable, Sendable {
        case another, registration, disk
    }

    public var stop: Stop?
    /// The ids of the rows told of, while they still wait, are not over and are due before the next run.
    public var rows: Set<String>
    /// The television's alone: the registration what is kept was learnt under -- when the cookie of the
    /// registration that the round of the run that learnt it began under arrived, or, with no round, the one in
    /// the store as that run began (`TVCredentials.cookieReceived`, handed on by `TVDriver.sendWithNoScreen`) --
    /// nil for none. A run that learnt nothing carries it on as it was. A registration made again forgets
    /// once more in the queue's turn, after a run that was telling then, only what is kept under a cookie
    /// from before it.
    public var registration: Date?

    public init(stop: Stop? = nil, rows: Set<String> = [], registration: Date? = nil) {
        self.stop = stop
        self.rows = rows
        self.registration = registration
    }

    /// What to tell after a run that came to `sending`, and what is told from then on. `waiting` is the
    /// phone's queue read after the run (nil when it could not be read); `nextRun` is when the next overnight
    /// run is asked for; `device` the word for the device in the queue's sentences, nil where they name none.
    /// The rule is one for both devices: whose rows it is about and every sentence are `words`, the
    /// television's unless the recorder's are handed in.
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
    /// state it is known to be in, and is never told here on its own; nor is a recorder that does not answer,
    /// which its run tells of only at the end of a late notice.
    ///
    /// The stop told last is forgotten once nothing waits, and after a round that got as far as a row; a run
    /// that learnt nothing of the television leaves it as it was. Silence at a create is no lasting state: it
    /// is said each time and never kept. What is told from then on carries `registration`, the television's
    /// registration its round began under (`ToldOnce.registration`); after a run that learnt nothing, the one
    /// it was kept under before, which the stop it carries on was learnt under: a registration made since
    /// forgets it, and takes its notices away, as it does what a run told under the registration before.
    /// A round refused for the cookie before the one in the store (`refusedForTheCookieBefore`, handed on by
    /// `TVDriver.sendWithNoScreen`) learnt nothing of the television as it is registered now, unless it got as
    /// far as a row: it carries the stop told before on as such a run does.
    public func after(_ sending: NoScreenSending, waiting: [PendingReservation]?, before nextRun: Date,
                      now: Date, naming device: String?, words: NoScreenWords = .television,
                      registration: Date? = nil,
                      refusedForTheCookieBefore: Bool = false) -> (notices: NoScreenNotices, told: ToldOnce) {
        var outcome: PendingQueue.Outcome?
        if case .sent(let round) = sending { outcome = round }
        let settled = Set(((outcome?.sent ?? []) + (outcome?.alreadyThere ?? [])).map(\.id))
        let late = waiting?.filter { row in
            Self.waitsToGo(row, to: words.slot, now: now) && row.request.start < nextRun
                && !settled.contains(row.id)
        }
        let new = late?.filter { !rows.contains($0.id) } ?? []

        var notices = NoScreenNotices()
        if let late, !new.isEmpty {
            notices.notYet = words.notYet(late) + "。" + (words.inTheWay(sending) ?? TVDriver.opensToSend)
        }
        var queue: [String] = []
        if let outcome, let said = words.round(outcome, device, notices.notYet != nil) { queue.append(said) }
        if notices.notYet == nil, let stop = sending.stop, stop != self.stop { queue.append(words.stop(stop)) }
        notices.queue = queue.isEmpty ? nil : queue.joined(separator: "。")

        let learntNothing = sending.learntNothing || refusedForTheCookieBefore
            && (outcome.map { ($0.sent + $0.alreadyThere + $0.refused + $0.deferred).isEmpty } ?? false)
        var told = self
        if !learntNothing { told.registration = registration }
        if sending == .nothingWaiting {
            told.stop = nil
        } else if !learntNothing {
            told.stop = sending.stop
        }
        if let late {
            told.rows = Set(late.map(\.id))
            // A notice of this run's has rows, so it never comes with a withdrawal.
            notices.withdrawsNotYet = !rows.isEmpty && told.rows.isEmpty
        }
        return (notices, told)
    }

    /// What is told from now on after a sending of the screens' own, `waiting` being the phone's queue read
    /// after it. Nil when nothing changes: no reservation was told of, or one told of still waits to go.
    /// Otherwise the same with none told of, and the warning about them is to be taken away at once: none of
    /// what it was about waits any more, and the next run with no screen, which would take it away, may come
    /// after their programmes have begun. The stop told is left as it was, for the runs with no screen to
    /// hold against what they find, under the registration it was kept under. The rows are those of the
    /// device `words` is of, as in `after`.
    public func afterTheScreensSent(waiting: [PendingReservation], now: Date = Date(),
                                    words: NoScreenWords = .television) -> ToldOnce? {
        guard !rows.isEmpty, !waiting.contains(where: {
            rows.contains($0.id) && Self.waitsToGo($0, to: words.slot, now: now)
        }) else { return nil }
        return ToldOnce(stop: stop, registration: registration)
    }

    /// Whether a row is still to go to the device in `slot` by itself: one of its, with no reason on it,
    /// whose programme is not over.
    private static func waitsToGo(_ row: PendingReservation, to slot: DeviceSlot, now: Date) -> Bool {
        row.target == slot && row.problem == nil && row.request.end >= now
    }

    /// The rows a notice of reservations not yet at a device names them by: the first by its title and its
    /// start in Japan, and how many more. The start is written out here and not by a formatter, as
    /// `ScalarClient.said` writes one, so that nothing of the phone's clock style gets in.
    static func named(_ rows: [PendingReservation]) -> String {
        guard let first = rows.first else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: first.request.start)
        let start = String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let more = rows.count > 1 ? "、ほか \(rows.count - 1) 件" : ""
        return "「\(first.request.title)」\(start) から\(more)"
    }
}

/// What a run with no screen has to tell of a device, as notifications.
public struct NoScreenNotices: Sendable, Equatable {
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
