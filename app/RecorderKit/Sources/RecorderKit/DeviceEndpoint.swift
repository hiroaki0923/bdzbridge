import Foundation

/// Something on the LAN that requests are sent to: the recorder, and whatever else the app comes to talk to.
///
/// The rules the screens and the overnight run share -- waiting for a device to wake, sending what waits in
/// the queue, fetching the guide -- are written against these protocols and not against `RecorderClient`, so
/// that a device of another kind can be put behind them. Each protocol holds only what one of those rules
/// asks for; what only the recorder's own screens use stays on `RecorderClient`.
public protocol DeviceEndpoint: Actor {
    /// The short ask that shows the device is listening, and nothing more: who it is, not everything about
    /// it. Throws when it does not answer, or answers as something else.
    func probe(timeout: TimeInterval) async throws
}

/// Which of a household's devices something is for. A name of the app's own, written on what waits to be
/// sent, and never anything the hardware calls itself: the recorder that takes another's place is still the
/// recorder. A string underneath, so that one written by a version that knows more devices than this one is
/// read as what it is, and left alone.
public struct DeviceSlot: RawRepresentable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let recorder = DeviceSlot(rawValue: "recorder")
    /// The household's television. The spelling will be written on what waits for it, as the recorder's is,
    /// so it is not to change.
    public static let tv = DeviceSlot(rawValue: "tv")
}

/// A device the guide can be fetched from, a broadcasting type at a time.
public protocol GuideSource: DeviceEndpoint {
    /// The guide for one broadcasting type. Nil when the device has no such channels.
    func guide(_ broadcasting: String) async throws -> [GuideService]?
    /// The station logos for one broadcasting type. Nil when the device has no such channels.
    func logos(_ broadcasting: String) async throws -> [StationLogo]?
}

/// What one waiting reservation came to, sent to a device in the device's own way. The queue reads only this:
/// what to do with the row, and whether to go on.
public enum RowSent: Sendable, Equatable {
    /// The device holds it now, by its own account. The row leaves the queue. `saying` is what making it did
    /// beyond the row itself, as a sentence of the device's own for the reader -- a reservation it left
    /// marked as sharing its time, the new one marked so itself -- and nil for a device that has nothing to
    /// add: the queue says it after the sentence for what was sent, and reads nothing in it.
    case made(saying: String?)
    /// The device held it already. The row leaves the queue, and is not said to have been sent.
    case alreadyThere
    /// Not to go as it stands, and asking again would get the same: the reason is written on the row, which
    /// waits for the reader.
    case refused(reason: String)
    /// Nothing is known against the row: it stays as it was, with no reason written on it, to go at the next
    /// chance, and the queue goes on to the next.
    case passedOver
    /// Nothing more is sent to the device in this round, and why. The row stays as it was, with no reason
    /// written on it. `passedOver` is whether it is told as a row passed over is, or left unsaid as the rows
    /// after it are: the device says which, so that the queue reads no stop to settle a row.
    case stopped(SendingStop, passedOver: Bool)
}

/// Why a round ended before its rows did. The rows not yet sent stay as they were, with nothing written on
/// them. The recorder's way of sending comes to the first alone.
public enum SendingStop: Sendable, Equatable {
    /// Nothing answered. `afterSending` when it was the request that makes the reservation that met it: that
    /// row may have been made all the same, and is not sent again in this round. A device that reads its
    /// list after a create says the same of silence at that read, when the create was answered as taken:
    /// by that answer the row was made, and it has not been seen.
    case silent(afterSending: Bool)
    /// The device answers and wants the app registered with it again.
    case needsPairing
    /// The device has nowhere to record to. The sentence is the device's own.
    case cannotRecord(reason: String)
    /// Rows one after another were answered with nothing that says anything about them: what is wrong is not
    /// theirs.
    case saysNothing
}

/// What a round stands on once the device has been read for it.
public enum RoundOpened<Round: Sendable>: Sendable {
    /// `alreadyThere`: the ids of the waiting rows the device holds already, those with a reason on them
    /// among them.
    case open(Round, alreadyThere: Set<String>)
    /// The device could not be read for the round: nothing is sent, and every row that is not over stays as
    /// it was.
    case stopped(SendingStop)
}

