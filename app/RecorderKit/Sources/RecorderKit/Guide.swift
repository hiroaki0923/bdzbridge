import Foundation

/// ARIB content nibbles. `code` is the same number the recorder puts in `genreID` on reservations.
public struct Genre: Sendable, Equatable, Hashable {
    public var level1: Int
    public var level2: Int

    public init(level1: Int, level2: Int) {
        self.level1 = level1
        self.level2 = level2
    }

    public init(code: Int) {
        self.init(level1: code / 16, level2: code % 16)
    }

    public var code: Int { level1 * 16 + level2 }
    public var label: String? { Codes.genreLabel[level1] }
}

/// One programme in the recorder's guide.
public struct GuideProgram: Sendable, Hashable, Identifiable {
    public var serviceID: Int
    public var eventID: Int
    public var start: Date
    public var end: Date
    public var title: String
    /// The EPG's short description.
    public var summary: String
    /// The long description, when the broadcaster sends one.
    public var extended: String
    public var genres: [Genre]
    public var copyControl: Int
    /// 0 when unrestricted, otherwise the minimum age.
    public var parentalRating: Int
    /// Sub-channels carry a reference to the programme on their parent service instead of repeating it.
    public var referenceServiceID: Int?
    public var referenceEventID: Int?

    /// Normally these come out of `Epg.decode`. The initialiser is public so that a port -- or a demo, or a
    /// test -- can build a guide without a recorder and a binary EPG file to decode.
    public init(serviceID: Int, eventID: Int, start: Date, end: Date, title: String, summary: String = "",
                extended: String = "", genres: [Genre] = [], copyControl: Int = 0, parentalRating: Int = 0,
                referenceServiceID: Int? = nil, referenceEventID: Int? = nil) {
        self.serviceID = serviceID
        self.eventID = eventID
        self.start = start
        self.end = end
        self.title = title
        self.summary = summary
        self.extended = extended
        self.genres = genres
        self.copyControl = copyControl
        self.parentalRating = parentalRating
        self.referenceServiceID = referenceServiceID
        self.referenceEventID = referenceEventID
    }

    public var id: String { "\(serviceID)-\(eventID)-\(Int(start.timeIntervalSince1970))" }
    public var isReference: Bool { referenceEventID != nil }
    public var durationSec: Int { Int(end.timeIntervalSince(start)) }
}

/// One channel and its programmes, as one `@SRV` record of the guide file.
public struct GuideService: Sendable, Equatable {
    public var serviceID: Int
    public var name: String
    public var programs: [GuideProgram]

    public init(serviceID: Int, name: String, programs: [GuideProgram]) {
        self.serviceID = serviceID
        self.name = name
        self.programs = programs
    }
}

public enum GuideError: Error, Equatable, Sendable {
    case notAServiceRecord
    case notAPng
    case zlib(status: Int32)

    public var localizedDescription: String {
        switch self {
        case .notAServiceRecord: "not an @SRV record"
        case .notAPng: "the logo payload was not a PNG"
        case .zlib(let status): "the guide file did not inflate (zlib status \(status))"
        }
    }
}
