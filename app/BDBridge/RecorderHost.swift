import Foundation
import Observation
import RecorderKit
import UIKit

/// What the recorder in play said, held in memory for the screens: its lists, the sets of copies with their ticks
/// and the texts they were built on, and what its sendings came to, for the strip. Exactly what letting go of a
/// recorder empties, and emptied by being replaced whole (`RecorderHost.forgetWhatTheRecorderSaid`).
///
/// An entry that reads the recorder notes the one in play as it begins and keeps what it read on that one
/// (`keep`): a list read for a recorder let go of meanwhile -- another answered or was chosen while the read was
/// out -- is kept where no screen reads it, and the one after it, whose own connect reads its list, is left alone.
/// Each recorder numbers its own rows, so a row left from one would be sent, by its number, to the next.
@MainActor
@Observable
final class RecorderSaid {
    var reservations: [Reservation] = [] {
        // Here, whoever sets the list. Only the load built the index, so a reservation just cancelled -- taken
        // out of a list the load had not built -- went on being marked 予約 in the guide.
        didSet { reservationsByProgram = ByProgram.of(reservations) }
    }
    /// When the recorder's list was last read and kept (`keep(reservations:)`), or nil when none has been since
    /// the lists were last emptied: a recorder that cannot be asked leaves the last list standing, and this says
    /// how old it is (`AppModel.reservationsStaleSince`), as a television's host keeps it for its own.
    var reservationsRead: Date?
    /// Reservations by the programme they follow, so the guide can mark what is already set to record.
    private(set) var reservationsByProgram: [String: Reservation] = [:]
    var titles: [RecordedTitle] = []
    /// Recordings are read in pages of 200 and there are well over a thousand, so they are kept once fetched.
    var titlesLoaded = false
    /// The USB disk whose recordings the list holds, as the read that kept it said; nil when it holds none.
    var titlesReadFrom: RecorderDisk?
    /// The recorder's own keyword conditions (おまかせ・まる録).
    var recorderRules: [RecorderRule] = []
    /// Whether `recorderRules` is the recorder's answer, and why the last read failed if it did. An empty list
    /// is also what there is while the first read is on its way and after one that failed, and saying
    /// 条件が登録されていません then tells the reader something the recorder never said.
    var recorderRulesLoaded = false
    var recorderRulesFailure: String?
    /// How many reservations are held for another recorder, and what the sendings of the queue came to since
    /// the reader last closed the strip, for the strip to say until the reader closes it or leaves the app. See
    /// `RecorderHost.tellTheStrip`.
    var report: String?
    var duplicates: [DuplicateSet] = []
    /// Which copies are ticked for deletion; the ones left unticked are kept. It lives here because the view
    /// holding it is thrown away every time the reader looks at the list or the programmes instead.
    var duplicatePicks: Set<String> = []
    /// How many candidates were left out of the sets because their text has not been read, which a scan run
    /// again reads.
    var unreadDuplicates = 0
    /// Whether the duplicates have been looked for: a scan of this recorder has come to its end, or 中止 has
    /// stopped one, either of which has worked the sets out from what it read and counted what it left unread.
    /// Set as such a scan ends (`RecorderHost.runScan`) and never taken back but with everything here, when the
    /// recorder is let go of: a later job, the bar's ✕, a scan run again, stopped or not, leave it.
    var lookedForDuplicates = false
    /// What the recorder said each recording is about, cached on disk as well. Only what it actually said:
    /// a recording missing here has not been read.
    var summaries: [String: String] = [:]
    /// The candidates' titles whose text the guide shows on more than one day: a text the programme carries
    /// every time, which does not make two recordings the same broadcast. Read from the guide at each scan.
    var fixedBlurbs: Set<Duplicates.Blurb> = []

    /// Puts a list of the recorder's reservations here. Nil, nothing read, leaves the list as it was, and its
    /// time. A list kept was read now, and its time is put down with it (`reservationsRead`).
    func keep(reservations list: [Reservation]?) {
        guard let list else { return }
        reservations = list
        reservationsRead = Date()
    }

    /// Puts a list of the recordings here, with the USB disk it holds the rows of.
    func keep(titles list: [RecordedTitle], readFrom disk: RecorderDisk?) {
        titles = list
        titlesReadFrom = disk
        titlesLoaded = true
        // The sets on screen were built from the list as it was. A copy one says it keeps may have gone since,
        // and deleting the others would then leave nothing.
        if !duplicates.isEmpty { recomputeDuplicates() }
    }

