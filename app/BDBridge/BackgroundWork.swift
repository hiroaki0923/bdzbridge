import BackgroundTasks
import Foundation
import os
import RecorderKit

/// Where the guide cache lives, so the screens and the background run open the same file.
enum Storage {
    /// The demo keeps its invented programmes in a database of its own, so that trying it leaves nothing
    /// behind in the cache of a real recorder -- and so that leaving it is a matter of deleting one file.
    static func guidePath(demo: Bool = DemoData.on) throws -> String {
        guidePath(demo: demo, in: try directory())
    }

    /// The same in a folder given, which for everything but the unit tests is `directory()`: see
    /// `Surroundings.folder`.
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

/// The overnight guide refresh.
///
/// The recorder rebuilds its own guide and logo files in the small hours, so this asks for them after that and
/// the reader wakes up to a guide that is current for the whole eight days, without the app or the LAN. iOS
/// decides whether to run it at all: it will not while the app is force-quit, while Background App Refresh is
/// switched off, or in Low Power Mode. Nothing breaks when a night is missed.
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
            // a guide file can be two minutes away. So this completes the task without waiting for the work.
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
    /// opened directly. The recorder is asleep most of the time -- measured over twelve hours, it was answering
    /// for a quarter of it -- so this wakes it rather than give up. Whatever is waiting in the queue goes out
    /// while the recorder is up, and the reader is told.
    ///
    /// Stops between steps once its time is up (see `register`): the task has been completed by then, and
    /// what the system allows after that is not to be counted on.
    @discardableResult
    static func refreshNow() async -> Bool {
        // Nothing to fetch and nobody to wake while the demo is on the screen.
        guard !DemoData.on else { return false }
        guard let host = UserDefaults.standard.string(forKey: DefaultsKey.recorderHost), !host.isEmpty,
              let path = try? Storage.guidePath(), let store = try? GuideStore(path: path) else {
            return false
        }
        return await refresh(client: RecorderClient(host: host), store: store,
                             mac: UserDefaults.standard.string(forKey: DefaultsKey.recorderMac), telling: .system)
    }

    /// Whether a television is saved beside the recorder, for what runs with no screen and so has no model to
    /// ask: read from what the screens saved, as the recorder's address is. It decides words only -- with one
    /// saved, what became of the queue says which device it went to (`PendingQueue.Outcome.said`) -- and
    /// nothing is asked of a television from here.
    static var televisionSaved: Bool {
        !(UserDefaults.standard.string(forKey: DefaultsKey.tvHost) ?? "").isEmpty
    }

    /// How a run with no screen tells the reader what it did, and what it keeps for the screens to show.
    /// Handed in, so that the run can be tried without the notifications and the settings of whatever it is
    /// tried on (`refresh`).
    struct Telling: Sendable {
        /// The queue was not sent, because the recorder that answered is not the one it was made for.
        var heldBack: @Sendable () async -> Void
        /// What became of the queue.
        var flushed: @Sendable (PendingQueue.Outcome) async -> Void
        var freeSpace: @Sendable (_ freeBytes: Int, _ totalBytes: Int) async -> Void
        /// A guide was fetched, at this time.
        var fetched: @Sendable (Date) -> Void

        /// Notifications, and the time the settings show.
        static let system = Telling(
            heldBack: { await Notify.queueHeldBack() },
            flushed: { await Notify.queueFlushed($0) },
            freeSpace: { await Notify.lowSpace(freeBytes: $0, totalBytes: $1) },
            fetched: {
                UserDefaults.standard.set(RecorderTime.format($0), forKey: DefaultsKey.lastBackgroundRefresh)
            })
    }

