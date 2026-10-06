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
}

/// What a run with no screen has to tell of the television, as notifications.
public struct TVNotices: Sendable, Equatable {
    /// What became of what waited for it, and why it could not go when that is news. Nil for nothing.
    public var queue: String?
    /// The rows that start before the next overnight run and have not reached it, each told once, and what
    /// stands in their way. Nil for nothing.
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
