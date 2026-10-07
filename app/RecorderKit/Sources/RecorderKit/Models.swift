import Foundation

/// A recording schedule as the recorder reports it, or as a television's row is read into the same terms
/// (`TVScheduleRow.reservation`).
public struct Reservation: Equatable, Sendable, Identifiable {
    /// The device's own name for it, as read: what a change or a delete sends back, so never rewritten. Two
    /// devices number for themselves, so it tells rows apart on one device only (see `listKey`).
    public var id: String
    public var title: String
    public var start: Date
    public var durationSec: Int
    /// `scheduledConditionID`; look it up in `Codes.repeatCodes`.
    public var repeatCode: String
    public var broadcastingType: Int
    public var serviceID: Int
    /// Present when the reservation follows the programme, so the recorder tracks schedule changes.
    public var eventID: Int?
    public var qualityCode: Int
    public var recording: Bool
    public var conflict: Bool
    public var destination: String
    public var sizeMB: Int?
    public var creator: String?
    /// ARIB content nibbles as level1 * 16 + level2.
    public var genreCode: Int?
    /// The device that holds it. Whatever writes looks here first, so that a television's row is not sent to the
    /// recorder, where the recorder's own reservation of that programme would be changed or deleted in its place.
    /// The recorder's way of finding a reservation again refuses it as well (`current`): it finds nothing for a
    /// row of another device.
    public var device: DeviceSlot = .recorder
    /// The television's row this was read from, for a television's: what a delete sends back as it was read, and
    /// what the reservation is found again by (`tvTarget`).
    public var tvRow: TVScheduleRow?

    public var end: Date { start.addingTimeInterval(TimeInterval(durationSec)) }
    public var broadcastingName: String? { Codes.broadcasting(code: broadcastingType) }
    public var qualityName: String? { Codes.quality(code: qualityCode) }
    public var repeatName: String? { Codes.repeatName(code: repeatCode) }

    /// What tells the rows apart in a list that shows the reservations of more than one device. A recorder's is
    /// its id as it stands, as it was while the recorder's were the only ones; any other device's carries the
    /// device in front.
    public var listKey: String { device == .recorder ? id : "\(device.rawValue)|\(id)" }

    /// An app on the network set this up: this one, or the official one.
    public var createdByApp: Bool { creator == "2200" }

    /// The recorder set this up by itself, which is what its own automatic recording does. On a BDZ-FBT4100
    /// deleting one works, and the recorder makes it again with a new id the next time it reads the guide.
    /// It renumbers the whole block of them at once, the programmes unchanged, so an id of one of these goes
    /// stale on its own: anything that writes has to find the reservation again first.
    public var createdByRecorder: Bool { creator == "1100" }
}

public extension Array where Element == Reservation {
    /// The same reservation as the device holds it now, in this list read from it, whatever it has been
    /// renumbered to: by its id while that stands, and otherwise by its channel and its start.
    ///
    /// Anything that writes finds the reservation again with this first (see `Reservation.createdByRecorder`).
    /// The id comes first so that two reservations of one programme are still told apart while their ids hold.
    /// Only among the rows of the device that holds it: another device numbers for itself and may hold the
    /// same programme, so its row would be found here by either, and written to in place of the one meant.
    func current(_ wanted: Reservation) -> Reservation? {
        first { $0.device == wanted.device && $0.id == wanted.id }
            ?? first { $0.device == wanted.device
                       && $0.broadcastingType == wanted.broadcastingType
                       && $0.serviceID == wanted.serviceID
                       && $0.start == wanted.start }
    }
}

/// What the recorder says about its own place on the network.
public struct NetworkSettings: Equatable, Sendable {
    /// The wired MAC. A BDZ-FBT4100 reports this whether it is wired or not, and it matches ARP.
    public var mac: String
    public var wireless: String
    public var address: String
    /// True when the address it is reachable at today is a lease rather than a setting.
    public var usesDhcp: Bool
}

