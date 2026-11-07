import Foundation

// On Android nothing runs Swift's main queue, and so nothing runs a job on the main actor: much of RecorderKit, and
// the app's model, would wait there for ever. Foundation's run loop serves the main queue whenever it runs on the main
// thread, as it does under UIKit on an iPhone. Android's main thread belongs to its looper, which nothing else may
// take over, so the app runs Foundation's run loop for a moment at a time from that thread (MainActivity).

/// Runs what has come to the main queue since the last call, and returns at once, without waiting for more. Called
/// from the app's main thread, again and again while the app is on screen. Elsewhere the platform runs the main
/// queue itself, and this does nothing.
public func runWhatWaitsOnTheMainQueue() {
    #if os(Android)
    _ = RunLoop.main.run(mode: .default, before: Date())
    #endif
}
