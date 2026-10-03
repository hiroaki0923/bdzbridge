import Foundation

/// A request, kept free of `URLRequest` so that everything here stays `Sendable` and the tests can stub the
/// transport without touching `URLSession`.
public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 30) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data
    /// As the server spelled the names. Only a television's registration reads any (`Set-Cookie`).
    public var headers: [String: String]

    public init(statusCode: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    public var text: String { String(decoding: body, as: UTF8.self) }

    /// A header by its name in any case, as HTTP compares them.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// The recorder is slow to answer and its files are large, so the session is patient by default.
    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.httpShouldUsePipelining = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    /// For a television, whose registration hands out a cookie: the client sends it by hand, and only to the
    /// television it came from, so the session neither keeps a cookie nor sends one of its own accord.
    public static func withoutCookies() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    /// A request answered with a demand for a password is not sent a second time, as `URLSession` would send
    /// it: see `ChallengeRefused`.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let challenge = ChallengeRefused()
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: challenge)
            guard let http = response as? HTTPURLResponse else { throw RecorderError.notHTTP }
            return HTTPResponse(statusCode: http.statusCode, body: data, headers: Self.headers(of: http))
        } catch let error as RecorderError {
            throw error
        } catch {
            // Ended at the challenge, the task has no response of its own: the one that asked is the answer.
            // Only for the end the challenge made, not for whatever else went wrong after one arrived.
            let code = (error as? URLError)?.code
            if code == .cancelled || code == .userCancelledAuthentication, let asked = challenge.answer {
                return HTTPResponse(statusCode: asked.statusCode, headers: Self.headers(of: asked))
            }
            throw RecorderError.transport(String(describing: error))
        }
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return headers
    }
}

/// Ends a request at the server's demand for a name and a password, and keeps the answer that made it.
///
/// Answered 401 with a Basic challenge, `URLSession` sends the request a second time before it hands the 401
/// back: unchanged, on a connection of its own. Seen on macOS against a server on the loopback, with no
/// delegate and with one that answered the challenge in every way short of cancelling it
/// (`URLSessionTransportTests`). The app has no password to give -- a television's PIN goes in a header the
/// client writes -- so the second is the first over again, and to a device two requests are two requests. A
/// television answers an unknown client that asks to register in just this way, with its PIN on the screen,
/// and takes the PIN off again for the second: tried both ways on one television (`LiveTVTests`), sent as
/// `URLSession` sends it the PIN was gone before it could be read, and sent once it stayed and registered.
/// So the challenge is cancelled, which sends nothing more. The task then fails, with no response to give,
/// and the answer that carried the challenge is what the caller gets: its status and headers. Its body is
/// not to be had this way, and nothing reads one.
///
/// Only what a device asks of the app. A server proving who it is, over TLS, and a proxy on the way that
/// wants a password, which the system may hold, are left to the system.
private final class ChallengeRefused: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: HTTPURLResponse?

    var answer: HTTPURLResponse? { lock.withLock { kept } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod != NSURLAuthenticationMethodServerTrust,
              space.authenticationMethod != NSURLAuthenticationMethodClientCertificate,
              !space.isProxy() else {
            return (.performDefaultHandling, nil)
        }
        // Cancelled whether or not the answer came with it: without one the request fails, and is still not
        // sent again.
        if let asked = challenge.failureResponse as? HTTPURLResponse { lock.withLock { kept = asked } }
        return (.cancelAuthenticationChallenge, nil)
    }
}
