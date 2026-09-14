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
    /// The DLNA item id of this recording: the low 32 bits of the XSRS id.
    public var dlnaID: String? {
        guard let value = hexInt(id) else { return nil }
        return "V_\(UInt32(truncatingIfNeeded: value))"
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
