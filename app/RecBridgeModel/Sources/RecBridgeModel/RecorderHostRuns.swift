import Foundation
import RecorderKit

extension RecorderSaid: DuplicatesHeld {}
extension TVHost: TitlesHeld {}

/// Work over many recordings at once -- the bulk delete and protect, and the scan for duplicates -- as the
/// recorder's host starts it: the loop, the stop, the wait while the app is away and what each recording comes to
/// are the package's (`BulkRuns`); when a run may be started, the hold that keeps a step going as the app leaves,
/// and what follows a job's end are the app's, here. The job is the recorder's host's: it is what stands of a
/// recorder, which the host's rules read, stop and clear (`holdsOffConnect`, `anotherAnsweredTheCheck`,
/// `forgetWhatTheRecorderSaid`).
extension RecorderHost {
    /// The job under way or last run.
    var job: BulkJob? { runs.job }

    var jobRunning: Bool { runs.running }

    /// Whether the job under way has recordings of the television's among it (`TVHost.holdsOffConnect`).
    var jobIsOnTheTelevision: Bool { runs.isOnTheTelevision }

    /// Whether the job under way has recordings of the recorder's among it: what holds the recorder's own rows, its
    /// pull-down and its connect.
    var jobIsOnTheRecorder: Bool { runs.isOnTheRecorder }

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

    /// Whether a run over these rows may be started now, by their ids: the recorder's conditions (`canStartARun`) only
    /// where one of them is the recorder's, what the recorder is doing being nothing to the television's rows. Not
    /// beside another run either way.
    func canStartARun(over ids: [String]) -> Bool {
        let chosen = Set(ids)
        return chosen.isEmpty || !chosen.isSubset(of: onTheTelevision(ids)) ? canStartARun : !jobRunning
    }

    /// Which of `ids` are the television's rows, as they are held now.
    private func onTheTelevision(_ ids: [String]) -> Set<String> {
        Set(model?.tvHost?.titles.map(\.id) ?? []).intersection(ids)
    }

    /// Whether one recording may be deleted or protected now, for the buttons that do it: not while the recorder
    /// works, and not while a run over its rows is under way, which puts no line on the strip and walks the list
    /// those would write to. Playback and the power go by the recorder's work alone (`isBusy(for:)`): none of them
    /// writes the list, and a playback begun before a long scan has to be stoppable from the app.
    var canAlterARecording: Bool { !isBusy && !jobIsOnTheRecorder }

    /// Whether the duplicates have been looked for, for their screen to say that none were found: kept on what
    /// the recorder said (`RecorderSaid.lookedForDuplicates`), and not read off the job that stands, which a later
    /// bulk job or the bar's ✕ replaces while the sets still stand.
    var scannedForDuplicates: Bool { said.lookedForDuplicates }

    /// Starts a bulk delete or protect (`BulkRuns.startBulk`). Nothing starts, and nothing is said, while a run
    /// over these may not be started (`canStartARun(over:)`): the press came from a confirm or a menu left open
    /// after its button went grey, and the job that stands is left as it is. False then, for the screen to keep
    /// the selection the press was about; true otherwise, a job set or none asked for.
    ///
    /// `ids` are the rows' ids, whichever device holds them: a television's is its uri, which no recorder's number
    /// can be. A television's rows are nothing to a recorder that is away, and a recorder's are as they always were
    /// with a television that is.
    @discardableResult
    func startBulk(_ kind: BulkJob.Kind, ids: [String]) -> Bool {
        guard canStartARun(over: ids), runs.task == nil else { return false }
        guard !ids.isEmpty, let driver = recorderDriver else { return true }
        let television = model?.tvHost
        runs.startBulk(kind, ids: ids, onTV: onTheTelevision(ids), recorder: (driver, said),
                       television: television.flatMap { host in host.runDriver.map { ($0, host) } })
        return true
    }

    /// Stops before the next recording. What has been done stays done; the recorder has no undo.
    func cancelBulk() {
        runs.cancel()
    }

    func clearJob() {
        runs.clear()
    }

    /// The app is back in front: a job waiting between two steps goes on, as the model is told of the return
    /// (`AppModel.returnedToForeground`).
    func letTheJobGoOn() {
        runs.appIsBack()
    }

    /// The scan for duplicates over the recorder's recordings (`BulkRuns.startScan`). Not while a run may not be
    /// started (`canStartARun`), as `startBulk`.
    func startDuplicateScan() {
        guard canStartARun, runs.task == nil, let store = model?.store, let driver = recorderDriver else { return }
        runs.startScan(through: driver, store: store, said: said)
    }

    /// The job is over: it no longer holds a connect off (`holdsOffConnect`), and a connect turned away while it
    /// ran -- a return to the app, a look that found another network -- is made now (`DeviceLink.connectIfOwed`),
    /// as it would have been without the job: unless the job, or anything else, met silence after it was turned
    /// away, which has given the recorder up (`DeviceLink.lost`). The television's the same, for a job that held
    /// its connect off. A job that walked the television's rows reads its list, which nothing read meanwhile: what
    /// it found there as it stopped or passed a row over -- a disk gone, a row protected, another recording under a
    /// uri -- is shown by that, as a single write's read again shows it (`TVHost.delete`).
    func jobEnded(_ walkedTheTelevision: Bool) async {
        // Beside the recorder's, so that neither waits for the other's silence.
        let television = Task { await self.model?.tv?.connectIfOwed() }
        await link.connectIfOwed()
        await television.value
        if walkedTheTelevision { await model?.tvHost?.loadTitles() }
    }

    /// Begins the time the system gives one step of a job once the reader leaves the app (`Surroundings.holdTime`,
    /// a background task in the app), so that a step under way then is finished rather than frozen half way, and
    /// hands back its end. iOS allows half a minute or so, which a step fits in with room to spare unless the
    /// recorder has gone quiet, and then the time is ended when it runs out, as iOS requires.
    func holdAStep() -> @MainActor () -> Void {
        stepEnd = model?.surroundings.holdTime { [weak self] in self?.endStepTime() }
        return { [weak self] in self?.endStepTime() }
    }

    private func endStepTime() {
        guard let end = stepEnd else { return }
        stepEnd = nil
        end()
    }
}