/// A recording on the recorder's hard disk.
public struct RecordedTitle: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var durationSec: Int
    public var broadcastingType: Int
    public var serviceID: Int
    public var qualityCode: Int
    public var protected: Bool
    public var isNew: Bool
    /// The recorder is writing to this one now. It lists a recording from the moment it starts, and refuses
    /// to delete one in progress -- with an HTTP 500 and no error code, which says nothing to anybody.
    public var recording: Bool
    public var destination: String
    public var sizeMB: Int?
    public var genreCode: Int?
    /// Nil when the recording has never been played; the recorder writes `notplayed` there.
    public var lastPlayed: Date?
    /// Where playback stopped, in seconds.
    public var resumeSec: Int?

    public var end: Date { start.addingTimeInterval(TimeInterval(durationSec)) }
    public var broadcastingName: String? { Codes.broadcasting(code: broadcastingType) }
    public var qualityName: String? { Codes.quality(code: qualityCode) }
}

/// One of the disks the recorder records to, as `X_GetMediaInfo` describes it: its own, or whatever disk is in
/// its USB slot. The slot is one id: with one disk registered and connected it was that disk's, and every other id
/// tried was refused. What it names with another disk, or with two connected at once, has not been seen, so the
/// disk behind it is taken to change: unplugged, swapped, or renamed on the recorder's own screen. Codable so
/// that the USB disk last known can be kept with the cache for the next launch (`GuideStore.knownUSBDisk`).
public struct RecorderDisk: Equatable, Sendable, Codable {
    /// The recorder's id for it: `internalID` or `usbID`.
    public var destination: String
    /// The name the recorder gives the disk, which its owner can change on the recorder; empty for its own.
    public var name: String
    /// `<mount>` is 1.
    public var mounted: Bool
    /// `<remain>`, the free space, in the recorder's MB (`bytesPerMB`).
    public var freeMB: Int?
    public var totalMB: Int?
    /// `<registeredTime>` as the recorder writes it, offset and all. Never read as a time, only compared: it is
    /// what tells one registered disk from another. The recorder's own disk has the element, empty; what a USB
    /// disk it has not registered is given has not been seen, and empty is read as not registered.
    public var registered: String

    public init(destination: String, name: String, mounted: Bool, freeMB: Int?, totalMB: Int?, registered: String) {
        self.destination = destination
        self.name = name
        self.mounted = mounted
        self.freeMB = freeMB
        self.totalMB = totalMB
        self.registered = registered
    }

    /// The recorder's own disk. The literal the official app sends, and what a row that names no disk is on.
    public static let internalID = "HDD"
    /// The USB slot. Every other id tried for a USB disk is answered with 803 (docs/upnp/service-sweep.md).
    public static let usbID = "USBHDD"

    /// Bytes to the recorder's MB. A USB disk's total and the internal disk's free space both read right at a
    /// million bytes on a BDZ-FBT4100; the figures have not yet been printed undivided beside each other.
    public static let bytesPerMB = 1_000_000

    /// What could be offered as somewhere to record: there, and of some size. Asked only of a disk already known
    /// to be registered (`RecorderDriver.usbDisk`).
    public var takesRecordings: Bool { mounted && (totalMB ?? 0) > 0 }

    /// The sizes in bytes, the unit the internal disk's come in (`RecorderClient.recordDestinationInfo`). Nil for
    /// a disk of no size, which has not said how full it is, as `RecorderDriver.storage` reads the internal one:
    /// shown as sizes, it would be a full disk.
    public var freeBytes: Int? { sized(freeMB) }
    public var totalBytes: Int? { sized(totalMB) }

    private func sized(_ megabytes: Int?) -> Int? {
        guard (totalMB ?? 0) > 0 else { return nil }
        return megabytes.map { $0 * Self.bytesPerMB }
    }

    /// What tells this disk from another in the same slot, as text a phone can keep: the slot, when it was
    /// registered and its name. A renamed disk counts as another, which errs the safe way: what was read from the
    /// one before is read again. Neither id nor time holds a line break, so the three cannot run into each other.
    public var identity: String { [destination, registered, name].joined(separator: "\n") }

    public func isSameDisk(as other: RecorderDisk?) -> Bool { other?.identity == identity }

