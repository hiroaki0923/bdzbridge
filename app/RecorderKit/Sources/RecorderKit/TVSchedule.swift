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
    /// Read on rows: `1` for once, `title` for every programme of the name, `d`, and a weekly one as `w4` on a
    /// Thursday's programme and `w7` on a Sunday's. The television says it takes `w15` and `w16` as well,
    /// which no row has carried.
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

    /// Whether this row, the recording the television holds for `request` (`holding`), is less than the
    /// request asks for: the programme recorded once -- a repeat of `1`, or none said -- where the request
    /// asks for a repeat. What the request asks is read as a television would be sent it
    /// (`TVReservationBody.repeatType`), and a repeat that is not sent is a repeat asked for all the same.
    /// Taken for the request's own, such a row would leave every later programme unreserved, with nothing
    /// said.
    ///
    /// Nothing else falls short. A request for once that a repeat holds loses nothing. And a repeat held
    /// for a request that asks for another repeat is taken for it: nothing measured tells what the
    /// difference between two repeats costs.
    func fallsShort(of request: ReservationRequest) -> Bool {
        (repeatType ?? "1") == "1"
            && TVReservationBody.repeatType(for: request.repeatCode, start: request.start) != "1"
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
