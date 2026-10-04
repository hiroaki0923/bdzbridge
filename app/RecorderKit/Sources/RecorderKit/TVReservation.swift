import Foundation

/// A station as a television lists it: the channel it is, and the uri a reservation on it is sent with -- as it
/// came, never built again from its parts. The television gives a reservation's uri back byte for byte, and the
/// uri of its own list is the only spelling of one it has ever been sent.
struct TVStation: Sendable, Equatable {
    var broadcastingType: Int
    var serviceID: Int
    var uri: String

    init(broadcastingType: Int, serviceID: Int, uri: String) {
        self.broadcastingType = broadcastingType
        self.serviceID = serviceID
        self.uri = uri
    }

    /// A row of `avContent.getContentList`, read among the stations of `broadcastingType`, which is the type
    /// that was asked for. The service id is the last number of `tripletStr`. Nil without a uri or without a
    /// triplet that reads (`TVScheduleRow.serviceID(ofTriplet:)`), so that such a row is left out and the rest
    /// of the list is still read. Nothing else is asked of a row: `programMediaType` has been seen to say
    /// `tv`, `radio` and nothing at all, and is not looked at.
    init?(_ fields: [String: Any], broadcastingType: Int) {
        guard let uri = fields["uri"] as? String, !uri.isEmpty, let triplet = fields["tripletStr"] as? String,
              let serviceID = TVScheduleRow.serviceID(ofTriplet: triplet) else { return nil }
        self.init(broadcastingType: broadcastingType, serviceID: serviceID, uri: uri)
    }

    /// What a television calls the stations of a broadcasting type when it is asked to list them: `tv:` and
    /// the scheme its uris spell that type with. Nil for a type it has no name for.
    static func source(of broadcastingType: Int) -> String? {
        TVScheduleRow.schemes.first { Codes.broadcasting[$0.value] == broadcastingType }.map { "tv:\($0.key)" }
    }
}

/// What the two reservation requests are sent for one reservation on one station, in the television's
/// spellings, which are not the recorder's: the start with its offset written `+0900`, a repeat by the
/// programme's name as `title`, the programme id as decimal text and the length as a number.
struct TVReservationBody: Sendable, Equatable {
    var uri: String
    var title: String
    var startDateTime: String
    var durationSec: Int
    var repeatType: String
    var eventId: String

    /// Nil for a request with no programme id -- a reservation made by its times goes by another version of
    /// the method, which is not sent -- and for a repeat a television is not sent (`repeatType(for:start:)`).
    /// Nil as well for a station that is not the request's own channel, by its broadcasting type and its
    /// service id: a programme id means something only on its own service, and what a television makes of
    /// one under another station's uri has never been sent. This is the last place that can refuse it.
    /// The mode is not looked at: a television has never been sent one, and lists what it records as DR.
    init?(_ request: ReservationRequest, on station: TVStation) {
        guard station.broadcastingType == request.broadcastingType, station.serviceID == request.serviceID,
              let eventID = request.eventID,
              let repeatType = Self.repeatType(for: request.repeatCode, start: request.start) else { return nil }
        uri = station.uri
        title = request.title
        startDateTime = Self.start(request.start)
        durationSec = request.durationSec
        self.repeatType = repeatType
        eventId = String(eventID)
    }

    /// What `recording.addSchedule` 1.1 is sent: the six fields here and `type`, seven and no others. No
    /// `quality`: none was ever sent.
    var creating: [String: Any] {
        asking.merging(["type": "recording", "eventId": eventId]) { $1 }
    }

    /// What `recording.getConflictScheduleList` 1.0 is asked: the create without `type` and `eventId`, five
    /// fields and no others.
    var asking: [String: Any] {
        ["uri": uri, "title": title, "startDateTime": startDateTime, "durationSec": durationSec,
         "repeatType": repeatType]
    }

    /// A start as the television writes one: Japan's time whatever zone the phone is in, `en_US_POSIX` so
    /// that the phone's calendar and clock style are not written into it, and the offset `+0900` with no
    /// colon. Not `RecorderTime.format`, which writes `+09:00` for the recorder: a television has never been
    /// sent that.
    static func start(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }

    /// The television's spelling of a repeat: `title` for the recorder's `S001`, the others as the recorder
    /// spells them. Nil for a repeat a television is not sent:
    ///
    /// - a weekly code that is not the weekday of `start` in Japan. Sunday's code was taken for a Sunday's
    ///   programme and Thursday's for a Thursday's, and what a television makes of a code on another day's
    ///   programme has not been seen;
    /// - Monday to Friday for a start on Saturday or Sunday, and Monday to Saturday for one on Sunday: taken,
    ///   such a reservation might record from the Monday and never the programme it was made on;
    /// - any of these for a start before four in the morning in Japan. A guide's day runs on past midnight
    ///   (this app's from four to four), so such a programme is one day's by the calendar and the day
    ///   before's by the guide, and which of the two a television's weekday means has not been seen: no
    ///   reservation for one has been sent with a weekday in it;
    /// - a code the recorder's table does not have.
    static func repeatType(for code: String, start: Date) -> String? {
        switch code {
        case "1", "d": return code
        case "S001": return "title"
        default: break
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let parts = calendar.dateComponents([.weekday, .hour], from: start)
        guard let weekday = parts.weekday, let hour = parts.hour, hour >= 4 else { return nil }
        // Monday is 1 and Sunday 7, as the weekly codes count them; the calendar's Sunday is 1.
        let day = (weekday + 5) % 7 + 1
        switch code {
        case "w\(day)": return code
        case "w15": return day <= 5 ? code : nil
        case "w16": return day <= 6 ? code : nil
        default: return nil
        }
    }
}
