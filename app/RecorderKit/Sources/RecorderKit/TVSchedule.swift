import Foundation

/// One row of a television's `recording.getScheduleList` 1.1, as read: a reservation to record, or a reminder
/// to watch (`type` is `reminder`), which the television lists among them.
///
/// The values are kept as the television wrote them and not as the app would: a delete sends six of them back,
/// and the television has only been seen to take them as they came -- the start with its offset written `+0900`,
/// the title in the form the television rewrote it to. They are also what the row is found again by.
public struct TVScheduleRow: Sendable, Equatable {
    /// `recording.<n>` or `reminder.<n>`, numbered by the television.
    public var id: String
    /// `recording` or `reminder`.
    public var type: String
    /// The channel: `tv:<scheme>?trip=<onid>.<tsid>.<sid>&srvName=<station name>`.
    public var uri: String
    /// The start as the television wrote it. The one reminder seen had it a second before its programme's.
    public var startDateTime: String
    public var durationSec: Int
    public var title: String?
    public var channelName: String?
    /// Read on rows: `1` for once, and every repeat a create was sent with, each read back as it was sent
    /// -- `title` for every programme of the name, `d`, `w15`, `w16`, and a weekly code on its programme's
    /// own weekday: `w1` on a Monday's programme, `w4` on a Thursday's and `w7` on a Sunday's. What a row
    /// is held to fall short of (`fallsShort`) stands on that: a repeat that was made is listed as the
    /// repeat that was asked for.
    public var repeatType: String?
    /// `notOverlapped`; `fullyOverlapped` for the recording that loses to others at its time, also when they
    /// share only a part of it; and `partlyOverlapped`, seen on a reminder to watch once recordings stood at
    /// a part of its time, and gone again when they were deleted.
    public var overlapStatus: String?
    /// Only `notStarted` has been seen.
    public var recordingStatus: String?
    /// A recording mode by its name, `DR`. The one reminder seen had none.
    public var quality: String?
    /// The programme's id, in decimal. A reservation made by its times has none: the field is not there.
    public var eventId: String?

    public init(id: String, type: String, uri: String, startDateTime: String, durationSec: Int, title: String? = nil,
                channelName: String? = nil, repeatType: String? = nil, overlapStatus: String? = nil,
                recordingStatus: String? = nil, quality: String? = nil, eventId: String? = nil) {
        self.id = id
        self.type = type
        self.uri = uri
        self.startDateTime = startDateTime
        self.durationSec = durationSec
        self.title = title
        self.channelName = channelName
        self.repeatType = repeatType
        self.overlapStatus = overlapStatus
        self.recordingStatus = recordingStatus
        self.quality = quality
        self.eventId = eventId
    }

    /// A row of the answer. Nil without what a delete has to send back and a list has to show -- the id, the
    /// type, the channel, a start that reads as a time, the length -- so that such a row is left out, as a
    /// recorder's reservation with no start is, rather than the whole list refused for it.
    init?(_ fields: [String: Any]) {
        guard let id = fields["id"] as? String, let type = fields["type"] as? String,
              let uri = fields["uri"] as? String, let startDateTime = fields["startDateTime"] as? String,
              RecorderTime.parse(startDateTime) != nil, let durationSec = fields["durationSec"] as? Int else {
            return nil
        }
        self.init(id: id, type: type, uri: uri, startDateTime: startDateTime, durationSec: durationSec,
                  title: fields["title"] as? String, channelName: fields["channelName"] as? String,
                  repeatType: fields["repeatType"] as? String, overlapStatus: fields["overlapStatus"] as? String,
                  recordingStatus: fields["recordingStatus"] as? String, quality: fields["quality"] as? String,
                  eventId: fields["eventId"] as? String)
    }

    /// What `deleteSchedule` is sent for this row: these six, each as it was read. The start is the string
    /// kept and not one written from a date, and the title is the television's own form of it; a row that came
    /// with no title sends an empty one, the field being one the method is always given.
    var deletion: [String: Any] {
        ["id": id, "startDateTime": startDateTime, "title": title ?? "", "durationSec": durationSec,
         "type": type, "uri": uri]
    }