    /// Puts what a read of the conditions came to here: the list, or why there is none.
    func keep(rules read: RecorderDriver.ConditionsRead) {
        if let list = read.list {
            recorderRules = list
            recorderRulesLoaded = true
            recorderRulesFailure = nil
        } else {
            recorderRulesFailure = read.why
        }
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
}

/// The app's side of the recorder's link (`RecorderLinkHost`): what the link tells the app about the recorder,
/// apart from the television's. Its own line for what went wrong, the keys it writes in the defaults, its own
/// wait for the local network permission, and what the recorder said (`said`). The lines of what is under way
/// are the app's one list, as the television's host has them.
///
/// Made once with the model and its link, and kept for as long as the model is: the recorder's link is never
/// dropped, and takes a newcomer up in the middle of an attach (`RecorderDriver.attach`), under doors that hold
/// the host they began with. So the host stays, and what the recorder said is replaced under it when a recorder
/// is let go of (`forgetWhatTheRecorderSaid`). What is the phone's -- the cache, the queue on screen, the demo,
/// the settings, the lines of what is under way -- stays the model's, reached through `model`. A host whose model
/// is gone, which a request still out can keep for a while, puts its lines on a list of its own and writes
/// nothing down.
@MainActor
@Observable
final class RecorderHost: RecorderLinkHost {
    /// What went wrong with the recorder, which every screen shows as a failure.
    var problem: String?
    /// What the recorder in play said. Replaced whole in `forgetWhatTheRecorderSaid`, and nowhere else.
    private(set) var said = RecorderSaid()
    /// Set when another recorder has answered where the last one had been and nobody chose it: at a connect
    /// made over the last one's lists (`anotherDeviceDescribedItself`), or at the check before an operation
    /// (`anotherAnsweredTheCheck`). The strip says so until the reader closes it or leaves the app: the failure line
    /// lasts only until the connect that follows, and an alert goes with its sheet when that closes with
    /// the lists.
    var anotherTookOver = false
    /// Bumped each time what a recorder said is let go of (`forgetWhatTheRecorderSaid`), for the screens to
    /// let go of what they hold of it: a row picked for a dialog, and the sheets on a recording or a
    /// reservation, which close themselves (`closesWithItsRecorder`, `closesWithItsDevice`). Left up over an
    /// emptied list, a sheet's buttons would send its row's number to the next recorder.
    private(set) var timesForgotten = 0
    /// The count of reservations held for another recorder as the strip's report begins with it, for the next
    /// sending to put its own count in place of (`tellTheStrip`).
    @ObservationIgnored private var heldBackSaid: String?
    /// The lists the reader had read, or was reading, when another recorder answered a connect made while the
    /// app was connected, for that connect to read again from the one that answered. See
    /// `anotherDeviceDescribedItself`.
    private var listsToReadAgain = (recordings: false, rules: false)
    /// How many reads of the recordings, and of the keyword conditions, are out (`loadTitlesNow`,
    /// `loadRecorderRulesNow`, a pull-down across its connect, and a condition's add or delete, which
    /// reads the list after it): one out when another recorder answers is a list the reader was about to see,
    /// which is not put on that one's screens and is read from it instead.
    private(set) var titleReads = 0
    private(set) var conditionReads = 0
    /// Counts the connects that reached the recorder (`reached`), so that the connect a check that heard another
    /// recorder sets going is not made over one that has taken the newcomer up since (`anotherAnsweredTheCheck`).
    @ObservationIgnored private var timesReached = 0
    /// Waits for the local network permission after the link ran into it, and tells the link when it comes
    /// (`DeviceLink.permissionArrived`).
    private var accessWatch: Task<Void, Never>?
    /// The bulk delete, protect or scan under way or last run (`RecorderHostRuns`).
    var job: BulkJob?
    var jobTask: Task<Void, Never>?
    /// A bulk job waiting between two steps for the app to come back. See `readyForNextStep`.
    var backInFront: CheckedContinuation<Void, Never>?
    /// The recorder a connect's refresh of the guide is for (`DeviceLink.generation`), while that refresh is
    /// out; nil otherwise. See `refreshTheGuideAfterTheConnect`.
    private(set) var guideAfterAConnect: Int?
    /// Counts the refreshes connects have started, so that one that ends takes down only itself.
    @ObservationIgnored private var guideRefreshesStarted = 0
    /// The background task the step of a bulk job under way runs under. See `keepingAlive`.
    var stepTask = UIBackgroundTaskIdentifier.invalid
    /// The recorder's link, for the model's life.
    let link: DeviceLink
    /// The model that made this, for what is the phone's.
    @ObservationIgnored weak var model: AppModel?

    init(link: DeviceLink) {
        self.link = link
    }

    var session: SessionState { link.session }
    var recorderDriver: RecorderDriver? { link.driver as? RecorderDriver }
    /// The recorder's address on the LAN, as the link has it.
    private var host: String { link.host }
    private var demo: Bool { model?.demo ?? false }
    private var client: RecorderClient? { link.client as? RecorderClient }
    private var unreachable: Bool { session.unreachable }

