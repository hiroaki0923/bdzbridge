import BackgroundTasks
import Foundation
import os
import RecorderKit

/// Where the guide cache lives, so the screens and the background run open the same file.
enum Storage {
    /// The demo keeps its invented programmes in a database of its own, so that trying it leaves nothing
    /// behind in the cache of a real recorder -- and so that leaving it is a matter of deleting one file.
    static func guidePath(demo: Bool = DemoData.on) throws -> String {
        try directory().appendingPathComponent(demo ? "guide-demo.sqlite3" : "guide.sqlite3").path
    }

    static func removeDemoGuide() {
        guard let path = try? guidePath(demo: true) else { return }
        // SQLite leaves a write-ahead log and a shared-memory file beside the database
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// A folder of their own under Application Support, left out of the phone's backups. The guide is some
    /// 28 MB that the recorder hands over again every night, and it went into every iCloud backup. The mark
    /// is on the folder rather than on the files because SQLite deletes its write-ahead log and shared-memory
    /// file and makes them again, and a new file does not carry the mark the old one had.
    ///
    /// The same database holds the reader's channel settings and the reservations waiting to be sent, which a
    /// restore to another phone therefore does not bring back either. The settings take a minute to make
    /// again, and a reservation waiting for the recorder belongs to the phone it was made on.
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

/// The overnight guide refresh.
///
/// The recorder rebuilds its own guide and logo files in the small hours, so this asks for them after that and
/// the reader wakes up to a guide that is current for the whole eight days, without the app or the LAN. iOS
/// decides whether to run it at all: it will not while the app is force-quit, while Background App Refresh is
/// switched off, or in Low Power Mode. Nothing breaks when a night is missed, which is what makes the guide a
/// fair thing to do this way.
enum BackgroundWork {
    static let refreshIdentifier = "jp.hiroaki.bdbridge.guideRefresh"

    /// Must be called before launching finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: .main) { task in
            guard let processing = task as? BGProcessingTask else { return }
            let handle = Handle(processing)
            schedule()   // ask for tomorrow before doing anything that might be cut short
            let work = Task {
                let refreshed = await refreshNow()
                handle.complete(refreshed)
            }
            // The system wants the task completed as soon as its time is up, and does not wait long for it.
            // Cancelling the work is only a request: the answer under way is waited for whatever the task says
            // (`SerialQueue`), and the work looks for the request only between one step and the next, which on
            // a guide file can be two minutes away. Completing when the work ended kept the system waiting for
            // all of it, since nothing looked for the request at all.
            handle.onExpire {
                work.cancel()
                handle.complete(false)
            }
        }
    }

    /// A `BGTask` cannot be passed between threads, and the work that finishes it runs on another executor.
    /// The handler is handed out on the main queue and only these two calls are ever made on it, both of
    /// which are safe from anywhere, so it travels in this box.
    private final class Handle: @unchecked Sendable {
        private let task: BGProcessingTask
        private let completed = OSAllocatedUnfairLock(initialState: false)

        init(_ task: BGProcessingTask) { self.task = task }

        /// Once, whichever comes first: the work ending or its time running out. Both can happen, in either
        /// order, and the task is completed by the first.
        func complete(_ success: Bool) {
            let first = completed.withLock { done in
                defer { done = true }
                return !done
            }
            if first { task.setTaskCompleted(success: success) }
        }

        func onExpire(_ handler: @escaping @Sendable () -> Void) { task.expirationHandler = handler }
    }

    /// Asks for the next run, soon after the recorder will have rebuilt its files. Submitting again replaces
    /// the pending request, and the handler asks again, because one request is all the system keeps.
    static func schedule(after earliest: Date = nextNightlyRun()) {
        let request = BGProcessingTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = true
        // not requiring power: a night without the charger is still a night the guide could be fetched
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The next 02:00 in the recorder's own time zone. The box rebuilds its guide files around 00:49.
    static func nextNightlyRun(after now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: 2, minute: 0),
                                     matchingPolicy: .nextTime)
        return next ?? now.addingTimeInterval(6 * 3600)
    }

    /// The work itself, with no screen behind it: the address comes from what the app saved, and the cache is
    /// opened directly.
    ///
    /// The recorder is asleep most of the time -- measured over twelve hours, it was answering for a quarter
    /// of it -- so this wakes it rather than giving up, which is what it used to do at two in the morning.
    /// Whatever is waiting in the queue goes out while the recorder is up, and the reader is told.
    ///
    /// Stops between steps once its time is up (see `register`): the task has been completed by then, and
    /// what the system allows after that is not to be counted on.
    @discardableResult
    static func refreshNow() async -> Bool {
        // Nothing to fetch and nobody to wake while the demo is on the screen.
        guard !DemoData.on else { return false }
        guard let host = UserDefaults.standard.string(forKey: DefaultsKey.recorderHost), !host.isEmpty else {
            return false
        }
        do {
            let store = try GuideStore(path: try Storage.guidePath())
            let client = RecorderClient(host: host)
            guard await reach(client, at: host), !Task.isCancelled else { return false }

            let outcome = await PendingQueue.flush(client: client, store: store)
            await Notify.queueFlushed(outcome)
            guard !Task.isCancelled else { return false }
            if let capacity = try? await client.recordDestinationInfo() {
                await Notify.lowSpace(freeBytes: capacity.freeBytes, totalBytes: capacity.totalBytes)
            }

            // A broadcasting type that could not be fetched is passed over, and the screens fetch it at the
            // next connect: nothing marks it fetched.
            let refresh = try await GuideRefresh.run(client: client, store: store)
            if !refresh.answered.isEmpty {
                UserDefaults.standard.set(RecorderTime.format(Date()), forKey: DefaultsKey.lastBackgroundRefresh)
            }
            return refresh.stored > 0
        } catch {
            return false
        }
    }

    /// Answers, or answers after a magic packet. The MAC is what the app wrote down the last time it reached
    /// the recorder; without one there is nothing to send and nothing to wait for.
    ///
    /// The packet goes again every few seconds of the wait (`WakeOnLan.resendInterval`). A cancelled wait
    /// ends there: `try?` on the sleep had a cancelled one go round all twenty times without sleeping, a
    /// probe after a probe, with the task already completed.
    private static func reach(_ client: RecorderClient, at host: String) async -> Bool {
        do {
            try await client.describe(timeout: RecorderClient.probeTimeout)
            return true
        } catch RecorderError.badAddress {
            // Nothing was asked, so waking the recorder would change nothing; the app says why on its screen.
            return false
        } catch {}
        guard let mac = UserDefaults.standard.string(forKey: DefaultsKey.recorderMac),
              WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host)) > 0 else { return false }
        var sent = Date()
        for _ in 0..<20 {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return false
            }
            if Date().timeIntervalSince(sent) >= WakeOnLan.resendInterval {
                WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host))
                sent = Date()
            }
            if (try? await client.describe(timeout: RecorderClient.wakeProbeTimeout)) != nil { return true }
        }
        return false
    }
}
