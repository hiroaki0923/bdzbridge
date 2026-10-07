import Foundation

/// What to ask the recorder to record. Without an `eventID` the recorder records by time only and never
/// back-fills the programme id, so the reservation will not follow schedule changes.
public struct ReservationRequest: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var durationSec: Int
    public var repeatCode: String
    public var broadcastingType: Int
    public var serviceID: Int
    public var qualityCode: Int
    public var eventID: Int?
    /// The recorder's id for the disk to record to: `HDD` for its own, `USBHDD` for a USB disk connected to it.
    public var destination: String

    /// When the programme ends. A reservation is worth sending until then: the recorder records what is left
    /// of a programme already on air, which is better than dropping it.
    public var end: Date { start.addingTimeInterval(TimeInterval(durationSec)) }

    public init(title: String, start: Date, durationSec: Int, repeatCode: String, broadcastingType: Int,
                serviceID: Int, qualityCode: Int, eventID: Int? = nil,
                destination: String = RecorderDisk.internalID) {
        self.title = title
        self.start = start
        self.durationSec = durationSec
        self.repeatCode = repeatCode
        self.broadcastingType = broadcastingType
        self.serviceID = serviceID
        self.qualityCode = qualityCode
        self.eventID = eventID
        self.destination = destination
    }
}

public extension ReservationRequest {
    /// What would be sent to record this programme, following it by its programme id, to the disk `destination`
    /// names: the internal disk unless the reader chose another. `quality` and `repeating` are the names in
    /// `Codes.quality` and `Codes.repeatCodes`; nil when the tables do not know one of them, or the programme's
    /// broadcasting type.
    init?(program: GuideProgramRow, quality: String, repeating: String,
          destination: String = RecorderDisk.internalID) {
        guard let broadcastingType = Codes.broadcasting[program.broadcasting],
              let qualityCode = Codes.quality[quality],
              let repeatCode = Codes.repeatCodes[repeating] else { return nil }
        self.init(title: program.title, start: program.start, durationSec: program.durationSec,
                  repeatCode: repeatCode, broadcastingType: broadcastingType, serviceID: program.serviceID,
                  qualityCode: qualityCode, eventID: program.eventID, destination: destination)
    }

    /// What would be sent to change the mode or the repeat of a reservation the device holds, and its disk when
    /// `destination` names one. Everything else is the reservation's own -- the title, the times, the channel
    /// and the programme id -- so one that follows its programme goes on following it, and one made by time stays
    /// as it was. So is the disk unless the reader moved it: a change names a disk whatever it is for, and a
    /// reservation on the USB disk changed with the internal disk's id goes to the internal disk without a word,
    /// as the recorder was seen to do (a move the other way has not been tried). Nil keeps the disk of the
    /// reservation given, which the app finds again on the device first: a disk changed on the recorder's own
    /// screen since a sheet was opened stays where it was put.
    init?(changing reservation: Reservation, quality: String, repeating: String, destination: String? = nil) {
        guard let qualityCode = Codes.quality[quality],
              let repeatCode = Codes.repeatCodes[repeating] else { return nil }
        self.init(title: reservation.title, start: reservation.start, durationSec: reservation.durationSec,
                  repeatCode: repeatCode, broadcastingType: reservation.broadcastingType,
                  serviceID: reservation.serviceID, qualityCode: qualityCode, eventID: reservation.eventID,
                  destination: destination ?? reservation.destination)
    }
}

/// A condition to register on the recorder itself. The recorder composes the name, and the channel cannot be set
/// this way (docs/xsrs-api.md).
public struct RecorderRuleRequest: Equatable, Sendable {
    public var keywords: [String]
    public var excluded: [String]
    public var logic: String
    /// The level-1 genre alone stands for the whole genre; with `genreLevel2` it is one sub-genre.
    public var genreLevel1: Int?
    public var genreLevel2: Int?
    public var timeScope: String
    public var broadcastingScope: String
    public var qualityCode: Int
    public var destination: String

    public init(keywords: [String], excluded: [String] = [], logic: String = "OR", genreLevel1: Int? = nil,
                genreLevel2: Int? = nil, timeScope: String = "ALL", broadcastingScope: String = "ALL",
                qualityCode: Int, destination: String = RecorderDisk.internalID) {
        self.keywords = keywords
        self.excluded = excluded
        self.logic = logic
        self.genreLevel1 = genreLevel1
        self.genreLevel2 = genreLevel2
        self.timeScope = timeScope
        self.broadcastingScope = broadcastingScope
        self.qualityCode = qualityCode
        self.destination = destination
    }
}

/// A reservation made while the recorder could not be reached, kept until it can be and sent the next time
/// it answers. It holds the request itself plus enough to show a row without the guide: nothing is looked up
/// again at sending time, so the reservation made is the one the recorder gets.
public struct PendingReservation: Sendable, Equatable, Identifiable {
    public var request: ReservationRequest
    /// The channel's name as the guide had it, so the row reads properly with the guide since replaced.
    public var serviceName: String
    public var queuedAt: Date
    /// What the recorder said last time this was tried, if it has been tried and refused. While it is set the
    /// queue does not send this again (`PendingQueue.flush`); clearing it is how the reader asks for another try.
    public var problem: String?
    /// The device it waits for, settled when it is queued.
    public var target: DeviceSlot

    /// One reservation per programme and device: the same programme queued twice for a device replaces the
    /// first. The recorder's go by the programme alone, as they did before a reservation said which device it
    /// waits for, so that one queued by an earlier version is found by the name it is kept under.
    public var id: String {
        let programme = "\(request.broadcastingType)/\(request.serviceID)/"
            + (request.eventID.map(String.init) ?? RecorderTime.format(request.start))
        return target == .recorder ? programme : "\(target.rawValue)|\(programme)"
    }

