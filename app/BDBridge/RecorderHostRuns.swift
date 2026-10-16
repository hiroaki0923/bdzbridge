import Foundation
import RecorderKit
import SwiftUI

/// Work over many recordings at once: the bulk delete and protect with their progress, pausing in the
/// background, and the scan for duplicates. The job is the recorder's host's: it is what stands of a recorder,
/// which the host's rules read, stop and clear (`holdsOffConnect`, `anotherAnsweredTheCheck`,
/// `forgetWhatTheRecorderSaid`).
extension RecorderHost {
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

    /// Whether a run may be started now, for the buttons that start one -- a bulk delete, a bulk protect, the
    /// scan for duplicates -- and for `startBulk` and `startDuplicateScan` themselves, which a confirm or a menu
    /// left open can reach after its button has gone grey: only with the recorder at rest. Not beside another
    /// run. Nor while the recorder works or a connect is under way: a run started then would write beside what
    /// is out, or be turned away as it begins for a recorder that has not yet said which it is
    /// (`RecorderDriver.beginRun`). `connecting` counts beside the lines for the turns a connect has between two
    /// lines of its own, as in `canChangeRecorder`, and so does the refresh of the guide a connect started for
    /// the turns before its line is up (`refreshesTheGuideAfterAConnect`). The television's work does not count:
    /// it is on a client of its own.
    var canStartARun: Bool { !jobRunning && !isBusy && !session.connecting && !refreshesTheGuideAfterAConnect }

    /// Whether one recording may be deleted or protected now, for the buttons that do it: not while the recorder
    /// works, and not while a run is under way, which puts no line on the strip and walks the list those would
    /// write to. Playback and the power go by the recorder's work alone (`isBusy(for:)`): none of them writes
    /// the list, and a playback begun before a long scan has to be stoppable from the app.
    var canAlterARecording: Bool { !isBusy && !jobRunning }

    /// Whether the duplicates have been looked for, for their screen to say that none were found: kept on what
    /// the recorder said (`RecorderSaid.lookedForDuplicates`), and not read off the job that stands, which a later
    /// bulk job or the bar's ✕ replaces while the sets still stand.
    var scannedForDuplicates: Bool { said.lookedForDuplicates }

