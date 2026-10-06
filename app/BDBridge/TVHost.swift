import Foundation
import Observation
import RecorderKit

/// The app's side of the television's link (`LinkHost`): what the link tells the app about the television, apart
/// from the recorder's. Its own line for what went wrong, its own keys in the defaults, and its own wait for the
/// local network permission, so that nothing the television does stops or clears the recorder's. The lines of
/// what is under way are the app's one list, the television's marked as its own (`televisionLines`).
///
/// What the television said is kept here as well, and not in the model: its reservations, and when they were
/// read. The steps of reading and deleting them, and the sentence for each way they can end, are the driver's
/// (`TVDriver`); this asks, and keeps what comes back. The app makes a host with each link and lets go of the
/// two together -- the television taken away, registered again, or left for the demo -- so a list goes with the
/// television it was read from, and nothing has to empty it or to ask whose it was before keeping it. A host
/// let go of asks nothing more and says nothing on the screens -- the lines it had up come down as the app lets
/// go of it (`takeDownLines`), and one begun after is on no list -- and writes nothing down for an attach that
/// was still out.
///
/// What waits in the phone's queue for the television is sent the same way: the driver has the steps, and
/// this asks for them when the link says to and keeps what the sending came to, for the strip (`report`).
/// So with the two things a reader asks for about a reservation the television does not hold yet: reserving
/// a programme on it (`reserve`), whose result is handed on to whoever asked, and sending a waiting row
/// again (`resend`), which is said on the strip as a sending is and whose result is handed on beside that,
/// for what the strip does not say. After either the list the driver read back is kept, and the queue on
/// screen is read again.
///
/// Most of what a link can tell its host is about a recorder -- its cache, its MAC and where it was read,
/// another recorder taking its place -- and is nothing to a television: those are left empty.
@MainActor
@Observable
final class TVHost: LinkHost {
    /// What went wrong with the television, said beside it in the settings and on the strip.
    var problem: String?
    /// What the television is set to record, as last read from it: its rows only, and never among the
    /// recorder's (`AppModel.reservations`), whose reads replace that list whole.
    private(set) var reservations: [Reservation] = [] {
        didSet { reservationsByProgram = AppModel.byProgram(reservations) }
    }
    /// The same by the programme each follows, for the guide to mark, as the model keeps the recorder's.
    private(set) var reservationsByProgram: [String: Reservation] = [:]
    /// When the list was last read from the television, or nil when it has not been: a television that cannot
    /// be asked leaves the last list standing, and this says how old it is.
    private(set) var reservationsRead: Date?
    /// What the sendings to the television came to, for the strip, each added to what the one before said
    /// (`tell`) until the reader closes it or leaves the app (`AppModel.queueReport`). It goes with the
    /// host, as the television's list does.
    var report: String?
    @ObservationIgnored private weak var model: AppModel?
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

    /// Reads the television's reservations, as a screen that shows them does when it appears. One that could
    /// not be read leaves the last list, and its time, as they were.
    func loadReservations() async {
        _ = await readReservations()
    }

    /// The same, handing back the list read now, nil when none was: for whoever has to know what the
    /// television holds at this moment, and not what it held when it was last read.
    func readReservations() async -> [Reservation]? {
        guard let list = await driver?.reservations() else { return nil }
        keep(list)
        return list
    }

    /// What pulling the reservations down asks of the television: what waits is sent, which the driver asks
    /// of this host on the way (`sendWhatWaits`), and the list is read again; or a connect when it cannot be
    /// asked, whose own read is kept from `reached`.
    func refreshReservations() async {
        guard let list = await driver?.refreshReservations() else { return }
        keep(list)
    }

    /// Takes a reservation off the television. Whether it was deleted; the list read on the way is kept
    /// either way, since a delete that was refused has still seen what the television holds now.
    func cancel(_ reservation: Reservation) async -> Bool {
        guard let driver else { return false }
        let (deleted, list) = await driver.cancel(reservation)
        if let list { keep(list) }
        return deleted
    }

    /// Changes a television's reservation, as far as the driver does yet. Whether it was changed.
    func update(_ reservation: Reservation, quality: String, repeating: String) async -> Bool {
        guard let driver else { return false }
        let (changed, list) = await driver.update(reservation, quality: quality, repeating: repeating)
        if let list { keep(list) }
        return changed
    }

    /// Reserves a programme on the television. What it came to, for whoever asked to say: the result is
    /// what says it, and nothing of the reservation itself goes on the strip, where it would read as one
    /// that had been waiting. The list a reservation made was read back with is kept. The queue on screen
    /// is read again whatever it came to: the driver writes the row before it sends anything, and the row
    /// is gone again once the television holds it. From a host the app has let go of nothing is kept or
    /// sent.
    ///
    /// A reservation kept to go by itself is heard of again in a notification, as one kept for the recorder
    /// is, so the system's dialog comes here as it does there: after the row is kept, before the result is
    /// said. Not for one held with a reason, which waits for the reader.
    func reserve(_ program: GuideProgramRow, repeating: String) async -> Reserved {
        guard let driver else { return .notDone(TVDriver.notConnected) }
        let (reserved, list) = await driver.reserve(program, repeating: repeating)
        if let list { keep(list) }
        await model?.loadPending()
        if case .waiting(let row, _) = reserved, row.problem == nil { await model?.askForNotifications() }
        return reserved
    }

