import Foundation
import Observation

/// Whoever holds a device's recordings in memory, for a run to walk and write to: what the recorder said, and the
/// television's host.
@MainActor
public protocol TitlesHeld: AnyObject, Sendable {
    var titles: [RecordedTitle] { get set }
}

/// What the recorder said that a run reads and writes beside its recordings: whether its list stands, and the sets
/// of copies with the texts they were built on, which the scan fills in and a run's deletes leave stale.
@MainActor
public protocol DuplicatesHeld: TitlesHeld {
    var titlesLoaded: Bool { get set }
    var summaries: [String: String] { get set }
    var fixedBlurbs: Set<Duplicates.Blurb> { get set }
    var duplicates: [DuplicateSet] { get }
    /// Whether the duplicates have been looked for, for their screen to say that none were found.
    var lookedForDuplicates: Bool { get set }
    /// The sets worked out again from the recordings and the texts held now.
    func recomputeDuplicates()
}

/// Deleting or protecting many recordings, or the scan for duplicates, as the screens follow it: how far it has
/// got, what it changed and passed over, and what stopped it.
public struct BulkJob: Equatable, Sendable {
    /// What the run does to each recording, in the recorder's own terms (`RunKind`).
    public typealias Kind = RunKind

    public struct Skip: Equatable, Identifiable, Sendable {
        public var id: String
        public var reason: String

        public init(id: String, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    public var kind: Kind
    public var total: Int
    public var done = 0
    public var changed: [String] = []
    public var skipped: [Skip] = []
    public var cancelled = false
    /// What stopped the run on a device's account, or kept it from beginning, in the driver's own terms
    /// (`RunStop`), and which device; nil for a run that came to its end or that 中止 stopped.
    public var stopped: RunStop?
    public var stoppedOn = DeviceSlot.recorder
    /// The ids of the recordings of the run that are the television's, and whether it has any of the
    /// recorder's: what it holds of either device goes by these. A scan's are all the recorder's.
    public var onTV: Set<String> = []
    public var onTheRecorder = true
    public var finished = false

    public init(kind: Kind, total: Int, done: Int = 0, changed: [String] = [], skipped: [Skip] = [],
                cancelled: Bool = false, stopped: RunStop? = nil, stoppedOn: DeviceSlot = .recorder,
                onTV: Set<String> = [], onTheRecorder: Bool = true, finished: Bool = false) {
        self.kind = kind
        self.total = total
        self.done = done
        self.changed = changed
        self.skipped = skipped
        self.cancelled = cancelled
        self.stopped = stopped
        self.stoppedOn = stoppedOn
        self.onTV = onTV
        self.onTheRecorder = onTheRecorder
        self.finished = finished
    }

    public var verb: String { RecorderDriver.verb(of: kind) }

    public var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    /// What to tell the reader once it has stopped, in the recorder's words (`RecorderDriver.outcome`).
    public var outcome: String {
        RecorderDriver.outcome(of: kind, done: done, changed: changed.count, passedOver: skipped.count,
                               cancelled: cancelled, stopped: stopped, on: stoppedOn)
    }
}

/// Work over many recordings at once: the bulk delete and protect, and the scan for duplicates, one request at a
/// time because that is all the recorder will take. A bulk delete or protect takes the recordings of both
/// devices, as the list shows them: the loop is one, and what is asked of a row is its device's (`RunDriver`). A
/// scan is the recorder's alone, a television's rows not always having a text to compare.
///
/// Held by the app for as long as the recorder's host, so that closing the sheet that started a job neither stops
/// it nor takes away the way to stop it. When a job may be started is the app's rule; so are the phone's own
/// parts, given as this is made: whether the app is away, a hold that keeps a step going as the app leaves, and
/// what follows a job's end.
@MainActor
@Observable
public final class BulkRuns {
    /// The job under way or last run.
    public private(set) var job: BulkJob?
    /// The loop of the job under way, for whoever is to wait for it to end.
    @ObservationIgnored public private(set) var task: Task<Void, Never>?
    /// Whether the job is waiting between two steps for the app to come back (`readyForNextStep`).
    public private(set) var waitsForTheApp = false
    @ObservationIgnored private var backInFront: CheckedContinuation<Void, Never>?