    /// What a disk is called on screen: the recorder's own name for it, or, where it gives none, the recorder's
    /// own id. So the internal disk is `HDD`, as the recorder writes it, and a slot whose disk is not known is
    /// `USBHDD`. Never a name of the app's own: the owner may have renamed the disk on the recorder.
    public static func label(_ destination: String, named name: String?) -> String {
        guard let name, !name.isEmpty else { return destination }
        return name
    }

    /// The recorder's own disk as a choice beside a USB disk: its id, and no name, so that it is labelled as the
    /// recorder writes it. Nothing that offers it reads its sizes, and it is always there.
    public static let internalDisk = RecorderDisk(destination: internalID, name: "", mounted: true, freeMB: nil,
                                                  totalMB: nil, registered: "")

    /// What a new reservation can be made to: the internal disk first, the default, then the USB disk known, and
    /// only while that disk takes recordings. Otherwise nothing, which is no choice at all: a home with no USB
    /// disk is offered nothing to choose, and its reservations go to the internal disk as they always have.
    public static func choices(with usb: RecorderDisk?) -> [RecorderDisk] {
        guard let usb, usb.takesRecordings else { return [] }
        return [internalDisk, usb]
    }

    /// What a reservation already on `destination` can be moved between: what a new one is offered, while that
    /// holds its disk or it is on the internal disk. A reservation on a disk not offered -- one gone from the
    /// slot, or there and not mounted -- is the one a reader most wants to move, and the internal disk is always
    /// there: so it is offered that and its own disk, which is the USB disk known when that is in its slot, and
    /// otherwise a disk known by its id alone. Left on its own disk, or put back on it, a change names no disk, so
    /// that a disk not offered is never sent from here. A television's reservation is offered nothing, as `shown`
    /// names no disk of one: what its rows carry for a disk is never read by what sends to the television.
    public static func choices(keeping destination: String, on device: DeviceSlot,
                               with usb: RecorderDisk?) -> [RecorderDisk] {
        guard device == .recorder else { return [] }
        let offered = choices(with: usb)
        if destination == internalID || offered.contains(where: { $0.destination == destination }) { return offered }
        let own = usb.flatMap { $0.destination == destination ? $0 : nil }
            ?? RecorderDisk(destination: destination, name: "", mounted: false, freeMB: nil, totalMB: nil,
                            registered: "")
        return [internalDisk, own]
    }

    /// Whether a disk chosen on a screen may be sent: the internal disk always, any other only while it is
    /// offered. Asked just before sending, since the USB disk can have gone between the choice and the press, and
    /// sending the internal disk in its place would make a reservation the reader did not agree to.
    public static func offers(_ destination: String, with usb: RecorderDisk?) -> Bool {
        destination == internalID || choices(with: usb).contains { $0.destination == destination }
    }

    /// The one rule for naming the disk of a row on screen, or nil to name none: only a recorder's row, and only
    /// off the internal disk, so that a home with no USB disk sees no disk named anywhere. A television's row is
    /// never named: its listed reservations carry no disk, and what waits for it carries the internal disk's id,
    /// neither of which it reads. A row on the slot is named after the disk known there, or by the slot's id
    /// when none is known.
    public static func shown(_ destination: String, on device: DeviceSlot, usb: RecorderDisk?) -> String? {
        guard device == .recorder, destination != internalID else { return nil }
        return label(destination, named: usb?.destination == destination ? usb?.name : nil)
    }

    /// What a screen says when the disk the reader picked is no longer offered as it is sent (`offers`): nothing
    /// has been sent, and what is offered instead is the screen's own choice with that disk taken out -- the
    /// internal disk, and on the programme's sheet the television where it can take the programme. The disk is
    /// named as it is known now: by its name while the slot's disk is known, by the slot's id once it has gone.
    public static func chooseAnother(than destination: String, usb: RecorderDisk?) -> String {
        label(destination, usb: usb) + "はいま使えません。別の録画先を選んでください。"
    }

