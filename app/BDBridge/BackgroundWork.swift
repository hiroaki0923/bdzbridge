import BackgroundTasks
import Foundation
import RecBridgeModel
import os
import RecorderKit

/// The overnight guide refresh.
///
/// The recorder rebuilds its own guide and logo files in the small hours, so this asks for them after that and
/// the reader wakes up to a guide that is current for the whole eight days, without the app or the LAN. Where the
/// television gives the home's guide, the same run fetches the television's through its helper instead. iOS
/// decides whether to run it at all: it will not while the app is force-quit, while Background App Refresh is
/// switched off, or in Low Power Mode. Nothing breaks when a night is missed.
extension BackgroundWork {
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

    /// The work itself, with no screen behind it, as the model does it with the app's own surroundings
    /// (`refreshNow(in:)`): the television's part beside the recorder's, both awaited.
    @discardableResult
    static func refreshNow() async -> Bool { await refreshNow(in: .app) }

    /// The television's sending, which the Shortcuts action runs beside the recorder's sending
    /// (`sendToTheTelevisionNow(in:)`).
    @discardableResult
    static func sendToTheTelevisionNow() async -> NoScreenSending? { await sendToTheTelevisionNow(in: .app) }

    /// Sends what is waiting in the queue to the recorder, for the Shortcuts action (`SendWaitingIntent`,
    /// `sendWaiting(in:)`).
    static func sendWaiting() async -> Sending { await sendWaiting(in: .app) }
}

extension NoScreenSurroundings {
    /// The app's own, as the model's are (`Surroundings.app`): the standard defaults, the guide's folder, the
    /// real sessions -- the television's keeping no cookies -- the registration and the helper's token in the
    /// Keychain, and the system's notifications.
    static var app: NoScreenSurroundings {
        NoScreenSurroundings(defaults: .standard, folder: Storage.directory,
                             transport: { _ in URLSessionTransport() },
                             tvTransport: { _ in URLSessionTransport.withoutCookies() },
                             tvCredentials: KeychainTVCredentials(), tvHelperTokens: KeychainTVHelperToken(),
                             notifications: .system)
    }
}
