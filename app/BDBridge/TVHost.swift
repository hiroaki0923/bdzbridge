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
        guard let list = await driver?.reservations() else { return }
        keep(list)
    }

    /// What pulling the reservations down asks of the television: the list read again, or a connect when it
    /// cannot be asked, whose own read is kept from `reached`.
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

    private func keep(_ list: [Reservation]) {
        reservations = list
        reservationsRead = Date()
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
    func sendWhatWaits() async {}

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
    /// going later would have nothing left to stop it.
    func waitForPermission(at host: String) {
        guard inPlay else { return }
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            let allowed = await LocalNetwork.waitForAccess(probing: host) {}
            guard let self, !Task.isCancelled else { return }
            // cleared before the link connects, since connecting stops whatever wait is still set
            self.accessWatch = nil
            await self.link?.permissionArrived(allowed, at: host)
        }
    }

    func stopWaitingForPermission() {
        accessWatch?.cancel()
        accessWatch = nil
    }
}
