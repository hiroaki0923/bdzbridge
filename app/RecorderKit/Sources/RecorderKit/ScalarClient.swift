import Foundation

/// What a television's registration leaves the app with: who the app is to the television, and the cookie it
/// was given. The client id is the secret of the two: anything on the LAN that knows a registered one can get a
/// cookie for it without a PIN, so it is kept like a password and never shown or logged.
public struct TVCredentials: Codable, Sendable, Equatable {
    public var clientID: String
    /// The value of the `auth` cookie, without its name.
    public var cookie: String?
    /// When the cookie arrived, by this device's clock: the television's answers carry no Date header, so its
    /// expiry is the arrival plus its Max-Age.
    public var cookieReceived: Date?
    public var cookieMaxAge: TimeInterval?

    public init(clientID: String, cookie: String? = nil, cookieReceived: Date? = nil, cookieMaxAge: TimeInterval? = nil) {
        self.clientID = clientID
        self.cookie = cookie
        self.cookieReceived = cookieReceived
        self.cookieMaxAge = cookieMaxAge
    }

    /// Whether the cookie is past half its life, when a connect renews it. The deadline is not a cliff -- a
    /// registered client gets a new cookie whenever it asks -- but a cookie that runs out leaves the overnight
    /// run, which never renews, with nothing to send with.
    public func renewalDue(now: Date) -> Bool {
        guard let cookieReceived, let cookieMaxAge else { return cookie != nil }
        return now.timeIntervalSince(cookieReceived) > cookieMaxAge / 2
    }
}

/// Where a television's credentials are kept: the Keychain in the app, memory in the tests. Read at every
/// request rather than held, so that a cookie one client renews is the one the next request of any client sends.
public protocol TVCredentialStore: Sendable {
    func load() -> TVCredentials?
    func save(_ credentials: TVCredentials)
    func remove()
}

/// Credentials that live as long as the store does: the tests', and the demo's, whose television is invented.
public final class MemoryTVCredentials: TVCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: TVCredentials?

    public init(_ credentials: TVCredentials? = nil) {
        kept = credentials
    }

    public func load() -> TVCredentials? { lock.withLock { kept } }
    public func save(_ credentials: TVCredentials) { lock.withLock { kept = credentials } }
    public func remove() { lock.withLock { kept = nil } }
}

/// What went wrong with a television, read as the rules read a device's failures (`DeviceFailure`).
public enum ScalarError: Error, Equatable, Sendable {
    /// Nothing answered: no route, refused, timed out.
    case transport(String)
    /// The saved address is not one a URL can be built on, so nothing was sent.
    case badAddress(host: String)
    /// An HTTP status other than the 200 every answer comes with, errors included. 401 is the registration's
    /// call for a PIN, 403 a request that needs a registration and carried none that works.
    case http(status: Int, method: String)
    /// The method's own error, `{"error": [code, message]}`, with the method and the version it came from:
    /// the same code means different things in different methods.
    case rpc(method: String, version: String, code: Int, message: String)
    /// An answer that is not the JSON the method gives.
    case unreadable(method: String)
    /// The device at the address says it is not a television.
    case notATelevision(host: String)
    /// Nothing is registered with the television, so nothing that needs a registration can be asked.
    case notRegistered

    /// What it means for the rules. Only the codes seen from the methods this app calls are told apart:
    /// 40005 (the television is off where the method needs it on), 41222 (the same programme reserved a second
    /// time) and 41200 (a reservation id the television no longer has). Any other code is not taken for a refusal
    /// of the request: an unknown answer holds nothing back for good. What a create's own codes say of a
    /// reservation is read where one is sent (`ScalarClient.refusals`): a code means that in that method alone.
    public var failure: DeviceFailure {
        switch self {
        case .transport: .silent
        case .badAddress: .badAddress
        case .http(401, _), .http(403, _), .notRegistered: .needsPairing
        case .http(503, _): .busy
        case .rpc(_, _, 40005, _): .needsPower
        case .rpc(_, _, 41222, _): .alreadyThere
        case .rpc(_, _, 41200, _): .unknownItem
        case .http, .rpc, .unreadable, .notATelevision: .unexpected(explanation)
        }
    }

    public var explanation: String {
        switch self {
        case .transport: "テレビに接続できませんでした。テレビの電源とネットワーク接続を確認してください"
        case .badAddress(let host): "「\(host)」はテレビのアドレスとして使えません"
        case .http(401, _), .http(403, _), .notRegistered:
            "テレビへの登録が必要です。設定の「テレビ」から登録してください"
        case .http(let status, let method): "テレビが HTTP \(status) を返しました (\(method))"
        case .rpc(_, _, 40005, _): "テレビの電源が入っていないため、操作できませんでした"
        case .rpc(let method, _, let code, _): "テレビがエラーを返しました (\(code): \(method))"
        case .unreadable(let method): "テレビの応答を読み取れませんでした (\(method))"
        case .notATelevision(let host): "\(host) はテレビとして応答しませんでした"
        }
    }
}

extension ScalarError: DeviceError {}

/// What a television says it is, without a registration.
public struct TVInterface: Sendable, Equatable {
    /// `tv` for a television.
    public var productCategory: String
    public var productName: String
    public var modelName: String
    public var interfaceVersion: String
}

/// What answers at an address given for a television, asked before anything is registered there.
public enum TVPresence: Equatable, Sendable {
    /// Nothing answered, or the address is not one a request can be sent to.
    case nothing
    /// Something answered that is not a television.
    case notATelevision
    /// A television, in standby: it shows its PIN only when it is on.
    case standby(model: String)
    case on(model: String)
}

/// What asking to be registered came to.
public enum TVEnrolment: Sendable, Equatable {
    /// The television wants its PIN, which it shows on its screen when it is showing a broadcast.
    case pinNeeded
    /// Registered, with the MAC it wakes on when it gave one, normalised.
    case registered(mac: String?)
    case failed(String)
}

/// The USB disk a television records to: mounted or not, and its space when it is.
public struct TVStorage: Sendable, Equatable {
    public var mounted: Bool
    public var freeMB: Int?
    public var totalMB: Int?
}

