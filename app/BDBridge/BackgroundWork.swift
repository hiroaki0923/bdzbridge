import BackgroundTasks
import Foundation
import RecorderKit

/// Where the guide cache lives, so the screens and the background run open the same file.
enum Storage {
    static func guidePath() throws -> String {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return directory.appendingPathComponent("guide.sqlite3").path
    }
}

/// Fetching every broadcasting type's guide and logos into the cache. One implementation, used by the button
/// on the settings screen and by the overnight run.
enum GuideRefresh {
    static let broadcastingTypes = ["td", "bs", "cs", "bs4k"]

    /// Returns how many programmes were stored. A broadcasting type the recorder cannot receive is skipped.
    @discardableResult
    /// `onType` is called on the main actor as each broadcasting type starts, for the screen to say so.
    static func run(client: RecorderClient, store: GuideStore,
                    onType: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> Int {
        var stored = 0
        for broadcasting in broadcastingTypes {
            await onType?(broadcasting)
            guard let services = try await client.guide(broadcasting) else { continue }
            stored += try await store.replace(services, broadcasting: broadcasting)
            if let logos = try? await client.logos(broadcasting) {
                try await store.replaceLogos(logos, broadcasting: broadcasting)
            }
        }
        return stored
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
    /// Shown on the settings screen, so that something invisible can still be seen to be working.
    static let lastRefreshKey = "lastBackgroundRefresh"

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
            handle.onExpire { work.cancel() }
        }
    }

    /// A `BGTask` cannot be passed between threads, and the work that finishes it runs on another executor.
    /// The handler is handed out on the main queue and only these two calls are ever made on it, both of
    /// which are safe from anywhere, so it travels in this box.
    private final class Handle: @unchecked Sendable {
        private let task: BGProcessingTask

        init(_ task: BGProcessingTask) { self.task = task }

        func complete(_ success: Bool) { task.setTaskCompleted(success: success) }
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
    @discardableResult
    static func refreshNow() async -> Bool {
        guard let host = UserDefaults.standard.string(forKey: "recorderHost"), !host.isEmpty else { return false }
        do {
            let store = try GuideStore(path: try Storage.guidePath())
            let client = RecorderClient(host: host)
            guard await reach(client, at: host) else { return false }

            let outcome = await PendingQueue.flush(client: client, store: store)
            await Notify.queueFlushed(outcome)
            if let capacity = try? await client.recordDestinationInfo() {
                await Notify.lowSpace(freeBytes: capacity.freeBytes, totalBytes: capacity.totalBytes)
            }

            let stored = try await GuideRefresh.run(client: client, store: store)
            UserDefaults.standard.set(RecorderTime.format(Date()), forKey: lastRefreshKey)
            return stored > 0
        } catch {
            return false
        }
    }

    /// Answers, or answers after a magic packet. The MAC is what the app wrote down the last time it reached
    /// the recorder; without one there is nothing to send and nothing to wait for.
    private static func reach(_ client: RecorderClient, at host: String) async -> Bool {
        if (try? await client.describe(timeout: RecorderClient.probeTimeout)) != nil { return true }
        guard let mac = UserDefaults.standard.string(forKey: "recorderMac"),
              WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host)) > 0 else { return false }
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if (try? await client.describe(timeout: RecorderClient.wakeProbeTimeout)) != nil { return true }
        }
        return false
    }
}