    /// The same with its surroundings handed in, which is what the tests give it. They hand it no MAC, for
    /// the reason they hand `sendWaiting` none.
    static func refresh(client: RecorderClient, store: GuideStore, mac: String?, telling: Telling) async -> Bool {
        guard await RecorderDriver.reachWithNoScreen(client, sendPacket: packet(for: client, mac: mac)),
              !Task.isCancelled else { return false }
        // Another recorder than the one this cache is of is left alone: see `RecorderDriver.isTheOneKnown`.
        // Said only when something was waiting to go to it, which is what the reader would otherwise miss.
        guard await RecorderDriver.isTheOneKnown(client, to: store) else {
            if PendingQueue.hasSomethingToSend((try? await store.pendingReservations()) ?? []) {
                await telling.heldBack()
            }
            return false
        }

        let outcome = await PendingQueue.flush(client: client, store: store)
        await telling.flushed(outcome)
        guard !Task.isCancelled else { return false }
        if let capacity = try? await client.recordDestinationInfo() {
            await telling.freeSpace(capacity.freeBytes, capacity.totalBytes)
        }

        // A broadcasting type that could not be fetched is passed over, and the screens fetch it at the next
        // connect: nothing marks it fetched.
        guard let refresh = try? await GuideRefresh.run(client: client, store: store) else { return false }
        if !refresh.answered.isEmpty { telling.fetched(Date()) }
        return refresh.stored > 0
    }

    /// What sending the queue with nothing on screen came to, for the Shortcuts action to say.
    enum Sending: Equatable {
        case demo
        case noRecorder
        /// Nothing the recorder could be sent: the queue is empty, or holds only what it refused before, or
        /// what has finished. The recorder was not asked.
        case nothingWaiting
        case unreachable
        /// A recorder answered, and not the one the queue and the cache are of. Nothing was sent to it.
        case anotherRecorder
        case sent(PendingQueue.Outcome)
    }

    /// Sends what is waiting in the queue, for the Shortcuts action (`SendWaitingIntent`), which an automation
    /// runs as the phone joins the home Wi-Fi. The reader hears the outcome the way the overnight run tells it.
    static func sendWaiting() async -> Sending {
        guard !DemoData.on else { return .demo }
        guard let host = UserDefaults.standard.string(forKey: DefaultsKey.recorderHost), !host.isEmpty,
              let path = try? Storage.guidePath(), let store = try? GuideStore(path: path) else {
            return .noRecorder
        }
        let sending = await sendWaiting(client: RecorderClient(host: host), store: store,
                                        mac: UserDefaults.standard.string(forKey: DefaultsKey.recorderMac))
        if case .sent(let outcome) = sending { await Notify.queueFlushed(outcome) }
        if sending == .anotherRecorder { await Notify.queueHeldBack() }
        return sending
    }

    /// The same with its surroundings handed in, which is what the tests give it. They hand it no MAC: the
    /// packet goes out from here (`packet`) and not through `Surroundings`, so one handed in is sent on
    /// whatever network the tests are run on.
    ///
    /// The queue is read before anything goes on the network. The automation runs at every arrival home,
    /// and most of them have nothing to send: a recorder woken for nothing is half a minute of a box
    /// starting up in the living room for no reason. The screens may be sending the same queue at the same
    /// moment -- the app open as the Wi-Fi comes back -- which `PendingQueue.flush` takes one at a time.
    static func sendWaiting(client: RecorderClient, store: GuideStore, mac: String?,
                            now: Date = Date()) async -> Sending {
        let waiting = (try? await store.pendingReservations()) ?? []
        guard PendingQueue.hasSomethingToSend(waiting, now: now) else { return .nothingWaiting }
        guard await RecorderDriver.reachWithNoScreen(client, sendPacket: packet(for: client, mac: mac)) else {
            return .unreachable
        }
        guard await RecorderDriver.isTheOneKnown(client, to: store) else { return .anotherRecorder }
        return .sent(await PendingQueue.flush(client: client, store: store, now: now))
    }

    /// The magic packet for the recorder the client asks, to the MAC the app wrote down the last time it
    /// reached it, and whether one went out: without a MAC there is nothing to send and nothing to wait for.
    /// It goes before the first probe (`RecorderDriver.reachWithNoScreen`), which saves five seconds the
    /// Shortcuts action can ill afford: how long the system lets it run in the background is not published.
    private static func packet(for client: RecorderClient, mac: String?) -> @Sendable () -> Bool {
        let host = client.host
        return { mac.map { WakeOnLan.wake($0, addresses: WakeOnLan.addresses(forRecorderAt: host)) > 0 } ?? false }
    }
}
