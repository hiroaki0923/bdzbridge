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
    /// of the request: an unknown answer holds nothing back for good.
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
    public func enrol(clientID: String, nickname: String, pin: String?,
                      timeout: TimeInterval = 5) async -> TVEnrolment {
        do {
            let mac = try await wakeOnLANAddress(timeout: timeout).flatMap(WakeOnLan.normalise)
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
    /// How a list ends whose last page is exactly fifty has not been seen. An empty page ends it, as any
    /// short page does. If what comes instead is an error, it is thrown like any other: none is taken for
    /// the end of the list until it is known which one a television answers a page past the end with.
    ///
    /// Any failure on any page throws, and nothing is handed back of the pages read before it: a list cut
    /// short would say of every station after the cut that the television does not have it. A list that has
    /// not ended after `stationPages` is not one that was read, and throws as an answer that cannot be read.
    func stations(of broadcastingType: Int) async throws -> [TVStation] {
        var stations: [TVStation] = []
        var index = 0
        for _ in 0..<Self.stationPages {
            let page = try await stationPage(of: broadcastingType, from: index)
            stations += page.stations
            guard page.rows >= Self.stationsToAPage else { return stations }
            index += page.rows
        }
        throw ScalarError.unreadable(method: "getContentList")
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
