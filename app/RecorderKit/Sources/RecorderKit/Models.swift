import Foundation

/// A recording schedule as the recorder reports it.
public struct Reservation: Equatable, Sendable, Identifiable {
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

    public var end: Date { start.addingTimeInterval(TimeInterval(durationSec)) }
    public var broadcastingName: String? { Codes.broadcasting(code: broadcastingType) }
    public var qualityName: String? { Codes.quality(code: qualityCode) }
    public var repeatName: String? { Codes.repeatName(code: repeatCode) }

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
    func current(_ wanted: Reservation) -> Reservation? {
        first { $0.id == wanted.id }
            ?? first { $0.broadcastingType == wanted.broadcastingType
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
