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
        /// Set when the recorder stopped answering and the job stopped there.
        var lostRecorder = false
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
                let head = lostRecorder ? "\(done) 件まで調べたところで、レコーダーの応答がなくなったため中止しました"
                    : cancelled ? "\(done) 件まで調べて中止しました" : "\(done) 件の確認が完了しました"
                return skipped.isEmpty ? head : head + "（\(skipped.count) 件は番組内容を取得できず、比べていません）"
            }
            let count = changed.count
            let head = lostRecorder ? "\(count) 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました"
                : cancelled ? "\(count) 件を\(verb)したところで中止しました" : "\(count) 件を\(verb)しました"
            return skipped.isEmpty ? head : head + "（\(skipped.count) 件はスキップ）"
        }
    }

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
        // Made sure of first, like anything else the reader asks for: a recorder asleep since the list was
        // read would otherwise cost the first recording a timeout, and every one after it another.
        if await wakeIfDozing() {
            for id in ids {
                guard await readyForNextStep() else {
                    job?.lostRecorder = true
                    break
                }
                // after the wait, so that 中止 tapped while the recorder was being woken is heeded
                if job?.cancelled == true { break }
                do {
                    try await keepingAlive {
                        switch kind {
                        case .delete: try await deleteOne(id, client)
                        case .protecting(let on): try await protectOne(id, on, client)
                        case .scanning: break
                        }
                    }
                } catch {
                    // Silence. Stop at the first, since every recording after it would wait out the same
                    // timeout, and do not send this one again: it may have gone through. The list is read
                    // again once the recorder answers, which settles what became of it.
                    lostTheRecorder()
                    titlesLoaded = false
                    job?.lostRecorder = true
                    break
                }
                job?.done += 1
            }
        } else {
            job?.lostRecorder = true
        }
        if case .delete = kind, !unreachable { await refreshStorage(client) }
        // the sets were built from recordings that may no longer all be there
        if !duplicates.isEmpty { recomputeDuplicates() }
        job?.finished = true
        jobTask = nil
    }

    /// Whether a bulk job or the scan may take its next step, having waited first for as long as the app is
    /// in the background.
    ///
    /// No step is started while the reader is away: iOS suspends the app soon after it leaves, and a request
    /// frozen with it comes back as a failure. The job waits here, between two steps, and goes on when the app
    /// is back, after making sure of a recorder that has had all that time to fall asleep. The step under way
    /// as the reader leaves is finished first, under `keepingAlive`.
    ///
    /// False when the recorder is not there to ask: silence met by anything stops the job, not only silence met
    /// by the job. A check of the recorder that is out is heard first: its verdict may be that another recorder
    /// answers here now, which stops the job (`makeSureItIsUp`).
    private func readyForNextStep() async -> Bool {
        if inBackground {
            await withCheckedContinuation { backInFront = $0 }
            // A screen coming back may be waking the recorder already, and until that is over the app counts
            // it as not answering. Its outcome is the one to go by.
            if let wakeCheck { _ = await wakeCheck.value }
            guard await wakeIfDozing() else { return false }
        }
        if let wakeCheck { _ = await wakeCheck.value }
        return !unreachable
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
        guard jobTask == nil, let client, let store else { return }
        let candidates = Duplicates.candidates(titles)
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
        // The recorder is needed only for what the cache does not already hold, and made sure of only then.
        var answering = true
        if ids.contains(where: { summaries[$0] == nil }) { answering = await wakeIfDozing() }

        scan: for group in candidates {
            for title in group {
                if !answering || job?.cancelled == true { break scan }
                if summaries[title.id] == nil {
                    guard await readyForNextStep() else {
                        answering = false
                        break scan
                    }
                    // after the wait, as in `runBulk`: a check heard out meanwhile may have stopped the scan
                    if job?.cancelled == true { break scan }
                    let read: SummaryRead
                    do {
                        read = try await keepingAlive { try await client.summary(of: title.id) }
                    } catch let error as RecorderError where error.unreachable {
                        // Stop at the first silence rather than wait it out once for every recording left,
                        // and keep nothing for this one: silence says nothing about what it is.
                        lostTheRecorder()
                        answering = false
                        break scan
                    } catch {
                        read = .failed(reason: String(describing: error))
                    }
                    switch read {
                    case .read(let summary):
                        summaries[title.id] = summary
                        try? await store.setTitleSummary(title.id, summary)
                    case .gone:
                        // deleted on the recorder since the list was read, so it is not a copy of anything
                        titles.removeAll { $0.id == title.id }
                    case .failed(let reason):
                        // Nothing is kept, so it is left out of the sets and asked about again next time.
                        job?.skipped.append(.init(id: title.id, reason: reason))
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

    /// Throws only silence, which ends the job: see `runBulk`.
    private func deleteOne(_ id: String, _ client: RecorderClient) async throws {
        guard let title = titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: "一覧に見つかりません"))
            return
        }
        let outcome = try await client.deleteIfPresent(title)
        switch outcome {
        case .changed:
            titles.removeAll { $0.id == id }
            job?.changed.append(id)
        case .gone:
            // the recorder had already lost it, so the list should not keep showing it either
            titles.removeAll { $0.id == id }
            job?.skipped.append(.init(id: id, reason: outcome.reason ?? ""))
        case .skipped(let reason):
            job?.skipped.append(.init(id: id, reason: reason))
        }
    }

    private func protectOne(_ id: String, _ on: Bool, _ client: RecorderClient) async throws {
        guard let title = titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: "一覧に見つかりません"))
            return
        }
        let outcome = try await client.setProtected(title, on)
        switch outcome {
        case .changed:
            // Found again rather than by the place it had before the request: the list can change while the
            // recorder answers -- a recording deleted from its sheet, the list read again -- and that place
            // may then be another recording's, which would be marked protected instead, or past the end.
            if let index = titles.firstIndex(where: { $0.id == id }) { titles[index].protected = on }
            job?.changed.append(id)
        case .gone, .skipped:
            job?.skipped.append(.init(id: id, reason: outcome.reason ?? ""))
        }
    }
}
