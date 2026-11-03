import Foundation

/// Where the app keeps the token the helper on the television handed it at registration. The app's is in the
/// Keychain beside the television's cookie; the demo's and the tests' are in memory.
public protocol TVHelperTokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func remove()
}

/// A token that lives as long as the store does.
public final class MemoryTVHelperToken: TVHelperTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: String?

    public init(_ token: String? = nil) {
        kept = token
    }

    public func load() -> String? { lock.withLock { kept } }
    public func save(_ token: String) { lock.withLock { kept = token } }
    public func remove() { lock.withLock { kept = nil } }
}

/// What the helper says of itself to anyone (`GET /ping`).
public struct TVHelperIdentity: Sendable, Equatable {
    public var app: String
    /// The API versions it speaks.
    public var api: [Int]
    public var version: String

    /// Whether this is the helper the app knows how to talk to, speaking its API.
    public var isHelper: Bool { app == TVHelperClient.appName && api.contains(TVHelperClient.apiVersion) }
}

/// What the helper knows of one broadcasting type's copy (`GET /v1/info`).
public struct TVHelperTypeState: Sendable, Equatable {
    /// When the helper last saw the type's rows change, and when it last copied them.
    public var changedAt: Date
    public var snapshotAt: Date
    public var programs: Int
    public var channels: Int
}

/// The helper's state, for the settings and for judging what to fetch (`GET /v1/info`).
public struct TVHelperInfo: Sendable, Equatable {
    public var version: String
    /// Whether the helper may read the television's guide store, which the reader allows on the television.
    public var listingsPermission: Bool
    public var tunerInstalled: Bool
    /// Whether a copy is being made now; what the last making failed with, nil for nothing.
    public var building: Bool
    public var lastBuildError: String?
    /// When the tuner last wrote to the guide store, as the helper saw it; nil while it has not seen a write.
    public var tunerLastWrite: Date?
    public var types: [String: TVHelperTypeState]
}

/// What asking the helper came to that was not an answer.
public enum TVHelperError: Error, Equatable, Sendable {
    /// Nothing answered, or not over HTTP.
    case transport(String)
    /// What answered is not the helper: another program on the port, or a helper speaking an API this app does
    /// not.
    case notAHelper
    /// The helper takes no token of the app's: it is to be registered again on the television screen.
    case unauthorized
    /// Registration was turned down: `noCode` with no code showing on the television, `badCode` for the wrong
    /// one, `locked` after too many wrong ones.
    case pairingRefused(String)
    /// The helper has no copy to serve yet, and why: `noPermission`, `noTuner`, `building`.
    case notReady(String)
    /// An answer of a shape the API does not promise, or a status it does not: what was found.
    case unexpected(String)
}

extension TVHelperError: DeviceError {
    public var failure: DeviceFailure {
        switch self {
        case .transport: .silent
        case .unauthorized: .needsPairing
        case .pairingRefused: .refused(reason: explanation)
        case .notReady("building"): .busy
        case .notReady: .deviceCannot(reason: explanation)
        case .notAHelper, .unexpected: .unexpected(explanation)
        }
    }

    public var explanation: String {
        switch self {
        case .transport: "テレビのヘルパーが応答しません"
        case .notAHelper: "テレビのヘルパーではないものが応答しました"
        case .unauthorized: "テレビのヘルパーに登録されていません。テレビの画面で登録し直してください"
        case .pairingRefused("noCode"): "テレビの画面に登録の番号が出ていません"
        case .pairingRefused("locked"): "間違いが続いたので、しばらく登録を受け付けません"
        case .pairingRefused: "登録の番号が違います"
        case .notReady("noPermission"): "テレビでヘルパーに番組表の読み取りを許可してください"
        case .notReady("noTuner"): "テレビにチューナーのアプリが見つかりません"
        case .notReady: "テレビのヘルパーが番組表の写しを作っています"
        case .unexpected(let what): "テレビのヘルパーの答えを読み取れませんでした: \(what)"
        }
    }
}