    /// What the reservation's sheet says when a move to `destination` is no longer offered as it is sent and the
    /// sheet has nothing else to offer -- a reservation on the internal disk, with the USB disk gone -- so that
    /// it does not ask for a choice it cannot show: the disk cannot be had, and the reservation stays on its own
    /// disk, `keeping`, named as the sheet names it.
    public static func stays(on keeping: String, notMovedTo destination: String, usb: RecorderDisk?) -> String {
        label(destination, usb: usb) + "はいま使えません。録画先は" + label(keeping, usb: usb) + "のままです。"
    }

    /// What to say when the recorder turns down a request that names `destination` -- a reservation, or a change
    /// that moves one -- so that one sent to the USB disk and turned down says which disk and what to do, rather
    /// than a code alone; the code and the action stay, as in every refusal, for looking it up. It says the
    /// reservation was not taken there, not that the disk was refused: the code alone does not say which. For
    /// the internal disk, for anything but a refusal, and for a refusal that names a cause of its own
    /// (`refusalTheDiskCanBeBehind`), what the error says, as it always has.
    public static func turnedDown(_ error: any DeviceError, sentTo destination: String,
                                  usb: RecorderDisk?) -> String {
        guard let disk = shown(destination, on: .recorder, usb: usb),
              let (code, action) = refusalTheDiskCanBeBehind(error) else { return error.explanation }
        return "レコーダーが\(disk)への予約を受け付けませんでした。別の録画先を選んでください (\(code): \(action))"
    }

    /// The reason a row waiting for `destination` carries when the recorder turns it down
    /// (`QueueTarget.sentByCreating`), by the same rule as `turnedDown`. A row that waits keeps the disk it was made
    /// to, and has no way to another, so it is told to be deleted and reserved again elsewhere. It does not name the
    /// disk: what sends it does not know the disk's name, and the row says its disk on the line above its reason.
    public static func waitingRowTurnedDown(_ error: any DeviceError, sentTo destination: String) -> String {
        guard destination != internalID, let (code, action) = refusalTheDiskCanBeBehind(error) else {
            return error.explanation
        }
        return "レコーダーがこの録画先への予約を受け付けませんでした。この予約を消して、別の録画先で予約し直してください"
            + " (\(code): \(action))"
    }

    /// The code and the action of a recorder turning a request down for a reason the disk could be behind:
    /// any code it refuses with (`DeviceFailure.refused`) but those that name a cause of their own, which
    /// another disk would not change (docs/xsrs-api.md): 831, a channel the recorder cannot receive, for a
    /// reservation that follows a programme; 401, an action the recorder does not have; 501 and 701, no such
    /// item. 804, an id that is no longer the
    /// reservation's -- the recorder renumbers its automatic ones -- is read as the reservation gone rather than
    /// as a refusal (`DeviceFailure.unknownItem`), and so is never the disk's either. Nil for anything else.
    private static func refusalTheDiskCanBeBehind(_ error: any DeviceError) -> (code: String, action: String)? {
        guard case .soap(let action, _, let code?, _) = error as? RecorderError, case .refused = error.failure,
              !["831", "401", "501", "701"].contains(code) else { return nil }
        return (code, action)
    }

    /// One of the recorder's disks named as the screens name it: the slot by the name of the disk known there.
    private static func label(_ destination: String, usb: RecorderDisk?) -> String {
        label(destination, named: usb?.destination == destination ? usb?.name : nil)
    }

    /// What the low-space notification says of a disk with `freeGB` left. Without a disk to name it is the
    /// sentence a recorder with its own disk alone has always had; with two disks it says which, by its label.
    /// The number goes in by itself, so that a `%` in a name the owner gave the disk is not read as a format.
    public static func lowSpaceBody(freeGB: Double, naming disk: String?) -> String {
        let left = String(format: "%.0f", freeGB)
        let advice = "古い録画を整理するか、録画モードを見直してください。"
        guard let disk else { return "残り \(left) GB です。" + advice }
        return "\(disk)の残りが \(left) GB です。" + advice
    }
}

