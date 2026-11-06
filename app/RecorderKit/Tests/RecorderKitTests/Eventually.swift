/// Gives up its turn until `done` says that what is waited for has come, for ten seconds at most, and says
/// whether it came; what follows says what did not.
///
/// By the clock, not by a number of turns: what is waited for may be sent from the main actor or come on a
/// thread, which a task giving up its turn does not wait for, and on a fast machine a hundred thousand turns
/// were over before it came (Android's emulator in CI). Only for what is to come: a check that something does
/// not happen gives it a number of turns, since a wait for it would always last its whole while.
@discardableResult
func eventually(within limit: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
                _ done: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while try await !done() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}
