import Foundation
import Observation
import RecorderKit

/// The app's side of the television's link (`LinkHost`): what the link tells the app about the television, apart
/// from the recorder's. Its own line for what went wrong, its own keys in the defaults, and its own wait for the
/// local network permission, so that nothing the television does stops or clears the recorder's. The lines of
/// what is under way are the app's one list, the television's marked as its own (`televisionLines`).
///
/// What the television said is kept here as well, and not in the model: its reservations, and when they were
/// read, and its recordings. The steps of reading and deleting them, and the sentence for each way they can end,
/// are the driver's (`TVDriver`); this asks, and keeps what comes back. The app makes a host with each link and
/// lets go of the two together -- the television taken away, registered again, or left for the demo -- so a list
/// goes with the television it was read from, and nothing has to empty it or to ask whose it was before keeping
/// it. A host let go of asks nothing more and says nothing on the screens -- the lines it had up come down as the
/// app lets go of it (`takeDownLines`), and one begun after is on no list -- and writes nothing down for an attach
/// that was still out.
///
/// What waits in the phone's queue for the television is sent the same way: the driver has the steps, and
/// this asks for them when the link says to and keeps what the sending came to, for the strip (`report`).
/// So with the two things a reader asks for about a reservation the television does not hold yet: reserving
/// a programme on it (`reserve`), whose result is handed on to whoever asked, and sending a waiting row
/// again (`resend`), which is said on the strip as a sending is and whose result is handed on beside that,
/// for what the strip does not say. After either the list the driver read back is kept, and the queue on
/// screen is read again.
///
/// What only a recorder's link tells its host -- its cache, its MAC and where it was read, another recorder
/// taking its place -- is nothing to a television, and is not asked of this (`RecorderLinkHost`).
@MainActor
@Observable
final class TVHost: LinkHost {
    /// What went wrong with the television, said beside it in the settings and on the strip.
    var problem: String?
    /// What the television is set to record, as last read from it: its rows only, and never among the
    /// recorder's (`RecorderSaid.reservations`), whose reads replace that list whole.
    private(set) var reservations: [Reservation] = [] {
        didSet { reservationsByProgram = ByProgram.of(reservations) }
    }
    /// The same by the programme each follows, for the guide to mark, as the recorder's host keeps the recorder's
    /// (`RecorderSaid.reservationsByProgram`).
    private(set) var reservationsByProgram: [String: Reservation] = [:]
    /// When the list was last read from the television, or nil when it has not been: a television that cannot
    /// be asked leaves the last list standing, and this says how old it is.
    private(set) var reservationsRead: Date?
    /// The recordings on its disk, as last read from it: its rows only, and never among the recorder's
    /// (`RecorderSaid.titles`), the model putting the two together for the screens. A television that cannot be
    /// asked leaves them standing, as it does its reservations.
    var titles: [RecordedTitle] = []
    /// What the last read of them came to beside what the disk has used (`TVDriver.account`).
    private(set) var titlesAccount = TVTitlesAccount.addsUp
    /// Set for as long as a list that may still be coming is read again, which the strip says
    /// (`TVDriver.titlesComingLine`). Not a line of the television's: that would hold its buttons for minutes, and
    /// nothing that is under way stands in the way of them.
    private(set) var waitingForTitles = false
    /// What the sendings to the television came to, for the strip, each added to what the one before said
    /// (`tell`) until the reader closes it or leaves the app (`AppModel.queueReport`). It goes with the
    /// host, as the television's list does.
    var report: String?
    @ObservationIgnored private(set) weak var model: AppModel?
    /// The link this answers for, set once the link is made.
    @ObservationIgnored weak var link: DeviceLink?
    /// Waits for the local network permission after the television's link ran into it.
    @ObservationIgnored private var accessWatch: Task<Void, Never>?
    /// The lines this has up on the model's list: emptied as the app lets go of this host (`takeDownLines`).
    /// One begun after that is on no list, and its token is not to end or change a line of the model's that
    /// happens to carry the same number.
    @ObservationIgnored private var shown: Set<Activities.Token> = []

    init(model: AppModel) {
        self.model = model
    }

    /// Whether the app still holds this host: the television it answers for is the one in play.
    private var inPlay: Bool { model?.tvHost === self }

    // MARK: - what the app asks of the television

    /// The television's driver, which is asked without being handed a link. Nil once the app has let go of
    /// this host or of its link: nothing is asked then.
    private var driver: TVDriver? { inPlay ? link?.driver as? TVDriver : nil }

    /// A change and a reservation by what a television takes, its repeat: it records in its one mode and has no
    /// disk to choose (`DeviceHost.change`, `DeviceHost.reserve`).
    func update(_ reservation: Reservation, repeating: String) async -> Altered? {
        await change(reservation, .changing(quality: TVDriver.recordsIn, repeating: repeating, disk: nil))
    }

    func reserve(_ program: GuideProgramRow, repeating: String) async -> Reserved {
        await reserve(program, .reserving(quality: TVDriver.recordsIn, repeating: repeating,
                                          disk: RecorderDisk.internalID))
    }