/// What `description.xml` says about a recorder found on the LAN.
public struct RecorderDescription: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var friendlyName: String
    public var product: String
    public var model: String
    public var udn: String
    /// False when `EPG_CAP` is absent or `00`; such a recorder serves no guide files.
    public var epgCapable: Bool
    public var location: String
    /// How it was found: `ssdp`, `scan` or `manual`.
    public var via: String

    /// Whether this is the recorder whose wired MAC is `mac`, written in any shape `WakeOnLan.normalise`
    /// takes. A Sony recorder's UDN ends with that MAC (`uuid:XXXXXXXX-XXXX-XXXX-XXXX-<MAC>`, the same as
    /// ARP on a BDZ-FBT4100), and it is the address `X_GetPrivateIp` reports as `macAddress`, which the app
    /// keeps for waking it. So a recorder given another address can be told from any other by what was saved.
    public func hasMAC(_ mac: String) -> Bool {
        guard let wanted = WakeOnLan.normalise(mac),
              let tail = udn.split(separator: "-").last,
              let own = WakeOnLan.normalise(String(tail)) else { return false }
        return own == wanted
    }

    /// Who this is, measured against the device whose UDN is `known`. A device that gives no UDN cannot be
    /// told from any other and is taken for the one known: read the other way, everything kept of the
    /// recorder would be forgotten each time it answered. A UDN is a UUID, so its case does not matter.
    public func recognised(as known: String?) -> Recognition {
        guard let known, !known.isEmpty else { return .first }
        return udn.isEmpty || udn.caseInsensitiveCompare(known) == .orderedSame ? .same : .another
    }
}

/// Who a device that has just described itself is, measured against the one known before.
///
/// The address is only where to knock. What the app keeps of a recorder is that device's wherever it
/// answers and nobody else's: each recorder numbers its recordings, its reservations and its keyword
/// conditions for itself, so a row kept from one names something else on the next. `RecorderDescription.udn`
/// is what is compared: by `SessionState` for what is in memory, by `GuideStore` for what is on the phone.
public enum Recognition: Sendable, Equatable {
    /// Nobody was known before.
    case first
    /// The device known before, at this address or another. What is kept of it stands.
    case same
    /// Another device than the one known before. What is kept is not this one's.
    case another
}

/// One of the recorder's own おまかせ・まる録 conditions: what the box records by itself, by keyword.
///
/// The channel narrowing the box can hold is neither reported nor accepted over the LAN, so it is not here. A
/// condition read this way and written back would lose it, which is why the client creates and deletes and
/// never updates (docs/xsrs-api.md).
public struct RecorderRule: Equatable, Sendable, Identifiable {
    public var id: String
    /// Composed by the recorder from the genre and the keywords; whatever is sent is replaced.
    public var name: String
    public var keywords: [String]
    public var excluded: [String]
    /// `OR`: any keyword matches; `AND`: all of them.
    public var logic: String
    /// The ARIB level-1 genre; on the wire as hex, `0x50` (type="2") or `0x5*` (type="3").
    public var genreLevel1: Int?
    /// The sub-genre; nil means the whole level-1 genre, the recorder's `0x5*` form.
    public var genreLevel2: Int?
    public var timeScope: String
    public var broadcastingScope: String
    /// 録画モード(地上/BS/CS); the recorder only sends it when asked with Filter "*".
    public var qualityCode: Int?
    /// 録画モード(BS4K/CS4K); DR where the condition was made without one, and not reported for a scope
    /// without the 4K waves.
    public var qualityCode4K: Int?
    public var destination: String

    public var qualityName: String? { qualityCode.flatMap(Codes.quality(code:)) }
    public var qualityName4K: String? { qualityCode4K.flatMap(Codes.quality(code:)) }
    public var logicLabel: String { Codes.ruleLogicLabel[logic] ?? logic }
    public var timeScopeLabel: String { Codes.timeScopeLabel[timeScope] ?? timeScope }
    public var broadcastingScopeLabel: String { Codes.broadcastingScopeLabel[broadcastingScope] ?? broadcastingScope }
    /// The genre as a reader sees it: the level-1 name, or "バラエティ / クイズ" when a sub-genre is set.
    public var genreLabel: String? {
        guard let level1 = genreLevel1, let name = Codes.genreLabel[level1] else { return nil }
        guard let sub = Codes.subGenre(level1: level1, level2: genreLevel2) else { return name }
        return "\(name) / \(sub)"
    }
}
