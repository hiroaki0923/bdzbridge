import Network
import RecBridgeModel
import RecorderKit
import SwiftUI
import UIKit

extension Surroundings {
    /// The app's own: what the model reaches on an iPhone.
    static var app: Surroundings {
        var app = Surroundings(defaults: .standard, folder: Storage.directory, transport: { _ in URLSessionTransport() },
                               networkSignature: LocalNetwork.signature, reachesTheLAN: true,
                               asksAboutNotifications: true)
        app.tvTransport = { _ in URLSessionTransport.withoutCookies() }
        app.tvCredentials = KeychainTVCredentials()
        app.tvHelperTokens = KeychainTVHelperToken()
        app.localNetworkAccess = { await LocalNetwork.access(probing: $0) }
        app.waitForLocalNetwork = { await LocalNetwork.waitForAccess(probing: $0) {} }
        app.linkIsBlocked = { await LocalNetwork.access(probing: $0) == .blocked }
        app.waitForTheLinksPermission = { await LocalNetwork.waitForAccess(probing: $0) {} }
        app.lanInterfaces = LocalNetwork.lanInterfaces
        app.scanTransport = { URLSessionTransport.withoutCookies() }
        app.scanPause = { try? await Task.sleep(for: $0) }
        app.scanLog = { ScanLog.note($0) }
        app.notifications = .system
        app.holdTime = { ranOut in
            // iOS allows half a minute or so, and the task is to be ended when that runs out.
            let task = UIApplication.shared.beginBackgroundTask(withName: "BulkStep") { ranOut() }
            guard task != .invalid else { return nil }
            return { UIApplication.shared.endBackgroundTask(task) }
        }
        app.announce = { AccessibilityNotification.Announcement($0).post() }
        app.watchTheNetwork = { reported in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { _ in reported() }
            monitor.start(queue: .global(qos: .utility))
            return monitor
        }
        app.demoLogo = DemoData.logo
        app.appVersion = { SettingsScreen.version }
        return app
    }
}
