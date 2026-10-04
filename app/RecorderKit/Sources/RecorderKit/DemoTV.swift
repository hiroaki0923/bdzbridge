import Foundation

/// An invented Sony BRAVIA: it answers the methods the app uses, in the shapes a real one gives them, and remembers
/// what it was told -- the clients registered with it, the cookies it gave out, the stations it receives, and
/// the reservations put on it or made on it by a request until they are deleted. For the tests of the package
/// and of the app, and for the demo, as `DemoRecorder` is for the recorder. Every value in it is invented.
///
/// Each request is put down in `calls` as its method and whether a cookie or a PIN came with it, which is what the
/// tests read: what was asked, never the cookie itself.
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
    /// What it is set to record and to remind of, in the order they were put or made.
    public private(set) var schedules: [Schedule] = []
    /// The stations it receives, in the order they were put: none until a test puts some.
    public private(set) var stations: [Station] = []
    /// The highest number anything it has held was listed under, a reminder included. What it makes is
    /// numbered one above, so a number is never given twice, whatever was deleted in between: a real one's
    /// ids were seen only to grow.
    private var numbered = 0
    public private(set) var calls: [String] = []

    public init(power: String = "standby", mac: String = DemoTV.mac) {
        self.power = power
        self.mac = mac
    }

    /// Says nothing from now on, as a television does that has left the network, or answers again.
    public func goSilent(_ value: Bool = true) { silent = value }
    /// Answers as another television would, with a MAC of its own.
    public func becomeAnother(mac: String) { self.mac = mac }

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

        /// The number in its id, which the list goes by: the newest reservation first.
        var number: Int { id.split(separator: ".").last.flatMap { Int($0) } ?? 0 }
    }

    /// Holds these and nothing else, as if they had been made on it with its remote.
    public func put(_ schedules: [Schedule]) {
        self.schedules = schedules
        numbered = max(numbered, schedules.map(\.number).max() ?? 0)
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

        public init(scheme: String = "isdbt", serviceID: Int = 1024, name: String = "サンプルテレビ",
                    programMediaType: String = "tv") {
            self.scheme = scheme
            self.serviceID = serviceID
            self.name = name
            self.programMediaType = programMediaType
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
            return ok(#"[[{"uri":"usb:recStorage","mounted":"mounted","wholeCapacityMB":1000,"freeCapacityMB":400}]]"#, id)
        case "getScheduleList":
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            return json(["result": [listed.map(\.fields)], "id": id])
        case "deleteSchedule":
            // A real one was seen to refuse the two reads above for their cookie. A write has not been sent
            // to one with a cookie it no longer takes: that it is refused the same way is taken, not seen.
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
            // As for a delete: that a create is refused for its cookie as the reads are is taken, not seen.
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            guard Self.asks(request, object, of: "recording", version: "1.1") else { return unknown(method, id) }
            return add(object, id)
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
    /// last station it answers an empty page: what a real one answers there has not been seen. A source that
    /// is no kind of broadcast is answered with error 3, as a real one answers it; a request with other
    /// fields than these three, with the invented error.
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

    /// What a create and the question before it both say of a reservation, read from a body with just the
    /// fields in `keys`. Nil unless each is as a real one has been sent it: a uri that is one of this
    /// television's stations' to the letter, a title, the start in the television's own spelling, the length
    /// as a number, and a repeat it takes. Whether the repeat suits the programme's day is not looked at.
    private func reservation(in sent: [String: Any], keys: Set<String>)
        -> (station: Station, title: String, start: Date, durationSec: Int, repeatType: String)? {
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
    /// the five fields and no others. Its answer is that nothing would be: which reservation loses to which
    /// is not played here.
    private func wouldPushOut(_ object: [String: Any], _ id: Int) -> HTTPResponse {
        let keys: Set = ["uri", "title", "startDateTime", "durationSec", "repeatType"]
        guard let sent = Self.parameter(of: object), reservation(in: sent, keys: keys) != nil else {
            return refused(id)
        }
        return ok("[[]]", id)
    }

    /// Makes a recording, for a create written as a real one has been sent it and no other way: the five
    /// fields of the question, `type` saying `recording` and the programme's id as decimal text, seven and no
    /// others -- no mode among them. Anything else is answered with the invented error, and nothing is made.
    ///
    /// The same station, start and programme a second time is answered with error 41222, whatever the repeat,
    /// as a real one answers it, and the first stays the only one. A reminder for the programme does not
    /// stand in the way: that is taken, not seen.
    ///
    /// What is made is listed in DR and under a number of its own (`numbered`); the answer names no
    /// reservation, as a real one's names none. Its title is kept as a real one keeps one, a half-width space
    /// made full-width: what was sent is not what is listed, and a row is not to be found again by it.
    private func add(_ object: [String: Any], _ id: Int) -> HTTPResponse {
        let keys: Set = ["type", "uri", "title", "startDateTime", "durationSec", "repeatType", "eventId"]
        guard let sent = Self.parameter(of: object), let asked = reservation(in: sent, keys: keys),
              sent["type"] as? String == "recording", let programme = sent["eventId"] as? String,
              !programme.isEmpty, programme.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let eventId = Int(programme) else { return refused(id) }
        let held = schedules.contains { schedule in
            schedule.type == "recording" && schedule.uri.unicodeScalars.elementsEqual(asked.station.uri.unicodeScalars)
                && schedule.start == asked.start && schedule.eventId == eventId
        }
        guard !held else { return json(["error": [41222, "already scheduled"], "id": id]) }
        numbered += 1
        schedules.append(Schedule(id: "recording.\(numbered)", scheme: asked.station.scheme,
                                  serviceID: asked.station.serviceID, station: asked.station.name,
                                  title: asked.title.replacingOccurrences(of: " ", with: "\u{3000}"),
                                  start: asked.start, durationSec: asked.durationSec,
                                  repeatType: asked.repeatType, eventId: eventId))
        return ok(#"[{"annotation":0}]"#, id)
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
        let held = schedules.firstIndex { schedule in
            sentAs("id", schedule.id) && sentAs("startDateTime", schedule.startDateTime)
                && sentAs("title", schedule.title) && sent["durationSec"] as? Int == schedule.durationSec
                && sentAs("type", schedule.type) && sentAs("uri", schedule.uri)
        }
        guard let held else { return json(["error": [41200, "no such schedule"], "id": id]) }
        schedules.remove(at: held)
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