    /// Whether the app is away, when no step is to be started.
    @ObservationIgnored private let away: @MainActor () -> Bool
    /// Begins a hold that keeps a step going should the app leave meanwhile, and hands back its end.
    @ObservationIgnored private let hold: @MainActor () -> @MainActor () -> Void
    /// What the recorder in play said now, which a scan's own is told apart from.
    @ObservationIgnored private let inPlay: @MainActor () -> (any DuplicatesHeld)?
    /// What follows a job's end, told whether the job walked the television's rows (`jobEnded`).
    @ObservationIgnored private let ended: @MainActor (_ walkedTheTelevision: Bool) async -> Void

    public init(away: @escaping @MainActor () -> Bool, hold: @escaping @MainActor () -> @MainActor () -> Void,
                inPlay: @escaping @MainActor () -> (any DuplicatesHeld)?,
                ended: @escaping @MainActor (_ walkedTheTelevision: Bool) async -> Void) {
        self.away = away
        self.hold = hold
        self.inPlay = inPlay
        self.ended = ended
    }

    public var running: Bool { job.map { !$0.finished } ?? false }

    /// Whether the job under way has recordings of the television's among it.
    public var isOnTheTelevision: Bool { running && job?.onTV.isEmpty == false }

    /// Whether the job under way has recordings of the recorder's among it. A run of the television's rows alone
    /// walks no list of the recorder's.
    public var isOnTheRecorder: Bool { running && job?.onTheRecorder == true }

    /// One device's side of a run: the driver that answers for its recordings, the run begun with it, and the list
    /// it walks and writes to, which is the one held as the run was set up, whatever has been let go of since.
    private struct Side {
        let device: DeviceSlot
        let driver: any RunDriver
        let run: Run
        let list: any TitlesHeld
    }

    // MARK: - bulk work

    /// Starts a bulk delete or protect of `ids`, the rows' ids whichever device holds them: those in `onTV` the
    /// television's, through `television`, and the rest the recorder's, through `recorder`, whose `said` is
    /// what the recorder said as the run was set up. A run begins with each device it has rows of, and only
    /// those (`RunDriver.beginRun`). A run a driver will not begin is a job all the same, one that has ended
    /// already with why, so that the screen that asked for it says so where it says what a run came to.
    public func startBulk(_ kind: BulkJob.Kind, ids: [String], onTV: Set<String>,
                          recorder: (driver: any RunDriver, said: any DuplicatesHeld),
                          television: (driver: any RunDriver, list: any TitlesHeld)?) {
        let onTheRecorder = onTV.count < Set(ids).count
        job = BulkJob(kind: kind, total: ids.count, onTV: onTV, onTheRecorder: onTheRecorder)
        var sides: [DeviceSlot: Side] = [:]
        if onTheRecorder {
            guard let side = begin(kind, on: .recorder, recorder.driver, recorder.said) else { return }
            sides[.recorder] = side
        }
        if !onTV.isEmpty, let television {
            guard let side = begin(kind, on: .tv, television.driver, television.list) else { return }
            sides[.tv] = side
        }
        let said = recorder.said
        task = Task { [weak self] in
            await self?.runBulk(kind, ids: ids, sides, on: said)
        }
    }

    /// One device's side of a run begun, or nil with the job ended, its run not begun, with why.
    private func begin(_ kind: BulkJob.Kind, on device: DeviceSlot, _ driver: any RunDriver,
                       _ list: any TitlesHeld) -> Side? {
        switch driver.beginRun(kind) {
        case .success(let run):
            return Side(device: device, driver: driver, run: run, list: list)
        case .failure(let stop):
            job?.stoppedOn = device
            endJob(stoppedBy: stop)
            return nil
        }
    }

    /// Ends the job just set up, its run not begun, with why.
    private func endJob(stoppedBy stop: RunStop) {
        job?.stopped = stop
        job?.finished = true
    }

    /// Stops before the next recording. What has been done stays done; the recorder has no undo.
    public func cancel() {
        job?.cancelled = true
    }

