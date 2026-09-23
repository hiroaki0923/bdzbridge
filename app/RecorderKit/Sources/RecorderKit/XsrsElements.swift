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

    /// When the programme ends. A reservation is worth sending until then: the recorder records what is left
    /// of a programme already on air, which is better than dropping it.
    public var end: Date { start.addingTimeInterval(TimeInterval(durationSec)) }

    public init(title: String, start: Date, durationSec: Int, repeatCode: String, broadcastingType: Int,
                serviceID: Int, qualityCode: Int, eventID: Int? = nil) {
        self.title = title
        self.start = start
        self.durationSec = durationSec
        self.repeatCode = repeatCode
        self.broadcastingType = broadcastingType
        self.serviceID = serviceID
        self.qualityCode = qualityCode
        self.eventID = eventID
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
                qualityCode: Int, destination: String = "HDD") {
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

/// A reservation made while the recorder could not be reached, kept until it can be.
///
/// Away from home the guide is on the phone but the recorder is not, so a reservation has nowhere to go. It
/// waits here instead, and is sent the next time the recorder answers. What it holds is the request itself
/// plus enough to show a row without the guide: nothing is looked up again at sending time, so a reservation
/// made on Tuesday is the one the recorder gets on Thursday.
public struct PendingReservation: Sendable, Equatable, Identifiable {
    public var request: ReservationRequest
    /// The channel's name as the guide had it, so the row reads properly with the guide since replaced.
    public var serviceName: String
    public var queuedAt: Date
    /// What the recorder said last time this was tried, if it has been tried and refused. While it is set the
    /// queue does not send this again (`PendingQueue.flush`); clearing it is how the reader asks for another try.
    public var problem: String?

    /// One reservation per programme: the same programme queued twice replaces the first.
    public var id: String {
        "\(request.broadcastingType)/\(request.serviceID)/\(request.eventID.map(String.init) ?? RecorderTime.format(request.start))"
    }

    public init(request: ReservationRequest, serviceName: String, queuedAt: Date = Date(), problem: String? = nil) {
        self.request = request
        self.serviceName = serviceName
        self.queuedAt = queuedAt
        self.problem = problem
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
        // condition on every wave that carries desiredQualityMode alone gets DR on its 4K side, so one made as
        // LSR recorded BS4K programmes at full size; it gets the chosen quality in both. So does a scope the
        // recorder does not know, since that is a condition on every wave by the time the recorder has it.
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
    /// Element order, the `channelType` attribute and the `+09:00` offset all matter.
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
            + "<recordDestinationID>HDD</recordDestinationID>"
            + "<portableRecordFile target=\"preselect\" transferPath=\"none\"></portableRecordFile>"
            + "</item></xsrs>"
    }

    /// `X_UpdateRecordSchedule` takes the same item with its id filled in, and changes quality or repeat in place.
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
