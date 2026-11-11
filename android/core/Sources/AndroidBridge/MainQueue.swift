import Foundation

// On Android nothing runs Swift's main queue, and so nothing runs a job on the main actor: much of RecorderKit, and
// the app's model, would wait there for ever. Foundation's run loop serves the main queue whenever it runs on the main
// thread, as it does under UIKit on an iPhone. Android's main thread belongs to its looper, which nothing else may
// take over, so the app runs Foundation's run loop for a moment at a time from that thread (MainActivity).

/// Runs what has come to the main queue since the last call, and returns at once, without waiting for more. Called
/// from the app's main thread, again and again while the app is on screen. Elsewhere the platform runs the main
/// queue itself, and this does nothing.
///
/// What it answers is whether the queue is to be run on although the app has left the screen: a step of a bulk job
/// is in hand (`StepsHeld`), which is finished rather than frozen half way.
@discardableResult
public func runWhatWaitsOnTheMainQueue() -> Bool {
    #if os(Android)
    _ = RunLoop.main.run(mode: .default, before: Date())
    #endif
    return StepsHeld.shared.any
}

/// The steps of a bulk job whose time has been begun and not yet ended (`Surroundings.holdTime`), counted where the
/// thread that runs the main queue can read it.
final class StepsHeld: @unchecked Sendable {
    static let shared = StepsHeld()
    private let lock = NSLock()
    private var count = 0

    var any: Bool { lock.withLock { count > 0 } }

    func begin() {
        lock.withLock { count += 1 }
    }

    func end() {
        lock.withLock { count = max(0, count - 1) }
    }
}