    /// Sends a row waiting for the television again, as the reader asked on that row. The list read after
    /// a row that was made is kept, and what the round came to is told as any sending's is (`tell`) -- with
    /// no round as well: the row had been waiting, and the strip may be saying what an earlier sending made
    /// of it. What the row came to is handed back beside that, for the screen the reader asked on to say
    /// what the strip does not: nil where there is nothing to say of the row, and from a host the app has
    /// let go of.
    ///
    /// `neverWaited` is for the row of a reservation the reader asked for a moment ago, sent again on the
    /// screen that asked because it would stop others from recording and the reader said to make it all
    /// the same. It is still that reservation, said by its result alone as `reserve` is: on the strip it
    /// would read as one that had been waiting.
    @discardableResult
    func resend(_ waiting: PendingReservation, neverWaited: Bool = false) async -> Reserved? {
        guard let driver else { return nil }
        let (round, list, came) = await driver.resend(waiting)
        if let list { keep(list) }
        await tell(neverWaited ? nil : round)
        return came
    }

    private func keep(_ list: [Reservation]) {
        reservations = list
        reservationsRead = Date()
    }

    /// Since when what is shown of the television is old, for the screens to say so: the time its list was
    /// read, while that list has rows and the television cannot be asked for them now -- not connected, to be
    /// registered again, or its link gone. Nil while it can be asked, since the list is then read as a screen
    /// appears; and nil with no rows, when nothing old is shown. Nil too while a connect to a television that
    /// answered last time is under way: the app connects again whenever it comes back, the list is read as
    /// that connect gets there, and it is old only once the connect has failed.
    var staleSince: Date? {
        guard !reservations.isEmpty, driver?.canBeAsked != true else { return nil }
        if let session = link?.session, session.connecting, session.connected { return nil }
        return reservationsRead
    }

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
    /// A bulk job holds the recorder's client, not the television's.
    var holdsOffConnect: Bool { false }
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

    var macReadAt: String? { nil }
    func macWasReadAt(_ host: String) {}
    func forgetMac() {}
    func anotherDeviceDescribedItself(wasConnected: Bool) {}
    func cacheMadeOver() async {}
    func cacheCouldNotBeMadeOver() {}

    /// What waits for the television is sent by its driver, and what that came to is kept (`tell`). With no
    /// sending -- nothing was to go, or the television could not be asked -- nothing changed, and nothing
    /// is read again. Nothing is sent from a host the app has let go of. The list is not read here: a
    /// connect reads it next (`reached`), and a pull-down reads it itself. Inside a connect, so nothing
    /// here may await `AppModel.start()`.
    func sendWhatWaits() async {
        guard let outcome = await driver?.sendWhatWaits() else { return }
        await tell(outcome)
    }

    /// Keeps what a sending to the television came to, for a sending of what waits and for a row sent again
    /// alike. The queue on screen is read again, always: with no round too, since a row sent again may have
    /// had its reason taken off before the television could be asked. What the round has to say goes on the
    /// strip, naming the television, after what is there unread: the next sending is not to take what this
    /// one said, which can end with what making a reservation did to another. A sentence the unread report
    /// holds already is not said a second time: a row passed over at every sending would add its own at
    /// each connect and each pull-down. A round with nothing to say, and no round, leave the report where
    /// it was, as the recorder's sending does. Reached from inside a connect, so nothing here may await
    /// `AppModel.start()`.
    ///
    /// A warning the runs with no screen left of reservations not yet at the television goes here once none
    /// of them waits to go any more (`AppModel.forgetTheWarningOnceSent`), whichever sending took them.
    private func tell(_ round: PendingQueue.Outcome?) async {
        await model?.loadPending()
        await model?.forgetTheWarningOnceSent()
        guard let said = round?.said(withATelevisionSaved: true) else { return }
        let unread = report.map(Self.sentences) ?? []
        let new = Self.sentences(said).filter { !unread.contains($0) }
        if !new.isEmpty { report = ([report].compactMap { $0 } + new).joined(separator: "。") }
    }

    /// The sentences of what a sending said, which joins them with a full stop. Cut at each full stop that
    /// is not inside a title's brackets: a programme's title can have one of its own.
    private static func sentences(_ said: String) -> [String] {
        var sentences = [""], depth = 0
        for character in said {
            if character == "「" { depth += 1 } else if character == "」" { depth = max(depth - 1, 0) }
            if character == "。", depth == 0 {
                sentences.append("")
            } else {
                sentences[sentences.count - 1].append(character)
            }
        }
        return sentences.filter { !$0.isEmpty }
    }

    /// A connect reached the television: its reservations are read, as the recorder's are when a connect
    /// reaches it. Inside the connect, so nothing here may await `AppModel.start()`.
    func reached() async {
        await loadReservations()
    }

    func anotherAnsweredTheCheck() {}

    func sayNotConnected() {
        problem = TVDriver.notConnected
    }

    /// Not from a host the app has let go of. A request still out on its link can run into the permission
    /// after that, and the app stops a host's wait once, as it lets go of it (`AppModel.dropTVLink`): one set
    /// going later would have nothing left to stop it. A wait that has given up ends as the recorder's does
    /// (`AppModel.waitForPermission`).
    func waitForPermission(at host: String) {
        guard inPlay else { return }
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            let access = await LocalNetwork.waitForAccess(probing: host) {}
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
