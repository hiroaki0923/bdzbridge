import Foundation

/// One recorder on the LAN. Every request goes through a serial queue because the recorder answers 503 to
/// concurrent calls, so hold on to a single client per device rather than making one per request.
public actor RecorderClient {
    /// Readable without waiting on the actor: it never changes, and a caller deciding whether this is the
    /// client for the address it wants should not have to give up its turn to find out.
    public nonisolated let host: String
    public let upnpPort: Int
    /// Where the EPG and logo files are served. Confirmed from the DLNA tree on first contact.
    public private(set) var streamPort: Int
    public private(set) var info: RecorderDescription?
    /// When the recorder last answered anything at all. A fault counts: only a recorder that is up can
    /// refuse something. Nil until the first answer.
    ///
    /// A BDZ-FBT4100 leaves the network after a quarter of an hour or so with nothing asked of it, and then
    /// says nothing, so how long it has been quiet is what tells a caller whether to make sure it is still
    /// there before asking it for something -- rather than finding out from a thirty-second timeout.
    /// Recorded here, where every request passes, so that no answer is missed whoever asked for it.
    public private(set) var lastAnswer: Date?

    private let transport: any HTTPTransport
    private let queue = SerialQueue()
    /// How long to wait, in seconds, before sending again what the recorder answered 503 to. See `send`.
    private let busyRetryDelay: ClosedRange<Double>
    /// How many times a request answered 503 is sent again before the 503 is thrown.
    static let busyRetries = 2
    private var streamPortConfirmed: Bool
    /// Whether the DLNA tree has already been walked looking for the port. A tree that gives nothing away
    /// leaves `streamPortConfirmed` false, and asking again for every one of the eight guide files would
    /// cost eight fruitless walks, so it is asked once per client and the default stands after that.
    private var streamPortTried = false

    private static let soapTimeout: TimeInterval = 30
    private static let fileTimeout: TimeInterval = 120
    /// Long enough for a recorder that is there, short enough not to sit through a recorder that is not.
    /// A recorder off the network does not refuse a connection, it says nothing at all, so this is the
    /// whole wait before the caller can conclude it has gone.
    public static let probeTimeout: TimeInterval = 5

    /// While waiting for a recorder to come back from a magic packet. It answers in milliseconds once it is
    /// up, so a long timeout only makes the app notice late: with this, each look costs at most two seconds
    /// and the waking is seen almost as soon as it happens.
    public static let wakeProbeTimeout: TimeInterval = 2

    public init(host: String, transport: any HTTPTransport = URLSessionTransport(),
                upnpPort: Int = Upnp.port, streamPort: Int? = nil, busyRetryDelay: ClosedRange<Double> = 0.5...1) {
        self.host = host
        self.upnpPort = upnpPort
        self.transport = transport
        self.busyRetryDelay = busyRetryDelay
        self.streamPort = streamPort ?? Upnp.defaultStreamPort
        self.streamPortConfirmed = streamPort != nil
    }

    // MARK: - identity

    /// Reads `description.xml`, which is also how a candidate found by a scan is confirmed to be a recorder.
    ///
    /// One request, and a short `timeout` really does bound it: finding the port the guide files are served
    /// on used to happen here, and that is a walk of up to eight SOAP browses which the timeout given here
    /// never reached. On a recorder that had just woken -- or over a VPN -- a probe meant to cost two seconds
    /// cost minutes, which is what made waking look as though it had hung. The walk now happens where its
    /// answer is needed, in `guideFile`.
    ///
    /// A 503 is the recorder busy, not something else at its address: it is thrown as `busy` (see `send`).
    /// Read as any other answer that was not a description, it had the app say the recorder was not a Sony
    /// recorder, while it was answering somebody else.
    @discardableResult
    public func describe(via: String = "manual", timeout: TimeInterval? = nil) async throws
        -> RecorderDescription {
        let location = try url(port: upnpPort, path: "/description.xml")
        let response = try await send(HTTPRequest(url: location, timeout: timeout ?? Self.soapTimeout),
                                      asking: "description.xml")
        guard response.statusCode == 200,
              let described = Discovery.parseDescription(response.text, host: host, port: upnpPort,
                                                         location: location.absoluteString, via: via)
        else { throw RecorderError.notARecorder(host: host) }
        info = described
        return described
    }

    /// Walks the DLNA tree until an item carries a `<res>` URL; its port is where the guide files live.
    /// Keeps the current port when the tree gives nothing away.
    @discardableResult
    public func detectStreamPort(maxRequests: Int = 8) async throws -> Int {
        var queue = ["0"]
        var requests = 0
        while let objectID = queue.first, requests < maxRequests {
            queue.removeFirst()
            requests += 1
            let didl = try await browseChildren(objectID: objectID)
            guard let root = try? XmlNode.parse(didl) else { continue }
            for res in root.descendants("res") {
                if let port = URL(string: res.text.trimmingCharacters(in: .whitespacesAndNewlines))?.port {
                    streamPort = port
                    streamPortConfirmed = true
                    return port
                }
            }
            queue += root.descendants("container").compactMap { $0.attributes["id"] }
        }
        return streamPort
    }

    // MARK: - reservations

    public func reservations(count: Int = 200) async throws -> [Reservation] {
        let result = try await resultText(Upnp.xsrsControlURL, Upnp.xsrsService, "X_GetRecordScheduleList",
                                          [("SearchCriteria", ""), ("StartingIndex", "0"), ("RequestedCount", "\(count)"),
                                           ("SortCriteria", "-scheduledStartDateTime"), ("Filter", "*")]).result
        return try XsrsParse.items(inResult: result).compactMap(XsrsParse.reservation)
    }

    /// Reservations that would clash with this one; the payload is the same as for creating it.
    public func conflicts(elements: String) async throws -> [Reservation] {
        let result = try await resultText(Upnp.xsrsControlURL, Upnp.xsrsService, "X_GetConflictList",
                                          [("Elements", elements)]).result
        return try XsrsParse.items(inResult: result).compactMap(XsrsParse.reservation)
    }

    /// Creates a reservation and returns its id.
    @discardableResult
    public func createReservation(_ request: ReservationRequest) async throws -> String {
        try await createReservation(elements: XsrsElements.create(request))
    }

    @discardableResult
    public func createReservation(elements: String) async throws -> String {
        let root = try await call(Upnp.xsrsControlURL, Upnp.xsrsService, "X_CreateRecordSchedule",
                                 [("Elements", elements)])
        return root.firstDescendantText("RecordScheduleID") ?? ""
    }

    /// Changes quality or repeat in place; the payload is the create item with its id filled in.
    public func updateReservation(id: String, _ request: ReservationRequest) async throws {
        _ = try await call(Upnp.xsrsControlURL, Upnp.xsrsService, "X_UpdateRecordSchedule",
                           [("Elements", XsrsElements.update(id: id, request))])
    }

    public func deleteReservation(id: String) async throws {
        _ = try await call(Upnp.xsrsControlURL, Upnp.xsrsService, "X_DeleteRecordSchedule",
                           [("RecordScheduleID", id)])
    }

    // MARK: - recordings

    public func titles(count: Int = 200, startingAt start: Int = 0) async throws -> [RecordedTitle] {
        try await titlePage(count: count, start: start).titles
    }

    /// Every recording, newest first. One call returns at most 200, so this follows `TotalMatches`.
    public func allTitles(pageSize: Int = 200) async throws -> [RecordedTitle] {
        var all: [RecordedTitle] = []
        var start = 0
        while true {
            let page = try await titlePage(count: pageSize, start: start)
            all += page.titles
            start += page.count
            if page.count == 0 || start >= page.total { return all }
        }
    }

    private func titlePage(count: Int, start: Int) async throws -> (titles: [RecordedTitle], count: Int, total: Int) {
        // No SearchCriteria: the official client sends none for the internal disk, and only
        // `recordDestinationID="USBHDD"` (no spaces, quoted) when listing a USB one. A criteria the
        // recorder cannot parse silently matches everything, so an "HDD" filter written any other way was
        // never doing anything either (docs/upnp/service-sweep.md).
        let answer = try await resultText(Upnp.xsrsControlURL, Upnp.xsrsService, "X_GetTitleList",
                                          [("SearchCriteria", ""),
                                           ("StartingIndex", "\(start)"),
                                           ("RequestedCount", "\(count)"), ("SortCriteria", "-scheduledStartDateTime"),
                                           ("Filter", "*")])
        let items = try XsrsParse.items(inResult: answer.result)
        return (items.compactMap(XsrsParse.title), items.count, Int(answer.totalMatches ?? "") ?? 0)
    }

    /// Renames a recording or changes its protect / new flag. Send only what should change.
    public func updateTitle(id: String, title: String? = nil, protected: Bool? = nil, isNew: Bool? = nil) async throws {
        _ = try await call(Upnp.xsrsControlURL, Upnp.xsrsService, "X_UpdateTitle",
                           [("Elements", XsrsElements.titleUpdate(id: id, title: title, protected: protected,
                                                                  isNew: isNew))])
    }

    /// Deletes a recording. The recorder refuses protected ones, but answers success for an id it does not
    /// know, so check the recording exists first if that matters.
    public func deleteTitle(id: String) async throws {
        _ = try await call(Upnp.xsrsControlURL, Upnp.xsrsService, "X_DeleteTitle", [("TitleID", id)])
    }

    /// The programme description stored with a recording. Also the cheapest way to tell whether an id exists:
    /// an unknown one answers with UPnP error 820.
    public func titleDetail(id: String) async throws -> (summary: String, details: [String]) {
        let root = try XmlNode.parse(try await pvr("X_GetTitleDetail", [("Id", id)]))
        var summary = ""
        var details: [String] = []
        for child in root.children {
            let text = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if child.name == "summary" {
                summary = text
            } else if child.name.hasPrefix("detail") {
                details.append(text)
            }
        }
        return (summary, details)
    }

    // MARK: - the box itself

    public func playStatus() async throws -> [String: String] {
        let root = try XmlNode.parse(try await pvr("X_GetPlayStatus"))
        return Dictionary(root.children.map { ($0.name, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    public func firmwareVersion() async throws -> String {
        try XmlNode.parse(try await pvr("X_GetFirmwareVersion")).firstDescendantText("version") ?? ""
    }

    /// The recorder's own network settings. `macAddress` is the wired side and is what a magic packet has
    /// to be addressed to; `wireless` is the Wi-Fi side. Worth reading while the recorder is answering,
    /// because it is the only way an iOS app can learn the address to wake it at later: ARP is off limits.
    public func networkSettings() async throws -> NetworkSettings {
        let root = try XmlNode.parse(try await pvr("X_GetPrivateIp"))
        return NetworkSettings(mac: root.firstDescendantText("macAddress") ?? "",
                               wireless: root.firstDescendantText("wirelessMacAddress") ?? "",
                               address: root.firstDescendantText("ipAddress") ?? "",
                               usesDhcp: root.firstDescendantText("useDhcp") == "1")
    }

    /// Wakes the recorder out of network standby. `PowerOn` and `On` do not work, only `on`.
    @discardableResult
    public func powerOn() async throws -> String {
        try XmlNode.parse(try await pvr("X_PowerControl", [("Operation", "on")]))
            .firstDescendantText("powerstatus") ?? ""
    }

    /// Playback on the television attached to the recorder. `pause` toggles, so it resumes as well; `play`
    /// starts from the beginning whatever position is given. The recorder has to be fully on: in network
    /// standby it answers 880.
    public func playControl(titleID: String, operation: String, position: Int = 0) async throws {
        _ = try await call(Upnp.pvrControlURL, Upnp.pvrService, "X_PlayControlTitle",
                           [("TitleID", titleID), ("Operation", operation), ("Position", "\(position)")])
    }

    /// Plays a recording on the television, turning the recorder on first if it is in network standby --
    /// which is how it is usually found, since it keeps answering the LAN in standby and is only switched on
    /// to be watched. Answered with 880, the play used to end there, and the reader had to turn the recorder
    /// on, wait without being told for how long, and ask again.
    ///
    /// Only an 880 turns it on. The power state is not asked first: that would be one request more on every
    /// play of a recorder that is already on, and the demo's recorder, which never answers 880, does not
    /// report a power state at all. Once it has been told to come on, `X_GetPlayStatus` is asked every
    /// `interval` until `powerstatus` says `PowerOn`, and the play is sent again. After `limit` it is sent
    /// regardless, and a recorder still in standby answers it with 880, which is thrown to the caller.
    ///
    /// `waiting` is told how many seconds the wait has lasted, each time round, for the screen to say: the
    /// recorder and the television coming on take long enough to look like nothing is happening.
    public func play(titleID: String, limit: TimeInterval = RecorderClient.powerOnLimit,
                     interval: Duration = .seconds(1), waiting: @Sendable (Int) async -> Void) async throws {
        do {
            try await playControl(titleID: titleID, operation: "play")
            return
        } catch let error as RecorderError where error.needsPowerOn {}
        try await powerOn()
        let started = Date()
        while Date().timeIntervalSince(started) < limit {
            await waiting(Int(Date().timeIntervalSince(started)))
            try await Task.sleep(for: interval)
            if try await playStatus()["powerstatus"] == "PowerOn" { break }
        }
        try await playControl(titleID: titleID, operation: "play")
    }

    /// How long `play` waits for a recorder in standby to come on. How long a BDZ-FBT4100 takes has not been
    /// timed, so this is as generous as the wait for a magic packet; the wait ends as soon as it says it is on.
    public static let powerOnLimit: TimeInterval = 30

    // MARK: - the recorder's own keyword conditions (おまかせ・まる録)

    /// Filter must be "*": unlike the title and reservation lists this one honours it, and an empty one drops
    /// the quality and the destination without a word.
    public func recorderRules() async throws -> [RecorderRule] {
        let result = try await pvr("X_GetPrefRecSettingList",
                                   [("SearchCriteria", ""), ("Filter", "*"), ("StartingIndex", "0"),
                                    ("RequestedCount", "200"), ("SortCriteria", ""), ("Format", "")])
        return try XsrsParse.objects(inResult: result).map(XsrsParse.recorderRule)
    }

    /// Answers with the new condition's id. The recorder renumbers a condition whenever its own screen edits it.
    public func createRecorderRule(_ request: RecorderRuleRequest) async throws -> String {
        let root = try await call(Upnp.pvrControlURL, Upnp.pvrService, "X_CreatePrefRecSetting",
                                  [("Elements", XsrsElements.recorderRule(request)), ("Format", "")])
        return root.firstDescendantText("SearchSettingID") ?? ""
    }

    public func deleteRecorderRule(id: String) async throws {
        _ = try await call(Upnp.pvrControlURL, Upnp.pvrService, "X_DeletePrefRecSetting", [("SearchSettingID", id)])
    }

    public func liveChannelIDs(broadcastingType: Int) async throws -> [Int] {
        let root = try XmlNode.parse(try await pvr("X_GetLiveChList",
                                                   [("BroadcastType", "\(broadcastingType)"), ("SkipChannel", "0")]))
        let list = root.firstDescendantText("channelList") ?? ""
        return list.split(separator: "_").compactMap { Int($0) }
    }

    /// Capacity of a recording destination, in bytes.
    ///
    /// An answer without both numbers in it is thrown as `unexpectedAnswer`. It used to be read as nothing
    /// of either, which is a full disk: 残り 0.0 GB on screen, and a warning that the recorder was running out
    /// of room, from a recorder that had only said it differently.
    public func recordDestinationInfo(destination: String = "HDD") async throws -> (totalBytes: Int, freeBytes: Int) {
        let action = "X_HDLnkGetRecordDestinationInfo"
        let root = try await call(Upnp.contentDirectoryControlURL, Upnp.contentDirectoryService, action,
                                  [("RecordDestinationID", destination)])
        guard let text = root.firstDescendantText("RecordDestinationInfo"),
              let info = try? XmlNode.parse(text),
              let total = info.attributes["totalCapacity"].flatMap({ Int($0) }),
              let free = info.attributes["availableCapacity"].flatMap({ Int($0) })
        else { throw RecorderError.unexpectedAnswer(action: action) }
        return (total, free)
    }

    /// Raw DIDL-Lite for a container's children.
    public func browseChildren(objectID: String, count: Int = 5,
                               controlPath: String = Upnp.contentDirectoryControlURL) async throws -> String {
        try await resultText(controlPath, Upnp.contentDirectoryService, "Browse",
                             [("ObjectID", objectID), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "*"),
                              ("StartingIndex", "0"), ("RequestedCount", "\(count)"), ("SortCriteria", "")]).result
    }

    // MARK: - guide files

    /// The raw EPG file for one broadcasting type, or nil when the recorder has no such channels, which it
    /// reports as HTTP 416.
    public func epgFile(_ broadcasting: String) async throws -> Data? {
        guard let name = Codes.epgFiles[broadcasting] else { return nil }
        return try await guideFile(named: name)
    }

    /// The guide for one broadcasting type, decoded. Nil when the recorder has no such channels.
    public func guide(_ broadcasting: String) async throws -> [GuideService]? {
        guard let file = try await epgFile(broadcasting) else { return nil }
        return try Epg.decode(file)
    }

    /// The station logos for one broadcasting type, decoded. The recorder rebuilds this file overnight, so a
    /// station whose logo has not been received yet is simply missing from the result.
    public func logos(_ broadcasting: String) async throws -> [StationLogo]? {
        guard let file = try await logoFile(broadcasting) else { return nil }
        return try LogoFile.decode(file)
    }

    public func logoFile(_ broadcasting: String) async throws -> Data? {
        guard let name = Codes.logoFiles[broadcasting] else { return nil }
        return try await guideFile(named: name)
    }

    /// The path really does start with two slashes; the media server does not answer otherwise.
    func guideFileURL(named name: String) throws -> URL {
        try url(port: streamPort, path: "//\(name)")
    }

    private func guideFile(named name: String) async throws -> Data? {
        if let info, !info.epgCapable { return nil }
        // The port is 60151 on every recorder seen so far, but it is asked for rather than assumed -- here,
        // where a guide file is actually wanted, and not on the way in.
        if !streamPortConfirmed, !streamPortTried {
            streamPortTried = true
            _ = try? await detectStreamPort()
        }
        let response = try await send(HTTPRequest(url: try guideFileURL(named: name), timeout: Self.fileTimeout),
                                      asking: name)
        switch response.statusCode {
        case 200: return response.body
        case 404, 416: return nil
        // Not `badResponse`: nothing here wanted XML, and saying so sent the reader looking for a fault
        // that was not there. The recorder has simply got no file to give yet.
        default: throw RecorderError.guideFileMissing(name: name, status: response.statusCode)
        }
    }

    // MARK: - plumbing

    /// Throws rather than crashing on an address no URL can be made of. The address is saved as soon as it
    /// is set and read again at every launch and by the overnight run, so a crash here was a crash for
    /// good. Thrown before anything is sent, and not as silence: nothing was asked, so a magic packet would
    /// answer nothing.
    private func url(port: Int, path: String) throws -> URL {
        guard let url = RecorderAddress.url(host: host, port: port, path: path) else {
            throw RecorderError.badAddress(host: host)
        }
        return url
    }

    /// Every request goes through here, one at a time.
    ///
    /// A 503 is the recorder busy with another request -- from the official app, another phone, or the
    /// overnight run's client beside the screens' -- and says nothing about this one, which it has not
    /// looked at. So it is sent again, up to `busyRetries` times, after a pause of half a second to a second:
    /// random, so that two clients that met are not in step when they ask again. Inside the queue, so that
    /// nothing else of this client's goes in between. A 503 after that is thrown as `busy`, naming `asking`:
    /// the callers read other statuses in their own ways, and every one of them read this one wrong -- as not
    /// a recorder, as a guide file not built yet, as an answer that was not XML.
    private func send(_ request: HTTPRequest, asking: String) async throws -> HTTPResponse {
        let transport = self.transport
        let delay = busyRetryDelay
        let response = try await queue.run {
            var response = try await transport.send(request)
            var retries = 0
            while response.statusCode == 503, retries < Self.busyRetries {
                retries += 1
                try await Task.sleep(for: .seconds(Double.random(in: delay)))
                response = try await transport.send(request)
            }
            return response
        }
        lastAnswer = Date()
        if response.statusCode == 503 { throw RecorderError.busy(action: asking) }
        return response
    }

    /// One SOAP call. Throws when the recorder answers a fault, which it does with an HTTP 500 and an
    /// `errorCode` in the body.
    private func call(_ controlPath: String, _ service: String, _ action: String,
                      _ arguments: [(String, String)] = []) async throws -> XmlNode {
        let request = HTTPRequest(url: try url(port: upnpPort, path: controlPath), method: "POST",
                                  headers: Soap.headers(service: service, action: action),
                                  body: Data(Soap.body(service: service, action: action, arguments: arguments).utf8),
                                  timeout: Self.soapTimeout)
        let response = try await send(request, asking: action)
        guard let root = try? XmlNode.parse(response.body) else {
            throw RecorderError.badResponse(status: response.statusCode)
        }
        let code = Soap.errorCode(in: root)
        if response.statusCode != 200 || code != nil {
            throw RecorderError.soap(action: action, status: response.statusCode, code: code,
                                     body: String(response.text.prefix(500)))
        }
        return root
    }

    private func resultText(_ controlPath: String, _ service: String, _ action: String,
                            _ arguments: [(String, String)] = []) async throws
        -> (result: String, totalMatches: String?) {
        let root = try await call(controlPath, service, action, arguments)
        return (root.firstDescendantText("Result") ?? "", root.firstDescendantText("TotalMatches"))
    }

    private func pvr(_ action: String, _ arguments: [(String, String)] = []) async throws -> String {
        let root = try await call(Upnp.pvrControlURL, Upnp.pvrService, action, arguments)
        return root.firstDescendantText("Result") ?? ""
    }
}
