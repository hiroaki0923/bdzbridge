import Network
import RecorderKit
import SwiftUI
import UIKit

extension Surroundings {
    /// The app's own: what the model reaches on an iPhone.
    static var app: Surroundings {
        Surroundings(defaults: .standard,
                     folder: Storage.directory,
                     transport: { _ in URLSessionTransport() },
                     networkSignature: LocalNetwork.signature,
                     reachesTheLAN: true,
                     asksAboutNotifications: true,
                     tvTransport: { _ in URLSessionTransport.withoutCookies() },
                     tvCredentials: KeychainTVCredentials(),
                     tvHelperTokens: KeychainTVHelperToken(),
                     localNetworkAccess: { await LocalNetwork.access(probing: $0) },
                     waitForLocalNetwork: { await LocalNetwork.waitForAccess(probing: $0) {} },
                     linkIsBlocked: { await LocalNetwork.access(probing: $0) == .blocked },
                     waitForTheLinksPermission: { await LocalNetwork.waitForAccess(probing: $0) {} },
                     lanInterfaces: LocalNetwork.lanInterfaces,
                     scanTransport: { URLSessionTransport.withoutCookies() },
                     scanPause: { try? await Task.sleep(for: $0) },
                     scanLog: { ScanLog.note($0) },
                     notifications: .system,
                     holdTime: { ranOut in
                         // iOS allows half a minute or so, and the task is to be ended when that runs out.
                         let task = UIApplication.shared.beginBackgroundTask(withName: "BulkStep") { ranOut() }
                         guard task != .invalid else { return nil }
                         return { UIApplication.shared.endBackgroundTask(task) }
                     },
                     announce: { AccessibilityNotification.Announcement($0).post() },
                     watchTheNetwork: { reported in
                         let monitor = NWPathMonitor()
                         monitor.pathUpdateHandler = { _ in reported() }
                         monitor.start(queue: .global(qos: .utility))
                         return monitor
                     },
                     demoLogo: DemoData.logo)
    }
}