    private func keep(_ list: [Reservation]) {
        reservations = list
        reservationsRead = Date()
    }

    // MARK: - its recordings

    private func keep(_ read: TVTitles) {
        titles = read.rows
        titlesAccount = read.account
    }

    /// Whether a job is walking the television's rows. Nothing reads the list beside it: a read is two requests,
    /// the disk's and the list's, and with a delete between them the disk counts a row the list no longer has, which
    /// would be said as rows missing. The job reads the list as it ends (`RecorderHost.jobEnded`).
    private var aJobWalksTheList: Bool { model?.recorderHost.jobIsOnTheTelevision == true }

    /// Reads the recordings, as the recordings tab does when it opens. What cannot be read leaves what is held,
    /// and the line says why.
    func loadTitles() async {
        await model?.start()
        guard !aJobWalksTheList else { return }
        _ = await driver?.titles { self.keep($0) }
    }

    /// What pulling the recordings down asks of the television: the list read now, or a connect (`TVDriver`).
    func refreshTitles() async {
        await model?.start()
        guard !aJobWalksTheList else { return }
        await driver?.refreshTitles { self.keep($0) }
    }

    /// Reads again a list that may still be coming, for as long as the screen's task lasts (`TVDriver`), and not
    /// beside a job or with the app away, which the screen's task is ended for.
    func waitForTitles() async {
        guard titlesAccount == .mayStillBeComing, !aJobWalksTheList, model?.inBackground != true, let driver,
              driver.canBeAsked else { return }
        waitingForTitles = true
        defer { waitingForTitles = false }
        await driver.waitForTitles { self.keep($0) }
    }

    /// A write: the television refuses to delete it until this is taken off (`TVDriver.protect`). What it came
    /// to, for the screen to say.
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Altered {
        await model?.start()
        guard let driver else { return .notDone(TVDriver.notConnected) }
        let came = await driver.protect(title, on) {
            if let index = self.titles.firstIndex(where: { $0.id == title.id }) { self.titles[index].protected = on }
        }
        if came.readAgain { await loadTitles() }
        return came.altered
    }

    /// A write, and not one that can be undone (`TVDriver.delete`). What it came to, for the screen to say.
    func delete(_ title: RecordedTitle) async -> Altered {
        await model?.start()
        guard let driver else { return .notDone(TVDriver.notConnected) }
        let came = await driver.delete(title) { self.titles.removeAll { $0.id == title.id } }
        if came.readAgain { await loadTitles() }
        return came.altered
    }

    /// What a run over recordings asks of the television (`RecorderHost.runBulk`), and the list it walks.
    var runDriver: (any RunDriver)? { driver }

    // MARK: - what the link tells the app

    /// On the app's one list, marked as the television's. From a host the app has let go of the line goes on
    /// a list of its own, which nothing shows: what is carried through on a television that was taken away
    /// says nothing on the screens.
    func beginActivity(_ text: String) -> Activities.Token {
        guard let model, inPlay else {
            var nowhere = Activities()
            return nowhere.begin(text)
        }
        let token = model.activities.begin(text)
        model.televisionLines.insert(token)
        shown.insert(token)
        return token
    }

    func updateActivity(_ token: Activities.Token, to text: String) {
        guard shown.contains(token) else { return }
        model?.activities.update(token, to: text)
    }

    /// Only a line this has up. One that came down as the app let go of this host, or was begun after, is
    /// none of the model's to end.
    func endActivity(_ token: Activities.Token) {
        guard shown.remove(token) != nil else { return }
        model?.televisionLines.remove(token)
        model?.activities.end(token)
    }

    /// Takes down every line this has up, as the app lets go of it (`AppModel.dropTVLink`), and not as the
    /// requests they stand for end: one still out on a television that was taken away can be out for a long
    /// while yet, and the screens no longer show that television. Ending its line afterwards does nothing.
    func takeDownLines() {
        for token in shown {
            model?.televisionLines.remove(token)
            model?.activities.end(token)
        }
        shown = []
    }

    /// Busy with the television: its own lines only.
    var isBusy: Bool { !(model?.televisionLines.isEmpty ?? true) }
    /// A job over recordings that holds rows of the television's: no connect starts beside it, as none does beside
    /// the recorder's, and one turned away is made as the job ends (`RecorderHost.jobEnded`).
    var holdsOffConnect: Bool { model?.recorderHost.jobIsOnTheTelevision ?? false }
    var isDemo: Bool { model?.demo ?? false }
    var cache: GuideStore? { model?.store }
    func cacheForAttempt() async { await model?.openCache() }

    func keepAddress(_ host: String) {
        guard let model, inPlay, !model.demo else { return }
        model.defaults.set(host, forKey: DefaultsKey.tvHost)
    }

    func keepMAC(_ text: String) {
        guard let model, inPlay, !model.demo, let mac = WakeOnLan.normalise(text) else { return }
        model.defaults.set(mac, forKey: DefaultsKey.tvMac)
    }