    /// A run the driver will not begin (`RecorderDriver.beginRun`) is a job all the same, one that has ended
    /// already with why, so that the screen that asked for it says so where it says what a run came to.
    ///
    /// Nothing starts, and nothing is said, while a run may not be started (`canStartARun`): the press came
    /// from a confirm or a menu left open after its button went grey, and the job that stands is left as it
    /// is. False then, for the screen to keep the selection the press was about; true otherwise, a job set or
    /// none asked for.
    @discardableResult
    func startBulk(_ kind: BulkJob.Kind, ids: [String]) -> Bool {
        guard canStartARun, jobTask == nil else { return false }
        guard !ids.isEmpty, let driver = recorderDriver else { return true }
        job = BulkJob(kind: kind, total: ids.count)
        switch driver.beginRun(kind) {
        case .success(let run):
            let said = self.said
            jobTask = Task { [weak self] in
                await self?.runBulk(kind, ids: ids, run, driver, on: said)
            }
        case .failure(let stop):
            endJob(stoppedBy: stop)
        }
        return true
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
    ///
    /// `said` is what the recorder said as the run was set up: the list it walks and writes to, whatever has
    /// been let go of since, as the scan keeps to its own (`runScan`). The run stops before anything more is sent
    /// once its recorder has been let go of (`RecorderDriver.mayGoOn`), and the newcomer's list is left alone.
    private func runBulk(_ kind: BulkJob.Kind, ids: [String], _ run: Run, _ driver: RecorderDriver,
                         on said: RecorderSaid) async {
        var stopped: RunStop?
        for id in ids {
            // Before the wait for the app to come back: a run the reader stopped on the way out, a recording's
            // request still out, ends here, in the turn after that recording, and does not wait for the return
            // to say so.
            if job?.cancelled == true { break }
            await readyForNextStep()
            // And before the recorder is made sure of: a run stopped while it waited for the app is not worth
            // asking who answers for, nor waking a recorder gone to sleep.
            if job?.cancelled == true { break }
            stopped = await driver.mayGoOn(run)
            guard stopped == nil else { break }
            // and after the wait, so that 中止 tapped while the recorder was being woken is heeded
            if job?.cancelled == true { break }
            stopped = await keepingAlive { () -> RunStop? in
                switch kind {
                case .delete: return await deleteOne(id, in: run, driver, on: said)
                case .protecting(let on): return await protectOne(id, on, in: run, driver, on: said)
                case .scanning: return nil
                }
            }
            if let stop = stopped {
                // Stop at the first. Silence has lost the recorder: every recording after it would wait out
                // the same timeout. A delete or a protect that met it is not sent again, since it may have
                // gone through -- the list is read again once the recorder answers, which settles what became
                // of it. Not after silence to the question a delete asks first, nor for a run turned away
                // between two requests for a recording: nothing was sent that changes one.
                if case .silent(afterSending: true) = stop { said.titlesLoaded = false }
                break
            }
            job?.done += 1
        }
        job?.stopped = stopped
        // The free space, when the driver reads it: a request like a recording's, finished under the same
        // hold if the reader leaves meanwhile. The hold is taken whatever the run came to, and given back at
        // once where the driver reads nothing: whether it reads is the driver's to say.
        let deleted = kind == .delete ? job?.changed.count ?? 0 : 0
        await keepingAlive { await driver.end(run, deleted: deleted, stopped: stopped) }
        // the sets were built from recordings that may no longer all be there
        if !said.duplicates.isEmpty { said.recomputeDuplicates() }
        await jobEnded()
    }

    /// The job is over: it no longer holds a connect off (`holdsOffConnect`), and a connect turned away while it
    /// ran -- a return to the app, a look that found another network -- is made now (`DeviceLink.connectIfOwed`),
    /// as it would have been without the job. The last thing either loop does.
    private func jobEnded() async {
        job?.finished = true
        jobTask = nil
        await link.connectIfOwed()
    }

    /// Waits, before a bulk job or the scan takes its next step, for as long as the app is in the background.
    ///
    /// No step is started while the reader is away: iOS suspends the app soon after it leaves, and a request
    /// frozen with it comes back as a failure. The job waits here, between two steps, and goes on when the app
    /// is back. Whether it may is the driver's to say (`RecorderDriver.mayGoOn`), asked after this wait: it
    /// makes sure of a recorder that has had all that time to fall asleep. The step under way as the reader
    /// leaves is finished first, under `keepingAlive`.
    private func readyForNextStep() async {
        guard model?.inBackground == true else { return }
        await withCheckedContinuation { backInFront = $0 }
    }

    /// The app is back in front: a job waiting between two steps goes on (`readyForNextStep`), as the model is
    /// told of the return (`AppModel.returnedToForeground`).
    func letTheJobGoOn() {
        backInFront?.resume()
        backInFront = nil
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
    /// reader gave it. Ticking waits until it has finished. Not while a run may not be started
    /// (`canStartARun`), as `startBulk`.
    func startDuplicateScan() {
        guard canStartARun, jobTask == nil, let store = model?.store, let driver = recorderDriver else { return }
        let candidates = Duplicates.candidates(said.titles)
        job = BulkJob(kind: .scanning, total: candidates.reduce(0) { $0 + $1.count })
        switch driver.beginRun(.scanning) {
        case .success(let run):
            let said = self.said
            jobTask = Task { [weak self] in
                await self?.runScan(candidates, store: store, run, driver, into: said)
            }
        case .failure(let stop):
            endJob(stoppedBy: stop)
        }
    }

    /// The scan's loop. `said` is what the recorder said as the scan was set up, which says which recorder's
    /// texts memory holds: what the cache had of these recordings is put there, as a list is kept
    /// (`RecorderSaid.keep`). The cache is read across a turn, and a recorder let go of meanwhile has had its
    /// texts emptied out of memory; the next one gives out the same numbers for its own recordings, and would be
    /// compared on these, were they not kept where no screen reads them.
    ///
    /// So the scan reads and writes `said` throughout, to its end: the texts, a recording gone, the guide's fixed
    /// blurbs, the sets worked out again. Once `said` is no longer the one in play -- the recorder let go of --
    /// the driver is asked before the next candidate, cached or not, which answers that with nothing sent
    /// (`RecorderDriver.mayGoOn`), and the scan stops there.
    private func runScan(_ candidates: [[RecordedTitle]], store: GuideStore, _ run: Run,
                         _ driver: RecorderDriver, into said: RecorderSaid) async {
        let ids = candidates.flatMap { $0.map(\.id) }
        if let known = try? await store.titleSummaries(ids) {
            said.summaries.merge(known) { _, new in new }
        }
        // The recorder is needed only for what the cache does not already hold, and made sure of only then,
        // and not for a scan that 中止 has stopped already.
        var stopped: RunStop?
        if job?.cancelled != true, ids.contains(where: { said.summaries[$0] == nil }) {
            stopped = await driver.mayGoOn(run)
        }

        scan: for group in candidates {
            for title in group {
                if stopped != nil || job?.cancelled == true { break scan }
                if said !== self.said {
                    stopped = await driver.mayGoOn(run)
                    if stopped != nil { break scan }
                }
                if said.summaries[title.id] == nil {
                    await readyForNextStep()
                    // before the recorder is made sure of, and after, as in `runBulk`: 中止 may have been tapped
                    // while the app was away, and a check heard out meanwhile may have stopped the scan
                    if job?.cancelled == true { break scan }
                    stopped = await driver.mayGoOn(run)
                    if stopped != nil { break scan }
                    if job?.cancelled == true { break scan }
                    switch await keepingAlive({ await driver.text(of: title, in: run) }) {
                    case .read(let summary):
                        said.summaries[title.id] = summary
                        try? await store.setTitleSummary(title.id, summary)
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
        if stopped == nil, said === self.said { said.lookedForDuplicates = true }
        await jobEnded()
    }

    /// One recording of a bulk delete: looked up in the list as it is now, asked of the driver, and the list and
    /// the job brought into step with what that came to. What stopped the run at it -- silence, a no before
    /// its delete was sent (`RecorderDriver.mayGoOn`), or the recorder let go of, when nothing is counted and
    /// the list, which is no longer that recorder's, is left alone -- or nil: see `runBulk`.
    private func deleteOne(_ id: String, in run: Run, _ driver: RecorderDriver, on said: RecorderSaid) async
        -> RunStop? {
        guard let title = said.titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: RecorderDriver.notInTheList))
            return nil
        }
        let came = await driver.delete(title, in: run)
        switch came {
        case .done:
            said.titles.removeAll { $0.id == id }
            job?.changed.append(id)
        case .gone:
            // the recorder had already lost it, so the list should not keep showing it either
            said.titles.removeAll { $0.id == id }
            job?.skipped.append(.init(id: id, reason: came.reason ?? ""))
        case .passedOver(let reason):
            job?.skipped.append(.init(id: id, reason: reason))
        case .stopped(let stop):
            return stop
        }
        return nil
    }

    /// One recording of a bulk protect, as `deleteOne`.
    private func protectOne(_ id: String, _ on: Bool, in run: Run, _ driver: RecorderDriver,
                            on said: RecorderSaid) async -> RunStop? {
        guard let title = said.titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: RecorderDriver.notInTheList))
            return nil
        }
        let came = await driver.protect(title, on, in: run)
        switch came {
        case .done:
            // Found again rather than by the place it had before the request: the list can change while the
            // recorder answers -- a recording deleted from its sheet, the list read again -- and that place
            // may then be another recording's, which would be marked protected instead, or past the end.
            if let index = said.titles.firstIndex(where: { $0.id == id }) { said.titles[index].protected = on }
            job?.changed.append(id)
        case .gone, .passedOver:
            job?.skipped.append(.init(id: id, reason: came.reason ?? ""))
        case .stopped(let stop):
            return stop
        }
        return nil
    }
}
