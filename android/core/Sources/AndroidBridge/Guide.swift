import Foundation
import RecorderKit

// The guide, kept as the iOS app keeps it: in RecorderKit's cache (`GuideStore`), one file per recorder in a folder
// the app names, filled from the recorder's own guide files (`GuideRefresh`) or, for the demo, with the invented
// line-up (`DemoLineUp.seed`). Reading the guide changes nothing on the recorder.

/// A station of one broadcasting type, in the guide's order.
public struct ChannelRow {
    public var serviceID: Int
    public var name: String
}

/// One programme of a day, worded for its row and for its sheet, which shows what the iOS app's does.
public struct ProgrammeRow {
    public var eventID: Int
    public var title: String
    /// `21:00〜21:54`.
    public var span: String
    /// The length and the genre: `54分 · ドラマ`.
    public var details: String
    public var station: String
    /// `11/8(日) 21:00`.
    public var starts: String
    /// `54分`.
    public var length: String
    /// Empty when the guide gives none.
    public var genre: String
    public var summary: String
    public var extended: String
    public var onAir: Bool
    public var ended: Bool
}

// In an extension, so that the memberwise initialiser stays.
extension ProgrammeRow {
    init(_ program: GuideProgramRow, now: Date) {
        let length = "\(max(0, program.durationSec) / 60)分"
        let genre = program.genre?.label ?? ""
        self.init(eventID: program.eventID, title: program.title,
                  span: "\(Wording.time.string(from: program.start))〜\(Wording.time.string(from: program.end))",
                  details: [length, genre].filter { !$0.isEmpty }.joined(separator: " · "),
                  station: program.serviceName, starts: Wording.day.string(from: program.start), length: length,
                  genre: genre, summary: program.summary, extended: program.extended,
                  onAir: program.start <= now && now < program.end, ended: program.end <= now)
    }
}

/// The guide's caches, one opened per file and kept open.
actor GuideFiles {
    static let shared = GuideFiles()
    private var open: [String: GuideStore] = [:]

    func store(in folder: String, for host: String) throws -> GuideStore {
        let name = host == DemoRecorder.host ? "guide-demo.sqlite3" : "guide-\(host).sqlite3"
        let path = (folder as NSString).appendingPathComponent(name)
        if let store = open[path] { return store }
        let store = try GuideStore(path: path)
        open[path] = store
        return store
    }
}

/// Fills the guide of the recorder at `host` into its cache in `folder`: terrestrial, BS and CS from the recorder, or
/// the demo's invented line-up. Says what came of it, in the iOS app's words where something failed.
public func refreshGuide(host: String, folder: String) async throws -> String {
    do {
        let store = try await GuideFiles.shared.store(in: folder, for: host)
        if host == DemoRecorder.host {
            try await DemoLineUp.seed(store) { _, _ in nil }
            return "デモの番組表を入れました"
        }
        let outcome = await GuideRefresh.run(client: RecorderClient(host: host), store: store,
                                             types: ["td", "bs", "cs"])
        let failed = RecorderDriver.guideFailed(outcome.failed)
        if outcome.stopped == .silent { return (failed + ["レコーダーが応答しませんでした"]).joined(separator: "\n") }
        return failed.isEmpty ? "番組表を更新しました" : failed.joined(separator: "\n")
    } catch {
        throw BridgeError.from(error)
    }
}

/// The stations of `broadcasting` (`td`, `bs`, `cs`) the cache in `folder` holds for the recorder at `host`.
public func channels(host: String, folder: String, broadcasting: String) async throws -> [ChannelRow] {
    do {
        let store = try await GuideFiles.shared.store(in: folder, for: host)
        return try await store.channels(broadcasting: broadcasting).map { ChannelRow(serviceID: $0.serviceID, name: $0.name) }
    } catch {
        throw BridgeError.from(error)
    }
}

/// One station's programmes on the broadcast day `dayOffset` days from today's (a day runs 04:00 to 04:00, Japan time).
public func programmes(host: String, folder: String, broadcasting: String, serviceID: Int,
                       dayOffset: Int) async throws -> [ProgrammeRow] {
    do {
        let store = try await GuideFiles.shared.store(in: folder, for: host)
        let day = broadcastDay(dayOffset)
        let now = Date()
        return try await store.day(day, broadcasting: broadcasting, serviceID: serviceID).map { ProgrammeRow($0, now: now) }
    } catch {
        throw BridgeError.from(error)
    }
}

/// The broadcast day `dayOffset` days from today's, as a heading: `11/8(日)`.
public func dayHeading(dayOffset: Int) -> String {
    Wording.dayOnly.string(from: GuideStore.dayRange(containing: broadcastDay(dayOffset)).start)
}

/// The broadcast day `dayOffset` days from the one on air now, as `GuideStore.dayRange` takes it: until four in the
/// morning the day on air is still the day before's (`GuideStore.broadcastDay`).
func broadcastDay(_ dayOffset: Int, from now: Date = Date()) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = RecorderTime.timeZone
    let today = GuideStore.broadcastDay(containing: now)
    return calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
}