/// The helper on the television, asked for the television's guide (`helper/README.md`). A `GuideSource`
/// like the recorder's client, so that `GuideRefresh.run` fetches from either; its channel list is read once
/// and kept, the rows of a type naming their service alone. Every request carries the token from the
/// registration except `ping` and `pair`, which are what registration is made of.
///
/// One request at a time, through the client's own queue, as the recorder's (`SerialQueue`): the helper
/// serves many at once, but what the app asks of it is a guide a type at a time, and nothing is gained by
/// asking two.
public actor TVHelperClient: GuideSource {
    public static let appName = "recbridge-helper"
    public static let apiVersion = 1
    public static let port = 8780

    public nonisolated let host: String
    private let port: Int
    private let transport: any HTTPTransport
    private let tokens: any TVHelperTokenStore
    private let queue = SerialQueue()
    private var channels: [TVGuideDecoder.Channel]?
    /// When the helper last answered anything at all.
    public private(set) var lastAnswer: Date?

    public init(host: String, port: Int = TVHelperClient.port, transport: any HTTPTransport,
                tokens: any TVHelperTokenStore) {
        self.host = host
        self.port = port
        self.transport = transport
        self.tokens = tokens
    }

    /// Whether the app holds a token for this helper, whatever the helper makes of it.
    public nonisolated var isRegistered: Bool { tokens.load() != nil }

    /// Forgets the token: the reader took the helper away, or registered afresh.
    public nonisolated func forgetRegistration() { tokens.remove() }

    // MARK: - DeviceEndpoint

    /// `GET /ping`: the helper is there, is the helper, and speaks this app's API.
    public func probe(timeout: TimeInterval) async throws {
        guard try await ping(timeout: timeout).isHelper else { throw TVHelperError.notAHelper }
    }

    public func ping(timeout: TimeInterval = 5) async throws -> TVHelperIdentity {
        let answer = try await send(path: "/ping", timeout: timeout, withToken: false)
        guard answer.statusCode == 200, let top = json(answer), let app = top["app"] as? String,
              let api = top["api"] as? [Int], let version = top["version"] as? String else {
            throw TVHelperError.notAHelper
        }
        return TVHelperIdentity(app: app, api: api, version: version)
    }

    // MARK: - registration

    /// `POST /v1/pair` with the six-digit code the television shows: the token is kept, and every request after
    /// this carries it. `label` is what the helper lists this phone as.
    public func pair(code: String, label: String, timeout: TimeInterval = 10) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "label": label])
        let answer = try await send(path: "/v1/pair", method: "POST", body: body, timeout: timeout, withToken: false)
        switch answer.statusCode {
        case 200:
            guard let top = json(answer), let token = top["token"] as? String else {
                throw TVHelperError.unexpected("pair")
            }
            tokens.save(token)
        case 403, 429:
            throw TVHelperError.pairingRefused(errorCode(answer) ?? "badCode")
        default:
            throw TVHelperError.unexpected("HTTP \(answer.statusCode)")
        }
    }

    // MARK: - reads

    public func info(timeout: TimeInterval = 10) async throws -> TVHelperInfo {
        let answer = try await send(path: "/v1/info", timeout: timeout)
        guard let top = json(answer) else { throw TVHelperError.unexpected("info") }
        var types: [String: TVHelperTypeState] = [:]
        for (bt, value) in top["types"] as? [String: [String: Any]] ?? [:] {
            guard let changedAt = ms(value["changedAt"]), let snapshotAt = ms(value["snapshotAt"]) else { continue }
            types[bt] = TVHelperTypeState(changedAt: changedAt, snapshotAt: snapshotAt,
                                          programs: value["programs"] as? Int ?? 0, channels: value["channels"] as? Int ?? 0)
        }
        return TVHelperInfo(version: top["helperVersion"] as? String ?? "",
                            listingsPermission: top["listingsPermission"] as? Bool ?? false,
                            tunerInstalled: top["tunerInstalled"] as? Bool ?? false,
                            building: top["building"] as? Bool ?? false,
                            lastBuildError: top["lastBuildError"] as? String,
                            tunerLastWrite: ms(top["tunerLastWrite"]), types: types)
    }

    /// The television's channels of every type, read once and kept for the guide and the logos.
    public func channels(timeout: TimeInterval = 30) async throws -> [TVGuideDecoder.Channel] {
        if let channels { return channels }
        let answer = try await send(path: "/v1/channels", timeout: timeout)
        let decoded = try TVGuideDecoder.decodeChannels(answer.body)
        channels = decoded
        return decoded
    }

    /// The broadcasting types the television has a channel of.
    public func broadcastingTypes() async throws -> [String] {
        let present = Set(try await channels().map(\.broadcasting))
        return TVGuideDecoder.broadcastingTypes.filter { present.contains($0) }
    }

    // MARK: - GuideSource

    /// A type's guide, or nil where the television has no channel of that type (404 `noSuchType`). The helper's
    /// copy is served as it stands; while it has none yet the helper says so (`TVHelperError.notReady`), and the
    /// type is tried again at the next refresh.
    public func guide(_ broadcasting: String) async throws -> [GuideService]? {
        let channels = try await channels()
        let answer = try await send(path: "/v1/guide/\(broadcasting)", timeout: 120, acceptingAbsence: true)
        guard answer.statusCode != 404 else { return nil }
        return try TVGuideDecoder.decodeGuide(answer.body, channels: channels)
    }

    public func logos(_ broadcasting: String) async throws -> [StationLogo]? {
        let channels = try await channels()
        let answer = try await send(path: "/v1/logos/\(broadcasting)", timeout: 60, acceptingAbsence: true)
        guard answer.statusCode != 404 else { return nil }
        return try TVGuideDecoder.decodeLogos(answer.body, channels: channels)
    }

    // MARK: - the wire

    /// One request, in the client's turn. Answers other than 200 are read for what they say: 401 is the
    /// registration gone, 503 the helper not ready, 404 absence where the caller takes absence for an answer, and
    /// anything else unexpected. The token is sent unless told not to.
    private func send(path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval,
                      withToken: Bool = true, acceptingAbsence: Bool = false) async throws -> HTTPResponse {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw TVHelperError.transport("bad address")
        }
        var headers = ["Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        if withToken {
            guard let token = tokens.load() else { throw TVHelperError.unauthorized }
            headers["Authorization"] = "Bearer \(token)"
        }
        let request = HTTPRequest(url: url, method: method, headers: headers, body: body, timeout: timeout)
        let answer: HTTPResponse
        do {
            answer = try await queue.run { try await self.transport.send(request) }
        } catch let error as TVHelperError {
            throw error
        } catch {
            throw TVHelperError.transport(String(describing: error))
        }
        lastAnswer = Date()
        switch answer.statusCode {
        case 200: return answer
        case 401: throw TVHelperError.unauthorized
        case 404 where acceptingAbsence: return answer
        case 503: throw TVHelperError.notReady(errorCode(answer) ?? "building")
        case 403, 429: return answer
        default: throw TVHelperError.unexpected("HTTP \(answer.statusCode)")
        }
    }

    private func json(_ answer: HTTPResponse) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any]
    }

    private func errorCode(_ answer: HTTPResponse) -> String? {
        json(answer)?["error"] as? String
    }

    private func ms(_ value: Any?) -> Date? {
        switch value {
        case let n as Int: Date(timeIntervalSince1970: TimeInterval(n) / 1000)
        case let n as Double: Date(timeIntervalSince1970: n / 1000)
        case let n as NSNumber: Date(timeIntervalSince1970: n.doubleValue / 1000)
        default: nil
        }
    }
}

extension TVHelperClient: LinkClient {}
