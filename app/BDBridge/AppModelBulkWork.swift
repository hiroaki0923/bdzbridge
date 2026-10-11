import Foundation
import RecorderKit
import SwiftUI

/// Work over many recordings at once: the bulk delete and protect with their progress, pausing in the
/// background, and the scan for duplicates.
extension AppModel {
    // MARK: - bulk work

    /// Deleting or protecting many recordings, one request at a time because that is all the recorder will
    /// take. It lives here rather than in a screen so that closing the sheet that started it neither stops it
    /// nor takes away the way to stop it.
    struct BulkJob: Equatable {
        /// What the run does to each recording, in the recorder's own terms (`RunKind`).
        typealias Kind = RunKind

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
        /// What stopped the run on the recorder's account, or kept it from beginning, in the driver's own terms
        /// (`RunStop`); nil for a run that came to its end or that 中止 stopped.
        var stopped: RunStop?
        var finished = false

        var verb: String { RecorderDriver.verb(of: kind) }

        var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

        /// What to tell the reader once it has stopped, in the recorder's words (`RecorderDriver.outcome`).
        var outcome: String {
            RecorderDriver.outcome(of: kind, done: done, changed: changed.count, passedOver: skipped.count,
                                   cancelled: cancelled, stopped: stopped)
        }
    }

    var jobRunning: Bool { job.map { !$0.finished } ?? false }

    /// A run the driver will not begin (`RecorderDriver.beginRun`) is a job all the same, one that has ended
    /// already with why, so that the screen that asked for it says so where it says what a run came to.
    func startBulk(_ kind: BulkJob.Kind, ids: [String]) {
        guard jobTask == nil, !ids.isEmpty, let driver = recorderDriver else { return }
        job = BulkJob(kind: kind, total: ids.count)
        switch driver.beginRun(kind) {
        case .success(let run):
            jobTask = Task { [weak self] in
                await self?.runBulk(kind, ids: ids, run, driver)
            }
        case .failure(let stop):
            endJob(stoppedBy: stop)
        }
    }

    /// Ends the job just set up, its run not begun, with why.
    private func endJob(stoppedBy stop: RunStop) {
        job?.stopped = stop
        job?.finished = true
    }

    /// Stops before the next recording. What has been done stays done; the recorder has no undo.
    func cancelBulk() {
        job?.cancelled = true
    }

    func clearJob() {
        guard job?.finished == true else { return }
        job = nil
    }

    /// The loop of a bulk delete or protect. Whether the run may go on to a recording, what is asked of the
    /// recorder for one, what stops the run on its account and the free space read as it ends are the driver's
    /// (`RecorderDriver.mayGoOn`, `delete(_:in:)`, `protect(_:_:in:)`, `end`), on the run begun as the job was set
    /// up; whatever stops it there is kept with the job, which says it (`BulkJob.stopped`).
    private func runBulk(_ kind: BulkJob.Kind, ids: [String], _ run: Run, _ driver: RecorderDriver) async {
        var stopped: RunStop?
        for id in ids {
            await readyForNextStep()
            stopped = await driver.mayGoOn(run)
            guard stopped == nil else { break }
            // after the wait, so that 中止 tapped while the recorder was being woken is heeded
            if job?.cancelled == true { break }
            stopped = await keepingAlive { () -> RunStop? in
                switch kind {
                case .delete: return await deleteOne(id, in: run, driver)
                case .protecting(let on): return await protectOne(id, on, in: run, driver)
                case .scanning: return nil
                }
            }
            if let stop = stopped {
                // Stop at the first. Silence has lost the recorder: every recording after it would wait out
                // the same timeout, and this one is not sent again, since it may have gone through -- the
                // list is read again once the recorder answers, which settles what became of it. A run
                // turned away between two requests for a recording has sent nothing that changes one.
                if case .silent = stop { titlesLoaded = false }
                break
            }
            job?.done += 1
        }
        job?.stopped = stopped
        let deleted = kind == .delete ? job?.changed.count ?? 0 : 0
        await driver.end(run, deleted: deleted, stopped: stopped)
        // the sets were built from recordings that may no longer all be there
        if !duplicates.isEmpty { recomputeDuplicates() }
        job?.finished = true
        jobTask = nil
    }

    /// Waits, before a bulk job or the scan takes its next step, for as long as the app is in the background.
    ///
    /// No step is started while the reader is away: iOS suspends the app soon after it leaves, and a request
    /// frozen with it comes back as a failure. The job waits here, between two steps, and goes on when the app
    /// is back. Whether it may is the driver's to say (`RecorderDriver.mayGoOn`), asked after this wait: it
    /// makes sure of a recorder that has had all that time to fall asleep. The step under way as the reader
    /// leaves is finished first, under `keepingAlive`.
    private func readyForNextStep() async {
        guard inBackground else { return }
        await withCheckedContinuation { backInFront = $0 }
    }

    /// Runs one step of a bulk job under a background task, so that a step under way when the reader leaves
    /// the app is finished rather than frozen half way (see `readyForNextStep`). iOS allows half a minute or
    /// so, which a step fits in with room to spare unless the recorder has gone quiet, and then the task is
    /// ended when the time runs out, as iOS requires.
    private func keepingAlive<T>(_ step: () async throws -> T) async rethrows -> T {
        stepTask = UIApplication.shared.beginBackgroundTask(withName: "BulkStep") { [weak self] in
            self?.endStepTask()
        }
        defer { endStepTask() }
        return try await step()
    }

