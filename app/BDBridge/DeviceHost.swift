import Foundation
import RecorderKit

/// What the screens and the model's entries ask of either device's host (`RecorderHost`, `TVHost`): its line,
/// whether it works, the reservations it holds and how old they are, and what its sendings came to. And the six
/// entries of a device's reservations -- the list read, the list pulled down, a delete, a change, a reservation, a
/// waiting row sent again -- written once below, over the driver's steps (`ReservationDriver`). Each opens the
/// cache before it asks, whichever device it is for (`AppModel.start`). Where the two hosts still differ in them
/// is a hook each answers for itself: which list a read is kept on (`keeping`), and what follows a reservation
/// and a sending (`afterAReservation`, `tell`).
///
/// Not a `LinkHost`: a screen reads a host's line here, and is given no way to set it.
@MainActor
protocol DeviceHost: AnyObject {
    static var slot: DeviceSlot { get }
    /// What went wrong with the device.
    var problem: String? { get }
    /// Busy with the device, for the buttons that write to it.
    var isBusy: Bool { get }
    var reservations: [Reservation] { get }
    var reservationsByProgram: [String: Reservation] { get }
    /// When the list was last read and kept, or nil when it has not been.
    var reservationsRead: Date? { get }
    /// What the sendings to the device came to, for the strip.
    var report: String? { get set }
    /// The device's driver, as far as its reservations go; nil when there is none to ask -- a television's once
    /// its host or its link has been let go of. The recorder's link always holds its driver, which answers for a
    /// recorder let go of at its own door.
    var reservationDriver: (any ReservationDriver)? { get }
    /// The session of the device's link, for whether a connect to a device that answered last time is under way.
    var deviceSession: SessionState? { get }
    /// The model, whose cache is opened before an entry asks (`AppModel.start`); nil once it has gone.
    var model: AppModel? { get }
    /// Keeps a list the driver handed back for the device answered for as this is read: an entry reads it as it
    /// begins, and keeps what comes back with it.
    var keeping: @MainActor ([Reservation]) -> Void { get }
    /// What follows a reservation, whatever it came to.
    func afterAReservation(_ reserved: Reserved) async
    /// What follows a waiting row sent again: what its round came to, nil for none or for none to say.
    func tell(_ round: PendingQueue.Outcome?) async
}

extension DeviceHost {
    /// Since when what is shown of the device is old, for the screens to say so: the time its list was read,
    /// while that list has rows and the device cannot be asked for them now -- not connected, given up on after
    /// silence, to be registered again, or its link gone (`ReservationDriver.canBeAsked`). Nil while it can be
    /// asked, since the list is then read as a screen appears; and nil with no rows, when nothing old is shown.
    /// Nil too while a connect to a device that answered last time is under way: the list is read as that
    /// connect gets there, and it is old only once the connect has failed.
    var staleSince: Date? {
        guard !reservations.isEmpty, reservationDriver?.canBeAsked != true else { return nil }
        if let session = deviceSession, session.connecting, session.connected { return nil }
        return reservationsRead
    }

    /// The driver's read of the list, after the cache is opened, handed back, nil when none was: for whoever has
    /// to know what the device holds at this moment, and not what it held when it was last read. Kept as the
    /// entry began (`keeping`): a list read for a device let go of meanwhile is kept where no screen reads it. One
    /// that could not be read leaves the last list, and its time, as they were.
    @discardableResult
    func readReservations() async -> [Reservation]? {
        let keep = keeping
        await model?.start()
        return await read(keepingOn: keep)
    }

    /// Reads the list, as a screen that shows it does when it appears.
    func loadReservations() async {
        _ = await readReservations()
    }

    /// The same read with nothing before it, for what a connect reaches, which may not await `AppModel.start()`
    /// and has tried to open the cache already (`cacheForAttempt`), and for a delete that reads the list in the
    /// queue's turn, whose row is one of the cache already open.
    @discardableResult
    func readReservationsNow() async -> [Reservation]? {
        await read(keepingOn: keeping)
    }

