import Foundation
import Observation
import RecorderKit

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
    /// The recorder's own keyword conditions (おまかせ・まる録).
    var recorderRules: [RecorderRule] = []
    /// Whether `recorderRules` is the recorder's answer, and why the last read failed if it did. An empty list
    /// is also what there is while the first read is on its way and after one that failed, and saying
    /// 条件が登録されていません then tells the reader something the recorder never said.
    var recorderRulesLoaded = false
    var recorderRulesFailure: String?
    /// How many reservations are held for another recorder, and what the sendings of the queue came to since
    /// the reader last closed the strip, for the strip to say until the reader closes it or leaves the app. See
    /// `AppModel.tellTheStrip`.
    var report: String?
    var duplicates: [DuplicateSet] = []
    /// Which copies are ticked for deletion; the ones left unticked are kept. It lives here because the view
    /// holding it is thrown away every time the reader looks at the list or the programmes instead.
    var duplicatePicks: Set<String> = []
    /// How many candidates were left out of the sets because their text has not been read, which a scan run
    /// again reads.
    var unreadDuplicates = 0
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

    /// Puts a list of the recordings here.
    func keep(titles list: [RecordedTitle]) {
        titles = list
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
    /// sending to put its own count in place of (`AppModel.tellTheStrip`).
    @ObservationIgnored var heldBackSaid: String?
    /// The lists the reader had read, or was reading, when another recorder answered a connect made while the
    /// app was connected, for that connect to read again from the one that answered. See
    /// `anotherDeviceDescribedItself`.
    var listsToReadAgain = (recordings: false, rules: false)
    /// How many reads of the recordings, and of the keyword conditions, are out (`AppModel.loadTitlesNow`,
    /// `AppModel.loadRecorderRulesNow`, a pull-down across its connect, and a condition's add or delete, which
    /// reads the list after it): one out when another recorder answers is a list the reader was about to see,
    /// which is not put on that one's screens and is read from it instead.
    var titleReads = 0
    var conditionReads = 0
    /// Waits for the local network permission after the link ran into it, and tells the link when it comes
    /// (`DeviceLink.permissionArrived`).
    var accessWatch: Task<Void, Never>?
    /// The recorder's link, for the model's life.
    let link: DeviceLink
    /// The model that made this, for what is the phone's.
    @ObservationIgnored weak var model: AppModel?

    init(link: DeviceLink) {
        self.link = link
    }

    private var session: SessionState { link.session }
    private var recorderDriver: RecorderDriver? { link.driver as? RecorderDriver }
    /// The recorder's address on the LAN, as the link has it.
    private var host: String { link.host }
    private var demo: Bool { model?.demo ?? false }

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
    /// run.
    ///
    /// A finished job goes because the duplicates view takes it for having looked. One still running is
    /// stopped by the check that hears the other recorder (`anotherAnsweredTheCheck`).
    func forgetWhatTheRecorderSaid() {
        said = RecorderSaid()
        anotherTookOver = false
        model?.clearJob()
        model?.titleGenre = nil
        model?.titleState = nil
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
        if again.recordings { await model?.loadTitlesNow(force: false) }
        if again.rules { await model?.loadRecorderRulesNow() }
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
    var holdsOffConnect: Bool { model?.jobRunning ?? false }
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
    /// told of it (`TVTold`): the next run tells what it finds afresh. Their warning of reservations not yet at
    /// the recorder is taken away, where the app asks the system about notifications at all: the rows it names
    /// are held for the reader now, and none of them waits to go.
    func cacheMadeOver() async {
        guard let model else { return }
        let defaults = model.defaults, surroundings = model.surroundings
        defaults.removeObject(forKey: DefaultsKey.warnedLowSpace)
        defaults.removeObject(forKey: DefaultsKey.warnedLowSpaceOnUSB)
        defaults.removeObject(forKey: DefaultsKey.lastBackgroundRefresh)
        defaults.removeObject(forKey: DefaultsKey.recorderTold)
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

    /// What waits for the recorder is sent by its driver (`RecorderDriver.sendWhatWaits`), from inside the
    /// attach and when the list is pulled down: the list it read after a sending, which it reads only after a
    /// waking's attach that no connect reads after, is kept on what was said as this began, and what the round
    /// came to goes on the strip (`AppModel.tellTheStrip`). A warning the runs with no screen left of
    /// reservations not yet at the recorder goes once none of them waits to go
    /// (`AppModel.forgetTheRecordersWarningOnceSent`). Nothing here may await `start()`.
    func sendWhatWaits() async {
        let said = self.said
        guard let sent = await recorderDriver?.sendWhatWaits() else { return }
        said.keep(reservations: sent.list)
        model?.tellTheStrip(sent.round)
        await model?.forgetTheRecordersWarningOnceSent()
    }

    func queueWritten() async {
        await model?.loadPending()
    }

    /// Provisional permission for notifications, now that there is a recorder for them to be about: no dialog,
    /// so nothing lands on the local network question just answered (`Notify`). Not for the demo. Then the
    /// reservations before the guide, which marks what is already set to record from that list: the driver's
    /// read, kept on what was said as this began. Inside the connect, so nothing here may await `start()`.
    func reached() async {
        let said = self.said
        guard let model else { return }
        let surroundings = model.surroundings
        if !demo, surroundings.asksAboutNotifications {
            Task {
                await Notify.allowQuietly()
                await model.readNotifications()
            }
        }
        let read = await recorderDriver?.reservations()
        said.keep(reservations: read)
        await readAgainWhatWasUp()
        await model.refreshGuideIfStale()
    }

    /// Its lists go at once, and the newcomer is taken up by a connect of its own, which reads its reservations
    /// and its guide as a waking's attach does not. A job under way was the last recorder's: it is stopped before
    /// its next step -- as its run stops itself for a recorder it did not begin with (`RecorderDriver.mayGoOn`),
    /// each of the two standing in for the other -- and the connect waits for it to end, since one does not start
    /// beside a job. Said twice: the failure line for whoever asked, which the link writes once this has returned
    /// (`RecorderDriver.anotherAnswered`) and the connect takes away, and the strip after that.
    func anotherAnsweredTheCheck() {
        forgetTheRecorder()
        model?.cancelBulk()
        anotherTookOver = true
        let model = self.model
        let running = model?.jobTask
        Task {
            await running?.value
            model?.clearJob()
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
}
