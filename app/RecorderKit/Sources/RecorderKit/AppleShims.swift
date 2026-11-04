#if !canImport(os)
#if canImport(Android)
import Android
#endif
import Foundation

// What the package takes from Apple's `os` module, for a platform that has none, in the shape the package uses
// it: so a file that logs or locks reads the same on Android as on an iPhone.

/// `os.Logger` as `ScanLog` and `WakeOnLan` write to it: a line at the default or the debug level, with what is
/// put into it marked public or not. On Android it goes to the system's log under `<subsystem>.<category>`,
/// read with `adb logcat`; elsewhere it goes nowhere. A value not marked public is left out of the line, as
/// the system's log on an iPhone leaves it out once nobody is watching, so that marking means the same here.
struct Logger: Sendable {
    private let tag: String

    init(subsystem: String, category: String) {
        tag = "\(subsystem).\(category)"
    }

    func notice(_ message: LogMessage) {
        write(message, priority: 4)  // ANDROID_LOG_INFO
    }

    func debug(_ message: LogMessage) {
        write(message, priority: 3)  // ANDROID_LOG_DEBUG
    }

    private func write(_ message: LogMessage, priority: Int32) {
        #if canImport(Android)
        _ = __android_log_write(priority, tag, message.text)
        #endif
    }
}

/// A line for `Logger`, written as one is written for `os.Logger`: `"sent to \(address, privacy: .public)"`.
struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: some Any, privacy: LogPrivacy = .private) {
            text += privacy == .public ? "\(value)" : "<private>"
        }
    }
}

enum LogPrivacy: Sendable {
    case `public`
    case `private`
}

/// `os.OSAllocatedUnfairLock` as `Series` holds its memo in it: one value, read and changed only inside
/// `withLock`.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
