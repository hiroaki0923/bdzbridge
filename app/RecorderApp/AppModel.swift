import Foundation
import RecorderKit
import SwiftUI

/// Everything the screens share: which recorder we talk to, the guide cache, and what is on screen now.
///
/// There is no server in the middle. The app holds one `RecorderClient`, which serialises its own requests,
/// and one `GuideStore` on disk, so the guide can be read while away from home.
@MainActor
@Observable
final class AppModel {
    /// The recorder's address on the LAN. Discovery by scanning comes later; for now it is typed in.
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }

    var broadcasting = "td"
    var day = Date()
    var serviceFilter: Int?

    private(set) var info: RecorderDescription?
    private(set) var firmware = ""
    private(set) var storage: (free: Int, total: Int)?
    private(set) var counts: [String: GuideCounts] = [:]
    private(set) var channels: [Channel] = []
    private(set) var programs: [GuideProgramRow] = []
    private(set) var reservations: [Reservation] = []
    private(set) var busy: String?
    private(set) var problem: String?

    private var store: GuideStore?
    private var client: RecorderClient?
    private var starting: Task<Void, Never>?

    private static let hostKey = "recorderHost"

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
    }

    var connected: Bool { info != nil }

    /// Opens the cache, shows what is in it, then connects. Every screen awaits this before asking for
    /// anything, and only the first caller does the work: two clients at once would mean two conversations
    /// with a recorder that answers 503 to the second.
    func start() async {
        if starting == nil { starting = Task { await self.begin() } }
        await starting?.value
    }

    /// Shows the cached guide before touching the network, so something is on screen at once.
    private func begin() async {
        guard store == nil else { return }
        do {
            store = try GuideStore(path: Self.databasePath())
            await reloadFromCache()
            if !host.isEmpty { await connect() }
            // a hook for driving the app from a simulator or a device without tapping through it:
            //   xcrun simctl launch <device> <bundle id> -recorderHost 192.0.2.63 -refreshOnStart 1
            if UserDefaults.standard.bool(forKey: "refreshOnStart"), connected { await refreshGuide() }
        } catch {
            problem = "番組表の保存先を開けませんでした: \(error)"
        }
    }

    func connect() async {
        guard !host.isEmpty else { return }
        let client = RecorderClient(host: host)
        self.client = client
        await run("接続中") {
            let info = try await client.describe()
            self.info = info
            self.firmware = try await client.firmwareVersion()
            let capacity = try await client.recordDestinationInfo()
            self.storage = (capacity.freeBytes, capacity.totalBytes)
        }
    }

    /// Downloads every broadcasting type the recorder has and replaces the cache.
    func refreshGuide() async {
        guard let client, let store else { return }
        await run("番組表を取得中") {
            for broadcasting in ["td", "bs", "cs", "bs4k"] {
                guard let services = try await client.guide(broadcasting) else { continue }
                self.busy = "番組表を取得中 (\(Codes.broadcastingLabel[broadcasting] ?? broadcasting))"
                try await store.replace(services, broadcasting: broadcasting)
                if let logos = try? await client.logos(broadcasting) {
                    try await store.replaceLogos(logos, broadcasting: broadcasting)
                }
            }
            await self.reloadFromCache()
        }
    }

    func loadReservations() async {
        await start()
        guard let client else { return }
        await run("予約を取得中") {
            self.reservations = try await client.reservations()
        }
    }

    func reloadFromCache() async {
        guard let store else { return }
        do {
            counts = try await store.counts()
            channels = try await store.channels(broadcasting: broadcasting)
            programs = try await store.day(day, broadcasting: broadcasting)
        } catch {
            problem = "番組表を読み出せませんでした: \(error)"
        }
    }

    /// The eight days the recorder's guide covers, starting today.
    var days: [Date] {
        (0..<8).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Date()) }
    }

    /// What the list shows: the day, narrowed to one channel when the reader picked one.
    var filteredPrograms: [GuideProgramRow] {
        guard let serviceFilter else { return programs }
        return programs.filter { $0.serviceID == serviceFilter }
    }

    var channelName: String {
        guard let serviceFilter else { return "すべての局" }
        return channels.first { $0.serviceID == serviceFilter }?.name ?? "すべての局"
    }

    private func run(_ what: String, _ work: () async throws -> Void) async {
        busy = what
        problem = nil
        do {
            try await work()
        } catch let error as RecorderError {
            problem = error.explanation
        } catch {
            problem = String(describing: error)
        }
        busy = nil
    }

    private static func databasePath() throws -> String {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return directory.appendingPathComponent("guide.sqlite3").path
    }
}