    // MARK: - letting go of the recorder

    /// Lets go of the recorder in play as far as memory goes: what it said of itself and which it was, the
    /// client that asked it, a wait for the permission at it, and the lists the app holds of it. Until the next
    /// connect there is no client, so nothing can be sent from a list that is no longer there. The queue, the
    /// MAC and what the phone keeps are left: those are decided when a recorder answers
    /// (`RecorderDriver.attach`).
    func forgetTheRecorder() {
        link.forgetTheDevice()
        forgetWhatTheRecorderSaid()
        problem = nil
    }

    /// Empties what the app holds in memory that a recorder said: its lists, the sets of copies with their
    /// ticks and the texts they were built on, the last job, and the lists' filters. Each recorder numbers
    /// its own, so a row left from one would be sent, by its number, to the next. For a choice
    /// (`forgetTheRecorder`), and for another recorder answering where nobody chose one
    /// (`anotherDeviceDescribedItself`); the screens are told (`timesForgotten`).
    ///
    /// What was said goes as one object, replaced here and only here, where the count moves: an entry that
    /// noted the one in play as it began keeps what it reads on that one, which no screen reads once this has
    /// run. Whether the duplicates were looked for goes with it (`RecorderSaid.lookedForDuplicates`).
    ///
    /// A finished job goes because what it says is about the recorder let go of. One still running is stopped
    /// by the check that hears the other recorder (`anotherAnsweredTheCheck`).
    func forgetWhatTheRecorderSaid() {
        said = RecorderSaid()
        anotherTookOver = false
        clearJob()
        model?.titleGenre = nil
        model?.titleState = nil
        model?.titleDestination = nil
        model?.reservationKind = .all
        timesForgotten += 1
    }

    // MARK: - the MAC

    /// Keeps a MAC for waking the recorder. Anything that is not one is ignored rather than stored, so a
    /// half-typed address never replaces a good one. Returns whether it was kept.
    @discardableResult
    func remember(mac text: String) -> Bool {
        guard session.remember(mac: text), let normalised = session.mac else { return false }
        model?.defaults.set(normalised, forKey: DefaultsKey.recorderMac)
        return true
    }

    func forgetMac() {
        session.forgetMac()
        guard let defaults = model?.defaults else { return }
        defaults.removeObject(forKey: DefaultsKey.recorderMac)
        defaults.removeObject(forKey: DefaultsKey.recorderMacHost)
    }

    /// The recordings and the keyword conditions, read from a recorder that has taken the place of another
    /// in the middle of being connected (`anotherDeviceDescribedItself`). The screens read them when the app
    /// becomes connected, and it never stopped being: left to them, the recordings tab said there were none.
    private func readAgainWhatWasUp() async {
        let again = listsToReadAgain
        listsToReadAgain = (false, false)
        if again.recordings { await loadTitlesNow(force: false) }
        if again.rules { await loadRecorderRulesNow() }
    }

    // MARK: - what the link tells the app

    /// On the app's one list. From a host whose model is gone the line goes on a list of its own, which nothing
    /// shows.
    func beginActivity(_ text: String) -> Activities.Token {
        guard let model else {
            var nowhere = Activities()
            return nowhere.begin(text)
        }
        return model.activities.begin(text)
    }

    func updateActivity(_ token: Activities.Token, to text: String) { model?.activities.update(token, to: text) }
    func endActivity(_ token: Activities.Token) { model?.activities.end(token) }

    /// Busy with the recorder: anything under way but the television's lines.
    var isBusy: Bool {
        guard let model else { return false }
        return model.activities.any(besides: model.televisionLines)
    }
    /// A job holds a connect off while it runs, and so does the refresh of the guide a connect started, while
    /// it is out for the recorder still in play: a second connect would put a client of its own beside the
    /// refresh's files. A let-go lifts the refresh's hold at once, so that the connect whoever let go makes is
    /// not kept behind a refresh of the recorder let go of, which may still be waiting its turn behind another.
    /// A connect turned away for either is made once it ends (`DeviceLink.connectIfOwed`), unless silence met the
    /// recorder after it was turned away (`DeviceLink.lost`).
    var holdsOffConnect: Bool {
        jobRunning || guideAfterAConnect.map { !link.letGo(since: $0) } ?? false
    }
    /// Whether the refresh of the guide a connect started is out, whichever recorder it was for: the turns
    /// before it has put its line up count as the connect's did, for what is held while a connect is under way
    /// (`canStartARun`, `AppModel.canChangeRecorder`, `AppModel.guideOnItsWay`).
    var refreshesTheGuideAfterAConnect: Bool { guideAfterAConnect != nil }
    var isDemo: Bool { demo }
    var cache: GuideStore? { model?.store }

