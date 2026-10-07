import Foundation
import os

/// What a search for a recorder leaves in the system's log (subsystem `RecorderKit`, category `scan`), so that
/// a press on a phone can be read afterwards: how long each look through the subnet took and how its requests
/// came back, what became of the single requests after a look that was turned away, and each change of the
/// app's phase meanwhile. The link's wait for the local network permission writes here too: what its
/// connection came to and what ended the wait; and so does the link's one look at the permission, what it read
/// or that it read nothing, and how long it took. What the system does behind its question about the local
/// network is seen nowhere but on a phone, and this is where it is seen.
///
/// Counts and codes, never an address or a name, nor anything else a device said of itself or that tells one
/// home from another. A line is written as public text, since one the system has blanked cannot be read off a
/// phone: so whoever writes one puts nothing in it but words of the app's own and numbers of those kinds.
///
/// At the default level, which the system keeps for a while after the fact. The debug level `WakeOnLan` writes
/// at is gone unless somebody was watching at the time.
public enum ScanLog {
    private static let log = Logger(subsystem: "RecorderKit", category: "scan")

    public static func note(_ line: String) {
        log.notice("\(line, privacy: .public)")
    }
}
