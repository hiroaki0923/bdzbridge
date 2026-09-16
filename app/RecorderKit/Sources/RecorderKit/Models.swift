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

    /// The recorder set this up by itself, which is what its own automatic recording does. Observed on a
    /// BDZ-FBT4100: deleting one of these does work, and then the recorder makes it again with a new id the
    /// next time it reads the guide. Telling the reader beats letting them wonder.
    ///
    /// The renumbering takes the whole block of them at once, not one at a time — 19 in one go, the
    /// programmes themselves unchanged — so an id of one of these goes stale on its own, without anything
    /// on screen looking different. Anything that writes has to find the reservation again first.
    public var createdByRecorder: Bool { creator == "1100" }
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
    /// The DLNA item id of this recording: the low 32 bits of the XSRS id, prefixed by the disk it lives on
    /// (`V_` internal, `USBV_` USB), which is how the official client derives it.
    public var dlnaID: String? {
        guard let value = hexInt(id) else { return nil }
        return "\(destination == "USBHDD" ? "USBV" : "V")_\(UInt32(truncatingIfNeeded: value))"
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
}