    /// The cache first: the queue is sent from it and the guide fetched into it, and a connect made on coming to
    /// the foreground can get here before `start()` has opened anything.
    func cacheForAttempt() async {
        listsToReadAgain = (false, false)
        await model?.openCache()
    }

    /// The overnight run reads the address from here and has no screen to ask, so an address that works is
    /// written down however it arrived.
    func keepAddress(_ host: String) {
        model?.defaults.set(host, forKey: DefaultsKey.recorderHost)
    }

    /// With the address it was read at, which lets the recorder be recognised by it elsewhere. Not the demo's.
    func keepMAC(_ text: String) {
        guard let defaults = model?.defaults else { return }
        if remember(mac: text), !demo { defaults.set(host, forKey: DefaultsKey.recorderMacHost) }
    }

    var macReadAt: String? { model?.defaults.string(forKey: DefaultsKey.recorderMacHost) }

    func macWasReadAt(_ host: String) {
        model?.defaults.set(host, forKey: DefaultsKey.recorderMacHost)
    }

    /// Another recorder's lists go in the turn its description arrives, and the strip says so: nobody chose it,
    /// or the last one would have been forgotten at the choice. The screens read their lists when the app
    /// becomes connected, and it never stopped being, so what they had read is read again by this connect --
    /// and what they were reading: a read out now is the last recorder's, and is kept on what the last recorder
    /// said, which no screen reads.
    func anotherDeviceDescribedItself(wasConnected: Bool) {
        let had = (recordings: said.titlesLoaded || titleReads > 0,
                   rules: said.recorderRulesLoaded || conditionReads > 0)
        forgetWhatTheRecorderSaid()
        anotherTookOver = true
        if wasConnected { listsToReadAgain = had }
    }

    /// The guide on screen was the other recorder's, and the rows waiting have a reason on them now. The marks
    /// the defaults keep about its disks and its guide go with it, and so does what the runs with no screen
    /// told of it (`ToldOnce`): the next run tells what it finds afresh. Their warning of reservations not yet at
    /// the recorder is taken away, where the app asks the system about notifications at all: the rows it names
    /// are held for the reader now, and none of them waits to go.
    ///
    /// Both go again in the queue's turn, as the runs with no screen tell and keep what they tell once: a run
    /// telling as the cache is made over, which looked at the cache before it did, is over first, and what it
    /// kept and posted of the recorder before goes after it. Not waited for: the make-over is part of an
    /// attach, and the turn can be a round of the screens' own on the client the attach has just retired,
    /// which ends only once its request on the wire does.
    func cacheMadeOver() async {
        guard let model else { return }
        let defaults = model.defaults, surroundings = model.surroundings
        defaults.removeObject(forKey: DefaultsKey.warnedLowSpace)
        defaults.removeObject(forKey: DefaultsKey.warnedLowSpaceOnUSB)
        defaults.removeObject(forKey: DefaultsKey.lastBackgroundRefresh)
        let kept = KeptOnce.recorder(in: defaults), withdraws = surroundings.asksAboutNotifications
        kept.forget()
        Task {
            _ = await PendingQueue.betweenFlushes {
                kept.forget()
                if withdraws { await Notify.recorder(notYet: nil, withdraws: true) }
            }
        }
        await model.reloadFromCache()
        await model.loadPending()
        if surroundings.asksAboutNotifications { await Notify.recorder(notYet: nil, withdraws: true) }
    }

    /// It lets go of the client as well -- left in hand, a programme reserved from the guide still on screen
    /// was sent to this recorder -- and the driver says why on the line once this has returned
    /// (`RecorderDriver.cacheNotMadeOver`). That another one answered is still to be said once it is taken up.
    func cacheCouldNotBeMadeOver() {
        let another = anotherTookOver
        forgetTheRecorder()
        anotherTookOver = another
    }

    /// While a television's link is in hand -- one saved, or the demo's added -- the recorder's lines name it.
    var televisionSaved: Bool { model?.tv != nil }

    /// What waits for the recorder is sent by its driver (`RecorderDriver.sendWhatWaits`), from inside the
    /// attach and when the list is pulled down: the list it read after a sending, which it reads only after a
    /// waking's attach that no connect reads after, is kept on what was said as this began, and what the round
    /// came to goes on the strip (`tellTheStrip`). A warning the runs with no screen left of
    /// reservations not yet at the recorder goes once none of them waits to go
    /// (`AppModel.forgetTheRecordersWarningOnceSent`). Nothing here may await `start()`.
    func sendWhatWaits() async {
        let said = self.said
        guard let sent = await recorderDriver?.sendWhatWaits() else { return }
        said.keep(reservations: sent.list)
        tellTheStrip(sent.round)
        model?.forgetTheRecordersWarningOnceSent()
    }

