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
        /// Set when the recorder stopped answering and the job stopped there.
        var lostRecorder = false
        var finished = false

        var verb: String { RecorderDriver.verb(of: kind) }

        var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

        /// What to tell the reader once it has stopped, in the recorder's words (`RecorderDriver.outcome`).
        var outcome: String {
            RecorderDriver.outcome(of: kind, done: done, changed: changed.count, passedOver: skipped.count,
                                   cancelled: cancelled, lost: lostRecorder)
        }
    }

    var jobRunning: Bool { job.map { !$0.finished } ?? false }

    func startBulk(_ kind: BulkJob.Kind, ids: [String]) {
        guard jobTask == nil, !ids.isEmpty, let driver = recorderDriver,
              case .success(let run) = driver.beginRun(kind) else { return }
        job = BulkJob(kind: kind, total: ids.count)
        jobTask = Task { [weak self] in
            await self?.runBulk(kind, ids: ids, run, driver)
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

    /// The loop of a bulk delete or protect. When the recorder is made sure of, what is asked of it for one
    /// recording, what stops the run on its account and the free space read as it ends are the driver's
    /// (`RecorderDriver.mayGoOn`, `delete(_:in:)`, `protect(_:_:in:)`, `end`), on the run begun as the job was set
    /// up; whatever stops it there is told here as the recorder lost.
    private func runBulk(_ kind: BulkJob.Kind, ids: [String], _ run: Run, _ driver: RecorderDriver) async {
        var stopped = await driver.mayGoOn(run, .first)
        if stopped == nil {
            for id in ids {
                stopped = await driver.mayGoOn(run, await readyForNextStep())
                guard stopped == nil else {
                    job?.lostRecorder = true
                    break
                }
                // after the wait, so that 中止 tapped while the recorder was being woken is heeded
                if job?.cancelled == true { break }
                stopped = await keepingAlive { () -> RunStop? in
                    switch kind {
                    case .delete: return await deleteOne(id, in: run, driver)
                    case .protecting(let on): return await protectOne(id, on, in: run, driver)
                    case .scanning: return nil
                    }
                }
                if stopped != nil {
                    // Silence, which has lost the recorder. Stop at the first, since every recording after it
                    // would wait out the same timeout, and do not send this one again: it may have gone
                    // through. The list is read again once the recorder answers, which settles what became of
                    // it.
                    titlesLoaded = false
                    job?.lostRecorder = true
                    break
                }
                job?.done += 1
            }
        } else {
            job?.lostRecorder = true
        }
        let deleted = kind == .delete ? job?.changed.count ?? 0 : 0
        await driver.end(run, deleted: deleted, stopped: stopped)
        // the sets were built from recordings that may no longer all be there
        if !duplicates.isEmpty { recomputeDuplicates() }
        job?.finished = true
        jobTask = nil
    }

    /// Where a bulk job or the scan stands as it comes to its next step, having waited first for as long as the
    /// app is in the background.
    ///
    /// No step is started while the reader is away: iOS suspends the app soon after it leaves, and a request
    /// frozen with it comes back as a failure. The job waits here, between two steps, and goes on when the app
    /// is back. Whether it may is the driver's to say (`RecorderDriver.mayGoOn`), which is told here whether
    /// the job waited: after a wait it makes sure of a recorder that has had all that time to fall asleep. The
    /// step under way as the reader leaves is finished first, under `keepingAlive`.
    private func readyForNextStep() async -> RunMoment {
        guard inBackground else { return .next }
        await withCheckedContinuation { backInFront = $0 }
        return .afterAReturn
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
        guard jobTask == nil, let store, let driver = recorderDriver,
              case .success(let run) = driver.beginRun(.scanning) else { return }
        let candidates = Duplicates.candidates(titles)
        job = BulkJob(kind: .scanning, total: candidates.reduce(0) { $0 + $1.count })
        jobTask = Task { [weak self] in
            await self?.runScan(candidates, store: store, run, driver)
        }
    }

    private func runScan(_ candidates: [[RecordedTitle]], store: GuideStore, _ run: Run,
                         _ driver: RecorderDriver) async {
        let ids = candidates.flatMap { $0.map(\.id) }
        if let known = try? await store.titleSummaries(ids) {
            summaries.merge(known) { _, new in new }
        }
        // The recorder is needed only for what the cache does not already hold, and made sure of only then.
        var answering = true
        if ids.contains(where: { summaries[$0] == nil }) { answering = await driver.mayGoOn(run, .first) == nil }

        scan: for group in candidates {
            for title in group {
                if !answering || job?.cancelled == true { break scan }
                if summaries[title.id] == nil {
                    guard await driver.mayGoOn(run, await readyForNextStep()) == nil else {
                        answering = false
                        break scan
                    }
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
                    case .stopped:
                        // Silence, which has lost the recorder. Stop at the first rather than wait it out once
                        // for every recording left, and keep nothing for this one: silence says nothing about
                        // what it is.
                        answering = false
                        break scan
                    }
                }
                job?.done += 1
            }
        }
        if !answering { job?.lostRecorder = true }
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
    /// the job brought into step with what that came to. What stopped the run at it, which only silence does,
    /// or nil: see `runBulk`.
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
