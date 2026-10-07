import Foundation

/// Looking through the subnet for a television, by the loop a look for a recorder goes through
/// (`Discovery.look`). Each address is asked through a client of its own (`ScalarClient`) with nothing
/// registered in it, so that what goes to each is a request the app sends a television anyway, in the same
/// envelope, and carries neither a cookie nor a PIN.
public enum TVDiscovery {
    /// The address of the television whose MAC is `mac`, or nil when none of `hosts` answers with it: for a
    /// television that is no longer where it was, its address being a DHCP lease the router hands out again as
    /// it likes. One request to each address, `getSystemSupportedFunction` 1.0, which needs no registration and
    /// is what an attach asks a television first; the MACs are compared normalised, and the look stops at the
    /// first that matches. Another television's MAC is not the one asked for, whatever else it answers.
    public static func find(mac: String, among hosts: [String], transport: any HTTPTransport,
                            timeout: TimeInterval = 1.2, atOnce: Int = 48) async -> String? {
        guard let wanted = WakeOnLan.normalise(mac) else { return nil }
        let found = await Discovery.look(hosts: hosts, atOnce: atOnce, until: { _ in true }) { host in
            await Discovery.raced(timeout) {
                await leftWhenCancelled { () -> String? in
                    let client = ScalarClient(host: host, transport: transport, credentials: MemoryTVCredentials())
                    guard let given = try? await client.wakeOnLANAddress(timeout: timeout),
                          WakeOnLan.normalise(given) == wanted else { return nil }
                    return host
                }
            }.map { [$0] } ?? []
        }
        return found.first
    }

    /// What `ask` hands back, or nil as soon as the task waiting for it is cancelled: by the deadline of the
    /// probe it is part of, or by the end of the look. A television's client lets no request go half way --
    /// one at a time, and none dropped for its caller being cancelled (`SerialQueue`) -- so a probe that waited
    /// for its request would hold the look for as long as that request lasts, which is what the deadline is
    /// there to stop. The request goes on by itself, and its answer is dropped.
    ///
    /// A probe that begins once the look is over -- its task cancelled before it started, which hands the wait
    /// its nil at once -- sends nothing: the task that would ask is a task of its own, which knows nothing of
    /// that cancellation, so it asks only while the wait is still open.
    static func leftWhenCancelled<Value: Sendable>(_ ask: @escaping @Sendable () async -> Value?) async -> Value? {
        let answer = FirstAnswer<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting in
                answer.wait(waiting)
                Task {
                    guard !answer.ended else { return }
                    answer.give(await ask())
                }
            }
        } onCancel: {
            answer.give(nil)
        }
    }
}

/// The first of two ends -- the answer, or the cancellation -- handed to whoever waits, whichever comes first
/// and whether or not it is waiting yet; the second is dropped.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Value?, Never>?
    private var given: Value??

    /// Whether one end has come already.
    var ended: Bool { lock.withLock { given != nil } }

    func wait(_ continuation: CheckedContinuation<Value?, Never>) {
        let ready: Value?? = lock.withLock {
            if given == nil { waiting = continuation }
            return given
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func give(_ value: Value?) {
        let waiter: CheckedContinuation<Value?, Never>? = lock.withLock {
            guard given == nil else { return nil }
            given = .some(value)
            defer { waiting = nil }
            return waiting
        }
        waiter?.resume(returning: value)
    }
}
