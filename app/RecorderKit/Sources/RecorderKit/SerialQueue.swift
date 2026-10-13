import Foundation

/// Runs its work one piece at a time, in the order the calls arrive.
///
/// An actor alone would not do: it lets other calls in whenever the current one suspends at an `await`, which
/// is exactly what a network request does. The recorder answers 503 to concurrent requests, so each piece of
/// work waits for the previous one to finish.
///
/// Cancelling a caller changes nothing here: the work runs in a task of its own, and the caller goes on waiting
/// for it. A write the recorder has begun to apply wants that, and a request abandoned half way would look to
/// the caller like silence, which is read as the recorder gone. Whoever has to stop sooner -- the overnight
/// run, when the system's time for it is up -- looks at its own cancellation between requests.
actor SerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ work: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            if let previous { await previous.value }
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// One at a time as well, for work that has to stay in the task that asked for it: a turn that is waited for,
/// taken in the order it was asked for, and given back.
///
/// `SerialQueue` runs each piece of work in a task of its own, which is what makes a caller's cancellation
/// change nothing there. Work that looks at its own cancellation to stop early would never see it from inside
/// such a task: the guide's refresh, which the overnight run asks in the task the system cancels when its time
/// is up, looks before each file (`GuideRefresh.run`), and behind a queue's task it would go on through every
/// file of a night already ended. So whoever has the turn runs its work itself.
///
/// The wait for the turn is not cut short when the caller is cancelled: the work is what looks at that, once
/// the turn is its own, and gives the turn back like any other.
actor Turn {
    private var taken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Returns once the turn is the caller's, which then gives it back, once (`giveBack`).
    func take() async {
        guard taken else {
            taken = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn to whoever has waited longest, or leaves it free.
    func giveBack() {
        if waiting.isEmpty {
            taken = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