    /// Takes away a job that has ended, for the screens to say nothing more of it.
    public func clear() {
        guard job?.finished == true else { return }
        job = nil
    }

    /// The loop of a bulk delete or protect. Whether the run may go on to a recording, what is asked of its device
    /// for one, what stops the run on its account and the free space read as it ends are the drivers'
    /// (`RunDriver`), each on the run begun with it as the job was set up; whatever stops it there is kept with the
    /// job, which says it (`BulkJob.stopped`). The first stop is the end, whichever device's: rows of the other are
    /// not walked past it.
    ///
    /// `said` is what the recorder said as the run was set up: the list it walks and writes to, whatever has
    /// been let go of since, as the scan keeps to its own (`runScan`). The run stops before anything more is sent
    /// once its recorder has been let go of (`RecorderDriver.mayGoOn`), and the newcomer's list is left alone. A
    /// television's list goes with its host, the run with it.
    private func runBulk(_ kind: BulkJob.Kind, ids: [String], _ sides: [DeviceSlot: Side],
                         on said: any DuplicatesHeld) async {
        let onTV = job?.onTV ?? []
        var stopped: RunStop?
        for id in ids {
            guard let side = sides[onTV.contains(id) ? .tv : .recorder] else { continue }
            job?.stoppedOn = side.device
            // Before the wait for the app to come back: a run the reader stopped on the way out, a recording's
            // request still out, ends here, in the turn after that recording, and does not wait for the return
            // to say so.
            if job?.cancelled == true { break }
            await readyForNextStep()
            // And before the recorder is made sure of: a run stopped while it waited for the app is not worth
            // asking who answers for, nor waking a recorder gone to sleep.
            if job?.cancelled == true { break }
            stopped = await side.driver.mayGoOn(side.run)
            guard stopped == nil else { break }
            // and after the wait, so that 中止 tapped while the recorder was being woken is heeded
            if job?.cancelled == true { break }
            stopped = await keepingAlive { () -> RunStop? in
                switch kind {
                case .delete: return await deleteOne(id, on: side)
                case .protecting(let on): return await protectOne(id, on, on: side)
                case .scanning: return nil
                }
            }
            if let stop = stopped {
                // Stop at the first. Silence has lost the device: every recording after it would wait out
                // the same timeout. A delete or a protect that met it is not sent again, since it may have
                // gone through -- the recorder's list is read again once it answers, which settles what became
                // of it, and a television's as the tab next reads it. Not after silence to the question a delete
                // asks first, nor for a run turned away between two requests for a recording: nothing was sent
                // that changes one.
                if case .silent(afterSending: true) = stop, side.device == .recorder { said.titlesLoaded = false }
                break
            }
            job?.done += 1
        }
        job?.stopped = stopped
        // The free space, when a driver reads it: a request like a recording's, finished under the same
        // hold if the reader leaves meanwhile. The hold is taken whatever the run came to, and given back at
        // once where a driver reads nothing: whether it reads is the driver's to say. A stop is told only to the
        // device it was on: the other has its deletes to read for, whatever became of its neighbour.
        let stoppedOn = job?.stoppedOn
        for side in [DeviceSlot.recorder, .tv].compactMap({ sides[$0] }) {
            let changed = job?.changed.filter { onTV.contains($0) == (side.device == .tv) }.count ?? 0
            let deleted = kind == .delete ? changed : 0
            let itsStop = stoppedOn == side.device ? stopped : nil
            await keepingAlive { await side.driver.end(side.run, deleted: deleted, stopped: itsStop) }
        }
        // the sets were built from recordings that may no longer all be there
        if !said.duplicates.isEmpty { said.recomputeDuplicates() }
        await jobEnded()
    }

    /// The job is over, and what follows its end is told whether it walked the television's rows, whose list
    /// nothing read meanwhile. The last thing either loop does.
    private func jobEnded() async {
        let walkedTheTelevision = job?.onTV.isEmpty == false
        job?.finished = true
        task = nil
        await ended(walkedTheTelevision)
    }

