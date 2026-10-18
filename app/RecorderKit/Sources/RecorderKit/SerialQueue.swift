import Foundation

/// Runs its work one piece at a time, in the order the calls arrive.
///
/// An actor alone would not do: it lets other calls in whenever the current one suspends at an `await`, which
/// is exactly what a network request does. The recorder answers 503 to concurrent requests, so each piece of
/// work waits for the previous one to finish.
///
/// Cancelling a caller changes nothing here: `run` runs the work in a task of its own, and the caller goes on
/// waiting for it (`whileHeld` runs it in the caller's, for work that looks at its cancellation). A write the
/// recorder has begun to apply wants that, and a request abandoned half way would look to the caller like
/// silence, which is read as the recorder gone. Whoever has to stop sooner -- the overnight run, when the
/// system's time for it is up -- looks at its own cancellation between requests.
///
/// What is handed over goes in its turn, unless the device its client was made for has been let go of by then:
/// a client of a link's asks first, inside its work, whether it is retired (`LinkClients`), and sends nothing
/// if it is.
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

    /// Takes a turn as `run` does, and runs `work` in the caller's own task rather than in one of its own: so
    /// that the work sees the caller's cancellation, which work run in a task of the queue's never does. What
    /// is handed over after it waits until it is over. The wait for the turn is not cut short when the caller is
    /// cancelled: the work is what looks at that, once the turn is its own.
    func whileHeld<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        let previous = tail
        let (over, end) = AsyncStream<Void>.makeStream()
        tail = Task { for await _ in over {} }
        if let previous { await previous.value }
        let done = await work()
        end.finish()
        return done
    }
}

/// One at a time as well, for work that has to stay in the task that asked for it: a turn that is waited for,
/// taken in the order it was asked for, and given back.
///
/// `SerialQueue.run` runs each piece of work in a task of its own, which is what makes a caller's cancellation
/// change nothing there (`whileHeld` keeps it in the caller's). Work that looks at its own cancellation to stop
/// early would never see it from inside such a task: the guide's refresh, which the overnight run asks in the
/// task the system cancels when its time is up, looks before each file (`GuideRefresh.run`), and behind a
/// queue's task it would go on through every file of a night already ended. So whoever has the turn runs its
/// work itself.
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
        /// How many of the holder's claims are not given back yet: a request of its on the wire, and a
        /// description it keeps (`kept`), which a request the client sends next, while it keeps it, adds to.
        var claims = 0
        /// Whether one of the claims is a description the holder keeps (`keep`), given back by `letGoOfTheKept`.
        var kept = false
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
    /// again as its transport returns (`release`) or keeps (`keep`); false when the limit came first, and
    /// nothing was put down. A client that holds the wire already -- a description it keeps -- puts another
    /// claim down at once, and the wire is the others' only once every claim of its is given back.
    func claimTheWire(at host: String, for client: Int, waitingAtMost limit: TimeInterval) async -> Bool {
        await withCheckedContinuation { resume in
            let free: Bool = lock.withLock {
                if wires[host]?.holder ?? client == client {
                    wires[host, default: Wire()].holder = client
                    wires[host]?.claims += 1
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

    /// `client`'s request at `host` has come back: its claim is given back, and once it has none left the wire
    /// goes to whoever has waited longest for it there.
    func release(at host: String, by client: Int) {
        giveBack(at: host, by: client, kept: false)
    }

    /// `client`'s request at `host` has come back with a description it keeps: the claim stays, as the one
    /// `letGoOfTheKept` gives back.
    func keep(at host: String, by client: Int) {
        lock.withLock {
            guard wires[host]?.holder == client else { return }
            wires[host]?.kept = true
        }
    }

    /// Gives back the claim of the description `client` keeps at `host` (`keep`). Nothing when it keeps none.
    func letGoOfTheKept(at host: String, by client: Int) {
        giveBack(at: host, by: client, kept: true)
    }

    private func giveBack(at host: String, by client: Int, kept: Bool) {
        let next: Waiting? = lock.withLock {
            guard var wire = wires[host], wire.holder == client, !kept || wire.kept else { return nil }
            if kept { wire.kept = false }
            wire.claims -= 1
            guard wire.claims == 0 else {
                wires[host] = wire
                return nil
            }
            guard !wire.waiting.isEmpty else {
                wires[host] = nil
                return nil
            }
            let next = wire.waiting.removeFirst()
            wire.holder = next.client
            wire.claims = 1
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

    /// Throws, with nothing sent, once the client is retired (`DeviceLetGo`): asked in the client's queue just
    /// before each request goes, and before each time one is sent again.
    func mayStillSend() throws {
        if clients.isRetired(number) { throw DeviceLetGo() }
    }
}

/// What a client a link made throws in place of sending once it is retired: the device it was made for has
/// been let go of (`LinkClients`), and whatever answers at its address now is not the device it was handed the
/// request for. Not a device's error: nothing was asked, so it is neither silence nor a refusal. What an
/// operation makes of it is `OperationFailure.letGoMeanwhile`; a queue's round stops on it, leaving its rows as
/// they were (`SendingStop.letGo`).
struct DeviceLetGo: Error, Sendable, Equatable {}
