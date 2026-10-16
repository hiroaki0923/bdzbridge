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

/// The clients one link has made, numbered in the order they were made: which of them are retired -- made for
/// a device the link has since let go of -- and, at each address, which one has a request on the wire there.
/// The session holds it beside the count it moves with (`SessionState.timesLetGo`), and the link's driver hands
/// it to every client it makes (`LinkDriver.makeClient`); a client made anywhere else -- the runs with no
/// screen, a search, a registration -- has none.
///
/// Retired on the main actor, in the same turn as the let-go, and asked by each client in its own queue, off
/// the main actor: so a lock rather than an actor, which a client would have to give its turn up to.
final class LinkClients: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    /// Every client numbered below this is retired.
    private var retiredBelow = 1
    /// At each address, the client with a request on the wire there and those waiting for it, in the order
    /// their waits began.
    private var wires: [String: Wire] = [:]
    private var waitsBegun = 0

    private struct Wire {
        var holder: Int?
        var waiting: [Waiting] = []
    }

    private struct Waiting {
        let wait: Int
        let client: Int
        let resume: CheckedContinuation<Bool, Never>
        let limit: Task<Void, Never>
    }

    /// The place of a client the link has just made: the next number.
    func enrol() -> LinkPlace {
        let number: Int = lock.withLock {
            made += 1
            return made
        }
        return LinkPlace(clients: self, number: number)
    }

    /// Every client made so far is retired: the link has let go of its device.
    func retireAll() {
        lock.withLock { retiredBelow = made + 1 }
    }

    /// Every client made before `client` is retired: the device the attach on `client` heard is another.
    func retire(before client: Int) {
        lock.withLock { retiredBelow = max(retiredBelow, client) }
    }

    /// Whether the device `client` was made for has been let go of since.
    func isRetired(_ client: Int) -> Bool {
        lock.withLock { client < retiredBelow }
    }

    /// Returns once no other client of the link has a request on the wire at `host`, and puts `client`'s down
    /// there, or once `limit` seconds have gone by first. True when it was put down, which the caller takes up
    /// again as its transport returns (`release`); false when the limit came first, and nothing was put down.
    func claimTheWire(at host: String, for client: Int, waitingAtMost limit: TimeInterval) async -> Bool {
        await withCheckedContinuation { resume in
            let free: Bool = lock.withLock {
                if wires[host]?.holder ?? client == client {
                    wires[host, default: Wire()].holder = client
                    return true
                }
                waitsBegun += 1
                let wait = waitsBegun
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit))
                    if !Task.isCancelled { self?.giveUp(wait, at: host) }
                }
                wires[host, default: Wire()].waiting.append(
                    Waiting(wait: wait, client: client, resume: resume, limit: timer))
                return false
            }
            if free { resume.resume(returning: true) }
        }
    }

    /// `client`'s request at `host` has come back: the wire goes to whoever has waited longest for it there.
    func release(at host: String, by client: Int) {
        let next: Waiting? = lock.withLock {
            guard wires[host]?.holder == client else { return nil }
            guard var wire = wires[host], !wire.waiting.isEmpty else {
                wires[host] = nil
                return nil
            }
            let next = wire.waiting.removeFirst()
            wire.holder = next.client
            wires[host] = wire
            return next
        }
        next?.limit.cancel()
        next?.resume.resume(returning: true)
    }

    /// The wait numbered `wait` has gone on for as long as its request may: it goes without the wire.
    private func giveUp(_ wait: Int, at host: String) {
        let ended: Waiting? = lock.withLock {
            guard let index = wires[host]?.waiting.firstIndex(where: { $0.wait == wait }) else { return nil }
            return wires[host]?.waiting.remove(at: index)
        }
        ended?.resume.resume(returning: false)
    }
}

/// A client's place among the clients of the link that made it (`LinkClients`).
struct LinkPlace: Sendable {
    let clients: LinkClients
    let number: Int
}