    func queueWritten() async {
        await model?.loadPending()
    }

    /// Provisional permission for notifications, now that there is a recorder for them to be about: no dialog,
    /// so nothing lands on the local network question just answered (`Notify`). Not for the demo. Then the
    /// reservations before the guide, which marks what is already set to record from that list: the driver's
    /// read, kept on what was said as it began (`DeviceHost.readReservationsNow`), which opens nothing. Inside the
    /// connect, so nothing here may await `start()`. Then whether the guide is behind, by what the cache holds
    /// now, which is read here as it was; the refresh itself is not awaited here, and is started as the connect
    /// ends, only where there is something to fetch (`refreshTheGuideAfterTheConnect`).
    func reached() async {
        guard let model else { return }
        let surroundings = model.surroundings
        timesReached += 1
        if !demo, surroundings.asksAboutNotifications {
            Task {
                await Notify.allowQuietly()
                await model.readNotifications()
            }
        }
        await readReservationsNow()
        await readAgainWhatWasUp()
        // A read that met silence has lost the recorder: there is no guide to fetch from it.
        guard model.connected else { return }
        await model.keepUpWithTheCache()
        if model.guideIsStale { refreshTheGuideAfterTheConnect(model) }
    }

    /// The guide, fetched where it is behind, in a task of the host's own that the connect does not wait for.
    /// Fetching the guide is what connecting is for, so it happens without being asked: the first run would
    /// otherwise land on an empty guide, and a cache the overnight run never got to would stay a day behind. A
    /// cache that is already current costs nothing, which is what makes this safe on every launch: where the
    /// cache read inside the connect says nothing is behind (`AppModel.keepUpWithTheCache`), none is started, so
    /// that no line goes up, none is counted as out, and nothing holds a second connect off after the connect.
    ///
    /// Not inside the connect: a refresh that is out as the connect is made -- the overnight run's, a press of
    /// 番組表を更新 -- holds the turn until it has fetched its files, and the connect would stand as under way all
    /// that time, and its checks pass without asking. What is fetched is what is behind once the refresh has its
    /// turn (`GuideAsked.whatIsBehind`), not what was behind here: what the refresh in front fetched is not
    /// fetched again. Started in the connect's last turn, so that the connect's end and the refresh being out are
    /// never apart (`refreshesTheGuideAfterAConnect`), and asked for in the task's first turn, for the recorder it
    /// was started for or not at all: its line goes up there. While it is out for the recorder still in play it
    /// holds a second connect off (`holdsOffConnect`), and a connect turned away meanwhile is made once it ends,
    /// unless silence met the recorder after it was turned away (`DeviceLink.lost`). From the screens that is, in
    /// practice, 再接続 or a pull-down in the few turns after a refresh that met silence has taken its line down.
    /// A return in the turn before its line is up, or after a refresh that went through, finds the recorder's
    /// last answer fresh and asks for nothing; while 番組表を取得中 stands, no 再接続 is offered, and a return or a
    /// look at the network only looks, as beside any line.
    private func refreshTheGuideAfterTheConnect(_ model: AppModel) {
        guideRefreshesStarted += 1
        let this = guideRefreshesStarted
        let noted = link.generation
        guideAfterAConnect = noted
        Task {
            if model.connected, !link.letGo(since: noted) { await model.refreshGuide(.whatIsBehind) }
            // Only the last one started takes the hold down: an older one ending first leaves a newer one's.
            guard guideRefreshesStarted == this else { return }
            guideAfterAConnect = nil
            await link.connectIfOwed()
        }
    }

    /// Its lists go at once, and the newcomer is taken up by a connect of its own, which reads its reservations
    /// and its guide as a waking's attach does not. A job under way was the last recorder's: it is stopped before
    /// its next step -- as its run stops itself for a recorder it did not begin with (`RecorderDriver.mayGoOn`),
    /// each of the two standing in for the other -- and the connect waits for it to end, since one does not start
    /// beside a job. A connect asked for while that job winds down -- a return to the app -- is owed, and made as
    /// the job ends (`jobEnded`): where it reached the newcomer, this one is not made on top of it. Said twice: the
    /// failure line for whoever asked, which the link writes once this has returned
    /// (`RecorderDriver.anotherAnswered`) and the connect takes away, and the strip after that.
    func anotherAnsweredTheCheck() {
        forgetTheRecorder()
        cancelBulk()
        anotherTookOver = true
        let model = self.model
        let running = jobTask
        let reached = timesReached
        Task {
            await running?.value
            self.clearJob()
            guard self.timesReached == reached else { return }
            await model?.connect()
        }
    }