    /// What waits for the television is sent by its driver, and what that came to is kept (`tell`). With no
    /// sending -- nothing was to go, or the television could not be asked -- nothing changed, and nothing
    /// is read again. Nothing is sent from a host the app has let go of. The list is not read here: a
    /// connect reads it next (`reached`), and a pull-down reads it itself. Inside a connect, so nothing
    /// here may await `AppModel.start()`.
    func sendWhatWaits() async {
        guard let outcome = await driver?.sendWhatWaits() else { return }
        await tell(outcome)
    }

    /// The queue on screen is the model's, for both devices' rows, and is read again there.
    func queueWritten() async {
        await model?.loadPending()
    }

    /// Keeps what a sending to the television came to, for a sending of what waits and for a row sent again
    /// alike. The queue on screen is read again, always: with no round too, since a row sent again may have
    /// had its reason taken off before the television could be asked. What the round has to say goes on the
    /// strip, naming the television, added to what is there unread by the strip's rule
    /// (`AppModel.adding(_:toUnread:)`): the next sending is not to take what this one said, which can end
    /// with what making a reservation did to another. A round with nothing to say, and no round, leave the
    /// report where it was, as the recorder's sending does. Reached from inside a connect, so nothing here may
    /// await `AppModel.start()`.
    ///
    /// A warning the runs with no screen left of reservations not yet at the television goes here once none
    /// of them waits to go any more (`AppModel.forgetTheWarningOnceSent`), whichever sending took them.
    func tell(_ round: PendingQueue.Outcome?) async {
        await model?.loadPending()
        model?.forgetTheWarningOnceSent()
        guard let said = round?.said(withATelevisionSaved: true) else { return }
        if let added = AppModel.adding(said, toUnread: report) { report = added }
    }

    /// A connect reached the television: its reservations are read, as the recorder's are when a connect
    /// reaches it. Inside the connect, so nothing here may await `AppModel.start()`.
    func reached() async {
        await readReservationsNow()
    }

    /// The check before an operation met another television at the television's address, by its MAC
    /// (`TVDriver.check`): nothing was sent, and nothing that needs the registration is asked from now on.
    /// The link says so in the line for another device (`TVDriver.anotherAnswered`): what the reader asked for
    /// was not done because another television is at its address, and that is what they are to know. Whatever
    /// else answers the check, a device that is no television included, is said by the driver as what it
    /// answered. The list stays, the television's and no longer read (`staleSince`), and nothing else is done
    /// here: the next connect asks again and looks past what answered, where a recorder's host connects at once
    /// to take the newcomer up.
    func anotherAnsweredTheCheck() {}

    /// Not from a host the app has let go of. A request still out on its link can run into the permission
    /// after that, and the app stops a host's wait once, as it lets go of it (`AppModel.dropTVLink`): one set
    /// going later would have nothing left to stop it. A wait that has given up ends as the recorder's does
    /// (`RecorderHost.waitForPermission`).
    func waitForPermission(at host: String) {
        guard inPlay, let wait = model?.surroundings.waitForTheLinksPermission else { return }
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            let access = await wait(host)
            guard let self, !Task.isCancelled else { return }
            // cleared before the link connects, since connecting stops whatever wait is still set
            self.accessWatch = nil
            await self.link?.permissionArrived(access == .allowed, at: host)
        }
    }

    func stopWaitingForPermission() {
        accessWatch?.cancel()
        accessWatch = nil
    }
}

/// The television's side of the six entries written once for both hosts (`DeviceHost`). The cache is opened
/// before one asks, as for the recorder's; a list is kept on this host, which goes with the television it was
/// read from; and what follows a reservation and a sending again is this host's own.
extension TVHost: DeviceHost {
    static var slot: DeviceSlot { .tv }
    var reservationDriver: (any ReservationDriver)? { driver }
    var deviceSession: SessionState? { link?.session }
    var keeping: @MainActor ([Reservation]) -> Void { { self.keep($0) } }

    /// The queue on screen is read again whatever a reservation came to: the driver writes the row before it
    /// sends anything, and the row is gone again once the television holds it.
    ///
    /// A reservation takes the place of a row that waited for the same programme on the television, so a
    /// warning the runs with no screen left of reservations not yet at the television goes here too, once
    /// none of them waits to go (`AppModel.forgetTheWarningOnceSent`), as it goes after a sending (`tell`).
    ///
    /// A reservation kept to go by itself is heard of again in a notification, as one kept for the recorder
    /// is, so the system's dialog comes here as it does there: after the row is kept, before the result is
    /// said. Not for one held with a reason, which waits for the reader, nor in the demo, whose television
    /// is nobody's to be told of.
    func afterAReservation(_ reserved: Reserved) async {
        await model?.loadPending()
        model?.forgetTheWarningOnceSent()
        if case .waiting(let row, _) = reserved, row.problem == nil, !isDemo { await model?.askForNotifications() }
    }
}
