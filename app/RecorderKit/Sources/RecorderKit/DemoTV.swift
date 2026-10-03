import Foundation

/// An invented Sony BRAVIA: it answers the methods the app uses, in the shapes a real one gives them, and remembers
/// what it was told -- the clients registered with it, the cookies it gave out, and the reservations put on it
/// until they are deleted. For the tests of the package and of the app, and for the demo, as `DemoRecorder` is
/// for the recorder. Every value in it is invented.
///
/// Each request is put down in `calls` as its method and whether a cookie or a PIN came with it, which is what the
/// tests read: what was asked, never the cookie itself.
public actor DemoTV: HTTPTransport {
    /// Sony's OUI and the rest zeroed, as everywhere in this repository, with a last digit of its own.
    public static let mac = "f8:4e:17:00:00:0a"
    public static let model = "KJ-SAMPLE"
    public static let pin = "1234"

    /// `standby` or `active`. It shows its PIN, and so can be registered by one, only when active.
    public var power: String
    public private(set) var mac: String
    private var silent = false
    private var cookies: Set<String> = []
    private var registered: Set<String> = []
    private var issued = 0
    /// What it is set to record and to remind of, in the order they were put.
    public private(set) var schedules: [Schedule] = []
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

        /// The station's name goes in as it is, as a real one writes it. The network and the transport stream
        /// before the service are invented numbers, the same for every station.
        var uri: String { "tv:\(scheme)?trip=65534.65533.\(serviceID)&srvName=\(station)" }

        /// The start as a real one writes it: Japan's time, the offset with no colon.
        var startDateTime: String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = RecorderTime.timeZone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+0900'"
            return formatter.string(from: start)
        }

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
    public func put(_ schedules: [Schedule]) { self.schedules = schedules }

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
        case "actRegister":
            return register(object, request, id)
        default:
            return HTTPResponse(statusCode: 200, body: Data(#"{"error":[12,"\#(method)"],"id":\#(id)}"#.utf8))
        }
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
