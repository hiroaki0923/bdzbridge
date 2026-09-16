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
    public var genreCode: Int?
    public var timeScope: String
    public var broadcastingScope: String
    public var qualityCode: Int
    public var destination: String

    public init(keywords: [String], excluded: [String] = [], logic: String = "OR", genreCode: Int? = nil,
                timeScope: String = "ALL", broadcastingScope: String = "ALL", qualityCode: Int,
                destination: String = "HDD") {
        self.keywords = keywords
        self.excluded = excluded
        self.logic = logic
        self.genreCode = genreCode
        self.timeScope = timeScope
        self.broadcastingScope = broadcastingScope
        self.qualityCode = qualityCode
        self.destination = destination
    }
}

public enum XsrsElements {
    /// The `<Elements>` for `X_CreatePrefRecSetting`, in the order the recorder itself writes a condition and with
    /// no id attribute at all. A name is sent because every request that went through carried one; the recorder
    /// composes its own from the genre and the keywords and drops whatever arrives.
    public static func recorderRule(_ request: RecorderRuleRequest) -> String {
        let genre = request.genreCode.map { "<genreID type=\"2\">\(hex($0))</genreID>" } ?? ""
        let words = request.keywords.map { "<keyword>\(Soap.escape($0, quotes: false))</keyword>" }.joined()
        let excluded = request.excluded.map { "<excludeKeyword>\(Soap.escape($0, quotes: false))</excludeKeyword>" }.joined()
        return "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\"><object type=\"SEARCH\">"
            + "<desiredQualityMode>\(request.qualityCode)</desiredQualityMode>"
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