    /// Waits for the reader to allow the local network, then tells the link. The screens say so from
    /// `AppModel.connectBlocked`. A wait that has given up with the permission still in the way ends for the link
    /// as one that found no path: it is told the permission did not come, and connecting again is the reader's.
    func waitForPermission(at host: String) {
        guard let wait = model?.surroundings.waitForTheLinksPermission else { return }
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            let access = await wait(host)
            guard let self, !Task.isCancelled else { return }
            // cleared before the link connects, since connecting stops whatever wait is still set
            self.accessWatch = nil
            await self.link.permissionArrived(access == .allowed, at: host)
        }
    }

    func stopWaitingForPermission() {
        accessWatch?.cancel()
        accessWatch = nil
    }


    // MARK: - the queue and the strip

    /// 削除する on a row waiting for the recorder, as the model hands it over once it has seen that nothing holds the row
    /// back (`AppModel.deleteWaiting`): the row is deleted by the driver in the queue's turn
    /// (`RecorderDriver.deleteWaiting`), which hands back the list it read in the turn, kept on what was said as the
    /// delete began (`RecorderSaid.keep`). A row made is not deleted, and what to say in place of that is handed back:
    /// that the reservation was made before the delete, and that it is deleted on the recorder
    /// (`RecorderDriver.madeBeforeItsDelete`, which names the recorder with or without a television saved). The warning
    /// of reservations not yet at the recorder is taken away once none of its rows waits
    /// (`AppModel.forgetTheRecordersWarningOnceSent`). Nil when the row was deleted, and when the row has gone and
    /// nothing says it was made.
    func deleteWaiting(_ waiting: PendingReservation) async -> String? {
        let said = self.said
        let deleted = await recorderDriver?.deleteWaiting(waiting)
        said.keep(reservations: deleted?.list)
        await model?.loadPending()
        model?.forgetTheRecordersWarningOnceSent()
        return deleted?.made == true
            ? RecorderDriver.madeBeforeItsDelete(waiting, naming: model?.deviceSaid(for: waiting)) : nil
    }

    /// What a sending of what waits for the recorder came to, on the strip, when a round ran
    /// (`RecorderDriver.sendWhatWaits`). Said on screen, since a notification does not show while the app is in
    /// front (nothing here answers `willPresent`). Added to what the strip holds unread, by the strip's rule
    /// (`AppModel.adding(_:toUnread:)`), as a television's sending adds to its own: two sendings before the reader
    /// closes the strip are both said, and a sentence it holds already is not said twice. A round with nothing
    /// to say leaves the strip as it was. What became of the queue says which device it went to once a
    /// television is saved beside the recorder, and not before (`PendingQueue.Outcome.said`).
    ///
    /// What is held for another recorder is said first, each time a sending is asked, for as long as any is
    /// (`RecorderDriver.heldBack`), counted from the rows on screen, which the driver has had read again as it
    /// looked at the queue and after its round (`queueWritten`): also when no round ran -- with nothing else
    /// waiting, the driver asks the recorder nothing, and no row for the recorder, or the recorder not there to
    /// send to, runs none either. The count said before is replaced by it (`heldBackSaid`), the rest kept. With
    /// nothing held and nothing to add, the strip stays as it was.
    func tellTheStrip(_ round: PendingQueue.Outcome?) {
        let held = RecorderDriver.heldBack(in: model?.pending ?? [])
        // What the strip holds unread, without the count it began with, which this sending's replaces.
        var unread = self.said.report
        if let said = heldBackSaid, let report = self.said.report, report.hasPrefix(said) {
            let rest = report.dropFirst(said.count).drop { $0 == "。" }
            unread = rest.isEmpty ? nil : String(rest)
        }
        let added = round?.said(withATelevisionSaved: model?.tv != nil)
            .flatMap { AppModel.adding($0, toUnread: unread) }
        let lines = [held, added ?? unread].compactMap { $0 }
        guard !lines.isEmpty else { return }
        self.said.report = lines.joined(separator: "。")
        heldBackSaid = held
    }

    // MARK: - the recordings

    func loadTitles(force: Bool = false) async {
        let said = self.said
        await model?.start()
        await loadTitlesNow(force: force, into: said)
    }

    /// The load itself, without `start()`, for anything `connect()` reaches: see there. The read is the driver's
    /// (`RecorderDriver.titles`), which hands the list over as it comes back, before the free space is read, and
    /// the list is kept on what was said as the entry began (`RecorderSaid.keep`), the one in play when `said` is
    /// nil, as for the reservations: a list read for a recorder let go of meanwhile is kept where no screen reads
    /// it, and the one after it, whose own connect reads its list (`anotherDeviceDescribedItself`),
    /// is left alone. While it is out it is counted (`titleReads`).
    func loadTitlesNow(force: Bool, into said: RecorderSaid? = nil) async {
        let said = said ?? self.said
        guard client != nil, !unreachable, force || !self.said.titlesLoaded else { return }
        titleReads += 1
        defer { titleReads -= 1 }
        _ = await recorderDriver?.titles { said.keep(titles: $0, readFrom: $1) }
    }