/// One Sony BRAVIA on the LAN, through its own control API: JSON-RPC over plain HTTP on port 80,
/// `POST /sony/<service>` with `{"method", "id", "params", "version"}`. Every answer comes back as HTTP 200, the
/// method's errors included, except 401 from the registration and 403 for a request without a working cookie.
///
/// One request at a time, as with the recorder: the television has been seen to answer several at once, but
/// the app has no need of more. The cookie is read from the store for each request and sent by
/// hand; the transport keeps none of its own (`URLSessionTransport.withoutCookies`).
public actor ScalarClient {
    public nonisolated let host: String
    /// When the television last answered anything, an error included.
    public private(set) var lastAnswer: Date?

    private let transport: any HTTPTransport
    private let credentials: any TVCredentialStore
    private let queue = SerialQueue()
    private var nextID = 1
    /// For a request with no timeout of its own. The television answers in a fraction of a second, in standby
    /// as well, so this is generous.
    static let timeout: TimeInterval = 10

    public init(host: String, transport: any HTTPTransport, credentials: any TVCredentialStore) {
        self.host = host
        self.transport = transport
        self.credentials = credentials
    }

    // MARK: - what needs no registration

    /// `standby` or `active`. Active is not the same as a lit screen.
    public func powerStatus(timeout: TimeInterval? = nil) async throws -> String {
        let result = try await call("system", "getPowerStatus", version: "1.0", timeout: timeout)
        guard let status = (result as? [[String: Any]])?.first?["status"] as? String else {
            throw ScalarError.unreadable(method: "getPowerStatus")
        }
        return status
    }

    public func interface(timeout: TimeInterval? = nil) async throws -> TVInterface {
        let result = try await call("system", "getInterfaceInformation", version: "1.0", timeout: timeout)
        guard let fields = (result as? [[String: Any]])?.first else {
            throw ScalarError.unreadable(method: "getInterfaceInformation")
        }
        return TVInterface(productCategory: fields["productCategory"] as? String ?? "",
                           productName: fields["productName"] as? String ?? "",
                           modelName: fields["modelName"] as? String ?? "",
                           interfaceVersion: fields["interfaceVersion"] as? String ?? "")
    }

    /// The MAC the television wakes on, which is also what tells it from any other: nil when it gives none.
    public func wakeOnLANAddress(timeout: TimeInterval? = nil) async throws -> String? {
        let result = try await call("system", "getSystemSupportedFunction", version: "1.0", timeout: timeout)
        guard let rows = (result as? [[[String: Any]]])?.first else {
            throw ScalarError.unreadable(method: "getSystemSupportedFunction")
        }
        return rows.first { $0["option"] as? String == "WOL" }?["value"] as? String
    }

    /// What is at the address: `getPowerStatus`, then `getInterfaceInformation`, neither of which needs a
    /// registration or changes anything on the television. Silence is nothing there, and so is an address
    /// nothing can be sent to. Whatever else goes wrong came from something that answered, and that is no
    /// television; nor is one that names another category than `tv`.
    public func presence(timeout: TimeInterval = 5) async -> TVPresence {
        do {
            let power = try await powerStatus(timeout: timeout)
            let television = try await interface(timeout: timeout)
            guard television.productCategory == "tv" else { return .notATelevision }
            return power == "standby" ? .standby(model: television.modelName) : .on(model: television.modelName)
        } catch let error as ScalarError where error.failure == .silent || error.failure == .badAddress {
            return .nothing
        } catch {
            return .notATelevision
        }
    }

    // MARK: - registration

    public enum Registration: Sendable, Equatable {
        /// A cookie came with the answer, and has been saved.
        case registered
        /// The television asked for its PIN (HTTP 401), which it shows on its screen when it can.
        case pinNeeded
    }

    /// `actRegister`, with nothing on it but the PIN when there is one. Unregistered, the television answers
    /// 401 and puts a PIN on its screen -- not always: whether it does depends on what the television is doing
    /// -- and the same request with the PIN registers. In standby it shows nothing and answers no 401: the
    /// request is turned down with error 40005, which is thrown as any error of a method is, and no cookie
    /// comes. Registered, it answers with a new cookie without a
    /// PIN, in standby as well, and the cookies given before stay good: which is why nothing else is sent, a
    /// cookie included -- a renewal carrying one ends it before its answer arrives, and a request already out
    /// with it would then be refused as if nothing had been registered.
    public func register(clientID: String, nickname: String, pin: String?) async throws -> Registration {
        guard let cookie = try await actRegister(clientID: clientID, nickname: nickname, pin: pin) else {
            return .pinNeeded
        }
        keep(cookie, for: clientID)
        return .registered
    }

    /// The steps of registering, and what each failure is said as: with no PIN at first, when the television
    /// answers by putting its PIN on its screen, and then with the PIN the reader read there, under the same
    /// client id. The MAC is read first, with the short `timeout`: it tells this television from any other
    /// afterwards, and reading it needs no registration, so a television that does not answer is found out
    /// before a PIN is asked for. Never throws: what went wrong is the sentence to show.
    ///
    /// `expecting` is the MAC of the television saved, nil when none is. Another television is refused before
    /// anything is asked to register, by the rule an attach tells a television from another by
    /// (`SessionState.recognition`): it would not be taken up once registered, and no PIN is to come up on a
    /// panel for a registration the app then refuses. A television that gives no MAC is taken for the one
    /// expected, as an attach takes it.
    public func enrol(clientID: String, nickname: String, pin: String?, expecting: String? = nil,
                      timeout: TimeInterval = 5) async -> TVEnrolment {
        do {
            let mac = try await wakeOnLANAddress(timeout: timeout).flatMap(WakeOnLan.normalise)
            let expected = expecting.map { WakeOnLan.normalise($0) ?? $0 }
            guard SessionState.recognition(of: mac ?? "", knownAs: expected) != .another else {
                return .failed(Self.anotherTelevision)
            }
            switch try await register(clientID: clientID, nickname: nickname, pin: pin) {
            case .pinNeeded: return .pinNeeded
            case .registered: return .registered(mac: mac)
            }
        } catch let error as any DeviceError {
            // Its display went off after it was found on: it shows no PIN then, and turns the request down.
            return .failed(error.failure == .needsPower ? Self.screenIsOff : error.explanation)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Said when a registration is turned down because the television shows nothing to read a PIN from.
    public static let screenIsOff = "テレビの画面が消えているため、登録できませんでした。"
        + "テレビの電源を入れて、放送を映してから、もう一度お試しください。"

    /// Said when the television at the address is not the one saved, and nothing was registered. "Answered as
    /// another" and not "is another": which MAC a television gives on Wi-Fi rather than a cable has not been
    /// seen, so the one saved may be refused after it moved from the one to the other.
    public static let anotherTelevision = "このアドレスの機器は、登録してあるテレビとは別のテレビとして応答しました。"
        + "別のテレビを使うときは、先に「テレビを外す」でいまのテレビを外してください。"

    /// A new cookie for the registration in the store: `register` with no PIN. Kept only while the store still
    /// holds that registration, so that one taken away while the request was out stays away. Whether it was kept.
    @discardableResult
    public func renew(nickname: String) async throws -> Bool {
        guard let clientID = credentials.load()?.clientID,
              let cookie = try await actRegister(clientID: clientID, nickname: nickname, pin: nil),
              credentials.load()?.clientID == clientID else { return false }
        keep(cookie, for: clientID)
        return true
    }

    /// The request itself: the cookie it was answered with, or nil when the television asked for its PIN.
    private func actRegister(clientID: String, nickname: String,
                             pin: String?) async throws -> (value: String, maxAge: TimeInterval?)? {
        var headers = ["Content-Type": "application/json"]
        if let pin {
            headers["Authorization"] = "Basic " + Data(":\(pin)".utf8).base64EncodedString()
        }
        let params: [Any] = [["clientid": clientID, "nickname": nickname, "level": "private"],
                             [["value": "no", "function": "WOL"]]]
        let response = try await send("accessControl", "actRegister", version: "1.0", params: params,
                                      headers: headers, timeout: nil)
        if response.statusCode == 401 { return nil }
        _ = try Self.result(of: response, method: "actRegister", version: "1.0")
        guard let cookie = response.header("Set-Cookie").flatMap(Self.authCookie) else {
            throw ScalarError.unreadable(method: "actRegister")
        }
        return cookie
    }

    private func keep(_ cookie: (value: String, maxAge: TimeInterval?), for clientID: String) {
        credentials.save(TVCredentials(clientID: clientID, cookie: cookie.value, cookieReceived: Date(),
                                       cookieMaxAge: cookie.maxAge))
    }

    /// The `auth` cookie of a `Set-Cookie` value, and its Max-Age. The Expires beside it is in a form of the
    /// television's own, and is not read.
    static func authCookie(_ header: String) -> (value: String, maxAge: TimeInterval?)? {
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, first.hasPrefix("auth=") else { return nil }
        let value = String(first.dropFirst("auth=".count))
        guard !value.isEmpty else { return nil }
        let maxAge = parts.first { $0.lowercased().hasPrefix("max-age=") }
            .flatMap { TimeInterval($0.dropFirst("max-age=".count)) }
        return (value, maxAge)
    }

    // MARK: - what needs a registration

    /// The USB disk: `usb:recStorage`. Version 1.1 only; 1.0 answers error 12.
    public func storage() async throws -> TVStorage {
        let result = try await authenticated("system", "getStorageList", version: "1.1",
                                             params: [["uri": "usb:recStorage"]])
        guard let row = (result as? [[[String: Any]]])?.first?.first else {
            throw ScalarError.unreadable(method: "getStorageList")
        }
        return TVStorage(mounted: row["mounted"] as? String == "mounted",
                         freeMB: row["freeCapacityMB"] as? Int, totalMB: row["wholeCapacityMB"] as? Int)
    }

    /// What the television is set to record, and the reminders to watch it lists among them, in its own
    /// order: the reservations were seen newest first, and the one reminder ever seen came after them, which
    /// says little of where reminders go. Version 1.1 only. One request for 130 rows, the most it is said to
    /// hold, and never a second: what `stIdx` counts from has not been measured. A row without what every row
    /// has is left out (`TVScheduleRow.init`), as the recorder's are.
    func schedules() async throws -> [TVScheduleRow] {
        let result = try await authenticated("recording", "getScheduleList", version: "1.1",
                                             params: [["stIdx": 0, "cnt": 130]])
        guard let rows = (result as? [Any])?.first as? [Any] else {
            throw ScalarError.unreadable(method: "getScheduleList")
        }
        return rows.compactMap { ($0 as? [String: Any]).flatMap { TVScheduleRow($0) } }
    }

    /// Takes a reservation off the television: the row as it was read (`TVScheduleRow.deletion`), in a list of
    /// its own inside the parameters. One row to a request is all that has ever been sent. One request removes
    /// a repeating reservation whole. A row the television no longer has is answered with error 41200, an id
    /// it never gave as well. Nothing is sent a second time for silence: the first may have arrived.
    func deleteSchedule(_ row: TVScheduleRow) async throws {
        _ = try await authenticated("recording", "deleteSchedule", version: "1.1", params: [[row.deletion]])
    }

    /// How many stations a page of the list is asked for: what a television has been seen to give in one
    /// answer of this version of the method.
    static let stationsToAPage = 50
    /// The most pages one list is read for: a thousand stations, more than any kind of broadcast has. A
    /// television whose pages did not move on with `stIdx` would otherwise be asked for ever.
    static let stationPages = 20

    /// The stations of one broadcasting type, in the television's order, read a page at a time: a page of
    /// fifty rows is followed by the one after it, and a shorter one ends the list.
    ///
    /// A page asked for past the end of a list is an empty one: a television answered no rows there. So a
    /// list whose last page is exactly fifty ends on the empty page after it, as any short page ends one,
    /// and an error is thrown like any other: none is the end of a list.
    ///
    /// Any failure on any page throws, and nothing is handed back of the pages read before it: a list cut
    /// short would say of every station after the cut that the television does not have it. A list that has
    /// not ended after `stationPages` is not one that was read, and throws as an answer that cannot be read.
    func stations(of broadcastingType: Int) async throws -> [TVStation] {
        try await stations(of: broadcastingType, after: stationPage(of: broadcastingType, from: 0))
    }

    /// The same list, read on from its first page: `first` is the page at nought, as `stationPage` gave it.
    /// For whoever has to tell a failure on the first page from one further on, and so asks for that page
    /// itself: the pages after it are asked for here, each once, by the rules above.
    func stations(of broadcastingType: Int,
                  after first: (stations: [TVStation], rows: Int)) async throws -> [TVStation] {
        var stations = first.stations
        var rows = first.rows
        var index = 0
        for _ in 1..<Self.stationPages {
            guard rows >= Self.stationsToAPage else { return stations }
            index += rows
            let page = try await stationPage(of: broadcastingType, from: index)
            stations += page.stations
            rows = page.rows
        }
        guard rows < Self.stationsToAPage else { throw ScalarError.unreadable(method: "getContentList") }
        return stations
    }

    /// One page of the stations of a broadcasting type, from the row at `index`: `avContent.getContentList`
    /// 1.0 with `{source, stIdx, cnt}`, which a television answers in standby. `rows` is how many it sent,
    /// which is what says whether a page follows: a row that is no station (`TVStation.init`) is left out of
    /// `stations` and counted all the same. A type the television has no source for has no stations, and
    /// nothing is asked.
    func stationPage(of broadcastingType: Int, from index: Int) async throws -> (stations: [TVStation], rows: Int) {
        guard let source = TVStation.source(of: broadcastingType) else { return ([], 0) }
        let asked: [String: Any] = ["source": source, "stIdx": index, "cnt": Self.stationsToAPage]
        let result = try await authenticated("avContent", "getContentList", version: "1.0", params: [asked])
        guard let rows = (result as? [Any])?.first as? [Any] else {
            throw ScalarError.unreadable(method: "getContentList")
        }
        let stations = rows.compactMap { row in
            (row as? [String: Any]).flatMap { TVStation($0, broadcastingType: broadcastingType) }
        }
        return (stations, rows.count)
    }

    /// What the television would stop recording if `body` were reserved on it:
    /// `recording.getConflictScheduleList` 1.0, which changes nothing there. The rows it names, each read as
    /// a row of the list is (`TVScheduleRow.init`; one here has seven fields) -- and every one of them,
    /// whatever its type: only recordings have been seen named, and what a reminder named here means is the
    /// caller's to say. An empty list is nothing lost. An answer that is no list throws, and so does one with
    /// a row that cannot be read: left out, it would pass for a reservation that costs nobody anything.
    func wouldPushOut(_ body: TVReservationBody) async throws -> [TVScheduleRow] {
        let result = try await authenticated("recording", "getConflictScheduleList", version: "1.0",
                                             params: [body.asking])
        guard let named = (result as? [Any])?.first as? [Any] else {
            throw ScalarError.unreadable(method: "getConflictScheduleList")
        }
        return try named.map { row in
            guard let row = (row as? [String: Any]).flatMap({ TVScheduleRow($0) }) else {
                throw ScalarError.unreadable(method: "getConflictScheduleList")
            }
            return row
        }
    }

    /// Reserves `body` on the television: `recording.addSchedule` 1.1, the version that follows a programme
    /// by its id. The answer names no reservation: what was made is read from the list afterwards. The same
    /// station, start and programme a second time is answered with error 41222, whatever the repeat. Nothing
    /// is sent a second time for silence: the first may have arrived.
    ///
    /// All the answer says is a number, its `annotation`, and that is what is handed back: nil when the
    /// answer has none. Every create a television has taken answered 0, the one that cost another
    /// reservation its recording included, so what another number means is not known, and nothing is made
    /// to depend on it: it is there for whoever sends a create to see what came back.
    @discardableResult
    func addSchedule(_ body: TVReservationBody) async throws -> Int? {
        let result = try await authenticated("recording", "addSchedule", version: "1.1", params: [body.creating])
        return (result as? [[String: Any]])?.first?["annotation"] as? Int
    }

    /// Changes the repeat of a reservation the television holds, in place: `recording.addSchedule` 1.2, the
    /// version that takes the list's id, sent the row as it was read with the repeat in the television's
    /// spelling (`TVScheduleRow.changing(to:)`). Never a delete and a create: the programme stays reserved
    /// throughout. A television sent such a change changed the row, keeping its id and the length of its
    /// list; sent an id it no longer had, it answered with error 41200 and made nothing. Nothing is sent a
    /// second time for silence: the first may have arrived.
    ///
    /// The answer is read as a create's is (`addSchedule`): the number it says, nil when it says none. What
    /// became of the row is read from the list afterwards.
    @discardableResult
    func changeSchedule(_ row: TVScheduleRow, repeatType: String) async throws -> Int? {
        let result = try await authenticated("recording", "addSchedule", version: "1.2",
                                             params: [row.changing(to: repeatType)])
        return (result as? [[String: Any]])?.first?["annotation"] as? Int
    }

    // MARK: - plumbing

    private func call(_ service: String, _ method: String, version: String, params: [Any] = [],
                      timeout: TimeInterval?) async throws -> Any {
        let response = try await send(service, method, version: version, params: params,
                                      headers: ["Content-Type": "application/json"], timeout: timeout)
        return try Self.result(of: response, method: method, version: version)
    }

    /// A request that needs the cookie. A 403 is sent again once when the store has a newer cookie than the
    /// one it went with: another client renewed in between. A 403 after that is a cookie the television no
    /// longer takes -- the app taken off its list, as seen, or a cookie that ran out -- and the registration is
    /// wanted again; a client still listed gets it without a PIN.
    private func authenticated(_ service: String, _ method: String, version: String, params: [Any] = [],
                               timeout: TimeInterval? = nil) async throws -> Any {
        var sentWith: String?
        for _ in 0..<2 {
            guard let cookie = credentials.load()?.cookie else { throw ScalarError.notRegistered }
            if cookie == sentWith { break }
            sentWith = cookie
            let response = try await send(service, method, version: version, params: params,
                                          headers: ["Content-Type": "application/json", "Cookie": "auth=\(cookie)"],
                                          timeout: timeout)
            if response.statusCode == 403 { continue }
            return try Self.result(of: response, method: method, version: version)
        }
        throw ScalarError.http(status: 403, method: method)
    }

    private func send(_ service: String, _ method: String, version: String, params: [Any],
                      headers: [String: String], timeout: TimeInterval?) async throws -> HTTPResponse {
        guard let url = RecorderAddress.url(host: host, port: 80, path: "/sony/\(service)") else {
            throw ScalarError.badAddress(host: host)
        }
        let id = nextID
        nextID += 1
        // The keys in order, at every depth. A dictionary has no order of its own, so without this the bytes
        // of one request differ from one launch to the next, and what was tried on a television would not be
        // what is sent to it afterwards.
        let body = try JSONSerialization.data(
            withJSONObject: ["method": method, "id": id, "params": params, "version": version] as [String: Any],
            options: [.withoutEscapingSlashes, .sortedKeys])
        let request = HTTPRequest(url: url, method: "POST", headers: headers, body: body,
                                  timeout: timeout ?? Self.timeout)
        let transport = self.transport
        let response: HTTPResponse
        do {
            response = try await queue.run { try await transport.send(request) }
        } catch let error as ScalarError {
            throw error
        } catch let error as RecorderError where error.failure != .silent {
            throw ScalarError.unreadable(method: method)
        } catch {
            throw ScalarError.transport(String(describing: error))
        }
        lastAnswer = Date()
        return response
    }

    /// The `result` of an answer, or the error it carries.
    static func result(of response: HTTPResponse, method: String, version: String) throws -> Any {
        guard response.statusCode == 200 else { throw ScalarError.http(status: response.statusCode, method: method) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw ScalarError.unreadable(method: method)
        }
        if let error = object["error"] as? [Any], let code = error.first as? Int {
            throw ScalarError.rpc(method: method, version: version, code: code,
                                  message: error.dropFirst().first as? String ?? "")
        }
        guard let result = object["result"] else { throw ScalarError.unreadable(method: method) }
        return result
    }
}

extension ScalarClient: DeviceEndpoint {
    /// `getPowerStatus`: one short request that needs no registration, and that the television answers in
    /// standby.
    public func probe(timeout: TimeInterval) async throws {
        _ = try await powerStatus(timeout: timeout)
    }
}

extension ScalarClient: LinkClient {}

// MARK: - sending what waits

/// What a round of sending to a television stands on, carried from one waiting reservation to the next.
public struct TVRound: Sendable {
    /// The television's list as last read: before anything was sent, and again after each create it answered.
    var listed: [TVScheduleRow]
    /// The stations read in this round, by broadcasting type: a kind of broadcast is read the first time a
    /// reservation on it is to be sent, and not again. A kind the television lists nothing of is here with
    /// no stations.
    var stations: [Int: [TVStation]] = [:]
    /// The kinds whose stations could not be read in this round. They are not asked for again in it.
    var unread: Set<Int> = []
    /// How many reservations running were answered with nothing that says anything about them.
    var saidNothing = 0
}

/// What sending a waiting reservation to a television is said as: the reasons written on a row that is held,
/// the one sentence for a round that could not start, and what making a reservation did beyond its own row.
/// The reasons are kept in the phone's database, and the one for a clash is held against the one made the
/// next time the television is asked (`send`): so nothing in them follows the phone's settings.
extension ScalarClient {
    /// Written on a reservation whose station is not in the television's list of its kind of broadcast. Not
    /// that the television cannot receive it: all that is known is that its list has no such station.
    static let stationNotListed = "テレビのチャンネル一覧にこの局が見つかりませんでした。"
    /// What the reason for a reservation that would stop others from recording begins with, whichever they
    /// are: a row held for that is known by it, so it is not to change. A reminder to watch named under it
    /// would read as a reservation that "is not recorded", which a reminder never is: what it would lose is
    /// the viewing. No television has named one.
    static let wouldStop = "この予約を入れると、次の予約は録画されません"
    /// What that reason ends with: how the reader says to make the reservation all the same.
    static let sendAgainToMakeIt = "「もう一度送る」を選ぶと、それでも予約します。"
    /// Written on a reservation whose create the television answered as taken and whose list does not have
    /// it. An answer alone takes nothing out of the queue.
    static let acceptedNotListed = "テレビは受け付けたと答えましたが、一覧にありません。"
    /// Written on a reservation whose create was answered as one the television holds already (41222), when
    /// its list has no recording of the programme.
    static let saidThereNotListed = "テレビはこの番組を予約済みと答えましたが、録画予約の一覧に見つかりませんでした。"
    /// Written on a reservation with no programme id: one made by its times goes by another version of the
    /// method, which is not sent.
    static let needsAProgramme = "番組を指定しない、時刻だけの予約は、テレビにはまだ送れません。"
    /// Written on a reservation whose repeat a television is not sent for its programme
    /// (`TVReservationBody.repeatType`).
    static let repeatNotTaken = "この番組には、選んだ毎回録画の設定でテレビに予約できません。"
    /// Written on a reservation that asks for a repeat, when the television holds a recording of its
    /// programme once (`TVScheduleRow.fallsShort`). It is not taken for there already: the programmes after
    /// this one would go unreserved with nothing said. Nor can it be made beside the one held, which a
    /// television answers as held already whatever the repeat. So the reader is told what would get the
    /// repeat made: the repeat of the reservation the television holds changed, which keeps the programme
    /// reserved throughout, as a delete before the row is sent again would not (`TVDriver.update`). Sent
    /// again then, the row is found there and not made a second time.
    static let reservedOnceOnly = "テレビにはこの番組の 1 回だけの予約がすでにあります。"
        + "毎回録画にするには、テレビの予約の毎回録画を変更してから「もう一度送る」を選んでください。"
    /// Written on a reservation that asks for a repeat, when the television holds a repeat of its programme
    /// that takes in some of that repeat's days and not all of them (`TVScheduleRow.fallsShort`): a weekly
    /// one, say, where every day was asked for. It is held as against a programme reserved once, and for
    /// the same reasons: taken for there already, the other days would go unreserved with nothing said.
    /// The sentence is its own, since what the television holds is no reservation for once.
    static let reservedOnFewerDays = "テレビにあるこの番組の予約は、選んだ毎回録画より録画する日が少ない設定です。"
        + "選んだ設定にするには、テレビの予約の毎回録画を変更してから「もう一度送る」を選んでください。"
    /// The codes a television answers a create with that turn the reservation itself down, each with what is
    /// written on the row: asked again, it would be answered the same. Of `addSchedule` alone: the same code
    /// means other things in other methods.
    ///
    /// 7 was seen for a create on a station the household is not subscribed to, two of them, and for a weekly
    /// repeat of another weekday than the programme's, which is not sent from here. Nothing was made by
    /// either.
    static let refusals = [
        7: "テレビがこの予約を受け付けませんでした（7）。契約していない局の番組などは予約できません。",
    ]
    /// Why a round did not start: the disk the television records to is not there. Said of the television
    /// and of no reservation, and nothing is written on any.
    static let diskNotFound = "録画用の USB HDD が見つからないため、テレビへの予約は送っていません"

    /// The reason written on a reservation that asks for more than `held`, the recording the television
    /// holds for it, or nil when that does not fall short of it (`TVScheduleRow.fallsShort`). Which of the
    /// two reasons goes by what is held: the programme once, or a repeat on fewer days. The one rule for a
    /// row the round's list has before anything is asked and for one found after a create answered as held
    /// already, so that the same row held is said the same at either.
    static func shortfall(of held: TVScheduleRow, for request: ReservationRequest) -> String? {
        guard held.fallsShort(of: request) else { return nil }
        return held.recordsOnce ? reservedOnceOnly : reservedOnFewerDays
    }

    /// The reason written on a reservation that would stop `named` from recording: the sentence that never
    /// changes, the rows the television named, each by its name (`name(of:)`) and in the order it named
    /// them, and how to make the reservation all the same.
    ///
    /// It says which reservations by more than their titles, since it is also what the reader consents to:
    /// it is made of the rows named and of nothing else, so the same sentence a second time is the same
    /// reservations named, and a consent given to one sentence is not taken for a consent to another.
    static func wouldStop(naming named: [TVScheduleRow]) -> String {
        "\(wouldStop): \(named.map(name(of:)).joined(separator: "、"))。\(sendAgainToMakeIt)"
    }

    /// Whether `reason`, written on a waiting reservation, is the one for what it would stop from recording
    /// (`wouldStop(naming:)`): the only reason that is also a consent once the reader sends the row again.
    static func holdsForWhatItWouldStop(_ reason: String) -> Bool { reason.hasPrefix(wouldStop + ": ") }

    /// How a row of the television's list is said in a sentence: its title as the television has it, and in
    /// brackets its station and the day and the time it starts. The start tells one reservation of a
    /// programme from the next day's, and the station tells it from the same title at the same minute on
    /// another station, as a simulcast is: the sentence is what a consent is held against, and what tells
    /// the reader which reservation is meant.
    ///
    /// The station is what the row's uri calls it (`TVScheduleRow.stationName`) and not its `channelName`:
    /// a row the question names has no `channelName`, and one rule serves both. A row with no station in
    /// its uri is said by its start alone, one whose start cannot be read by its station alone, and one
    /// with neither by its title. A reminder to watch says that it is one, in the television's own word
    /// for it: it is no recording, and the app lists none.
    static func name(of row: TVScheduleRow) -> String {
        let station = TVScheduleRow.stationName(of: row.uri)
        let start = RecorderTime.parse(row.startDateTime).map { said($0) }
        let which = [station, start].compactMap { $0 }.joined(separator: " ")
        return (row.type == "reminder" ? "視聴予約" : "") + "「\(row.title ?? "")」" + (which.isEmpty ? "" : "（\(which)）")
    }

    /// A start as a sentence says it: the month, the day and the time of day in Japan, to the nearest minute
    /// -- a television writes a reminder's start a second before its programme's. Written out here and not by
    /// a formatter, so that nothing of the phone's calendar or clock style gets into a sentence that is kept
    /// and compared.
    static func said(_ start: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: start.addingTimeInterval(30))
        return String(format: "%d/%d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
                      parts.minute ?? 0)
    }

    /// Said of a reservation that was made and that the television's list marks as sharing its time with
    /// others. What the mark costs it is the television's to decide: a recording marked `fullyOverlapped`
    /// was seen to be the one that loses, and no other mark has been seen on a recording.
    static func madeAndMarked(_ title: String) -> String {
        "「\(title)」はほかの予約と重なっていて、録画されないことがあります"
    }

    /// Said when making a reservation left others marked that were not marked before, and that the television
    /// had not named when it was asked: one sentence for rows of one kind, as `remark` hands them. Of
    /// recordings it says what the mark may cost, as `madeAndMarked` says of the row made: a recording
    /// marked `fullyOverlapped` was seen to be the one that loses. Of the others, reminders to watch, it
    /// says only that they share their time: a reminder records nothing, so no recording is lost with it.
    /// Handed both kinds it says only that much of them all, so that what is said of rows left marked
    /// never says of a viewing reservation that it may not be recorded.
    static func leftMarked(_ title: String, _ rows: [TVScheduleRow]) -> String {
        let cost = rows.allSatisfy { $0.type == "recording" } ? "重なり、録画されないことがあります" : "重なりました"
        return "「\(title)」を登録したため、\(rows.map(name(of:)).joined(separator: "、"))がほかの予約と\(cost)"
    }

    /// What making the reservation titled `title` did beyond its own row, as a sentence for the reader, or
    /// nil when it did nothing more: read from the list as it was before the create (`before`) and as it is
    /// after (`after`), where `made` is the row that was made.
    ///
    /// Two things are said. That the row made is itself marked as overlapping: it was made, and may not
    /// record. And each row that was not marked before and is now, by its name -- but for the rows in
    /// `named`, which the television named when it was asked and the reader consented to. A television was
    /// seen to mark a reminder to watch so, without having named it. A row that was marked already, and one
    /// that was not in the list before, are not this create's doing.
    ///
    /// The rows left marked are said in two sentences, the recordings in one and the others in another
    /// (`leftMarked`): what the mark may cost a recording is not what it costs a reminder to watch.
    static func remark(on title: String, made: TVScheduleRow, before: [TVScheduleRow], after: [TVScheduleRow],
                       named: [TVScheduleRow]) -> String? {
        let unmarked = Set(before.filter { !$0.overlaps }.map(\.id))
        let consentedTo = Set(named.map(\.id))
        let marked = after.filter { $0.overlaps && unmarked.contains($0.id) && !consentedTo.contains($0.id) }
        var sentences: [String] = []
        if made.overlaps { sentences.append(madeAndMarked(title)) }
        let recordings = marked.filter { $0.type == "recording" }, others = marked.filter { $0.type != "recording" }
        for rows in [recordings, others] where !rows.isEmpty { sentences.append(leftMarked(title, rows)) }
        return sentences.isEmpty ? nil : sentences.joined(separator: "。")
    }

    /// Said when changing the repeat of the reservation titled `title` left other recordings marked that
    /// were not marked before, as `leftMarked` says it of a create: by their names, and with what the mark may
    /// cost them. A repeat added by a change was seen to leave a recording on a later day marked
    /// `fullyOverlapped`, the one that loses.
    static func leftMarked(changing title: String, _ rows: [TVScheduleRow]) -> String {
        "「\(title)」の毎回録画を変更したため、\(rows.map(name(of:)).joined(separator: "、"))がほかの予約と"
            + "重なり、録画されないことがあります"
    }

    /// What changing the repeat of the reservation titled `title` did to the marks in the list, as a sentence
    /// for the reader, or nil when it did nothing: read from the list before the change (`before`) and the list
    /// after it (`after`), where `row` is the row that was changed.
    ///
    /// That the row itself is marked as overlapping is said in the create's own sentence, where the list
    /// after marks it and the one before did not. Then each other recording that the list after marks and
    /// the one before listed unmarked, by its name. A mark that was there before is not this change's doing,
    /// and a row new to the list is not either. Not the create's `remark`: a changed row keeps its id, so
    /// that would say it twice -- as the row made, and as one left marked -- and would say a mark it had
    /// before. Reminders to watch are left out: a reminder loses no recording, and the list a change reads
    /// has none.
    static func remark(changing title: String, row: TVScheduleRow, before: [TVScheduleRow],
                       after: [TVScheduleRow]) -> String? {
        let unmarked = Set(before.filter { !$0.overlaps }.map(\.id))
        let marked = after.filter { $0.type == "recording" && $0.overlaps && unmarked.contains($0.id) }
        var sentences: [String] = []
        if marked.contains(where: { $0.id == row.id }) { sentences.append(madeAndMarked(title)) }
        let others = marked.filter { $0.id != row.id }
        if !others.isEmpty { sentences.append(leftMarked(changing: title, others)) }
        return sentences.isEmpty ? nil : sentences.joined(separator: "。")
    }
}

extension ScalarClient: QueueTarget {
    /// What waits for the television is what a television's client is sent.
    public static let slot = DeviceSlot.tv

    /// How many reservations running may be answered with nothing that says anything about them before the
    /// round stops: at the second, what is wrong is taken to be the television's and not theirs.
    static let rowsThatSayNothing = 2

    /// The codes that, answered to the list of stations, say a state the television is in and nothing of
    /// the kinds of broadcast it has: 40005, which this client reads as "has to be on" in every method
    /// (`ScalarError.failure`) and which a television in standby answered other methods with; and 7, its
    /// "illegal state", which that list has not been seen answered with. Not what 7 says of a create
    /// (`refusals`): a code means that in that method alone.
    static let statesOfTheTelevision: Set = [7, 40005]

    /// The disk, then the list. A disk that is not there stops the round before anything else is asked, and
    /// nothing is written on any reservation for it: they go by themselves once it is back. Silence stops
    /// the round, and so does a cookie the television does not take. An answer that cannot be read stops it
    /// too, as one that says nothing: without the disk known and the list read, nothing is to be sent.
    ///
    /// The rows the list holds already are handed back, the ones with a reason on them as well: each
    /// reservation the television has a recording for, by its channel and its programme (`holding`), never
    /// a reminder. But not a reservation that asks for a repeat where the recording held is of the
    /// programme once, or repeats on some of that repeat's days and not all (`fallsShort`): what the
    /// television holds is less than was asked, and the row stays in the queue for `send` to hold with the
    /// reason for that.
    public func openRound(for waiting: [PendingReservation]) async -> RoundOpened<TVRound> {
        do {
            guard try await storage().mounted else { return .stopped(.cannotRecord(reason: Self.diskNotFound)) }
            let listed = try await schedules()
            let there = waiting.filter { row in
                listed.holding(row.request).map { !$0.fallsShort(of: row.request) } == true
            }
            return .open(TVRound(listed: listed), alreadyThere: Set(there.map(\.id)))
        } catch {
            return .stopped(Self.stop(for: error, afterSending: false) ?? .saysNothing)
        }
    }

    /// One waiting reservation, in this order, each request once:
    ///
    ///  1. What a television is not sent is held with its reason, and nothing is asked: a reservation with
    ///     no programme id, and a repeat that is not sent for its programme. So is a repeat whose programme
    ///     the round's list has a recording of that falls short of it, once or on fewer days
    ///     (`shortfall`): its create would be answered as held already, and what is held is less than it
    ///     asks for.
    ///  2. The station, from the list of the reservation's kind of broadcast (`stations(for:in:)`): read
    ///     once in a round, and only for a kind that has a reservation to send. A station that is not in a
    ///     list that was read holds the row. A list that could not be read passes the row over, and is not
    ///     asked for again in the round.
    ///  3. What it would stop from recording. The television is asked every time, with the reader's consent
    ///     as well: the consent was given to the reservations a sentence named, and the list may have
    ///     changed since. Rows named hold the reservation with the reason that names them, whatever their
    ///     type, and nothing is sent -- unless the reader consented and the reason on the row is the very
    ///     reason this answer makes. An answer that cannot be read is never taken for nothing named.
    ///  4. The create, then the list. Listed: made, with what the list shows it did beyond its own row
    ///     (`remark`). Answered and not listed: held, since an answer alone takes nothing out of the queue.
    ///     Answered as held already (41222) and listed: already there, unless what is listed falls short
    ///     of the repeat the reservation asks for, which holds it as in 1; not listed: held.
    ///     A code that turns the reservation down (`refusals`): held with its reason. Silence at the create
    ///     stops the round, and nothing is sent after it, the list included: the reservation may have been
    ///     made, and the next round's list says.
    ///  5. An answer to the question or to the create that says nothing about the reservation -- a code not
    ///     known here, one that cannot be read -- passes the row over with nothing written on it, and a
    ///     second such row running stops the round. So does such an answer to the list after a create
    ///     answered as held already: nothing was made, and the list the round holds still stands.
    ///  6. Such an answer to the list after a create answered as taken ends the round there, whatever the
    ///     count: the round no longer has the list it stands on. The row is left unsaid, as after silence
    ///     at that read, with nothing written on it: by the television's answer it was made, so it is not
    ///     told as one that could not be sent, and the next round's list says.
    ///  7. The count of the rows that say nothing is started again by a reservation the television answered
    ///     about, at the question, the create or the list after it: one held for what it would stop,
    ///     turned down by a code, held for not being listed, held for what is listed falling short of
    ///     its repeat after a create answered as held already, made, or found there. A reservation that
    ///     nothing was asked about neither counts nor starts the count again: one held in 1, one whose
    ///     station is not in the list, and one passed over for a list of stations that could not be read.
    ///     A row held without a question says nothing of whether the television answers one.
    ///
    /// At any step, silence stops the round, and so does a cookie the television does not take. Silence
    /// after the create was answered as taken is told as silence at the create is: the reservation is on the
    /// television as far as its answer goes, and has not been seen in its list.
    ///
    /// Left as it is: a reservation whose create met silence, or whose list could not be read, is found by
    /// the next round's opening and told as there already, and what making it did beyond its own row
    /// (`remark`) is then never said.
    public func send(_ waiting: PendingReservation, consented: Bool,
                     in round: TVRound) async -> (sent: RowSent, round: TVRound) {
        var round = round
        let request = waiting.request
        guard request.eventID != nil else { return (.refused(reason: Self.needsAProgramme), round) }
        guard TVReservationBody.repeatType(for: request.repeatCode, start: request.start) != nil else {
            return (.refused(reason: Self.repeatNotTaken), round)
        }
        // Found by the round's list as it stands now, which a create earlier in the round may have read
        // again: the opening left such a row in the queue, and so does this.
        if let reason = round.listed.holding(request).flatMap({ Self.shortfall(of: $0, for: request) }) {
            return (.refused(reason: reason), round)
        }

        let stations: [TVStation]
        switch await self.stations(for: request.broadcastingType, in: round) {
        case .read(let read):
            stations = read
            round.stations[request.broadcastingType] = read
        case .unread:
            round.unread.insert(request.broadcastingType)
            return (.passedOver, round)
        case .stopped(let stop):
            return (.stopped(stop, passedOver: false), round)
        }
        // The body is nil for a station that is not the reservation's own channel, and for nothing else by
        // now: so with no body there is no station of its own to send it on. Nothing was asked about the
        // reservation itself, whether the list was read for it or for one before it.
        guard let station = stations.first(where: { $0.serviceID == request.serviceID }),
              let body = TVReservationBody(request, on: station) else {
            return (.refused(reason: Self.stationNotListed), round)
        }

        let named: [TVScheduleRow]
        do {
            named = try await wouldPushOut(body)
        } catch {
            return Self.unanswered(error, afterSending: false, round)
        }
        if !named.isEmpty {
            let reason = Self.wouldStop(naming: named)
            guard consented, waiting.problem == reason else { return Self.settled(.refused(reason: reason), round) }
        }

        var saidThere = false
        do {
            try await addSchedule(body)
        } catch let error as ScalarError where error.failure == .alreadyThere {
            saidThere = true
        } catch {
            if let reason = Self.refusal(in: error) { return Self.settled(.refused(reason: reason), round) }
            return Self.unanswered(error, afterSending: true, round)
        }

        let before = round.listed
        do {
            round.listed = try await schedules()
        } catch {
            // The create was taken and the list cannot be read: the round has no list to stand on any
            // more. What the next reservation did beyond its own row would be worked out from a list from
            // before this create, and said of the wrong one. The row is left unsaid, as silence at this
            // read leaves it: a row passed over is told as one that could not be sent, and this one was
            // taken. After a create answered as held already nothing was made, and the list the round
            // holds still stands.
            if !saidThere, Self.stop(for: error, afterSending: true) == nil {
                return (.stopped(.saysNothing, passedOver: false), round)
            }
            return Self.unanswered(error, afterSending: !saidThere, round)
        }
        guard let made = round.listed.holding(request) else {
            let reason = saidThere ? Self.saidThereNotListed : Self.acceptedNotListed
            return Self.settled(.refused(reason: reason), round)
        }
        guard !saidThere else {
            // Held already, whatever the repeat that was asked: so what is held may be less than that.
            let short = Self.shortfall(of: made, for: request)
            return Self.settled(short.map { .refused(reason: $0) } ?? .alreadyThere, round)
        }
        let remark = Self.remark(on: request.title, made: made, before: before, after: round.listed, named: named)
        return Self.settled(.made(saying: remark), round)
    }

    /// What reading the stations of one kind of broadcast came to, for a round.
    private enum StationsRead {
        case read([TVStation])
        /// The list could not be read, and nothing says why that is the reservation's.
        case unread
        case stopped(SendingStop)
    }

    /// The stations of one kind of broadcast, for a round: what the round has read already, and otherwise
    /// the television's list, asked for once. Nothing is asked for a kind that could not be read in this
    /// round.
    ///
    /// The first page is asked for here, so that an error on it can be told from one further on. Answered
    /// with the method's own error, the television is taken to list no such kind of broadcast, as one with
    /// no tuner for it might, and the kind has no stations: its reservations are held as any whose station
    /// is missing, where the reader sees them, and do not wait unsaid for a list that will never come.
    ///
    /// But for an error that says a state the television is in (`statesOfTheTelevision`): that is no word
    /// on what it receives, and held for it, every reservation of the kind would stop going by itself for
    /// something that passes. It leaves the kind unread, as any other failure does, on that page or a later
    /// one: a list cut short would say of every station after the cut that the television does not have it.
    ///
    /// Both readings are taken, not seen. The list was read from a television in standby by this client, in
    /// the round, about a minute after it was switched off: it answered with its stations. No television
    /// has been seen to answer the list with 40005 or with 7, and none was asked for a kind it lacks.
    private func stations(for broadcastingType: Int, in round: TVRound) async -> StationsRead {
        if let read = round.stations[broadcastingType] { return .read(read) }
        if round.unread.contains(broadcastingType) { return .unread }
        do {
            let first: (stations: [TVStation], rows: Int)
            do {
                first = try await stationPage(of: broadcastingType, from: 0)
            } catch ScalarError.rpc(_, _, let code, _) where !Self.statesOfTheTelevision.contains(code) {
                return .read([])
            }
            return .read(try await stations(of: broadcastingType, after: first))
        } catch {
            return Self.stop(for: error, afterSending: false).map { .stopped($0) } ?? .unread
        }
    }

    /// The stop a failure is, when it is one that ends a round whatever was being asked: nothing answered,
    /// or the television wants the app registered again. Nil for a failure that says nothing of the kind.
    private static func stop(for error: any Error, afterSending: Bool) -> SendingStop? {
        switch (error as? any DeviceError)?.failure {
        case .silent?: .silent(afterSending: afterSending)
        case .needsPairing?: .needsPairing
        default: nil
        }
    }

    /// What a create's failure turns the reservation down with, when its code is one that does (`refusals`).
    private static func refusal(in error: any Error) -> String? {
        guard case .rpc(_, _, let code, _)? = error as? ScalarError else { return nil }
        return refusals[code]
    }

    /// A reservation the television answered about, at the question, the create or the list after it -- made,
    /// found there, or held with a reason that answer gave -- which starts the count of the rows that say
    /// nothing again: the television has said something that reads. Not for a reservation held with nothing
    /// asked about it, which shows nothing of the television either way.
    private static func settled(_ sent: RowSent, _ round: TVRound) -> (sent: RowSent, round: TVRound) {
        var round = round
        round.saidNothing = 0
        return (sent, round)
    }

    /// What a request about one reservation that failed leaves of it: the round stopped for silence or for
    /// the cookie, and otherwise the row passed over with nothing written on it, as one more that says
    /// nothing -- which stops the round at the second running.
    private static func unanswered(_ error: any Error, afterSending: Bool,
                                   _ round: TVRound) -> (sent: RowSent, round: TVRound) {
        if let stop = stop(for: error, afterSending: afterSending) {
            return (.stopped(stop, passedOver: false), round)
        }
        var round = round
        round.saidNothing += 1
        guard round.saidNothing >= rowsThatSayNothing else { return (.passedOver, round) }
        return (.stopped(.saysNothing, passedOver: true), round)
    }
}
