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
    var day: Date
    var titleGenre: Int?
    var titleState: WatchState?
    var titleSort = TitleSort.newest
    var serviceFilter: Int?

    private(set) var info: RecorderDescription?
    private(set) var firmware = ""
    private(set) var storage: (free: Int, total: Int)?
    private(set) var counts: [String: GuideCounts] = [:]
    private(set) var channels: [Channel] = []
    /// Every channel's name, of every broadcasting type, so a reservation can say where it records from.
    private(set) var channelNames: [String: String] = [:]
    private(set) var programs: [GuideProgramRow] = []
    private(set) var reservations: [Reservation] = []
    private(set) var titles: [RecordedTitle] = []
    /// Recordings are read in pages of 200 and there are well over a thousand, so they are kept once fetched.
    private(set) var titlesLoaded = false
    /// Reservations by the programme they follow, so the guide can mark what is already set to record.
    private(set) var reservationsByProgram: [String: Reservation] = [:]
    private(set) var busy: String?
    /// Set when the recorder answered that it is in network standby, so the caller can offer to wake it.
    private(set) var needsPower = false
    private(set) var problem: String?

    private var store: GuideStore?
    private var client: RecorderClient?
    private var starting: Task<Void, Never>?

    private static let hostKey = "recorderHost"

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        // `-startDay 6` opens the guide six days out, which is how a day with reservations on it is reached
        // without tapping through the app.
        let offset = UserDefaults.standard.integer(forKey: "startDay")
        day = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
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
            self.reservationsByProgram = Dictionary(
                self.reservations.compactMap { reservation in
                    reservation.eventID.map { (Self.key(reservation.broadcastingType, reservation.serviceID, $0),
                                               reservation) }
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - bulk work

    /// Deleting or protecting many recordings, one request at a time because that is all the recorder will
    /// take. It lives here rather than in a screen so that closing the sheet that started it neither stops it
    /// nor takes away the way to stop it.
    struct BulkJob: Equatable {
        enum Kind: Equatable {
            case delete
            case protecting(Bool)
        }

        struct Skip: Equatable, Identifiable {
            var id: String
            var reason: String
        }

        var kind: Kind
        var total: Int
        var done = 0
        var changed: [String] = []
        var skipped: [Skip] = []
        var cancelled = false
        var finished = false

        var verb: String {
            switch kind {
            case .delete: "削除"
            case .protecting(true): "保護"
            case .protecting(false): "保護解除"
            }
        }

        var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

        /// What to tell the reader once it has stopped, in the shape the web app settled on.
        var outcome: String {
            let count = changed.count
            let head = cancelled ? "\(count) 件を\(verb)したところで中止しました" : "\(count) 件を\(verb)しました"
            return skipped.isEmpty ? head : head + "（\(skipped.count) 件はスキップ）"
        }
    }

    private(set) var job: BulkJob?
    private var jobTask: Task<Void, Never>?

    var jobRunning: Bool { job.map { !$0.finished } ?? false }

    func startBulk(_ kind: BulkJob.Kind, ids: [String]) {
        guard jobTask == nil, !ids.isEmpty, let client else { return }
        job = BulkJob(kind: kind, total: ids.count)
        jobTask = Task { [weak self] in
            await self?.runBulk(kind, ids: ids, client: client)
        }
    }

    /// Stops before the next recording. What has been done stays done; the recorder has no undo.
    func cancelBulk() {
        job?.cancelled = true
    }

    func clearJob() {
        guard job?.finished == true else { return }
        job = nil
    }

    private func runBulk(_ kind: BulkJob.Kind, ids: [String], client: RecorderClient) async {
        for id in ids {
            if job?.cancelled == true { break }
            switch kind {
            case .delete: await deleteOne(id, client)
            case .protecting(let on): await protectOne(id, on, client)
            }
            job?.done += 1
        }
        if case .delete = kind, let capacity = try? await client.recordDestinationInfo() {
            storage = (capacity.freeBytes, capacity.totalBytes)
        }
        job?.finished = true
        jobTask = nil
    }

    private func deleteOne(_ id: String, _ client: RecorderClient) async {
        guard let title = titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: "一覧にありません"))
            return
        }
        let outcome = await client.deleteIfPresent(title)
        switch outcome {
        case .changed:
            titles.removeAll { $0.id == id }
            job?.changed.append(id)
        case .skipped(let reason):
            // the recorder had already lost it, so the list should not keep showing it either
            if reason == "すでにありません" { titles.removeAll { $0.id == id } }
            job?.skipped.append(.init(id: id, reason: reason))
        }
    }

    private func protectOne(_ id: String, _ on: Bool, _ client: RecorderClient) async {
        guard let index = titles.firstIndex(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: "一覧にありません"))
            return
        }
        switch await client.setProtected(titles[index], on) {
        case .changed:
            titles[index].protected = on
            job?.changed.append(id)
        case .skipped(let reason):
            job?.skipped.append(.init(id: id, reason: reason))
        }
    }

    // MARK: - recordings

    enum TitleSort: String, CaseIterable {
        case newest, oldest, largest

        var label: String {
            switch self {
            case .newest: "新しい順"
            case .oldest: "古い順"
            case .largest: "大きい順"
            }
        }
    }

    func loadTitles(force: Bool = false) async {
        await start()
        guard let client, force || !titlesLoaded else { return }
        await run("録画一覧を取得中") {
            self.titles = try await client.allTitles()
            self.titlesLoaded = true
            let capacity = try await client.recordDestinationInfo()
            self.storage = (capacity.freeBytes, capacity.totalBytes)
        }
    }

    /// The recordings the screen is showing: filtered, then sorted.
    var shownTitles: [RecordedTitle] {
        var shown = titles
        if let titleGenre { shown = shown.filter { $0.genre?.level1 == titleGenre } }
        if let titleState { shown = shown.filter { $0.watchState == titleState } }
        switch titleSort {
        case .newest: shown.sort { $0.start > $1.start }
        case .oldest: shown.sort { $0.start < $1.start }
        case .largest: shown.sort { ($0.sizeMB ?? 0) > ($1.sizeMB ?? 0) }
        }
        return shown
    }

    var titleGroups: [TitleGroup] { TitleGroup.group(shownTitles) }

    /// How many recordings each genre holds, for the filter row.
    var titleGenreCounts: [Int: Int] {
        Dictionary(titles.compactMap { $0.genre?.level1 }.map { ($0, 1) }, uniquingKeysWith: +)
    }

    func members(of group: TitleGroup) -> [RecordedTitle] {
        shownTitles.filter { $0.seriesKey == group.key }
    }

    func channelName(for title: RecordedTitle) -> String {
        channelNames["\(title.broadcastingType)-\(title.serviceID)"]
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: title.broadcastingType) ?? ""]
            ?? ""
    }

    func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        await start()
        guard let client else { return nil }
        return try? await client.titleDetail(id: title.id)
    }

    /// A write: the recorder stops deleting this one to make room.
    @discardableResult
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Bool {
        await start()
        guard let client else { return false }
        var changed = false
        await run(on ? "保護中" : "保護を解除中") {
            try await client.updateTitle(id: title.id, protected: on)
            if let index = self.titles.firstIndex(where: { $0.id == title.id }) {
                self.titles[index].protected = on
            }
            changed = true
        }
        return changed
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder.
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Bool {
        await start()
        guard let client else { return false }
        var deleted = false
        await run("削除中") {
            try await client.deleteTitle(id: title.id)
            self.titles.removeAll { $0.id == title.id }
            deleted = true
            let capacity = try await client.recordDestinationInfo()
            self.storage = (capacity.freeBytes, capacity.totalBytes)
        }
        return deleted
    }

    /// Playback happens on the television the recorder is attached to, not here. `pause` toggles, so the same
    /// call resumes. A recorder in network standby answers 880, which is what `needsPower` reports.
    func play(_ title: RecordedTitle, _ operation: String) async {
        await start()
        guard let client else { return }
        needsPower = false
        await run(operation == "stop" ? "停止中" : "再生を指示中") {
            do {
                try await client.playControl(titleID: title.id, operation: operation)
            } catch let error as RecorderError where error.needsPowerOn {
                self.needsPower = true
                throw error
            }
        }
    }

    /// Turns the recorder on, which also turns on the television attached to it.
    func powerOn() async {
        await start()
        guard let client else { return }
        await run("電源を入れています") {
            _ = try await client.powerOn()
            self.needsPower = false
        }
    }

    /// The reservation that follows this programme, if there is one. Time-only reservations carry no
    /// programme id and so cannot be matched to one.
    func reservation(for program: GuideProgramRow) -> Reservation? {
        guard let broadcastingType = Codes.broadcasting[program.broadcasting] else { return nil }
        return reservationsByProgram[Self.key(broadcastingType, program.serviceID, program.eventID)]
    }

    private static func key(_ broadcastingType: Int, _ serviceID: Int, _ eventID: Int) -> String {
        "\(broadcastingType)-\(serviceID)-\(eventID)"
    }

    /// What would be sent to the recorder to record this programme.
    func request(for program: GuideProgramRow, quality: String, repeating: String) -> ReservationRequest? {
        guard let broadcastingType = Codes.broadcasting[program.broadcasting],
              let qualityCode = Codes.quality[quality],
              let repeatCode = Codes.repeatCodes[repeating] else { return nil }
        return ReservationRequest(title: program.title, start: program.start, durationSec: program.durationSec,
                                  repeatCode: repeatCode, broadcastingType: broadcastingType,
                                  serviceID: program.serviceID, qualityCode: qualityCode,
                                  eventID: program.eventID)
    }

    /// Reservations that would clash. This asks the recorder with the very payload a creation would send, so
    /// it also proves the payload is one the recorder accepts, without recording anything.
    func conflicts(for program: GuideProgramRow, quality: String, repeating: String) async -> [Reservation]? {
        await start()
        guard let client, let request = request(for: program, quality: quality, repeating: repeating) else {
            return nil
        }
        do {
            return try await client.conflicts(elements: XsrsElements.create(request))
        } catch let error as RecorderError {
            problem = error.explanation
            return nil
        } catch {
            problem = String(describing: error)
            return nil
        }
    }

    /// Writes to the recorder: after this the box really will record the programme.
    func reserve(_ program: GuideProgramRow, quality: String, repeating: String) async -> Bool {
        await start()
        guard let client, let request = request(for: program, quality: quality, repeating: repeating) else {
            return false
        }
        var created = false
        await run("予約中") {
            _ = try await client.createReservation(request)
            created = true
        }
        if created { await loadReservations() }
        return created
    }

    /// Also a write: the recorder forgets the reservation.
    @discardableResult
    func cancel(_ reservation: Reservation) async -> Bool {
        await start()
        guard let client else { return false }
        var removed = false
        await run("予約を削除中") {
            try await client.deleteReservation(id: reservation.id)
            self.reservations.removeAll { $0.id == reservation.id }
            removed = true
        }
        await loadReservations()
        return removed
    }

    func channelName(for reservation: Reservation) -> String {
        channelNames["\(reservation.broadcastingType)-\(reservation.serviceID)"]
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: reservation.broadcastingType) ?? ""]
            ?? "不明な局"
    }

    /// The programme a reservation follows, when it is still in the cached guide.
    func program(for reservation: Reservation) async -> GuideProgramRow? {
        guard let store, let eventID = reservation.eventID,
              let broadcasting = Codes.broadcasting(code: reservation.broadcastingType) else { return nil }
        return try? await store.program(broadcasting: broadcasting, serviceID: reservation.serviceID,
                                        eventID: eventID)
    }

    func reloadFromCache() async {
        guard let store else { return }
        do {
            counts = try await store.counts()
            channels = try await store.channels(broadcasting: broadcasting)
            channelNames = Dictionary(
                try await store.channels(includeHidden: true).compactMap { channel in
                    Codes.broadcasting[channel.broadcasting].map { ("\($0)-\(channel.serviceID)", channel.name) }
                },
                uniquingKeysWith: { first, _ in first })
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