    /// Whether the list held is not what a read would give with the USB disk known now, for the screen to read it
    /// again: its rows of a disk that has left the slot are not to be written to
    /// (`RecorderDriver.whyNot(altering:usb:)`) and go with a read, and a disk that has turned up, or that the last
    /// read could not read, comes in with one. Nothing changes in a home with no USB disk, where both sides are
    /// none.
    ///
    /// Not while the disk known has yet to be answered by the slot, which has not said anything of it yet, right
    /// after a waking above all: that read would be waited out, and the list goes out of date only once the slot has
    /// answered. Not while nothing could be read, nor while a job walks the list, as a pull-down: both end with this
    /// turning true if the list still is, which is what the screen goes by.
    var usbListOutdated: Bool {
        guard said.titlesLoaded, !jobRunning, client != nil, !unreachable, !session.usbDiskUnanswered else {
            return false
        }
        guard let read = said.titlesReadFrom else { return session.usbDisk?.takesRecordings == true }
        return !read.isStill(session.usbDisk)
    }

    /// What pulling the recordings down asks for: the list read again, or a connect when nothing can be written
    /// to the recorder -- the driver's to decide (`RecorderDriver.refresh`), after `start()` whichever it does.
    /// Not while a bulk job is walking the list. Counted as a read of the list across the connect it may make
    /// (`titleReads`): one that takes another recorder up has the newcomer's connect read the list, read before
    /// or not, and the pull-down reads nothing after it.
    func refreshTitles() async {
        let said = self.said
        await model?.start()
        guard !jobRunning else { return }
        titleReads += 1
        defer { titleReads -= 1 }
        await recorderDriver?.refresh { await self.loadTitlesNow(force: true, into: said) }
    }

    /// Asked as a recording's sheet opens (`RecorderDriver.detail`), which is also the moment to wake a recorder
    /// that has gone to sleep.
    func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        await model?.start()
        return await recorderDriver?.detail(of: title)
    }

    /// A write: the recorder stops deleting this one to make room (`RecorderDriver.protect`). What it came to, for
    /// the screen to say.
    @discardableResult
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Altered {
        await model?.start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        let came = await recorderDriver.protect(title, on) {
            if let index = self.said.titles.firstIndex(where: { $0.id == title.id }) {
                self.said.titles[index].protected = on
            }
        }
        // Silence may have come after the recorder made the change. The list is read again once it answers,
        // rather than guessed at.
        if came.readAgain { said.titlesLoaded = false }
        // which copy of a set to keep can change with it
        if case .done = came.altered, !said.duplicates.isEmpty { said.recomputeDuplicates() }
        return came.altered
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder
    /// (`RecorderDriver.delete`). What it came to, for the screen to say.
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Altered {
        await model?.start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        let came = await recorderDriver.delete(title) { self.said.titles.removeAll { $0.id == title.id } }
        // as for protecting: silence may have come after the recording had gone
        if came.readAgain { said.titlesLoaded = false }
        // A set on screen may have been left with one copy, or none of the one it says it keeps.
        if case .done = came.altered, !said.duplicates.isEmpty { said.recomputeDuplicates() }
        return came.altered
    }

    /// Playback happens on the television the recorder is attached to, not here (`RecorderDriver.play`). A
    /// recorder in standby is what `needsPower` reports, and the sheet offers to turn it on for. What it came to,
    /// for the sheet to say.
    @discardableResult
    func play(_ title: RecordedTitle, _ operation: String) async -> Altered {
        await model?.start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        return await recorderDriver.play(title, operation)
    }

    /// Turns the recorder on, which also turns on the television attached to it (`RecorderDriver.powerOn`). What
    /// it came to, for the sheet to say.
    @discardableResult
    func powerOn() async -> Altered {
        await model?.start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        return await recorderDriver.powerOn()
    }

    // MARK: - the recorder's own keyword conditions (おまかせ・まる録)

    func loadRecorderRules() async {
        let said = self.said
        await model?.start()
        await loadRecorderRulesNow(into: said)
    }

    /// The read itself, without `start()`, for anything `connect()` reaches: see there. The read is the driver's
    /// (`RecorderDriver.recorderRules`), and so is why it could not be made; what the screen holds of it is the
    /// app's, kept on what was said as the entry began (`RecorderSaid.keep`), the one in play when `said` is nil,
    /// as for the recordings: a read for a recorder let go of meanwhile says nothing on the screen of the one
    /// after it, whose own connect reads its list. While it is out it is counted (`conditionReads`).
    func loadRecorderRulesNow(into said: RecorderSaid? = nil) async {
        let said = said ?? self.said
        guard let recorderDriver, client != nil, !unreachable else {
            // A list read before stays on screen under the strip that says the recorder is not there; with
            // none, the screen says why there is nothing rather than waiting for a read that is not coming.
            if !self.said.recorderRulesLoaded {
                self.said.recorderRulesFailure = recorderDriver?.whyNotConnected ?? RecorderDriver.notConnected
            }
            return
        }
        conditionReads += 1
        defer { conditionReads -= 1 }
        said.keep(rules: await recorderDriver.recorderRules())
    }

    /// What pulling the conditions down asks for: the list read again, or a connect when nothing can be written
    /// to the recorder -- the driver's to decide (`RecorderDriver.refresh`), after `start()` whichever it does.
    /// Counted as a read of the list across the connect it may make, as the recordings' pull-down is
    /// (`conditionReads`).
    func refreshRecorderRules() async {
        let said = self.said
        await model?.start()
        conditionReads += 1
        defer { conditionReads -= 1 }
        await recorderDriver?.refresh { await self.loadRecorderRulesNow(into: said) }
    }

    /// Registers a condition on the recorder itself (`RecorderDriver.addRule`), which reads the list again once it
    /// has, kept on what was said as the entry began (`RecorderSaid.keep`). What it came to, for the sheet to say.
    /// Counted as a read of the list while it is out (`conditionReads`), the read after among it: another recorder
    /// answering meanwhile has its own conditions read by its connect, as for any read of them out.
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Altered {
        let said = self.said
        await model?.start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        conditionReads += 1
        defer { conditionReads -= 1 }
        return await recorderDriver.addRule(request) { said.keep(rules: $0) }
    }

    /// Delete only, never edit (`RecorderDriver.removeRule`), which reads the list first, sending nothing for a
    /// condition not in it as shown (`RecorderDriver.conditionNotInList`), and again after a delete that went
    /// through or that the recorder refused as holding no such condition, both kept as a condition added has its
    /// list kept. What it came to, for the screen to say: any other refusal is said there and stays on the line,
    /// nothing being read after it; after the recorder's "no such condition" the read after it clears the line
    /// when it goes through, or says its own failure when it does not. Counted while it is out, both reads among
    /// it, as a condition added is.
    func removeRecorderRule(_ rule: RecorderRule) async -> Altered {
        let said = self.said
        await model?.start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        conditionReads += 1
        defer { conditionReads -= 1 }
        return await recorderDriver.removeRule(rule) { said.keep(rules: $0) }
    }
}