    /// What `addSchedule` 1.2 is sent to change this reservation's repeat to `repeatType`, the television's
    /// spelling of one: the row's own id and every value it was read with, each as it was read, but the
    /// repeat. A television sent a create's values with the id beside them changed the repeat in place, and
    /// these are the same values as the list gave them -- the start as the string kept, the title in the
    /// television's own form, an empty one for a row that came with none -- for the reason a delete sends
    /// them so. The programme id goes only on a row that was read with one: a reservation made by its times
    /// has none, and an empty one is not what it was read with. Nothing the list alone gives is sent (the
    /// station's name, the two statuses, the mode), nor anything else the method takes: none of it was ever
    /// sent to a television.
    func changing(to repeatType: String) -> [String: Any] {
        var fields: [String: Any] = ["id": id, "type": type, "uri": uri, "title": title ?? "",
                                     "startDateTime": startDateTime, "durationSec": durationSec,
                                     "repeatType": repeatType]
        if let eventId { fields["eventId"] = eventId }
        return fields
    }

    /// Whether the television marks the row as sharing its time with others: any status but `notOverlapped`,
    /// one it has never been seen to say included. A row that says nothing is taken for one that is not
    /// marked.
    var overlaps: Bool { overlapStatus.map { $0 != "notOverlapped" } == true }

    /// The broadcasting type behind each scheme of a television's uri, by the name `Codes.broadcasting` has
    /// for it.
    static let schemes = ["isdbt": "td", "isdbbs": "bs", "isdbcs": "cs", "isdbs3bs": "bs4k", "isdbs3cs": "cs4k"]

    /// The broadcasting type and the service id a uri names, or nil for one that is not in the form above:
    /// both or neither, half a channel being none. Cut as a string and not as a URL: the station name is in it
    /// as the television has it, unescaped, and may hold anything. So the three numbers run from the first
    /// `?trip=` to the first `&` after it, or to the end when nothing follows them, and what the station is
    /// called is not looked at. The numbers are read as `serviceID(ofTriplet:)` reads them.
    static func channel(of uri: String) -> (broadcastingType: Int, serviceID: Int)? {
        guard uri.hasPrefix("tv:"), let trip = uri.range(of: "?trip=", options: .literal) else { return nil }
        let scheme = String(uri[..<trip.lowerBound].dropFirst("tv:".count))
        let rest = uri[trip.upperBound...]
        let triplet = rest[..<(rest.range(of: "&", options: .literal)?.lowerBound ?? rest.endIndex)]
        guard let type = schemes[scheme].flatMap({ Codes.broadcasting[$0] }),
              let serviceID = serviceID(ofTriplet: triplet) else { return nil }
        return (type, serviceID)
    }

    /// What the television calls the station a uri names: the text after the first `&srvName=`, to the end
    /// of the uri, as the television has it. Cut as a string, as the channel is, and for the same reason: the
    /// name is unescaped and may hold anything, an `&` or another `srvName=` included, and nothing in it is
    /// taken for its end. Nil for a uri with no name, and for one whose name is empty. It is for saying
    /// which station is meant, and nothing is found by it: a channel is its numbers.
    static func stationName(of uri: String) -> String? {
        guard let marker = uri.range(of: "&srvName=", options: .literal) else { return nil }
        let name = uri[marker.upperBound...]
        return name.isEmpty ? nil : String(name)
    }

    /// The service id in `<onid>.<tsid>.<sid>`, as a uri writes a channel and as a station's own row does: the
    /// last of three numbers. Each of the three is digits and nothing else -- `Int` by itself would take a
    /// sign -- and the service id is one its sixteen bits can hold. Nil for anything else.
    static func serviceID(ofTriplet triplet: some StringProtocol) -> Int? {
        let numbers = triplet.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let serviceID = Int(numbers[2]), serviceID <= 0xFFFF else { return nil }
        return serviceID
    }

