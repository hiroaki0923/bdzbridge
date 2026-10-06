import Foundation

/// An invented Sony BRAVIA: it answers the methods the app uses, in the shapes a real one gives them, and remembers
/// what it was told -- the clients registered with it, the cookies it gave out, the stations it receives, and
/// the reservations put on it or made on it by a request until they are deleted. For the tests of the package
/// and of the app, and for the demo, as `DemoRecorder` is for the recorder. Every value in it is invented.
///
/// Where a real one was sent the app's own requests and what it answered was written down, this one answers
/// the same and is no kinder: a reservation made by a request is listed under a title of the television's
/// own, a third recording at one time costs the one made first its recording, a station the household is not
/// subscribed to and a weekly repeat of another weekday are refused. Each such rule says beside it what was
/// seen of a real one and what is taken without having been seen.
///
/// Each request is put down in `calls` as its method and whether a cookie or a PIN came with it, which is what the
/// tests read: what was asked, never the cookie itself. Its body is kept beside it, in `bodies`.
public actor DemoTV: HTTPTransport {
    /// Sony's OUI and the rest zeroed, as everywhere in this repository, with a last digit of its own.
    public static let mac = "f8:4e:17:00:00:0a"
    public static let model = "KJ-SAMPLE"
    public static let pin = "1234"
    /// The error it answers a request with that is not written as a real one has been sent it. What a real one
    /// makes of such a request has not been seen, so the code is one no television gives: nothing can come to
    /// read it as a real one's.
    public static let inventedError = 99999

    /// `standby` or `active`. It shows its PIN, and so can be registered by one, only when active.
    public var power: String
    public private(set) var mac: String
    private var silent = false
    private var cookies: Set<String> = []
    private var registered: Set<String> = []
    private var issued = 0
    /// What it holds, in the order they were put or made, each as it was put or made: what the television
    /// itself has since made of a row's overlap is worked out when it is read (`schedules`).
    private var held: [Schedule] = []
    /// The ids of the recordings a request made, which are the ones that cost others their recording.
    private var made: Set<String> = []
    /// The stations it receives, in the order they were put: none until a test puts some.
    public private(set) var stations: [Station] = []
    /// The highest number anything it has held was listed under, a reminder included. What it makes is
    /// numbered one above, so a number is never given twice, whatever was deleted in between: a real one's
    /// ids were seen only to grow.
    private var numbered = 0
    /// Whether the disk it records to is there.
    private var mounted = true
    /// What the next create comes to in place of what it would, when a test has said so.
    private var nextCreate: NextCreate?
    public private(set) var calls: [String] = []
    /// The body of each request as it came, in step with `calls`: what a test holds against what was to be
    /// sent, to the byte.
    public private(set) var bodies: [String] = []

    public init(power: String = "standby", mac: String = DemoTV.mac) {
        self.power = power
        self.mac = mac
    }

    /// Says nothing from now on, as a television does that has left the network, or answers again.
    public func goSilent(_ value: Bool = true) { silent = value }
    /// Answers as another television would, with a MAC of its own.
    public func becomeAnother(mac: String) { self.mac = mac }
    /// Is switched on with its remote, or off: `active` or `standby` from now on.
    public func turn(_ power: String) { self.power = power }
    /// Has the disk it records to taken away from now on, or put back. Without it the disk is said as a real
    /// one was seen to say it, and a create is answered with the invented error and makes nothing: no real
    /// one has been sent a create with its disk away -- the official app does not send one -- so a client
    /// that sends one is caught here rather than told something no television said.
    public func unmount(_ value: Bool = true) { mounted = !value }

    /// What one create can be made to come to, in place of what it would: the things a television or the
    /// network between can do to a create that no test can otherwise bring about.
    public enum NextCreate: Sendable, Equatable {
        /// It is carried out as it would be, and its answer never arrives: the request ends as one nothing
        /// answered.
        case carriedOutAndNotAnswered
        /// It is answered as taken, and nothing is made. No real one was seen to do this.
        case answeredAndNotKept
        /// It is answered with the error of this code, and nothing is made.
        case answered(code: Int)
    }

    /// The next create that is written as a real one has been sent it, with a cookie it knows and the disk
    /// there, comes to `once`; the ones after it are answered as ever. A create that is refused before that
    /// -- for its cookie, its shape, the disk -- does not use it up.
    public func atTheNextCreate(_ once: NextCreate) { nextCreate = once }

    /// A client registered with its PIN before, holding `cookie`.
    public func knows(_ clientID: String, cookie: String) {
        registered.insert(clientID)
        cookies.insert(cookie)
    }

    /// One thing the invented television is set to do: a recording, or a reminder to watch (`type`
    /// `reminder`, and no `quality`), which a real one lists among them. Said with an id and a start alone it
    /// is a single recording made by its times; an `eventId` makes it one that follows its programme.
    public struct Schedule: Sendable, Equatable {
        /// `recording.<n>` or `reminder.<n>`, as a real one numbers them.
        public var id: String
        public var type: String
        /// The kind of broadcast, as a uri spells it: `isdbt`, `isdbbs`, `isdbcs`, `isdbs3bs`, `isdbs3cs`.
        public var scheme: String
        public var serviceID: Int
        public var station: String
        public var title: String
        public var start: Date
        public var durationSec: Int
        public var repeatType: String
        public var overlapStatus: String
        public var recordingStatus: String
        public var quality: String?
        public var eventId: Int?

        public init(id: String, type: String = "recording", scheme: String = "isdbt", serviceID: Int = 1024,
                    station: String = "サンプルテレビ", title: String = "サンプル番組", start: Date,
                    durationSec: Int = 1800, repeatType: String = "1", overlapStatus: String = "notOverlapped",
                    recordingStatus: String = "notStarted", quality: String? = "DR", eventId: Int? = nil) {
            self.id = id
            self.type = type
            self.scheme = scheme
            self.serviceID = serviceID
            self.station = station
            self.title = title
            self.start = start
            self.durationSec = durationSec
            self.repeatType = repeatType
            self.overlapStatus = overlapStatus
            self.recordingStatus = recordingStatus
            self.quality = quality
            self.eventId = eventId
        }

        /// Its channel, as a real one writes one (`DemoTV.uri`).
        var uri: String { DemoTV.uri(scheme: scheme, serviceID: serviceID, station: station) }

        /// Its start, as a real one writes one (`DemoTV.startText`).
        var startDateTime: String { DemoTV.startText(start) }

        /// The mode as the list gives it: only what is recorded has one, whatever this was made with.
        private var listedQuality: String? { type == "recording" ? quality : nil }

        /// Its row as the list gives it: twelve fields, less the two a real one leaves out where there is
        /// nothing to say -- the mode of a reminder, the programme of a reservation made by its times.
        var fields: [String: Any] {
            var fields: [String: Any] = [
                "id": id, "type": type, "uri": uri, "title": title, "channelName": station,
                "startDateTime": startDateTime, "durationSec": durationSec, "repeatType": repeatType,
                "overlapStatus": overlapStatus, "recordingStatus": recordingStatus,
            ]
            if let listedQuality { fields["quality"] = listedQuality }
            if let eventId { fields["eventId"] = String(eventId) }
            return fields
        }

        /// Its row as a client reads it from the list, for a test to hold against what one did read.
        public var row: TVScheduleRow {
            TVScheduleRow(id: id, type: type, uri: uri, startDateTime: startDateTime, durationSec: durationSec,
                          title: title, channelName: station, repeatType: repeatType, overlapStatus: overlapStatus,
                          recordingStatus: recordingStatus, quality: listedQuality,
                          eventId: eventId.map { String($0) })
        }

        /// Its row as the question before a create names it: seven fields, as a real one named a row --
        /// without the station's name, the two statuses, the mode and the programme.
        var named: [String: Any] {
            ["id": id, "type": type, "uri": uri, "title": title, "startDateTime": startDateTime,
             "durationSec": durationSec, "repeatType": repeatType]
        }

        /// The number in its id, which the list goes by: the newest reservation first.
        var number: Int { id.split(separator: ".").last.flatMap { Int($0) } ?? 0 }

        /// The time it takes, by the one start it is listed with: the later days of a repeat are not played.
        fileprivate var slot: Slot { Slot(from: start, durationSec: durationSec) }
    }

    /// What it is set to record and to remind of, in the order they were put or made, each as the list reads
    /// it now. A row reads as it was put or made, but for its overlap where a request has since made a
    /// recording at its time: the reservations made by a request are gone through in the order they were
    /// made, and each marks what it cost a recording (`pushedOut`) and the viewing reservations it overlaps
    /// in part. Worked out afresh each time, so that a row reads as it did once what marked it is deleted.
    ///
    /// What was seen of a real one: with a viewing reservation on a station of its own beside three
    /// recordings that each overlapped it in part, the viewing reservation read `partlyOverlapped`, and
    /// `notOverlapped` again once the three were deleted. Taken, not seen: that one such recording is enough
    /// to mark it, and that it is marked for as long as that recording is listed, a recording that has itself
    /// lost to others included. A recording that covers a viewing reservation whole has not been seen beside
    /// one: here it leaves the viewing reservation as it reads. And only what a request made marks anything:
    /// rows put read as they were put, whatever stands at their time, since what is put is whatever a test
    /// says a television holds.
    public var schedules: [Schedule] {
        var reads = held
        var there = held.indices.filter { !made.contains(held[$0].id) }
        let inOrder = held.indices.filter { made.contains(held[$0].id) }
            .sorted { held[$0].number < held[$1].number }
        for new in inOrder {
            let slot = held[new].slot
            for loser in Self.pushedOut(by: slot, among: reads, at: there) {
                reads[loser].overlapStatus = "fullyOverlapped"
            }
            for index in there where reads[index].type == "reminder" && slot.overlapsInPart(reads[index].slot) {
                reads[index].overlapStatus = "partlyOverlapped"
            }
            there.append(new)
        }
        return reads
    }

    /// Holds these and nothing else, as if they had been made on it with its remote. A row handed back just
    /// as `schedules` gave it is the row it was, a recording a request made included: what the television
    /// made of its overlap is not put on it for good, and goes on being worked out.
    public func put(_ schedules: [Schedule]) {
        let reads = self.schedules
        var stillMade: Set<String> = []
        held = schedules.map { row in
            guard let index = reads.firstIndex(of: row) else { return row }
            if made.contains(held[index].id) { stillMade.insert(held[index].id) }
            return held[index]
        }
        made = stillMade
        numbered = max(numbered, schedules.map(\.number).max() ?? 0)
    }

    /// The time a reservation takes, from its start to its end.
    fileprivate struct Slot {
        var from: Date
        var to: Date

        init(from: Date, durationSec: Int) {
            self.from = from
            to = from.addingTimeInterval(TimeInterval(durationSec))
        }

        func overlaps(_ other: Slot) -> Bool { from < other.to && other.from < to }

        /// Whether this one and `other` share some of their time and this one does not take up all of
        /// `other`'s.
        func overlapsInPart(_ other: Slot) -> Bool {
            overlaps(other) && !(from <= other.from && other.to <= to)
        }

        /// Whether there is a moment all three are under way at.
        static func meet(_ one: Slot, _ other: Slot, _ third: Slot) -> Bool {
            max(one.from, other.from, third.from) < min(one.to, other.to, third.to)
        }
    }

    /// The recordings a new one at `slot` would stop from recording, among the rows of `rows` at `there`, as
    /// their places in `rows` and in the order they lose.
    ///
    /// What was seen of a real one, in two arrangements: with two recordings at one time on two stations,
    /// neither marked, the question for a third on a third station that overlapped them in part named one
    /// row, the one of the two that was made first -- with the third starting later than the two, and with
    /// it starting earlier. The third was taken all the same, and that first one then read
    /// `fullyOverlapped`; the second and the third, `notOverlapped`. A viewing reservation at that time was
    /// not named. So: two record at one time, a third costs the one made first of those it meets its
    /// recording, and the new one never loses.
    ///
    /// Taken, not seen: that "made first" goes by the number in the id; that a recording which has lost
    /// already is not counted among those under way; that the stations do not matter, two recordings on one
    /// station counting as two; that a recording that only overlaps the new one, and is never under way
    /// with it and another at one moment, loses nothing; and that where the new one would be a third at more
    /// than one time, a row is named for each. No real one has named more than one row.
    private static func pushedOut(by slot: Slot, among rows: [Schedule], at there: [Int]) -> [Int] {
        var underWay = there.filter { index in
            rows[index].type == "recording" && rows[index].overlapStatus != "fullyOverlapped"
                && rows[index].slot.overlaps(slot)
        }
        var losers: [Int] = []
        while true {
            let crowded = underWay.filter { one in
                underWay.contains { other in other != one && Slot.meet(rows[one].slot, rows[other].slot, slot) }
            }
            guard let loser = crowded.min(by: { rows[$0].number < rows[$1].number }) else { return losers }
            losers.append(loser)
            underWay.removeAll { $0 == loser }
        }
    }

    /// One station the invented television receives: a row of the list a real one gives of a kind of
    /// broadcast, and what a reservation made by a request is made on.
    public struct Station: Sendable, Equatable {
        /// The kind of broadcast, as a uri spells it: one of the five a schedule's can be.
        public var scheme: String
        public var serviceID: Int
        public var name: String
        /// A real one has been seen to say `tv`, `radio` and nothing at all.
        public var programMediaType: String
        /// Whether the household is subscribed to it. A real one listed a station it was not subscribed to
        /// among the others, answered the question about a reservation on it with nothing, and refused the
        /// create with error 7: seen for two such stations, of two kinds of broadcast.
        public var subscribed: Bool

        public init(scheme: String = "isdbt", serviceID: Int = 1024, name: String = "サンプルテレビ",
                    programMediaType: String = "tv", subscribed: Bool = true) {
            self.scheme = scheme
            self.serviceID = serviceID
            self.name = name
            self.programMediaType = programMediaType
            self.subscribed = subscribed
        }

        /// As a schedule on it writes it: what a reservation for it has to be sent with, to the letter.
        var uri: String { DemoTV.uri(scheme: scheme, serviceID: serviceID, station: name) }

        /// Its row as the list gives it, the `index`th of its kind: seven fields. The number it is shown
        /// under is made of the service id, and it has no button of the remote, as a real one's subchannel
        /// has none.
        func fields(at index: Int) -> [String: Any] {
            ["uri": uri, "title": name, "index": index, "dispNum": String(format: "%03d", serviceID % 1000),
             "tripletStr": "65534.65533.\(serviceID)", "programMediaType": programMediaType,
             "directRemoteNum": -1]
        }
    }

    /// Receives these stations and no others, each kind of broadcast in the order given.
    public func receives(_ stations: [Station]) { self.stations = stations }

    /// A channel's uri: the station's name goes in as it is, as a real one writes it. The network and the
    /// transport stream before the service are invented numbers, the same for every station.
    static func uri(scheme: String, serviceID: Int, station: String) -> String {
        "tv:\(scheme)?trip=65534.65533.\(serviceID)&srvName=\(station)"
    }

    /// A start as a real one writes it: Japan's time, the offset with no colon. Written here and not by the
    /// client's own function: a television that shared that could not catch the client writing a start wrong.
    static func startText(_ date: Date) -> String { startFormatter().string(from: date) }

    /// The time a start names, when it is written just as a real one writes it. Nil for any other spelling
    /// of the same time: a real one has never been sent one.
    static func startTime(_ text: String) -> Date? {
        guard let date = startFormatter().date(from: text),
              startText(date).unicodeScalars.elementsEqual(text.unicodeScalars) else { return nil }
        return date
    }

    private static func startFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+0900'"
        return formatter
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let object = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
        let method = object["method"] as? String ?? ""
        let id = object["id"] as? Int ?? 0
        let cookie = request.headers["Cookie"].map { String($0.dropFirst("auth=".count)) }
        calls.append("\(method) cookie=\(cookie == nil ? "no" : "yes") pin=\(request.headers["Authorization"] == nil ? "no" : "yes")")
        bodies.append(String(decoding: request.body ?? Data(), as: UTF8.self))
        if silent { throw RecorderError.transport("The request timed out.") }
        switch method {
        case "getPowerStatus":
            return ok(#"[{"status":"\#(power)"}]"#, id)
        case "getInterfaceInformation":
            return ok(#"[{"productCategory":"tv","productName":"BRAVIA","modelName":"\#(Self.model)","serverName":"","interfaceVersion":"5.7.0"}]"#, id)
        case "getSystemSupportedFunction":
            return ok(#"[[{"option":"WOL","value":"\#(mac)"}]]"#, id)
        case "getStorageList":
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            // A real one whose disk was not there was seen to say that and nothing of its size.
            guard mounted else { return ok(#"[[{"uri":"usb:recStorage","mounted":"unmounted"}]]"#, id) }
            return ok(#"[[{"uri":"usb:recStorage","mounted":"mounted","wholeCapacityMB":1000,"freeCapacityMB":400}]]"#, id)
        case "getScheduleList":
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            return json(["result": [listed.map(\.fields)], "id": id])
        case "deleteSchedule":
            // A real one was seen to refuse the two reads above for their cookie, and a create. A delete has
            // not been sent to one with a cookie it does not take: that it is refused the same way is taken,
            // not seen.
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            return delete(object, id)
        case "getContentList":
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            guard Self.asks(request, object, of: "avContent", version: "1.0") else { return unknown(method, id) }
            return stationPage(object, id)
        case "getConflictScheduleList":
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            guard Self.asks(request, object, of: "recording", version: "1.0") else { return unknown(method, id) }
            return wouldPushOut(object, id)
        case "addSchedule":
            // A real one answered a create with a cookie it never gave with HTTP 403, and made nothing.
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            guard Self.asks(request, object, of: "recording", version: "1.1") else { return unknown(method, id) }
            return try add(object, id)
        case "actRegister":
            return register(object, request, id)
        default:
            return unknown(method, id)
        }
    }

    /// What a real one answers a method, or a version of one, that it does not have.
    private func unknown(_ method: String, _ id: Int) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"error":[12,"\#(method)"],"id":\#(id)}"#.utf8))
    }

    /// Whether a request went to `service` in `version`: the one version of a method the app sends, at the
    /// service it sends it to. A real one has other versions of these methods, which mean other things and
    /// which the app does not send: here they are answered as a method it does not have.
    private static func asks(_ request: HTTPRequest, _ object: [String: Any], of service: String,
                             version: String) -> Bool {
        request.url.path == "/sony/\(service)" && object["version"] as? String == version
    }

    /// The kinds of broadcast a real one lists stations of.
    private static let schemes = ["isdbt", "isdbbs", "isdbcs", "isdbs3bs", "isdbs3cs"]
    /// The repeats a real one says it takes.
    private static let repeatTypes: Set = ["1", "d", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w15", "w16", "title"]

    /// The one thing in a request's parameters, which is all these three methods are sent.
    private static func parameter(of object: [String: Any]) -> [String: Any]? {
        guard let params = object["params"] as? [Any], params.count == 1 else { return nil }
        return params[0] as? [String: Any]
    }

    private func refused(_ id: Int) -> HTTPResponse {
        json(["error": [Self.inventedError, "not as a real one has been sent it"], "id": id])
    }

    /// One page of the stations of a kind of broadcast, as a real one lists them: from `stIdx`, as many as
    /// `cnt` says and never more than fifty, the most a real one has been asked for in one answer. Past the
    /// last station it answers an empty page, as a real one answered a page asked for past the end of its
    /// list. A station the household is not subscribed to is listed among the others. A source that is no
    /// kind of broadcast is answered with error 3, as a real one answers it; a request with other fields
    /// than these three, with the invented error.
    private func stationPage(_ object: [String: Any], _ id: Int) -> HTTPResponse {
        guard let sent = Self.parameter(of: object), Set(sent.keys) == ["source", "stIdx", "cnt"],
              let source = sent["source"] as? String, let from = sent["stIdx"] as? Int, from >= 0,
              let count = sent["cnt"] as? Int, count > 0 else { return refused(id) }
        guard source.hasPrefix("tv:"), Self.schemes.contains(String(source.dropFirst("tv:".count))) else {
            return json(["error": [3, "no such source"], "id": id])
        }
        let page = stations.filter { "tv:\($0.scheme)" == source }.enumerated()
            .dropFirst(from).prefix(min(count, 50))
        return json(["result": [page.map { $0.element.fields(at: $0.offset) }], "id": id])
    }

    /// What a create and the question before it both say of a reservation. The title has to be there and is
    /// not kept: what is made is listed under the television's own.
    private typealias Asked = (station: Station, title: String, start: Date, durationSec: Int, repeatType: String)

    /// What a body says of a reservation, when it has just the fields in `keys`. Nil unless each is as a real
    /// one has been sent it: a uri that is one of this television's stations' to the letter, a title, the
    /// start in the television's own spelling, the length as a number, and a repeat it takes. Whether the
    /// repeat suits the programme's day, and whether the household is subscribed to the station, are not
    /// looked at here: a real one answered the question whichever, and refused the create (`make`).
    private func reservation(in sent: [String: Any], keys: Set<String>) -> Asked? {
        guard Set(sent.keys) == keys, let uri = sent["uri"] as? String,
              let station = stations.first(where: { $0.uri.unicodeScalars.elementsEqual(uri.unicodeScalars) }),
              let title = sent["title"] as? String,
              let start = (sent["startDateTime"] as? String).flatMap(Self.startTime),
              let durationSec = sent["durationSec"] as? Int, durationSec > 0,
              let repeatType = sent["repeatType"] as? String, Self.repeatTypes.contains(repeatType) else {
            return nil
        }
        return (station, title, start, durationSec, repeatType)
    }

    /// The question of what a reservation would stop from recording, asked as a real one has been asked it:
    /// the five fields and no others. Its answer is the recordings that would lose to it (`pushedOut`), each
    /// in the seven fields a real one named a row with, and an empty list when none would. It changes
    /// nothing, and never names a viewing reservation: a real one did not name the one that read
    /// `partlyOverlapped` once the reservation asked about was made.
    private func wouldPushOut(_ object: [String: Any], _ id: Int) -> HTTPResponse {
        let keys: Set = ["uri", "title", "startDateTime", "durationSec", "repeatType"]
        guard let sent = Self.parameter(of: object), let asked = reservation(in: sent, keys: keys) else {
            return refused(id)
        }
        let reads = schedules
        let losers = Self.pushedOut(by: Slot(from: asked.start, durationSec: asked.durationSec), among: reads,
                                    at: Array(reads.indices))
        return json(["result": [losers.map { reads[$0].named }], "id": id])
    }

    /// Makes a recording, for a create written as a real one has been sent it and no other way: the five
    /// fields of the question, `type` saying `recording` and the programme's id as decimal text, seven and no
    /// others -- no mode among them. Anything else is answered with the invented error, and nothing is made.
    /// So is any create while the disk is away (`unmount`). What a test has said the next create comes to
    /// (`atTheNextCreate`) is done in place of the rest (`make`), once.
    private func add(_ object: [String: Any], _ id: Int) throws -> HTTPResponse {
        let keys: Set = ["type", "uri", "title", "startDateTime", "durationSec", "repeatType", "eventId"]
        guard let sent = Self.parameter(of: object), let asked = reservation(in: sent, keys: keys),
              sent["type"] as? String == "recording", let programme = sent["eventId"] as? String,
              !programme.isEmpty, programme.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let eventId = Int(programme), mounted else { return refused(id) }
        let once = nextCreate
        nextCreate = nil
        switch once {
        case .answered(let code)?:
            return json(["error": [code, "as it was told to answer"], "id": id])
        case .answeredAndNotKept?:
            return ok(#"[{"annotation":0}]"#, id)
        case .carriedOutAndNotAnswered?:
            _ = make(asked, eventId: eventId, id)
            throw RecorderError.transport("The request timed out.")
        case nil:
            return make(asked, eventId: eventId, id)
        }
    }

    /// What a create comes to once it is written as it should be, as a real one answered the app's own:
    ///
    /// - On a station the household is not subscribed to, and with a weekly repeat that is not the code of
    ///   the start's weekday, it is error 7 and nothing is made. Seen: two such stations, of two kinds of
    ///   broadcast; and Tuesday's code on a Monday's programme, where Monday's was taken.
    /// - The same station, start and programme a second time is error 41222, whatever the repeat, and the
    ///   first stays the only one. A viewing reservation for the programme does not stand in the way: a real
    ///   one took a recording of a programme it held a viewing reservation for.
    /// - Anything else is taken, answered with `annotation` 0 and no id, and listed in DR, under a number of
    ///   its own (`numbered`) and under a title of the television's own (`title(ofProgramme:)`), never the
    ///   one sent. It is taken as well when it costs another reservation its recording, which the list then
    ///   shows (`schedules`).
    ///
    /// Taken, not seen: that the weekday is the start's by the calendar in Japan, a start before four in the
    /// morning included, which a guide counts to the day before -- no real one has been sent a weekly repeat
    /// for one; that Monday to Friday and Monday to Saturday are taken on any day, as they were on a
    /// Monday's programme; that error 7 comes before 41222 where both would; and that a create whose start
    /// has passed is taken as any other is. This one has no clock and does not tell such a create from one
    /// still ahead: what a real one answers it, and does on getting it while switched off, has not been
    /// seen yet.
    private func make(_ asked: Asked, eventId: Int, _ id: Int) -> HTTPResponse {
        let station = asked.station
        guard station.subscribed, Self.suitsItsDay(asked.repeatType, start: asked.start) else {
            return json(["error": [7, "not to be reserved"], "id": id])
        }
        let there = held.contains { schedule in
            schedule.type == "recording" && schedule.uri.unicodeScalars.elementsEqual(station.uri.unicodeScalars)
                && schedule.start == asked.start && schedule.eventId == eventId
        }
        guard !there else { return json(["error": [41222, "already scheduled"], "id": id]) }
        numbered += 1
        let schedule = Schedule(id: "recording.\(numbered)", scheme: station.scheme, serviceID: station.serviceID,
                                station: station.name, title: Self.title(ofProgramme: eventId),
                                start: asked.start, durationSec: asked.durationSec,
                                repeatType: asked.repeatType, eventId: eventId)
        held.append(schedule)
        made.insert(schedule.id)
        return ok(#"[{"annotation":0}]"#, id)
    }

    /// The weekly codes by the day of the week as a calendar counts it, from Sunday. Monday's is `w1`: a real
    /// one took `w1` and refused `w2` for a Monday's programme, and took `w7` for a Sunday's and `w4` for a
    /// Thursday's. The other four are taken to run on in order. Written here as a table, and not as the
    /// client works a code out: a television that shared that could not catch the client working it out wrong.
    private static let weekly = ["w7", "w1", "w2", "w3", "w4", "w5", "w6"]

    /// Whether a repeat can be the repeat of a programme that starts at `start`: a weekly code only when it
    /// is the code of that day in Japan, anything else always.
    private static func suitsItsDay(_ repeatType: String, start: Date) -> Bool {
        guard weekly.contains(repeatType) else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        return weekly[calendar.component(.weekday, from: start) - 1] == repeatType
    }

    /// The title this television lists a reservation of a programme under. A real one listed every
    /// reservation that followed a programme under a title of its own for the programme and not under the
    /// one it was sent: so a row is not to be found again by the title it was made with. A real one's comes
    /// from its guide; this one has no guide, and makes the title of the programme's id, with an ideographic
    /// space and an enclosed character in it, both of which a real one's titles were seen to have and a
    /// delete has to send back as they are.
    public static func title(ofProgramme eventId: Int) -> String {
        "サンプル番組\u{3000}\(eventId)\u{1F211}"
    }

    /// A client it lists gets a new cookie, in standby as well, and the ones given before stay good. One it does
    /// not list is answered 401 while the display is on, as the real one answers while it shows its PIN, and is
    /// registered by the request that carries the PIN. In standby nothing is shown: such a client is turned down
    /// with error 40005 and no cookie, as the real one turns down a request with nothing on it -- and, it is
    /// taken, one with a PIN, which has not been tried.
    private func register(_ object: [String: Any], _ request: HTTPRequest, _ id: Int) -> HTTPResponse {
        let clientID = ((object["params"] as? [Any])?.first as? [String: Any])?["clientid"] as? String ?? ""
        if !registered.contains(clientID) {
            guard power == "active" else {
                return HTTPResponse(statusCode: 200, body: Data(#"{"error":[40005,"display off"],"id":\#(id)}"#.utf8))
            }
            guard request.headers["Authorization"] == "Basic " + Data(":\(Self.pin)".utf8).base64EncodedString() else {
                return HTTPResponse(statusCode: 401)
            }
            registered.insert(clientID)
        }
        issued += 1
        let value = "invented-\(issued)"
        cookies.insert(value)
        return HTTPResponse(statusCode: 200, body: Data(#"{"result":[],"id":\#(id)}"#.utf8),
                            headers: ["Set-Cookie": "auth=\(value); Path=/sony/; Max-Age=1209600"])
    }

    /// The order a real one was seen to list them in: what it is to record, the newest first by its
    /// numbering. The one reminder ever seen on a real one came after those, and here every reminder does.
    private var listed: [Schedule] {
        let newestFirst = schedules.sorted { $0.number > $1.number }
        return newestFirst.filter { $0.type == "recording" } + newestFirst.filter { $0.type != "recording" }
    }

    /// Takes off the row whose six fields are all as they were sent, and answers anything else as a real one
    /// answers a row it does not have: HTTP 200 and error 41200. That is stricter than a real one, which has
    /// only been seen to go by the id -- it has never been sent a right id with another field wrong, so what
    /// it makes of one is not known. Here a client that sends anything but the row as it read it is caught:
    /// the texts are held scalar against scalar, since two spellings of one title are equal as strings and
    /// are not the same bytes. One row to a request, as the app sends them.
    private func delete(_ object: [String: Any], _ id: Int) -> HTTPResponse {
        let sent = (((object["params"] as? [Any])?.first as? [Any])?.first as? [String: Any]) ?? [:]
        func sentAs(_ field: String, _ held: String) -> Bool {
            (sent[field] as? String).map { $0.unicodeScalars.elementsEqual(held.unicodeScalars) } ?? false
        }
        let found = held.firstIndex { schedule in
            sentAs("id", schedule.id) && sentAs("startDateTime", schedule.startDateTime)
                && sentAs("title", schedule.title) && sent["durationSec"] as? Int == schedule.durationSec
                && sentAs("type", schedule.type) && sentAs("uri", schedule.uri)
        }
        guard let found else { return json(["error": [41200, "no such schedule"], "id": id]) }
        made.remove(held.remove(at: found).id)
        return json(["result": [Any](), "id": id])
    }

    private func ok(_ result: String, _ id: Int) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"result":\#(result),"id":\#(id)}"#.utf8))
    }

    /// An answer whose values have to be escaped: titles and station names are whatever was put.
    private func json(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}
