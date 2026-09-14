import Foundation

/// One programme in the recorder's guide.
public struct GuideProgram: Sendable, Equatable, Identifiable {
    public var serviceID: Int
    public var eventID: Int
    public var start: Date
    public var end: Date
    public var title: String
    /// The EPG's short description.
    public var summary: String
    /// The long description, when the broadcaster sends one.
    public var extended: String
    /// ARIB content nibbles, as (level1, level2) pairs.
    public var genres: [(level1: Int, level2: Int)]
    public var copyControl: Int
    /// 0 when unrestricted, otherwise the minimum age.
    public var parentalRating: Int
    /// Sub-channels carry a reference to the programme on their parent service instead of repeating it.
    public var referenceServiceID: Int?
    public var referenceEventID: Int?

    public var id: String { "\(serviceID)-\(eventID)-\(Int(start.timeIntervalSince1970))" }
    public var isReference: Bool { referenceEventID != nil }
    public var durationSec: Int { Int(end.timeIntervalSince(start)) }

    public static func == (lhs: GuideProgram, rhs: GuideProgram) -> Bool {
        lhs.serviceID == rhs.serviceID && lhs.eventID == rhs.eventID && lhs.start == rhs.start
            && lhs.end == rhs.end && lhs.title == rhs.title && lhs.summary == rhs.summary
            && lhs.extended == rhs.extended && lhs.copyControl == rhs.copyControl
            && lhs.parentalRating == rhs.parentalRating && lhs.referenceServiceID == rhs.referenceServiceID
            && lhs.referenceEventID == rhs.referenceEventID
            && lhs.genres.map { [$0.level1, $0.level2] } == rhs.genres.map { [$0.level1, $0.level2] }
    }
}

/// One channel and its programmes, as one `@SRV` record of the guide file.
public struct GuideService: Sendable, Equatable {
    public var serviceID: Int
    public var name: String
    public var programs: [GuideProgram]
}

public enum GuideError: Error, Equatable, Sendable {
    case notAServiceRecord
    case zlib(status: Int32)

    public var localizedDescription: String {
        switch self {
        case .notAServiceRecord: "not an @SRV record"
        case .zlib(let status): "the guide file did not inflate (zlib status \(status))"
        }
    }
}
