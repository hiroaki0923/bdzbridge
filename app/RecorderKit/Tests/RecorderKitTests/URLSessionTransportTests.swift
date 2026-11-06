#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RecorderKit

/// The one transport that is not a stub, against a server on this machine's loopback: what `URLSession` itself
/// does with an answer is not seen through a stubbed transport, and one thing it does by itself is send a
/// request again. Nothing here leaves the machine.
final class URLSessionTransportTests: XCTestCase {
    /// A request answered with a demand for a name and a password is sent once, and its answer handed back
    /// as an answer. `URLSession` left alone sends it twice, which a television asked to register takes its
    /// PIN off the screen for. With the PIN on the request as well: a wrong one is one try, not two.
    func testARequestAnsweredWithAChallengeIsSentOnce() async throws {
        let transports = [("the recorder's", URLSessionTransport()),
                          ("the television's", URLSessionTransport.withoutCookies())]
        for (whose, transport) in transports {
            for authorization in [nil, "Basic OjAwMDA="] {
                let server = try LoopbackServer(answering: LoopbackServer.challenge)
                defer { server.stop() }
                var headers = ["Content-Type": "application/json"]
                if let authorization { headers["Authorization"] = authorization }

                let response = try await transport.send(HTTPRequest(
                    url: server.url("/sony/accessControl"), method: "POST", headers: headers,
                    body: Data(#"{"method":"actRegister"}"#.utf8), timeout: 5))

                let way = "\(whose) transport, \(authorization == nil ? "nothing on it" : "a PIN on it")"
                XCTAssertEqual(response.statusCode, 401, way)
                XCTAssertEqual(response.header("WWW-Authenticate"), #"Basic realm="Private Page""#, way)
                XCTAssertEqual(server.requests, ["POST /sony/accessControl HTTP/1.1"],
                               "\(way): the request was sent again")
            }
        }
    }

    /// Any other answer comes back whole: the status, the headers as the server spelled them, and the body.
    func testAnAnswerComesBackWhole() async throws {
        let server = try LoopbackServer(answering: LoopbackServer.answer(
            status: "200 OK", headers: ["Set-Cookie: auth=sample; Max-Age=1209600"], body: #"{"result":[]}"#))
        defer { server.stop() }

        let response = try await URLSessionTransport.withoutCookies().send(HTTPRequest(
            url: server.url("/sony/system"), method: "POST", body: Data("{}".utf8), timeout: 5))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.text, #"{"result":[]}"#)
        XCTAssertEqual(response.header("set-cookie"), "auth=sample; Max-Age=1209600")
        XCTAssertEqual(server.requests, ["POST /sony/system HTTP/1.1"])
    }

    /// A television's session follows no redirect. What answers on port 80 where a television is asked may be a
    /// router's page that sends the request on, to its https page or a name off the LAN: the answer that would
    /// send it there is handed back as the answer, and the place it names hears nothing. The same answer through
    /// the recorder's session, which is left as it was, is followed, which is what shows the test can tell.
    func testATelevisionsSessionHandsARedirectBackAsTheAnswer() async throws {
        let elsewhere = try LoopbackServer(answering: LoopbackServer.answer(
            status: "200 OK", headers: [], body: "{}"))
        defer { elsewhere.stop() }
        let sendsOn = elsewhere.url("/elsewhere").absoluteString
        let redirecting = try LoopbackServer(answering: LoopbackServer.answer(
            status: "302 Found", headers: ["Location: \(sendsOn)"], body: ""))
        defer { redirecting.stop() }

        let response = try await URLSessionTransport.withoutCookies().send(HTTPRequest(
            url: redirecting.url("/sony/system"), method: "POST", headers: ["Content-Type": "application/json"],
            body: Data(#"{"method":"getSystemSupportedFunction"}"#.utf8), timeout: 5))

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.header("Location"), sendsOn)
        XCTAssertEqual(redirecting.requests, ["POST /sony/system HTTP/1.1"])
        XCTAssertEqual(elsewhere.requests, [], "the redirect was followed")

        let followed = try await URLSessionTransport().send(HTTPRequest(url: redirecting.url("/description.xml"),
                                                                        timeout: 5))
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(elsewhere.requests, ["GET /elsewhere HTTP/1.1"])
    }

    /// A request that fails in transit is kept as the system's own text for the failure, and a search's tally
    /// reads the system's code back out of that text (`ScanTally`). The wording is the system's, so it is
    /// looked at with the real session: a connection refused on the loopback, where nothing listens on port 9.
    func testAFailureInTransitKeepsTheSystemsCodeForASearchsTally() async throws {
        let server = try LoopbackServer(answering: LoopbackServer.answer(
            status: "200 OK", headers: [], body: "{}"))
        defer { server.stop() }
        let tally = ScanTally(URLSessionTransport())

        let answered = try await tally.send(HTTPRequest(url: server.url("/description.xml"), timeout: 5))
        XCTAssertEqual(answered.statusCode, 200)
        do {
            let refused = try XCTUnwrap(URL(string: "http://127.0.0.1:9/description.xml"))
            _ = try await tally.send(HTTPRequest(url: refused, timeout: 5))
            XCTFail("something on this machine answers on port 9")
        } catch let error as RecorderError {
            guard case .transport = error else { return XCTFail("not a failure in transit: \(error)") }
        }

        let counts = await tally.counts
        XCTAssertEqual(counts.answered, [200: 1])
        XCTAssertEqual(counts.failed, [-1004: 1], "the system's code was not read out of its text for the failure")
        XCTAssertEqual(counts.timedOut + counts.other, 0)
    }

    /// What a search's tally makes of an address where nobody answers, through the real session: a request
    /// there times out when its own time is up, and is cancelled when the search ends it first, as a search's
    /// deadline does to one that has outlived its time (`Discovery.probe`). Either is a request that was out,
    /// so a look made of such addresses was not turned away (`ScanTally.Counts.mostTurnedAway`). On a Mac
    /// 127.0.0.2 is the loopback network's and nobody's: what is sent there never leaves this machine and is never
    /// answered. Elsewhere every address of 127/8 is the machine's own, and one where nothing listens refuses at
    /// once, so the silence is a socket that listens and takes no connection up.
    func testASilentAddressCountsAsARequestThatWasOut() async throws {
        #if canImport(Darwin)
        let silent = try XCTUnwrap(URL(string: "http://127.0.0.2:9/description.xml"))
        #else
        let mute = try Listening()
        defer { mute.stop() }
        let silent = mute.url("/description.xml")
        #endif

        let timingOut = ScanTally(URLSessionTransport())
        _ = try? await timingOut.send(HTTPRequest(url: silent, timeout: 0.5))
        let timedOut = await timingOut.counts
        XCTAssertEqual(timedOut.timedOut, 1, "not timed out: \(timedOut.summary)")
        XCTAssertFalse(timedOut.mostTurnedAway, "a request that timed out was taken for one turned away")

        let endedEarly = ScanTally(URLSessionTransport())
        let request = Task { _ = try? await endedEarly.send(HTTPRequest(url: silent, timeout: 30)) }
        try await Task.sleep(for: .milliseconds(300))
        request.cancel()
        await request.value
        let cancelled = await endedEarly.counts
        XCTAssertEqual(cancelled.failed, [-999: 1], "not counted as cancelled: \(cancelled.summary)")
        XCTAssertFalse(cancelled.mostTurnedAway, "a request the search ended was taken for one turned away")
    }
}

/// A server on the loopback that answers every request with the same bytes, closes, and keeps the request
/// lines it was sent: a request sent again arrives on a connection of its own and is one more line.
///
/// Written on the sockets every platform has, so that the same tests read what `URLSession` does on Android
/// as on a Mac.
private final class LoopbackServer: @unchecked Sendable {
    private let listening: Int32
    private let port: UInt16
    private let queue = DispatchQueue(label: "loopback server")
    private let lock = NSLock()
    private let answer: Data
    private var lines: [String] = []
    private var stopped = false

    /// What a television answers a client it does not know that asks to register.
    static let challenge = answer(status: "401 Unauthorized", headers: [#"WWW-Authenticate: Basic realm="Private Page""#],
                                  body: #"{"error":[401,"Unauthorized"],"id":1}"#)

    static func answer(status: String, headers: [String], body: String) -> Data {
        let head = ["HTTP/1.1 \(status)", "Content-Type: application/json",
                    "Content-Length: \(body.utf8.count)", "Connection: close"] + headers
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    /// Listening by the time this returns, on a port the system chose, at the loopback address only.
    init(answering answer: Data) throws {
        self.answer = answer
        let socket = try Listening()
        listening = socket.handle
        port = socket.port
        queue.async { [self] in serve() }
    }

    /// The first line of each request received, in the order they came.
    var requests: [String] { lock.withLock { lines } }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// Stops taking connections within a twentieth of a second, and closes the socket it listened on.
    func stop() { lock.withLock { stopped = true } }

    /// Takes one connection at a time until stopped, looking for one every twentieth of a second: a socket
    /// closed under a thread waiting on it does not wake the thread on every platform, a wait that times out does.
    private func serve() {
        while !lock.withLock({ stopped }) {
            var waiting = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 50) > 0 else { continue }
            let connection = accept(listening, nil, nil)
            if connection >= 0 { answer(connection) }
        }
        close(listening)
    }

    /// Reads until the request is whole -- its head, and as much body as the head says -- then answers and closes.
    private func answer(_ connection: Int32) {
        defer { close(connection) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[..<count])
            guard let line = Self.requestLine(ofWhole: received) else { continue }
            lock.withLock { lines.append(line) }
            sendAll(answer, on: connection)
            return
        }
    }

    private static func requestLine(ofWhole received: Data) -> String? {
        guard let head = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: received[..<head.lowerBound], as: UTF8.self)
        let length = text.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard received.count - head.upperBound >= length else { return nil }
        return text.components(separatedBy: "\r\n")[0]
    }

    /// All of it, unless the client has gone, which ends the sending and not the test run: a write to a socket
    /// its other end has closed raises SIGPIPE unless the socket or the call says not to.
    private func sendAll(_ data: Data, on connection: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = send(connection, base + offset, bytes.count - offset, flags)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}

/// A socket listening at the loopback address, on a port the system chose, which takes up nothing by itself:
/// the system completes a connection to it and holds it, and whoever sends there hears nothing back.
private struct Listening {
    let handle: Int32
    let port: UInt16

    init() throws {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw ServerError.call("socket", errno) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(handle, address, length) == 0 && listen(handle, 16) == 0
                    && getsockname(handle, address, &length) == 0
            }
        }
        guard bound else {
            let code = errno
            close(handle)
            throw ServerError.call("bind, listen or getsockname", code)
        }
        self.handle = handle
        port = UInt16(bigEndian: address.sin_port)
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() {
        close(handle)
    }
}

private enum ServerError: Error {
    case call(String, Int32)
}
