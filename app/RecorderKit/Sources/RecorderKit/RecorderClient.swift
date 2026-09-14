import Foundation

/// One recorder on the LAN. Every request goes through a serial queue because the recorder answers 503 to
/// concurrent calls, so hold on to a single client per device rather than making one per request.
public actor RecorderClient {
    public let host: String
    public let upnpPort: Int
    /// Where the EPG and logo files are served. Confirmed from the DLNA tree on first contact.
    public private(set) var streamPort: Int
    public private(set) var info: RecorderDescription?

    private let transport: any HTTPTransport
    private let queue = SerialQueue()
    private var streamPortConfirmed: Bool

    private static let soapTimeout: TimeInterval = 30
    private static let fileTimeout: TimeInterval = 120

    public init(host: String, transport: any HTTPTransport = URLSessionTransport(),
                upnpPort: Int = Upnp.port, streamPort: Int? = nil) {
        self.host = host
        self.upnpPort = upnpPort
        self.transport = transport
        self.streamPort = streamPort ?? Upnp.defaultStreamPort
        self.streamPortConfirmed = streamPort != nil
    }

    // MARK: - identity

    /// Reads `description.xml`, which is also how a candidate found by a scan is confirmed to be a recorder.
    @discardableResult
    public func describe(via: String = "manual") async throws -> RecorderDescription {
        let response = try await send(HTTPRequest(url: url(port: upnpPort, path: "/description.xml"),
                                                  timeout: Self.soapTimeout))
        guard response.statusCode == 200,
              let described = Discovery.parseDescription(response.text, host: host, port: upnpPort,
                                                         location: url(port: upnpPort, path: "/description.xml").absoluteString,
                                                         via: via)
        else { throw RecorderError.notARecorder(host: host) }
        info = described
        if !streamPortConfirmed { _ = try? await detectStreamPort() }
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
        let answer = try await resultText(Upnp.xsrsControlURL, Upnp.xsrsService, "X_GetTitleList",
                                          [("SearchCriteria", "recordDestinationID=HDD"), ("StartingIndex", "\(start)"),
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

    /// Wakes the recorder out of network standby. `PowerOn` and `On` do not work, only `on`.
    @discardableResult
    public func powerOn() async throws -> String {
        try XmlNode.parse(try await pvr("X_PowerControl", [("Operation", "on")]))
            .firstDescendantText("powerstatus") ?? ""
    }

    /// Playback on the television attached to the recorder. `pause` toggles, so it resumes as well; `play`
    /// with a position restarts from the beginning. The recorder has to be fully on.
    public func playControl(titleID: String, operation: String, position: Int = 0) async throws {
        _ = try await call(Upnp.pvrControlURL, Upnp.pvrService, "X_PlayControlTitle",
                           [("TitleID", titleID), ("Operation", operation), ("Position", "\(position)")])
    }

    public func liveChannelIDs(broadcastingType: Int) async throws -> [Int] {
        let root = try XmlNode.parse(try await pvr("X_GetLiveChList",
                                                   [("BroadcastType", "\(broadcastingType)"), ("SkipChannel", "0")]))
        let list = root.firstDescendantText("channelList") ?? ""
        return list.split(separator: "_").compactMap { Int($0) }
    }

    /// Capacity of a recording destination, in bytes.
    public func recordDestinationInfo(destination: String = "HDD") async throws -> (totalBytes: Int, freeBytes: Int) {
        let root = try await call(Upnp.contentDirectoryControlURL, Upnp.contentDirectoryService,
                                  "X_HDLnkGetRecordDestinationInfo", [("RecordDestinationID", destination)])
        guard let text = root.firstDescendantText("RecordDestinationInfo"),
              let info = try? XmlNode.parse(text) else { return (0, 0) }
        return (Int(info.attributes["totalCapacity"] ?? "") ?? 0, Int(info.attributes["availableCapacity"] ?? "") ?? 0)
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
    func guideFileURL(named name: String) -> URL {
        URL(string: "http://\(host):\(streamPort)//\(name)")!
    }

    private func guideFile(named name: String) async throws -> Data? {
        if let info, !info.epgCapable { return nil }
        let response = try await send(HTTPRequest(url: guideFileURL(named: name), timeout: Self.fileTimeout))
        switch response.statusCode {
        case 200: return response.body
        case 404, 416: return nil
        default: throw RecorderError.badResponse(status: response.statusCode)
        }
    }

    // MARK: - plumbing

    private func url(port: Int, path: String) -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let transport = self.transport
        return try await queue.run { try await transport.send(request) }
    }

    /// One SOAP call. Throws when the recorder answers a fault, which it does with an HTTP 500 and an
    /// `errorCode` in the body.
    private func call(_ controlPath: String, _ service: String, _ action: String,
                      _ arguments: [(String, String)] = []) async throws -> XmlNode {
        let request = HTTPRequest(url: url(port: upnpPort, path: controlPath), method: "POST",
                                  headers: Soap.headers(service: service, action: action),
                                  body: Data(Soap.body(service: service, action: action, arguments: arguments).utf8),
                                  timeout: Self.soapTimeout)
        let response = try await send(request)
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