    /// The reservation in the terms the screens read, the recorder's: nil for a reminder, which is not one,
    /// and for a start that is no time, which no row that was read has.
    ///
    /// A uri that cannot be read leaves the channel at type 0 and service 0: the row is still listed, under
    /// the television's own name for the station, and can still be deleted, which goes by the row. A
    /// reservation for every programme of a name is the recorder's `S001`; the other repeats are spelled as the
    /// recorder spells them.
    ///
    /// It is recording only inside its own times: no status but `notStarted` has been seen, so any other is
    /// taken for a recording under way, and the times are what keep a row the television leaves in its list
    /// from reading as one for ever. That is as of `now`, the moment the row is read into a reservation:
    /// nothing turns it over afterwards, until the list is read again.
    ///
    /// Every row seen said both of its statuses. One that says neither is taken for a reservation that is not
    /// recording and that loses to no other: that is a choice made here, not something a television showed.
    public func reservation(now: Date = Date()) -> Reservation? {
        guard type == "recording", let start = RecorderTime.parse(startDateTime) else { return nil }
        let channel = Self.channel(of: uri)
        let underWay = start <= now && now < start.addingTimeInterval(TimeInterval(durationSec))
        return Reservation(
            id: id,
            title: title ?? "",
            start: start,
            durationSec: durationSec,
            repeatCode: repeatType.map { $0 == "title" ? "S001" : $0 } ?? "1",
            broadcastingType: channel?.broadcastingType ?? 0,
            serviceID: channel?.serviceID ?? 0,
            eventID: eventId.flatMap { Int($0) },
            qualityCode: quality.flatMap { Codes.quality[$0] } ?? 0,
            recording: underWay && recordingStatus.map { $0 != "notStarted" } == true,
            conflict: overlaps,
            destination: "",
            sizeMB: nil,
            creator: nil,
            genreCode: nil,
            device: .tv,
            tvRow: self
        )
    }

    /// Whether `other`, read later under the same id, is still this reservation: the same channel and the
    /// same programme, by the television's own values. A reservation that follows a programme is that
    /// programme's wherever its start has moved to; one made by its times is its start. One that has gained
    /// a programme id since, or lost the one it had, is not what was held, whatever its start.
    func isStill(_ other: TVScheduleRow) -> Bool {
        guard uri == other.uri, eventId == other.eventId else { return false }
        return eventId != nil || startDateTime == other.startDateTime
    }

    /// Whether the row records its programme once: a repeat of `1`, or none said.
    var recordsOnce: Bool { (repeatType ?? "1") == "1" }

    /// The days of the week a repeat takes in, Monday as 1 and Sunday as 7 as the weekly codes count them:
    /// all seven for `d`, Monday to Friday for `w15`, Monday to Saturday for `w16` -- a television's own
    /// list words the three so -- and its own day for a weekly code. Nil for what goes by no day of the
    /// week: once, every programme of a name, and a code that is none of these.
    static func weekdays(ofRepeat code: String) -> Set<Int>? {
        switch code {
        case "d": return Set(1...7)
        case "w15": return Set(1...5)
        case "w16": return Set(1...6)
        default: return (1...7).first { code == "w\($0)" }.map { [$0] }
        }
    }