    /// Waits, before a bulk job or the scan takes its next step, for as long as the app is away.
    ///
    /// No step is started while the reader is away: the system suspends the app soon after it leaves, and a
    /// request frozen with it comes back as a failure. The job waits here, between two steps, and goes on when the
    /// app is back (`appIsBack`). Whether it may is the driver's to say (`RecorderDriver.mayGoOn`), asked after
    /// this wait: it makes sure of a recorder that has had all that time to fall asleep. The step under way as the
    /// reader leaves is finished first, under `keepingAlive`.
    private func readyForNextStep() async {
        guard away() else { return }
        waitsForTheApp = true
        await withCheckedContinuation { backInFront = $0 }
        waitsForTheApp = false
    }

    /// The app is back in front: a job waiting between two steps goes on (`readyForNextStep`).
    public func appIsBack() {
        backInFront?.resume()
        backInFront = nil
    }

    /// Runs one step of a job under the app's hold, so that a step under way when the reader leaves the app is
    /// finished rather than frozen half way (see `readyForNextStep`).
    private func keepingAlive<T>(_ step: () async throws -> T) async rethrows -> T {
        let release = hold()
        defer { release() }
        return try await step()
    }

    // MARK: - duplicates

    /// Candidates cost nothing to find; confirming them means asking the recorder about each one, which is
    /// why this is a job with a progress bar and a stop button. `said` is what the recorder said as the scan is
    /// set up, whose recordings are looked through, and `store` the cache their texts are kept in.
    ///
    /// The sets already on screen stay there while it runs, so that one it finds again keeps the ticks the
    /// reader gave it. Ticking waits until it has finished.
    public func startScan(through driver: RecorderDriver, store: GuideStore, said: any DuplicatesHeld) {
        let candidates = Duplicates.candidates(said.titles)
        job = BulkJob(kind: .scanning, total: candidates.reduce(0) { $0 + $1.count })
        switch driver.beginRun(.scanning) {
        case .success(let run):
            task = Task { [weak self] in
                await self?.runScan(candidates, store: store, run, driver, into: said)
            }
        case .failure(let stop):
            endJob(stoppedBy: stop)
        }
    }

    /// Whether `said` is what the recorder in play said now.
    private func isInPlay(_ said: any DuplicatesHeld) -> Bool {
        inPlay().map { $0 === said } ?? false
    }

