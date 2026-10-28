import Foundation

/// What a reservation is made or changed with, in one value whichever device is asked: the recording mode, the
/// repeat and the disk. Each driver reads what its device takes and nothing else -- a television its repeat
/// alone, since it records in its one mode (`TVDriver.recordsIn`) and has no disk to choose. A reservation always
/// names a disk; a change may leave the one it has as it is. So there are two makers and no other way to make one.
public struct ReservationTerms: Sendable, Equatable {
    public let quality: String
    public let repeating: String
    /// The disk to record to; nil only for a change that leaves it as it is.
    public let disk: String?

    private init(quality: String, repeating: String, disk: String?) {
        self.quality = quality
        self.repeating = repeating
        self.disk = disk
    }

    /// For a new reservation, which records to `disk`.
    public static func reserving(quality: String, repeating: String, disk: String) -> ReservationTerms {
        ReservationTerms(quality: quality, repeating: repeating, disk: disk)
    }

    /// For a change of one; `disk` nil leaves its disk as it is.
    public static func changing(quality: String, repeating: String, disk: String?) -> ReservationTerms {
        ReservationTerms(quality: quality, repeating: repeating, disk: disk)
    }
}

/// What a device's driver is asked of the reservations it holds, the same six steps on either device: the list
/// read, the list pulled down, a delete, a change, a reservation, and a waiting row sent again. Each hands back
/// what it came to and the list it read on the way, for the app to keep. A row of another device is refused at
/// each door with nothing read, sent or said. Not here, since the two devices do them differently: the delete of
/// a waiting row, the sending of what waits, and the clash check.
@MainActor
public protocol ReservationDriver: AnyObject {
    /// Whether the device can be asked now, for how old a list on screen is said to be.
    var canBeAsked: Bool { get }
    func reservations() async -> [Reservation]?
    func refreshReservations() async -> [Reservation]?
    func cancel(_ reservation: Reservation) async -> (deleted: Altered?, list: [Reservation]?)
    func update(_ reservation: Reservation,
                _ terms: ReservationTerms) async -> (altered: Altered?, list: [Reservation]?)
    func reserve(_ program: GuideProgramRow,
                 _ terms: ReservationTerms) async -> (reserved: Reserved, list: [Reservation]?)
    func resend(_ waiting: PendingReservation, neverWaited: Bool) async
        -> (round: PendingQueue.Outcome?, list: [Reservation]?, came: Reserved?)
}

extension RecorderDriver: ReservationDriver {
    public func update(_ reservation: Reservation,
                       _ terms: ReservationTerms) async -> (altered: Altered?, list: [Reservation]?) {
        await update(reservation, quality: terms.quality, repeating: terms.repeating, disk: terms.disk)
    }

    /// A reservation's terms always name a disk. Terms made for a change that leaves the disk as it is name none,
    /// and go to the internal disk, as the app's entry does when it is given none.
    public func reserve(_ program: GuideProgramRow,
                        _ terms: ReservationTerms) async -> (reserved: Reserved, list: [Reservation]?) {
        await reserve(program, quality: terms.quality, repeating: terms.repeating,
                      disk: terms.disk ?? RecorderDisk.internalID)
    }
}

extension TVDriver: ReservationDriver {
    public func update(_ reservation: Reservation,
                       _ terms: ReservationTerms) async -> (altered: Altered?, list: [Reservation]?) {
        await update(reservation, repeating: terms.repeating)
    }

    public func reserve(_ program: GuideProgramRow,
                        _ terms: ReservationTerms) async -> (reserved: Reserved, list: [Reservation]?) {
        await reserve(program, repeating: terms.repeating)
    }
}
