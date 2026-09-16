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
    /// Every channel's name and logo, of every broadcasting type, so a reservation or a search result can
    /// say where it comes from.
    private(set) var channelNames: [String: String] = [:]
    private(set) var channelLogos: [String: Data] = [:]
    private(set) var programs: [GuideProgramRow] = []
    private(set) var reservations: [Reservation] = []
    private(set) var titles: [RecordedTitle] = []
    /// Recordings are read in pages of 200 and there are well over a thousand, so they are kept once fetched.
    private(set) var titlesLoaded = false
    /// Reservations by the programme they follow, so the guide can mark what is already set to record.
    private(set) var reservationsByProgram: [String: Reservation] = [:]
    private(set) var found: [RecorderDescription] = []
    private(set) var scanning: (done: Int, total: Int)?
    private(set) var busy: String?
    /// Set when the recorder answered that it is in network standby, so the caller can offer to wake it.
    private(set) var needsPower = false
    /// Set when the recorder answered nothing at all rather than answering with an error.
    private(set) var unreachable = false
    private(set) var problem: String?
    /// Set when a reservation went to the queue instead of the recorder, so a screen can say so once.
    var queued: PendingReservation?
    /// The MAC a magic packet is sent to. The recorder reports it whenever it is reached; the reader can
    /// also type it, for a recorder that has never been reached from this phone.
    private(set) var mac: String?

    private var store: GuideStore?
    private var client: RecorderClient?
    private var starting: Task<Void, Never>?

    private static let hostKey = "recorderHost"
    private static let macKey = "recorderMac"

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let midnight = calendar.startOfDay(for: Date())
        days = (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: midnight) }
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        mac = UserDefaults.standard.string(forKey: Self.macKey)
        day = days.first ?? Date()
    }

    var connected: Bool { info != nil }

    /// Bumped when the reader asks to be taken back to what is on now. A count rather than a flag, so that
    /// asking twice works.
    private(set) var nowRequests = 0

    /// Today, at this minute. Tapping the guide tab while already on it scrolls to the top of the day by
    /// itself, and the top of a broadcast day is four in the morning, which is nobody's idea of home.
    func goToNow() {
        day = days.first ?? Date()
        nowRequests += 1
    }

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
            store = try GuideStore(path: try Storage.guidePath())
            await reloadFromCache()
            if !host.isEmpty { await connect() }
        } catch {
            problem = "番組表の保存領域を開けませんでした: \(error)"
        }
    }

    /// Looks through the subnet this device is on for a recorder. One short request per address, so the
    /// first run also asks the reader for permission to reach the local network.
    func scanForRecorders() async {
        found = []
        let hosts = LocalNetwork.hostsToScan()
        guard !hosts.isEmpty else {
            problem = "この端末のネットワーク情報を取得できませんでした"
            return
        }
        scanning = (0, hosts.count)
        // a recorder shows up the moment it answers, so the reader can take it while the rest of the
        // subnet is still being tried
        found = await Discovery.scan(hosts: hosts, progress: { done, total in
            Task { @MainActor in self.scanning = (done, total) }
        }, found: { recorder in
            Task { @MainActor in
                if !self.found.contains(where: { $0.host == recorder.host }) { self.found.append(recorder) }
            }
        })
        scanning = nil
        if found.isEmpty { problem = "レコーダーが見つかりませんでした。同じネットワークに接続されているか確認してください。" }
    }

    /// Takes one of the recorders the scan turned up.
    func use(_ recorder: RecorderDescription) async {
        host = recorder.host
        found = []
        await connect()
    }

    /// Connects, and wakes the recorder first if that is what it needs. A BDZ-FBT4100 leaves the LAN when
    /// it has been idle a while and then answers nothing at all, which is below the network standby that
    /// `X_PowerControl` can reach: only a magic packet gets it back. Nobody has to ask for that, so it
    /// happens here rather than as a button — the address came from the recorder itself, the packet costs
    /// nothing, and the reader only wanted to see their guide.
    func connect() async {
        guard !host.isEmpty else { return }
        let client = RecorderClient(host: host)
        self.client = client
        // The first ask is a short one. A recorder that has left the network does not refuse the
        // connection, it says nothing, so a patient timeout means half a minute of silence before anything
        // can be done about it — and that silence looked like the waking never happened.
        var reached = await attach(client, timeout: RecorderClient.probeTimeout)
        if !reached { reached = await wakeAndAttach(client) }
        if reached { await refreshGuideIfStale() }
    }

    /// Reads what the recorder says about itself. Sets `unreachable` when nothing answered at all, which
    /// is the only case worth sending a magic packet for.
    private func attach(_ client: RecorderClient, what: String = "接続中",
                        timeout: TimeInterval? = nil) async -> Bool {
        busy = what
        defer { busy = nil }
        do {
            info = try await client.describe(timeout: timeout)
            // the overnight run reads the address from here and has no screen to ask, so make sure an
            // address that works is written down however it arrived
            UserDefaults.standard.set(host, forKey: Self.hostKey)
            firmware = try await client.firmwareVersion()
            // Kept for waking it later. The recorder is the only place this can come from on iOS, which
            // cannot read an ARP table, so it is read every time rather than once.
            if let settings = try? await client.networkSettings() { remember(mac: settings.mac) }
            let capacity = try await client.recordDestinationInfo()
            storage = (capacity.freeBytes, capacity.totalBytes)
            unreachable = false
            problem = nil
            await flushPending()
            return true
        } catch {
            let recorderError = error as? RecorderError
            unreachable = recorderError?.unreachable ?? false
            problem = recorderError?.explanation ?? String(describing: error)
            return false
        }
    }

    /// The magic packet, then waiting for the recorder to answer. Nothing acknowledges the packet, so the
    /// only way to know is to keep asking; a BDZ-FBT4100 is back in about ten seconds.
    @discardableResult
    func wakeAndAttach(_ client: RecorderClient? = nil) async -> Bool {
        guard let client = client ?? self.client, unreachable, let mac,
              WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host)) > 0
        else { return false }
        // Nothing is wrong yet, so nothing should be on screen saying there is: the failed probe that got
        // us here left its explanation behind, and waking is the answer to it rather than another fault.
        problem = nil
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(2))
            if await attach(client, what: "レコーダーを起動しています",
                            timeout: RecorderClient.probeTimeout) { return true }
        }
        problem = "レコーダーが応答しません。電源とネットワーク接続を確認してください。"
        return false
    }

    /// True once a MAC is known, which is what a magic packet needs. Until then there is nothing to send:
    /// the address cannot be guessed and iOS will not read the ARP table.
    var canWake: Bool { mac != nil }

    /// Keeps a MAC for waking the recorder. Anything that is not one is ignored rather than stored, so a
    /// half-typed address never replaces a good one.
    func remember(mac text: String) {
        guard let normalised = WakeOnLan.normalise(text) else { return }
        mac = normalised
        UserDefaults.standard.set(normalised, forKey: Self.macKey)
    }

    func forgetMac() {
        mac = nil
        UserDefaults.standard.removeObject(forKey: Self.macKey)
    }

    /// The recorder builds its guide files again in the small hours, so a cache from before the most recent
    /// rebuild is behind what the recorder would hand over now.
    static func lastRebuild(before now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let previous = calendar.nextDate(after: now, matching: DateComponents(hour: 1, minute: 0),
                                         matchingPolicy: .nextTime, direction: .backward)
        return previous ?? now.addingTimeInterval(-24 * 3600)
    }

    /// Whether the cache holds nothing, or nothing newer than that rebuild.
    var guideIsStale: Bool {
        guard counts.values.contains(where: { $0.programs > 0 }),
              let newest = counts.values.compactMap(\.refreshed).compactMap(RecorderTime.parse).max()
        else { return true }
        return newest < Self.lastRebuild()
    }

    /// Fetching the guide is what connecting is for, so it happens without being asked: the first run
    /// otherwise lands on an empty guide with nothing to say that anything has to be fetched, and a cache
    /// the overnight run never got to would quietly stay a day behind. A cache that is already current
    /// costs nothing, which is what makes this safe on every launch.
    func refreshGuideIfStale() async {
        guard connected, guideIsStale else { return }
        await refreshGuide()
    }

    /// Downloads every broadcasting type the recorder has and replaces the cache.
    func refreshGuide() async {
        guard let client, let store else { return }
        await run("番組表を取得中") {
            try await GuideRefresh.run(client: client, store: store) { broadcasting in
                self.busy = "番組表を取得中 (\(Codes.broadcastingLabel[broadcasting] ?? broadcasting))"
            }
            await self.reloadFromCache()
        }
    }

    func loadReservations() async {
        await start()
        guard let client else { return }
        await run("予約一覧を取得中") {
            self.reservations = try await client.reservations()
            self.reservationsByProgram = Dictionary(
                self.reservations.compactMap { reservation in
                    reservation.eventID.map { (Self.key(reservation.broadcastingType, reservation.serviceID, $0),
                                               reservation) }
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - the recorder's own keyword conditions (おまかせ・まる録)

    private(set) var recorderRules: [RecorderRule] = []

    /// Reservations made while the recorder could not be reached, waiting for it to answer.
    private(set) var pending: [PendingReservation] = []

    func loadRecorderRules() async {
        await start()
        guard let client else { return }
        await run("おまかせ・まる録の設定を取得中") { self.recorderRules = try await client.recorderRules() }
    }

    /// Registers a condition on the recorder itself, which then records by it with nothing else running.
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Bool {
        await start()
        guard let client else { return false }
        let made = await run("レコーダーに登録中") { _ = try await client.createRecorderRule(request) }
        if made { await loadRecorderRules() }
        return made
    }

    /// Delete only, never edit: a condition read over the LAN lacks the channel narrowing the recorder's own
    /// screen can set, and writing it back would erase that. The list is read again afterwards either way,
    /// because the recorder renumbers a condition whenever its screen edits one.
    func removeRecorderRule(_ rule: RecorderRule) async -> Bool {
        await start()
        guard let client else { return false }
        let removed = await run("レコーダーから削除中") { try await client.deleteRecorderRule(id: rule.id) }
        await loadRecorderRules()
        return removed
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
                return cancelled ? "\(done) 件まで調べて中止しました" : "\(done) 件の確認が完了しました"
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
            job?.skipped.append(.init(id: id, reason: "一覧に見つかりません"))
            return
        }
        let outcome = await client.deleteIfPresent(title)
        switch outcome {
        case .changed:
            titles.removeAll { $0.id == id }
            job?.changed.append(id)
        case .skipped(let reason):
            // the recorder had already lost it, so the list should not keep showing it either
            if reason == "すでに削除されています" { titles.removeAll { $0.id == id } }
            job?.skipped.append(.init(id: id, reason: reason))
        }
    }

    private func protectOne(_ id: String, _ on: Bool, _ client: RecorderClient) async {
        guard let index = titles.firstIndex(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: "一覧に見つかりません"))
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
            case .mine: "通常の予約"
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
    ///
    /// Away from home the recorder is not there to write to, and the programme is still worth keeping: a
    /// reservation that cannot be delivered is queued and sent the next time the recorder answers. Only
    /// silence is queued — a recorder that answers and refuses has said something the reader needs to see.
    func reserve(_ program: GuideProgramRow, quality: String, repeating: String) async -> Bool {
        await start()
        guard let request = request(for: program, quality: quality, repeating: repeating) else { return false }
        guard let client else {
            await queue(request, serviceName: program.serviceName)
            return true
        }
        busy = "予約を登録中"
        defer { busy = nil }
        do {
            _ = try await client.createReservation(request)
            problem = nil
            await loadReservations()
            return true
        } catch let error as RecorderError where error.unreachable {
            await queue(request, serviceName: program.serviceName)
            return true
        } catch let error as RecorderError {
            problem = error.explanation
            return false
        } catch {
            problem = String(describing: error)
            return false
        }
    }

    // MARK: - reservations waiting for the recorder

    /// Keeps a reservation the recorder never heard, and says so on screen rather than failing.
    private func queue(_ request: ReservationRequest, serviceName: String) async {
        guard let store else { return }
        let waiting = PendingReservation(request: request, serviceName: serviceName)
        do {
            try await store.queue(waiting)
            pending = try await store.pendingReservations()
            problem = nil
            queued = waiting
        } catch {
            problem = String(describing: error)
        }
    }

    func loadPending() async {
        guard let store else { return }
        pending = (try? await store.pendingReservations()) ?? []
    }

    func removePending(_ waiting: PendingReservation) async {
        guard let store else { return }
        try? await store.removePending(waiting.id)
        await loadPending()
    }

    /// Sends what has been waiting. Called whenever the recorder has just answered, so it runs on a launch at
    /// home and after the overnight refresh. Only a programme that has already finished is dropped: one that
    /// is on air can still be recorded from where it has got to, which beats losing it.
    @discardableResult
    func flushPending() async -> Int {
        guard let client, let store else { return 0 }
        await loadPending()
        guard !pending.isEmpty else { return 0 }
        var sent = 0
        for waiting in pending {
            if waiting.request.end < Date() {
                try? await store.removePending(waiting.id)
                continue
            }
            do {
                _ = try await client.createReservation(waiting.request)
                try? await store.removePending(waiting.id)
                sent += 1
            } catch let error as RecorderError where error.unreachable {
                break                                   // it went away again; the rest keep waiting
            } catch let error as RecorderError {
                try? await store.setPendingProblem(waiting.id, error.explanation)
            } catch {
                try? await store.setPendingProblem(waiting.id, String(describing: error))
            }
        }
        await loadPending()
        if sent > 0 { await loadReservations() }
        return sent
    }

    /// Also a write: the recorder forgets the reservation. A recorder that refuses says why, and that reason
    /// is left on screen rather than being reloaded away.
    @discardableResult
    /// Deletes one reservation, by what it is rather than by the id the app happens to be holding.
    ///
    /// The recorder rewrites the ids of the reservations its own automatic recording made — the whole block
    /// of them at once, when it works through the guide again — so an id read a few hours ago can be dead
    /// while the row on screen still looks right, and deleting it answers 804. Observed on a BDZ-FBT4100:
    /// 19 automatic reservations were renumbered in one go, the programmes themselves unchanged. So read
    /// the list again first and find this reservation by its channel and the moment it starts, which no two
    /// reservations can share. Only when it is not there at all has it really gone.
    func cancel(_ reservation: Reservation) async -> Bool {
        await start()
        guard client != nil else { return false }
        await loadReservations()
        guard let target = current(reservation) else {
            problem = "この予約はすでにレコーダーから削除されていました。一覧を更新しました。"
            return false
        }
        guard let client else { return false }
        busy = "予約を削除中"
        do {
            try await client.deleteReservation(id: target.id)
        } catch let error as RecorderError where error.unknownReservation {
            // the list we just read was itself out of date, which is what happens when reading it failed
            busy = nil
            await loadReservations()  // first, because a successful read clears `problem`
            problem = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"
            return false
        } catch {
            busy = nil
            problem = (error as? RecorderError)?.explanation ?? String(describing: error)
            return false
        }
        busy = nil
        problem = nil
        reservations.removeAll { $0.id == target.id }
        await loadReservations()
        // the reload asks the recorder again, and if it is a moment behind itself the row would come back
        reservations.removeAll { $0.id == target.id }
        return true
    }

    /// The same reservation as the recorder holds it now, whatever it has renumbered it to.
    private func current(_ wanted: Reservation) -> Reservation? {
        reservations.first { $0.id == wanted.id }
            ?? reservations.first { $0.broadcastingType == wanted.broadcastingType
                                    && $0.serviceID == wanted.serviceID
                                    && $0.start == wanted.start }
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
            let everyChannel = try await store.channels(includeHidden: true)
            channelNames = Dictionary(
                everyChannel.compactMap { channel in
                    Codes.broadcasting[channel.broadcasting].map { ("\($0)-\(channel.serviceID)", channel.name) }
                },
                uniquingKeysWith: { first, _ in first })
            channelLogos = Dictionary(
                everyChannel.compactMap { channel in
                    channel.logo.map { ("\(channel.broadcasting)-\(channel.serviceID)", $0) }
                },
                uniquingKeysWith: { first, _ in first })
            programs = try await store.day(day, broadcasting: broadcasting)
        } catch {
            problem = "番組表を読み込めませんでした: \(error)"
        }
    }

    func logo(for program: GuideProgramRow) -> Data? {
        channelLogos["\(program.broadcasting)-\(program.serviceID)"]
    }

    /// A reservation names its channel by the numeric broadcasting type, which the logos are not keyed by.
    /// Stations whose logo the recorder never received have none, so this is often nil on purpose.
    func logo(for reservation: Reservation) -> Data? {
        logo(broadcastingType: reservation.broadcastingType, serviceID: reservation.serviceID)
    }

    func logo(for title: RecordedTitle) -> Data? {
        logo(broadcastingType: title.broadcastingType, serviceID: title.serviceID)
    }

    private func logo(broadcastingType: Int, serviceID: Int) -> Data? {
        Codes.broadcasting(code: broadcastingType)
            .flatMap { channelLogos["\($0)-\(serviceID)"] }
    }

    /// Programmes still to come whose title or description contains this, across every broadcasting type.
    /// The search runs against the cache, so it works away from home too.
    func search(_ query: String) async -> [GuideProgramRow] {
        await start()
        guard let store, query.trimmingCharacters(in: .whitespaces).count >= 1 else { return [] }
        return (try? await store.programs(since: Date(), query: query, limit: 300)) ?? []
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

}