    fileprivate func read(keepingOn keep: @MainActor ([Reservation]) -> Void) async -> [Reservation]? {
        guard let list = await reservationDriver?.reservations() else { return nil }
        keep(list)
        return list
    }

    /// What pulling the reservations down asks of the device: what waits sent and then the list read, or a
    /// connect when it cannot be asked, which does both once the device has answered -- the driver's to decide.
    /// The list it hands back is kept as the entry began.
    func refreshReservations() async {
        let keep = keeping
        await model?.start()
        guard let list = await reservationDriver?.refreshReservations() else { return }
        keep(list)
    }

    /// Takes a reservation off the device. What it came to, for whoever asked to say: the result is what says
    /// it. The list read on the way is kept either way, since a delete that was refused has still seen what the
    /// device holds now. Nil for a row that is not the device's, which the driver refuses with nothing said.
    /// With no driver nothing is sent, and the answer is that the app is not connected.
    func cancel(_ reservation: Reservation) async -> Altered? {
        let keep = keeping
        await model?.start()
        guard let driver = reservationDriver else { return .notDone(Self.slot.notConnected) }
        let came = await driver.cancel(reservation)
        if let list = came.list { keep(list) }
        return came.deleted
    }

    /// Changes a reservation on the device, by what its driver reads of `terms`. What it came to, as for a
    /// delete; the list read on the way is kept whatever it came to.
    func change(_ reservation: Reservation, _ terms: ReservationTerms) async -> Altered? {
        let keep = keeping
        await model?.start()
        guard let driver = reservationDriver else { return .notDone(Self.slot.notConnected) }
        let came = await driver.update(reservation, terms)
        if let list = came.list { keep(list) }
        return came.altered
    }

    /// Reserves a programme on the device. What it came to, for whoever asked to say: the result is what says
    /// it, and nothing of the reservation itself goes on the strip, where it would read as one that had been
    /// waiting. The list a reservation made was read back with is kept, and what follows a reservation is done
    /// (`afterAReservation`). With no driver nothing is kept or sent.
    func reserve(_ program: GuideProgramRow, _ terms: ReservationTerms) async -> Reserved {
        let keep = keeping
        await model?.start()
        guard let driver = reservationDriver else { return .notDone(Self.slot.notConnected) }
        let came = await driver.reserve(program, terms)
        if let list = came.list { keep(list) }
        await afterAReservation(came.reserved)
        return came.reserved
    }

    /// Sends a waiting row again, as the reader asked on that row. The list read after it is kept, and what the
    /// round came to is told as any sending's is (`tell`) -- with no round as well: the row had been waiting, and
    /// the strip may be saying what an earlier sending made of it. What the row came to is handed back beside
    /// that, for the screen the reader asked on to say what the strip does not: nil where there is nothing to say
    /// of the row, and with no driver.
    ///
    /// `neverWaited` is for the row of a reservation the reader asked for a moment ago, sent again on the screen
    /// that asked because it would stop others from recording and the reader said to make it all the same. It is
    /// still that reservation, said by its result alone as `reserve` is: on the strip it would read as one that
    /// had been waiting.
    @discardableResult
    func resend(_ waiting: PendingReservation, neverWaited: Bool = false) async -> Reserved? {
        let keep = keeping
        await model?.start()
        guard let driver = reservationDriver else { return nil }
        let sent = await driver.resend(waiting, neverWaited: neverWaited)
        if let list = sent.list { keep(list) }
        await tell(neverWaited ? nil : sent.round)
        return sent.came
    }
}

extension AppModel {
    /// The host of the device in `device`'s slot: the television's while one is in play, the recorder's always.
    func deviceHost(for device: DeviceSlot) -> (any DeviceHost)? {
        device == .tv ? tvHost : recorderHost
    }
}
