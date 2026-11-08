import Foundation

/// Where the guide cache lives, so the screens and the background run open the same file.
enum Storage {
    /// The demo keeps its invented programmes in a database of its own, so that trying it leaves nothing
    /// behind in the cache of a real recorder -- and so that leaving it is a matter of deleting one file.
    /// In `folder`, which for everything but the unit tests is the app's own (`Surroundings.folder`).
    static func guidePath(demo: Bool, in folder: URL) -> String {
        folder.appendingPathComponent(demo ? "guide-demo.sqlite3" : "guide.sqlite3").path
    }

    static func removeDemoGuide(in folder: URL) {
        let path = guidePath(demo: true, in: folder)
        // SQLite leaves a write-ahead log and a shared-memory file beside the database
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
