import Foundation

/// Runs its work one piece at a time, in the order the calls arrive.
///
/// An actor alone would not do: it lets other calls in whenever the current one suspends at an `await`, which
/// is exactly what a network request does. The recorder answers 503 to concurrent requests, so each piece of
/// work waits for the previous one to finish.
///
/// Cancelling a caller changes nothing here: the work runs in a task of its own, which the caller's
/// cancellation does not reach, and the caller goes on waiting for it -- its turn, the request and the answer.
/// That is what a write the recorder has begun to apply wants, and it is why cancelling is not made to count
/// here: a request abandoned half way would look to the caller like silence, which is read as the recorder
/// gone. Whoever has to stop sooner -- the overnight run, when the system's time for it is up -- looks at
/// its own cancellation between requests, and does not wait for the one under way to find out.
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
