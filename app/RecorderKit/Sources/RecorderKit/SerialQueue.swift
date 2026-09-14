import Foundation

/// Runs its work one piece at a time, in the order the calls arrive.
///
/// An actor alone would not do: it lets other calls in whenever the current one suspends at an `await`, which
/// is exactly what a network request does. The recorder answers 503 to concurrent requests, so each piece of
/// work waits for the previous one to finish.
///
/// Cancelling a caller stops it waiting but does not abandon a request that is already on the wire, which is
/// what we want for a write the recorder has begun to apply.
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
