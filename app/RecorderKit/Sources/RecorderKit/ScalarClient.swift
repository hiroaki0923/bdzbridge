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
        let body = try JSONSerialization.data(
            withJSONObject: ["method": method, "id": id, "params": params, "version": version] as [String: Any],
            options: [.withoutEscapingSlashes])
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