/// The round of a device that reads nothing before it is sent a reservation.
public struct NoRound: Sendable {
    public init() {}
}

/// A device that what waits in the queue is sent to, a row at a time, in the device's own way. What
/// `PendingQueue` asks of a device, and all it asks.
public protocol QueueTarget: DeviceEndpoint {
    /// What the device was read for before the first row, and what is carried from one row to the next.
    associatedtype Round: Sendable
    /// The device whose waiting rows this is sent (`PendingReservation.target`). Said here, by the kind of
    /// client, and nowhere else: the queue takes its rows by it, so a client cannot be handed the rows that
    /// wait for another device.
    static var slot: DeviceSlot { get }
    /// Reads what the device has to be read for before any of `waiting` is sent. Asked once in a round, and
    /// only when the round has a row to send; `waiting` is every row of the round whose programme is not over:
    /// all that wait for the device, or the one row the reader asked to have sent.
    func openRound(for waiting: [PendingReservation]) async -> RoundOpened<Round>
    /// The same, with what the phone keeps to hand, which the queue sends from: what the queue asks
    /// (`PendingQueue.flush`). For a device whose round goes by something kept there as well; any other is
    /// opened as above, and that is what it is given.
    func openRound(for waiting: [PendingReservation], keeping store: GuideStore) async -> RoundOpened<Round>
    /// Sends one waiting row. `consented`: the reader has said to make it though it stops another reservation
    /// from recording. A request that may have been taken is not sent a second time. The round comes back as it
    /// stands after this row.
    func send(_ waiting: PendingReservation, consented: Bool,
              in round: Round) async -> (sent: RowSent, round: Round)
}

public extension QueueTarget {
    func openRound(for waiting: [PendingReservation], keeping store: GuideStore) async -> RoundOpened<Round> {
        await openRound(for: waiting)
    }
}

extension QueueTarget {
    /// What one waiting row came to when `create` was sent for it, the one request that makes a reservation, and
    /// what its failure says of the row (`DeviceFailure`). Silence ends the round: the device has gone, and the
    /// row may have been made. A refusal with a reason of the device's own (`DeviceFailure.turnsTheRequestDown`)
    /// is the row's, and is written on it -- for a row off the internal disk turned down for what its disk could
    /// be behind, with what to do about a row that cannot change its disk (`RecorderDisk.waitingRowTurnedDown`).
    /// A failure that says nothing about the reservation -- a 503, an answer with no code -- passes it over; an
    /// answer that the device holds it already (`DeviceFailure.alreadyThere`) is among those, as it always was:
    /// no recorder's answer says it. A reservation made is said with nothing beside it: all such a request says of
    /// one is that it was taken.
    func sentByCreating(_ waiting: PendingReservation,
                        _ create: (ReservationRequest) async throws -> Void) async -> RowSent {
        do {
            try await create(waiting.request)
            return .made(saying: nil)
        } catch let error as any DeviceError where error.failure == .silent {
            return .stopped(.silent(afterSending: true), passedOver: false)
        } catch let error as any DeviceError where error.failure.turnsTheRequestDown {
            return .refused(reason: RecorderDisk.waitingRowTurnedDown(error, sentTo: waiting.request.destination))
        } catch {
            // Nothing written on it: a reason on the row is what holds a reservation back, and nothing here
            // says this one is wrong.
            return .passedOver
        }
    }
}

/// A device that makes a reservation in one request and reads nothing first. Making one says nothing back worth
/// keeping: what the device made is read from its list afterwards. Sent a waiting row, it is sent that request
/// (below), so a device with `create` alone is one the queue can send to. The recorder sends the same request
/// (`sentByCreating`) in a round of its own, which waits for its USB slot (`RecorderClient`'s round).
public protocol ReservationTarget: QueueTarget where Round == NoRound {
    func create(_ request: ReservationRequest) async throws
}

public extension ReservationTarget {
    /// What waits for the recorder: a device with a create alone is sent the recorder's rows. Given here and
    /// not to `QueueTarget`, so that a device sent in a way of its own has to say whose rows it takes.
    static var slot: DeviceSlot { .recorder }

