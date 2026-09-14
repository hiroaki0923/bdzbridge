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

public enum XsrsElements {
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
