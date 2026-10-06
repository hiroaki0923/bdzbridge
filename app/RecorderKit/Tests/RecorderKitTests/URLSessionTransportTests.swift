import Foundation
import Network
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
                let server = try await LoopbackServer(answering: LoopbackServer.challenge)
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
        let server = try await LoopbackServer(answering: LoopbackServer.answer(
            status: "200 OK", headers: ["Set-Cookie: auth=sample; Max-Age=1209600"], body: #"{"result":[]}"#))
        defer { server.stop() }

        let response = try await URLSessionTransport.withoutCookies().send(HTTPRequest(
            url: server.url("/sony/system"), method: "POST", body: Data("{}".utf8), timeout: 5))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.text, #"{"result":[]}"#)
        XCTAssertEqual(response.header("set-cookie"), "auth=sample; Max-Age=1209600")
        XCTAssertEqual(server.requests, ["POST /sony/system HTTP/1.1"])
    }

    /// A request that fails in transit is kept as the system's own text for the failure, and a search's tally
    /// reads the system's code back out of that text (`ScanTally`). The wording is the system's, so it is
    /// looked at with the real session: a connection refused on the loopback, where nothing listens on port 9.
    func testAFailureInTransitKeepsTheSystemsCodeForASearchsTally() async throws {
        let server = try await LoopbackServer(answering: LoopbackServer.answer(
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
    /// so a look made of such addresses was not turned away (`ScanTally.Counts.mostTurnedAway`). 127.0.0.2 is
    /// the loopback network's and nobody's: what is sent there never leaves this machine and is never answered.
    func testASilentAddressCountsAsARequestThatWasOut() async throws {
        let silent = try XCTUnwrap(URL(string: "http://127.0.0.2:9/description.xml"))

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
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback server")
    private let lock = NSLock()
    private let answer: Data
    private var lines: [String] = []

    /// What a television answers a client it does not know that asks to register.
    static let challenge = answer(status: "401 Unauthorized", headers: [#"WWW-Authenticate: Basic realm="Private Page""#],
                                  body: #"{"error":[401,"Unauthorized"],"id":1}"#)

    static func answer(status: String, headers: [String], body: String) -> Data {
        let head = ["HTTP/1.1 \(status)", "Content-Type: application/json",
                    "Content-Length: \(body.utf8.count)", "Connection: close"] + headers
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    /// Listening by the time this returns, on a port the system chose, at the loopback address only.
    init(answering answer: Data) async throws {
        self.answer = answer
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let started = Once()
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                // Anything but ready ends the wait: a test left waiting for a listener would never end.
                switch state {
                case .ready: started.first { waiting.resume() }
                case .failed(let error), .waiting(let error): started.first { waiting.resume(throwing: error) }
                case .cancelled: started.first { waiting.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The first line of each request received, in the order they came.
    var requests: [String] { lock.withLock { lines } }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)\(path)")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, so: Data())
    }

    /// Reads until the request is whole -- its head, and as much body as the head says -- then answers.
    private func read(_ connection: NWConnection, so far: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self else { return }
            let received = far + (data ?? Data())
            if let head = received.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(decoding: received[..<head.lowerBound], as: UTF8.self)
                let length = text.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if received.count - head.upperBound >= length {
                    self.lock.withLock { self.lines.append(text.components(separatedBy: "\r\n")[0]) }
                    connection.send(content: self.answer, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if ended || error != nil {
                connection.cancel()
            } else {
                self.read(connection, so: received)
            }
        }
    }
}

/// Runs the first thing it is handed and nothing after: a listener reports its state more than once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first(_ body: () -> Void) {
        let isFirst = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if isFirst { body() }
    }
}