/// The recorder's side of the six entries written once for both hosts (`DeviceHost`). The cache is opened before
/// one asks (`AppModel.start`); a list is kept on what the recorder said as the entry began, which a let-go
/// replaces (`RecorderSaid.keep`), so that a list read for a recorder let go of meanwhile is kept where no screen
/// reads it; and what follows a reservation and a sending again is this host's own.
extension RecorderHost: DeviceHost {
    static var slot: DeviceSlot { .recorder }
    var reservations: [Reservation] { said.reservations }
    var reservationsByProgram: [String: Reservation] { said.reservationsByProgram }
    var reservationsRead: Date? { said.reservationsRead }
    var report: String? {
        get { said.report }
        set { said.report = newValue }
    }
    var reservationDriver: (any ReservationDriver)? { recorderDriver }
    var deviceSession: SessionState? { session }
    var keeping: @MainActor ([Reservation]) -> Void {
        let said = self.said
        return { said.keep(reservations: $0) }
    }

    /// A reservation takes the place of a row that waited for the same programme, so a warning the runs with no
    /// screen left of reservations not yet at the recorder goes here too, once none of them waits to go
    /// (`AppModel.forgetTheRecordersWarningOnceSent`).
    ///
    /// A reservation kept for the recorder is heard of again in a notification once it is sent, so the system's
    /// dialog comes here, as it comes in the television's host: after the row is kept, before the result is
    /// said, and once the reservation's line is down. The dialog waits on the reader, who may leave the app
    /// instead of answering, and neither the reservation nor the app's work waits with it. As there, not for one
    /// held with a reason, which waits for the reader, nor in the demo, whose recorder is nobody's to be told of.
    func afterAReservation(_ reserved: Reserved) async {
        model?.forgetTheRecordersWarningOnceSent()
        if case .waiting(let row, _) = reserved, row.problem == nil, !demo { await model?.askForNotifications() }
    }

    /// What a row sent again came to goes on the strip (`tellTheStrip`), and a warning the runs with no screen
    /// left of reservations not yet at the recorder goes once none of them waits to go.
    func tell(_ round: PendingQueue.Outcome?) async {
        tellTheStrip(round)
        model?.forgetTheRecordersWarningOnceSent()
    }
}
