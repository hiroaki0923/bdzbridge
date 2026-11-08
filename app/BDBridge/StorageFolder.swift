import Foundation
import RecBridgeModel
import os

extension Storage {
    /// The guide's path in the app's own folder (`directory()`), for the entries the system calls, which
    /// have no model to ask.
    static func guidePath(demo: Bool = DemoData.on) throws -> String {
        guidePath(demo: demo, in: try directory())
    }

    /// A folder of their own under Application Support, left out of the phone's backups: the guide is some
    /// 28 MB that the recorder hands over again every night. The mark is on the folder rather than on the
    /// files because SQLite deletes its write-ahead log and shared-memory file and makes them again, and a
    /// new file does not carry the mark the old one had. The reader's channel settings and the reservations
    /// waiting to be sent are in the same database, so a restore to another phone brings back neither: the
    /// settings take a minute to make again, and a waiting reservation belongs to the phone it was made on.
    ///
    /// Made once per process, on the first ask: the overnight run and the screens can both ask at once, and
    /// the databases an earlier build kept in Application Support itself are moved in before either opens them.
    static func directory() throws -> URL {
        try folder.withLock { folder in
            if let folder { return folder }
            let made = try makeFolder()
            folder = made
            return made
        }
    }

    private static let folder = OSAllocatedUnfairLock<URL?>(initialState: nil)

    private static func makeFolder() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        var folder = support.appendingPathComponent("Guide", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Not a reason to go without the guide: a folder that could not be marked is backed up, as before.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        for name in ["guide.sqlite3", "guide-demo.sqlite3"] {
            try moveIn(name, from: support, to: folder)
        }
        return folder
    }

    /// Moves a database an earlier build kept in Application Support, with the log and the shared-memory file
    /// beside it: the three together are the database, and the log can hold transactions the database file
    /// does not have yet. The log goes first. Should the database then fail to move, the error is thrown and
    /// nothing is opened -- SQLite would read a log without its database as a database, with most of its pages
    /// missing -- and the next ask moves the database to the log that went ahead of it.
    private static func moveIn(_ name: String, from old: URL, to new: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.appendingPathComponent(name).path),
              !manager.fileExists(atPath: new.appendingPathComponent(name).path) else { return }
        for suffix in ["-wal", "-shm", ""] {
            let from = old.appendingPathComponent(name + suffix)
            guard manager.fileExists(atPath: from.path) else { continue }
            try manager.moveItem(at: from, to: new.appendingPathComponent(name + suffix))
        }
    }
}