    private func endStepTask() {
        guard stepTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(stepTask)
        stepTask = .invalid
    }

    // MARK: - duplicates

    /// Candidates cost nothing to find; confirming them means asking the recorder about each one, which is
    /// why this is a job with a progress bar and a stop button.
    ///
    /// The sets already on screen stay there while it runs, so that one it finds again keeps the ticks the
    /// reader gave it. Ticking waits until it has finished.
    func startDuplicateScan() {
        guard jobTask == nil, let store, let driver = recorderDriver else { return }
        let candidates = Duplicates.candidates(titles)
        job = BulkJob(kind: .scanning, total: candidates.reduce(0) { $0 + $1.count })
        switch driver.beginRun(.scanning) {
        case .success(let run):
            jobTask = Task { [weak self] in
                await self?.runScan(candidates, store: store, run, driver)
            }
        case .failure(let stop):
            endJob(stoppedBy: stop)
        }
    }

    private func runScan(_ candidates: [[RecordedTitle]], store: GuideStore, _ run: Run,
                         _ driver: RecorderDriver) async {
        let ids = candidates.flatMap { $0.map(\.id) }
        if let known = try? await store.titleSummaries(ids) {
            summaries.merge(known) { _, new in new }
        }
        // The recorder is needed only for what the cache does not already hold, and made sure of only then.
        var stopped: RunStop?
        if ids.contains(where: { summaries[$0] == nil }) { stopped = await driver.mayGoOn(run) }

        scan: for group in candidates {
            for title in group {
                if stopped != nil || job?.cancelled == true { break scan }
                if summaries[title.id] == nil {
                    await readyForNextStep()
                    stopped = await driver.mayGoOn(run)
                    if stopped != nil { break scan }
                    // after the wait, as in `runBulk`: a check heard out meanwhile may have stopped the scan
                    if job?.cancelled == true { break scan }
                    switch await keepingAlive({ await driver.text(of: title, in: run) }) {
                    case .read(let summary):
                        summaries[title.id] = summary
                        try? await store.setTitleSummary(title.id, summary)
                    case .gone:
                        // deleted on the recorder since the list was read, so it is not a copy of anything
                        titles.removeAll { $0.id == title.id }
                    case .failed(let reason):
                        // Nothing is kept, so it is left out of the sets and asked about again next time.
                        job?.skipped.append(.init(id: title.id, reason: reason))
                    case .stopped(let stop):
                        // Silence as a rule, which has lost the recorder. Stop at the first rather than wait
                        // it out once for every recording left, and keep nothing for this one: silence says
                        // nothing about what it is.
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
        if let found = try? await store.fixedBlurbs(among: titleKeys) { fixedBlurbs = found }
        // from the list as it is now, which a recording deleted meanwhile has left
        recomputeDuplicates()
        job?.finished = true
        jobTask = nil
    }

    /// Rebuilds the sets from what is still on the recorder, using the text already gathered. A recording whose
    /// text has not been read is left out rather than compared on nothing, and counted (`Duplicates.readSets`).
    func recomputeDuplicates() {
        let found = Duplicates.readSets(titles, summaries: summaries, fixedBlurbs: fixedBlurbs)
        unreadDuplicates = found.unread
        setDuplicates(found.sets)
    }

    /// A set the reader has already seen keeps its ticks; a new or changed one is ticked as suggested, if its
    /// text confirms it. See `Duplicates.picks`.
    private func setDuplicates(_ sets: [DuplicateSet]) {
        duplicatePicks = Duplicates.picks(for: sets, shown: duplicates, picked: duplicatePicks)
        duplicates = sets
    }

    /// One recording of a bulk delete: looked up in the list as it is now, asked of the driver, and the list and
    /// the job brought into step with what that came to. What stopped the run at it -- silence, or a no before
    /// its delete was sent (`RecorderDriver.mayGoOn`) -- or nil: see `runBulk`.
    private func deleteOne(_ id: String, in run: Run, _ driver: RecorderDriver) async -> RunStop? {
        guard let title = titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: RecorderDriver.notInTheList))
            return nil
        }
        let came = await driver.delete(title, in: run)
        switch came {
        case .done:
            titles.removeAll { $0.id == id }
            job?.changed.append(id)
        case .gone:
            // the recorder had already lost it, so the list should not keep showing it either
            titles.removeAll { $0.id == id }
            job?.skipped.append(.init(id: id, reason: came.reason ?? ""))
        case .passedOver(let reason):
            job?.skipped.append(.init(id: id, reason: reason))
        case .stopped(let stop):
            return stop
        }
        return nil
    }

    /// One recording of a bulk protect, as `deleteOne`.
    private func protectOne(_ id: String, _ on: Bool, in run: Run, _ driver: RecorderDriver) async -> RunStop? {
        guard let title = titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: RecorderDriver.notInTheList))
            return nil
        }
        let came = await driver.protect(title, on, in: run)
        switch came {
        case .done:
            // Found again rather than by the place it had before the request: the list can change while the
            // recorder answers -- a recording deleted from its sheet, the list read again -- and that place
            // may then be another recording's, which would be marked protected instead, or past the end.
            if let index = titles.firstIndex(where: { $0.id == id }) { titles[index].protected = on }
            job?.changed.append(id)
        case .gone, .passedOver:
            job?.skipped.append(.init(id: id, reason: came.reason ?? ""))
        case .stopped(let stop):
            return stop
        }
        return nil
    }
}