    /// Whether this row, the recording the television holds for `request` (`holding`), is less than the
    /// request asks for, where the request asks for a repeat:
    ///
    /// - the programme recorded once is less than any repeat;
    /// - a repeat held is less than the one asked for when its days are some of that one's and not all of
    ///   them (`weekdays(ofRepeat:)`): any weekly code, Monday to Friday and Monday to Saturday where every
    ///   day is asked for; Monday to Friday and a weekly code up to Saturday's where Monday to Saturday is;
    ///   a weekly code up to Friday's where Monday to Friday is.
    ///
    /// Taken for the request's own, such a row would leave the other days unreserved -- every later
    /// programme, for one recorded once -- with nothing said.
    ///
    /// Nothing else falls short. A request for once that a repeat holds loses nothing. Nor does a repeat
    /// lose anything to the same repeat held, or to one that takes in each of its days and more. A repeat
    /// by the programme's name is compared with nothing but once, on either side: it goes by a name and
    /// not by days, and what it takes in beside the others is not known. And two repeats with no day in
    /// common are not told apart: one of them is of other days than the programme's own, which a
    /// television refused for a weekly code and was not asked for otherwise.
    ///
    /// What the request asks is its own code, whether or not a television is sent that repeat for the
    /// programme (`TVReservationBody.repeatType`): a repeat that is not sent is a repeat asked for all the
    /// same.
    func fallsShort(of request: ReservationRequest) -> Bool {
        guard request.repeatCode != "1" else { return false }
        guard !recordsOnce, let held = repeatType else { return true }
        guard let asked = Self.weekdays(ofRepeat: request.repeatCode),
              let days = Self.weekdays(ofRepeat: held) else { return false }
        return days.isStrictSubset(of: asked)
    }
}

extension Array where Element == TVScheduleRow {
    /// The recording the television holds for what `request` asks, when this list of its rows has one: a row
    /// to record, on the request's channel (`TVScheduleRow.channel(of:)`), for the request's programme id as
    /// a create writes one. What says that a reservation need not be sent, or that one sent was made.
    ///
    /// Nothing else is held against the request. Not the title: a television lists a reservation under a
    /// title of its own and not under the one it was sent. Not the start: a reservation that follows its
    /// programme is that programme's wherever its start has moved to. Not the name in the uri, which is
    /// the television's own for the station. And not the repeat: whether the row found is all that the
    /// request asks for is another question (`TVScheduleRow.fallsShort`), for whoever reads the answer as
    /// a reservation that need not be sent.
    ///
    /// A reminder to watch the programme is no match: it records nothing. A request with no programme id
    /// matches nothing, whatever stands at its time: its channel alone does not say which row is its own.
    func holding(_ request: ReservationRequest) -> TVScheduleRow? {
        guard let programme = request.eventID.map({ String($0) }) else { return nil }
        return first { row in
            guard row.type == "recording", row.eventId == programme,
                  let channel = TVScheduleRow.channel(of: row.uri) else { return false }
            return channel.broadcastingType == request.broadcastingType && channel.serviceID == request.serviceID
        }
    }
}

/// What has become of a television's reservation the app holds, in the list just read from the television.
enum TVTarget: Equatable, Sendable {
    /// It is there as it was held. The row is the one just read, which is the one to send.
    case found(Reservation)
    /// The television lists nothing under its id.
    case gone
    /// The id is there, and not as it was held: on another programme, or on more than one row.
    case changed
}

extension Array where Element == Reservation {
    /// A television's reservation as the television holds it now, in this list just read from it: the row
    /// with its id, when that row is still the same programme on the same channel (`TVScheduleRow.isStill`).
    ///
    /// Not the recorder's rule (`current`), which goes on to look for the programme when the id has gone. A
    /// television's ids were seen to hold through two days of standby and use, and a row picked by its
    /// programme alone can be another reservation of it -- the weekly one beside the single one -- which nobody
    /// asked to have deleted. So without the id there is nothing to write to; and with it the programme is
    /// checked as well, against an id the television has since given to another reservation. Two rows under
    /// one id have not been seen: which of them a delete would take is not known, so neither is written to.
    /// Nor is anything for a reservation held without its row, which has nothing to be checked by.
    func tvTarget(of wanted: Reservation) -> TVTarget {
        let sameID = filter { $0.id == wanted.id }
        guard let row = sameID.first else { return .gone }
        guard sameID.count == 1, let held = wanted.tvRow, row.tvRow.map(held.isStill) == true else {
            return .changed
        }
        return .found(row)
    }
}