    public init(request: ReservationRequest, serviceName: String, queuedAt: Date = Date(), problem: String? = nil,
                target: DeviceSlot = .recorder) {
        self.request = request
        self.serviceName = serviceName
        self.queuedAt = queuedAt
        self.problem = problem
        self.target = target
    }
}

public enum XsrsElements {
    /// The `<Elements>` for `X_CreatePrefRecSetting`, in the order the recorder itself writes a condition and with
    /// no id attribute at all. A name is sent because every request that went through carried one; the recorder
    /// composes its own from the genre and the keywords and drops whatever arrives.
    public static func recorderRule(_ request: RecorderRuleRequest) -> String {
        let genre: String
        if let level1 = request.genreLevel1, let level2 = request.genreLevel2 {
            genre = "<genreID type=\"2\">\(hex(level1 * 16 + level2))</genreID>"
        } else if let level1 = request.genreLevel1 {
            genre = "<genreID type=\"3\">\(hex(level1))*</genreID>"   // the recorder's own form for a whole genre
        } else {
            genre = ""
        }
        let words = request.keywords.map { "<keyword>\(Soap.escape($0, quotes: false))</keyword>" }.joined()
        let excluded = request.excluded.map { "<excludeKeyword>\(Soap.escape($0, quotes: false))</excludeKeyword>" }.joined()
        // The recorder keeps a quality per wave -- desiredQualityMode for 地上/BS/CS, the Advanced one for
        // BS4K/CS4K -- and reads only those the scope covers. A 4K-only condition drops desiredQualityMode. A
        // condition on every wave that carries desiredQualityMode alone gets DR on its 4K side, so it gets the
        // chosen quality in both; so does a scope the recorder does not know, which it takes for every wave.
        let scope = request.broadcastingScope
        var quality = ""
        if !Codes.advancedScopes.contains(scope) {
            quality += "<desiredQualityMode>\(request.qualityCode)</desiredQualityMode>"
        }
        if !Codes.ordinaryScopes.contains(scope) {
            quality += "<desiredQualityModeForAdvanced>\(request.qualityCode)</desiredQualityModeForAdvanced>"
        }
        return "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\"><object type=\"SEARCH\">"
            + quality
            + "<recordDestinationID>\(request.destination)</recordDestinationID>"
            + "<searchSetting type=\"MULTIPLE\" logic=\"\(request.logic)\">"
            + "<name>\(Soap.escape(request.keywords.first ?? "", quotes: false))</name>" + genre + words + excluded
            + "<timeScope>\(request.timeScope)</timeScope>"
            + "<broadcastTypeScope>\(request.broadcastingScope)</broadcastTypeScope>"
            + "</searchSetting></object></xsrs>"
    }

    /// The `<Elements>` payload for `X_CreateRecordSchedule`, identical to what the official app sends.
    /// Element order, the `channelType` attribute and the `+09:00` offset all matter. Only the disk may differ
    /// from it: the recorder takes `USBHDD` in place of `HDD`, with everything else as it is.
    public static func create(_ request: ReservationRequest) -> String {
        let matching = request.eventID.map {
            "<desiredMatchingID type=\"SI_PROGRAMID\">,,\(hex(request.serviceID)),\(hex($0))</desiredMatchingID>"
        } ?? ""
        return "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\"><item id=\"\">"
            + "<title>\(Soap.escape(request.title, quotes: false))</title>"
            + "<scheduledStartDateTime>\(RecorderTime.format(request.start))</scheduledStartDateTime>"
            + "<scheduledDuration>\(request.durationSec)</scheduledDuration>"
            + "<scheduledConditionID>\(request.repeatCode)</scheduledConditionID>"
            + "<scheduledChannelID broadcastingType=\"\(request.broadcastingType)\" channelType=\"2\">"
            + "\(hex4(request.serviceID))</scheduledChannelID>"
            + matching
            + "<desiredQualityMode>\(request.qualityCode)</desiredQualityMode>"
            + "<priorityFlag>0</priorityFlag>"
            // Escaped like the title: on a change it is the recorder's own text, read back and sent again.
            + "<recordDestinationID>\(Soap.escape(request.destination, quotes: false))</recordDestinationID>"
            + "<portableRecordFile target=\"preselect\" transferPath=\"none\"></portableRecordFile>"
            + "</item></xsrs>"
    }

    /// `X_UpdateRecordSchedule` takes the same item with its id filled in, and changes quality or repeat in place.
    /// A reservation on the USB disk sent back naming the internal disk was seen to move there, which is why a change
    /// carries the reservation's own disk.
    public static func update(id: String, _ request: ReservationRequest) -> String {
        create(request).replacingOccurrences(of: "<item id=\"\">", with: "<item id=\"\(id)\">")
    }

    /// `X_UpdateTitle` is a partial update: the id plus only the properties to change.
    public static func titleUpdate(id: String, title: String? = nil, protected: Bool? = nil,
                                  isNew: Bool? = nil) -> String {
        var properties = ""
        if let title { properties += "<title>\(Soap.escape(title, quotes: false))</title>" }
        if let protected { properties += "<titleProtectFlag>\(protected ? 1 : 0)</titleProtectFlag>" }
        if let isNew { properties += "<titleNewFlag>\(isNew ? 1 : 0)</titleNewFlag>" }
        return "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\"><item id=\"\(id)\">\(properties)</item></xsrs>"
    }
}