    /// The scan's loop. `said` is what the recorder said as the scan was set up, which says which recorder's
    /// texts memory holds: what the cache had of these recordings is put there, as a list is kept. The cache is
    /// read across a turn, and a recorder let go of meanwhile has had its texts emptied out of memory; the next one
    /// gives out the same numbers for its own recordings, and would be compared on these, were they not kept where
    /// no screen reads them.
    ///
    /// So the scan reads and writes `said` throughout, to its end: the texts, a recording gone, the guide's fixed
    /// blurbs, the sets worked out again. Once `said` is no longer the one in play -- the recorder let go of --
    /// the driver is asked before the next candidate, cached or not, which answers that with nothing sent
    /// (`RecorderDriver.mayGoOn`), and the scan stops there.
    private func runScan(_ candidates: [[RecordedTitle]], store: GuideStore, _ run: Run,
                         _ driver: RecorderDriver, into said: any DuplicatesHeld) async {
        let keys = candidates.flatMap { $0.map(\.listKey) }
        if let known = try? await store.titleSummaries(keys) {
            said.summaries.merge(known) { _, new in new }
        }
        // The recorder is needed only for what the cache does not already hold, and made sure of only then,
        // and not for a scan that 中止 has stopped already.
        var stopped: RunStop?
        if job?.cancelled != true, keys.contains(where: { said.summaries[$0] == nil }) {
            stopped = await driver.mayGoOn(run)
        }

        scan: for group in candidates {
            for title in group {
                if stopped != nil || job?.cancelled == true { break scan }
                if !isInPlay(said) {
                    stopped = await driver.mayGoOn(run)
                    if stopped != nil { break scan }
                }
                if said.summaries[title.listKey] == nil {
                    await readyForNextStep()
                    // before the recorder is made sure of, and after, as in `runBulk`: 中止 may have been tapped
                    // while the app was away, and a check heard out meanwhile may have stopped the scan
                    if job?.cancelled == true { break scan }
                    stopped = await driver.mayGoOn(run)
                    if stopped != nil { break scan }
                    if job?.cancelled == true { break scan }
                    switch await keepingAlive({ await driver.text(of: title, in: run) }) {
                    case .read(let summary):
                        said.summaries[title.listKey] = summary
                        try? await store.setTitleSummary(title.listKey, summary)
                    case .gone:
                        // deleted on the recorder since the list was read, so it is not a copy of anything
                        said.titles.removeAll { $0.id == title.id }
                    case .failed(let reason):
                        // Nothing is kept, so it is left out of the sets and asked about again next time.
                        job?.skipped.append(.init(id: title.id, reason: reason))
                    case .stopped(let stop):
                        // Silence as a rule, which has lost the recorder. Stop at the first rather than wait
                        // it out once for every recording left, and keep nothing for this one: silence says
                        // nothing about what it is. Nor is anything kept of a text that came back once the
                        // recorder had been let go of: it comes here as a stop, not as a text.
                        stopped = stop
                        break scan
                    }
                }
                job?.done += 1
            }
        }
        job?.stopped = stopped
        // Read again each time, since the guide moves on a day at a time. It is the cache on this device, so
        // it is read whether or not the recorder answered; one that cannot be read leaves what was read last.
        let titleKeys = Set(candidates.compactMap { $0.first.map { Series.sameTitleKey($0.title) } })
        if let found = try? await store.fixedBlurbs(among: titleKeys) { said.fixedBlurbs = found }
        // from the list as it is now, which a recording deleted meanwhile has left
        said.recomputeDuplicates()
        // Looked for, unless the recorder stopped the scan or kept it from reading (`BulkJob.stopped`), and only
        // for the recorder still in play: the recorder may have been let go of under such a scan, its recordings
        // gone from memory, with nothing left to count as unread, and the screen would then say of a recorder
        // never looked at that it holds no duplicates. 中止 stops a scan with nothing of the recorder's.
        if stopped == nil, isInPlay(said) { said.lookedForDuplicates = true }
        await jobEnded()
    }

    /// One recording of a bulk delete: looked up in the list as it is now, asked of its driver, and the list and
    /// the job brought into step with what that came to. What stopped the run at it -- silence, a no before
    /// its delete was sent (`RecorderDriver.mayGoOn`), or the device let go of, when nothing is counted and
    /// the list, which is no longer that device's, is left alone -- or nil: see `runBulk`.
    private func deleteOne(_ id: String, on side: Side) async -> RunStop? {
        // In the list a read out brings, not in the one it is about to replace (`RunDriver.afterTheListRead`).
        await side.driver.afterTheListRead()
        guard let title = side.list.titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: RecorderDriver.notInTheList))
            return nil
        }
        let came = await side.driver.delete(title, in: side.run)
        switch came {
        case .done:
            side.list.titles.removeAll { $0.id == id }
            job?.changed.append(id)
        case .gone:
            // the device had already lost it, so the list should not keep showing it either
            side.list.titles.removeAll { $0.id == id }
            job?.skipped.append(.init(id: id, reason: came.reason ?? ""))
        case .passedOver(let reason):
            job?.skipped.append(.init(id: id, reason: reason))
        case .stopped(let stop):
            return stop
        }
        return nil
    }

    /// One recording of a bulk protect, as `deleteOne`.
    private func protectOne(_ id: String, _ on: Bool, on side: Side) async -> RunStop? {
        await side.driver.afterTheListRead()
        guard let title = side.list.titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: RecorderDriver.notInTheList))
            return nil
        }
        let came = await side.driver.protect(title, on, in: side.run)
        switch came {
        case .done:
            // Found again rather than by the place it had before the request: the list can change while the
            // device answers -- a recording deleted from its sheet, the list read again -- and that place
            // may then be another recording's, which would be marked protected instead, or past the end.
            if let index = side.list.titles.firstIndex(where: { $0.id == id }) { side.list.titles[index].protected = on }
            job?.changed.append(id)
        case .gone, .passedOver:
            job?.skipped.append(.init(id: id, reason: came.reason ?? ""))
        case .stopped(let stop):
            return stop
        }
        return nil
    }
}