    /// Nothing is asked and nothing is found: a device with a create alone is read for nothing before it.
    func openRound(for waiting: [PendingReservation]) async -> RoundOpened<NoRound> {
        .open(NoRound(), alreadyThere: [])
    }

    /// The create (`sentByCreating`). `consented` is not read: the device is asked nothing before the create that
    /// the reader could have answered.
    func send(_ waiting: PendingReservation, consented: Bool,
              in round: NoRound) async -> (sent: RowSent, round: NoRound) {
        (await sentByCreating(waiting) { try await create($0) }, round)
    }
}

extension RecorderClient: DeviceEndpoint {
    /// `description.xml`, which is one request and is bounded by `timeout` (see `describe`).
    public func probe(timeout: TimeInterval) async throws {
        try await describe(timeout: timeout)
    }
}

extension RecorderClient: GuideSource {}

/// What the recorder's round carries from one row to the next: whether a USB disk is kept with the cache, and what
/// the slot came to once a row that names it was reached.
public struct RecorderRound: Sendable {
    let knowsADisk: Bool
    /// Nil until the slot is settled in the round, which it is once at most.
    var slot: SlotSettled?
}

extension RecorderClient: QueueTarget {
    /// What waits for the recorder is what a recorder's client is sent.
    public static let slot = DeviceSlot.recorder

    /// With nothing the phone keeps to hand, no USB disk is known, and every row is sent as it waits.
    public func openRound(for waiting: [PendingReservation]) async -> RoundOpened<RecorderRound> {
        .open(RecorderRound(knowsADisk: false), alreadyThere: [])
    }

    /// Nothing is asked of the recorder, and nothing is looked for there. What is read is the USB disk kept with
    /// the cache (`GuideStore.knownUSBDisk`), by the screens and by the runs with no screen alike, for the rows
    /// that name the slot (`send`). A cache that cannot be read knows none.
    public func openRound(for waiting: [PendingReservation],
                          keeping store: GuideStore) async -> RoundOpened<RecorderRound> {
        let known = (try? await store.knownUSBDisk()) != nil
        return .open(RecorderRound(knowsADisk: known), alreadyThere: [])
    }

    /// The create (`sentByCreating`), as for a device with a create alone, but for the USB slot. Nothing that names
    /// it is sent on the strength of a disk it has not answered since the recorder woke, which every round may
    /// follow -- the attach sends what waits before it reads the slot, and the night run and the Shortcuts action
    /// right after the wake. So before the first row that names the slot while a disk is known, the slot is
    /// settled, once in the round (`RecorderDriver.settle`), and read as the screens read it: a disk answered that
    /// takes recordings sends that row and the slot's rows after it. None throughout, or a disk that takes no
    /// recordings, gives each of them a reason of its own (`RecorderDisk.waitingRowNotAnswered`) with nothing sent:
    /// passed over in silence, a row could wait until its programme was over, a run with no screen never letting the
    /// disk known go. The reason holds it for the reader, and is told as a refusal is. Silence ends the round there,
    /// before the row was sent, with nothing written, as silence anywhere in a round does; a round given up on
    /// passes the row over. A row on the internal disk is sent as ever, the settling the most it waits. With no disk
    /// known the slot is not read, and the recorder's answer decides. The slot is read here whatever the screens
    /// know of it, the runs with no screen knowing nothing: one read more, where the disk answers at once.
    /// `consented` is not read, as for any device with a create alone.
    public func send(_ waiting: PendingReservation, consented: Bool,
                     in round: RecorderRound) async -> (sent: RowSent, round: RecorderRound) {
        var round = round
        if waiting.request.destination == RecorderDisk.usbID, round.knowsADisk {
            if round.slot == nil { round.slot = await RecorderDriver.settle(self, by: slotSettling) }
            switch round.slot {
            case .silent?: return (.stopped(.silent(afterSending: false), passedOver: false), round)
            case .cancelled?: return (.passedOver, round)
            case .noDisk?: return (.refused(reason: RecorderDisk.waitingRowNotAnswered), round)
            case .answered(let disk)? where !disk.takesRecordings:
                return (.refused(reason: RecorderDisk.waitingRowNotAnswered), round)
            case .answered?, nil: break
            }
        }
        return (await sentByCreating(waiting) { try await self.create($0) }, round)
    }
}
