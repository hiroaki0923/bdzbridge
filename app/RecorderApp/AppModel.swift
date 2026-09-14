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
    var reservationSort = ReservationSort.time
    var reservationKind = ReservationKind.all
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let midnight = calendar.startOfDay(for: Date())
        days = (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: midnight) }
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        // `-startDay 6` opens the guide six days out, which is how a day with reservations on it is reached
        // without tapping through the app.
        let offset = UserDefaults.standard.integer(forKey: "startDay")
        day = days.indices.contains(offset) ? days[offset] : (days.first ?? Date())
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
            //   xcrun simctl launch <device> <bundle id> -recorderHost 192.168.0.63 -refreshOnStart 1
            if UserDefaults.standard.bool(forKey: "refreshOnStart"), connected { await refreshGuide() }
            if UserDefaults.standard.bool(forKey: "scanOnStart"), connected {
                await loadTitlesNow(force: false)
                startDuplicateScan()
            }
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
            /// Asking the recorder what each candidate is about. It changes nothing.
            case scanning
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
            case .scanning: "重複の検出"
            }
        }

        var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

        /// What to tell the reader once it has stopped, in the shape the web app settled on.
        var outcome: String {
            if case .scanning = kind {
                return cancelled ? "\(done) 件まで調べて中止しました" : "\(done) 件を調べ終わりました"
            }
            let count = changed.count
            let head = cancelled ? "\(count) 件を\(verb)したところで中止しました" : "\(count) 件を\(verb)しました"
            return skipped.isEmpty ? head : head + "（\(skipped.count) 件はスキップ）"
        }
    }

    private(set) var job: BulkJob?
    private(set) var duplicates: [DuplicateSet] = []
    /// Which copies are ticked for deletion. It lives here because the view holding it is thrown away every
    /// time the reader looks at the list or the programmes instead.
    var duplicatePicks: Set<String> = []
    /// What the recorder said each recording is about, cached on disk as well.
    private var summaries: [String: String] = [:]
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
            case .scanning: break
            }
            job?.done += 1
        }
        if case .delete = kind, let capacity = try? await client.recordDestinationInfo() {
            storage = (capacity.freeBytes, capacity.totalBytes)
        }
        // the sets were built from recordings that may no longer all be there
        if !duplicates.isEmpty { recomputeDuplicates() }
        job?.finished = true
        jobTask = nil
    }

    // MARK: - duplicates

    /// Candidates cost nothing to find; confirming them means asking the recorder about each one, which is
    /// why this is a job with a progress bar and a stop button.
    func startDuplicateScan() {
        guard jobTask == nil, let client, let store else { return }
        let candidates = Duplicates.candidates(titles)
        setDuplicates([])
        job = BulkJob(kind: .scanning, total: candidates.reduce(0) { $0 + $1.count })
        jobTask = Task { [weak self] in
            await self?.runScan(candidates, client: client, store: store)
        }
    }

    private func runScan(_ candidates: [[RecordedTitle]], client: RecorderClient, store: GuideStore) async {
        let ids = candidates.flatMap { $0.map(\.id) }
        if let known = try? await store.titleSummaries(ids) {
            summaries.merge(known) { _, new in new }
        }

        scan: for group in candidates {
            for title in group {
                if job?.cancelled == true { break scan }
                if summaries[title.id] == nil {
                    let summary = (try? await client.titleDetail(id: title.id))?.summary ?? ""
                    summaries[title.id] = summary
                    try? await store.setTitleSummary(title.id, summary)
                }
                job?.done += 1
            }
        }
        setDuplicates(Duplicates.sets(candidates: candidates, summaries: summaries))
        job?.finished = true
        jobTask = nil
    }

    /// Rebuilds the sets from what is still on the recorder, using the text already gathered.
    func recomputeDuplicates() {
        setDuplicates(Duplicates.sets(candidates: Duplicates.candidates(titles), summaries: summaries))
    }

    /// The copies to delete are ticked for the reader; a set that changes gets a fresh set of ticks.
    private func setDuplicates(_ sets: [DuplicateSet]) {
        duplicates = sets
        duplicatePicks = Set(sets.flatMap(\.suggestDelete))
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
        await loadTitlesNow(force: force)
    }

    /// The load itself. Anything called from `begin()` has to use this: going through `loadTitles` would wait
    /// on the very start-up task it is already running inside.
    private func loadTitlesNow(force: Bool) async {
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
        return await run(on ? "保護中" : "保護を解除中") {
            try await client.updateTitle(id: title.id, protected: on)
            if let index = self.titles.firstIndex(where: { $0.id == title.id }) {
                self.titles[index].protected = on
            }
        }
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder.
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Bool {
        await start()
        guard let client else { return false }
        return await run("削除中") {
            try await client.deleteTitle(id: title.id)
            self.titles.removeAll { $0.id == title.id }
            let capacity = try await client.recordDestinationInfo()
            self.storage = (capacity.freeBytes, capacity.totalBytes)
        }
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

    enum ReservationSort: String, CaseIterable {
        case time, genre, channel

        var label: String {
            switch self {
            case .time: "日時"
            case .genre: "ジャンル"
            case .channel: "局"
            }
        }
    }

    /// The recorder keeps its own automatic recordings alongside the ones an app put in, and so does Sony's
    /// app: two lists rather than one.
    enum ReservationKind: String, CaseIterable {
        case all, mine, automatic

        var label: String {
            switch self {
            case .all: "すべて"
            case .mine: "自分の予約"
            case .automatic: "おまかせ"
            }
        }
    }

    struct ReservationSection: Identifiable {
        var title: String
        var items: [Reservation]
        var id: String { title }
    }

    /// Reservations under a heading: the day they record on, or the genre, or the channel. Soonest first
    /// within each, since a reservation is something that has not happened yet.
    var shownReservations: [Reservation] {
        switch reservationKind {
        case .all: reservations
        case .mine: reservations.filter { !$0.createdByRecorder }
        case .automatic: reservations.filter(\.createdByRecorder)
        }
    }

    var reservationSections: [ReservationSection] {
        let byStart = shownReservations.sorted { $0.start < $1.start }
        switch reservationSort {
        case .time:
            return sections(byStart) { Format.day.string(from: $0.start) }
        case .genre:
            return sections(byStart.sorted { key($0) < key($1) }) {
                $0.genreCode.flatMap { Codes.genreLabel[$0 / 16] } ?? "ジャンルなし"
            }
        case .channel:
            return sections(byStart.sorted { ($0.serviceID, $0.start) < ($1.serviceID, $1.start) }) {
                self.channelName(for: $0)
            }
        }
    }

    private func key(_ reservation: Reservation) -> (Int, Date) {
        (reservation.genreCode ?? 0xFF * 16, reservation.start)
    }

    /// Keeps the headings in the order they first appear, so the sort decides the order of the sections too.
    private func sections(_ reservations: [Reservation],
                          by heading: (Reservation) -> String) -> [ReservationSection] {
        var order: [String] = []
        var grouped: [String: [Reservation]] = [:]
        for reservation in reservations {
            let title = heading(reservation)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(reservation)
        }
        return order.map { ReservationSection(title: $0, items: grouped[$0] ?? []) }
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
        let created = await run("予約中") {
            _ = try await client.createReservation(request)
        }
        if created { await loadReservations() }
        return created
    }

    /// Also a write: the recorder forgets the reservation. A recorder that refuses says why, and that reason
    /// is left on screen rather than being reloaded away.
    @discardableResult
    func cancel(_ reservation: Reservation) async -> Bool {
        await start()
        guard let client else { return false }
        let removed = await run("予約を削除中") {
            try await client.deleteReservation(id: reservation.id)
            self.reservations.removeAll { $0.id == reservation.id }
        }
        guard removed else { return false }
        await loadReservations()
        // the reload asks the recorder again, and if it is a moment behind itself the row would come back
        reservations.removeAll { $0.id == reservation.id }
        return true
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

    /// The eight days the recorder's guide covers, starting today. Fixed when the app opened: building them
    /// from the current moment each time gives every chip a new identity and the day strip loses its place.
    let days: [Date]

    /// What the list shows: the day, narrowed to one channel when the reader picked one.
    var filteredPrograms: [GuideProgramRow] {
        guard let serviceFilter else { return programs }
        return programs.filter { $0.serviceID == serviceFilter }
    }

    var channelName: String {
        guard let serviceFilter else { return "すべての局" }
        return channels.first { $0.serviceID == serviceFilter }?.name ?? "すべての局"
    }

    /// Runs one action, keeping whatever went wrong on screen. The message is cleared only by something
    /// that works: clearing it on the way in meant a failure could be wiped by the very next request.
    @discardableResult
    private func run(_ what: String, _ work: () async throws -> Void) async -> Bool {
        busy = what
        var failed = false
        do {
            try await work()
            problem = nil
        } catch let error as RecorderError {
            problem = error.explanation
            failed = true
        } catch {
            problem = String(describing: error)
            failed = true
        }
        busy = nil
        return !failed
    }

    private static func databasePath() throws -> String {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return directory.appendingPathComponent("guide.sqlite3").path
    }
}
