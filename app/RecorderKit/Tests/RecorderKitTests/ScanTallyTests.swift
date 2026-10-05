import XCTest
@testable import RecorderKit

/// How a search's requests came back, counted for its line in the log. The transport is a stub and the
/// addresses are reserved for documentation: nothing leaves this machine.
final class ScanTallyTests: XCTestCase {
    /// The system's text for a failure in transit, as `URLSessionTransport` keeps it: the domain and the code
    /// first, and the address the request was for further on.
    private static func failure(_ code: Int, at host: String) -> RecorderError {
        .transport("Error Domain=NSURLErrorDomain Code=\(code) \"(null)\" UserInfo={"
                   + "NSErrorFailingURLStringKey=http://\(host):64220/description.xml, "
                   + "NSUnderlyingError={Error Domain=kCFErrorDomainCFNetwork Code=\(code)}}")
    }

    /// Each way a request can come back is counted under its own head, and the answer or the failure goes on
    /// to the search as it came. The line for the log has the counts and the codes, and nothing of where a
    /// request was sent, though the system's text for a failure names the address.
    func testEachRequestIsCountedByHowItCameBackAndHandedOnAsItCame() async {
        let stub = StubTransport { request, _ in
            let host = request.url.host() ?? ""
            switch host {
            case "192.0.2.1": return HTTPResponse(statusCode: 200, body: Data("サンプル".utf8))
            case "192.0.2.2", "192.0.2.3": return HTTPResponse(statusCode: 404)
            case "192.0.2.4": throw Self.failure(-1001, at: host)
            case "192.0.2.5", "192.0.2.6": throw Self.failure(-1009, at: host)
            case "192.0.2.7": throw Self.failure(-1004, at: host)
            case "192.0.2.8": throw RecorderError.transport("Nobody here.")
            default: throw RecorderError.notHTTP
            }
        }
        let tally = ScanTally(stub)

        var cameBack: [String] = []
        for last in 1...9 {
            let host = "192.0.2.\(last)"
            do {
                let response = try await tally.send(HTTPRequest(url: URL(string: "http://\(host):64220/")!))
                cameBack.append("\(response.statusCode) \(response.text)")
            } catch let error as RecorderError {
                cameBack.append(error == Self.failure(-1001, at: host) ? "timed out"
                    : error == Self.failure(-1009, at: host) ? "no network"
                    : error == Self.failure(-1004, at: host) ? "refused" : "\(error)")
            } catch {
                cameBack.append("\(error)")
            }
        }

        XCTAssertEqual(cameBack, ["200 サンプル", "404 ", "404 ", "timed out", "no network", "no network", "refused",
                                  "transport(\"Nobody here.\")", "notHTTP"],
                       "what came back was not handed on as it came")
        let counts = await tally.counts
        XCTAssertEqual(counts.answered, [200: 1, 404: 2])
        XCTAssertEqual(counts.timedOut, 1)
        XCTAssertEqual(counts.failed, [-1009: 2, -1004: 1])
        XCTAssertEqual(counts.other, 2)
        XCTAssertEqual(counts.asked, 9)
        XCTAssertEqual(counts.summary,
                       "asked 9; answered [200: 1, 404: 2]; timed out 1; failed [-1009: 2, -1004: 1]; other 2")
    }

    /// A search through a tally finds what it finds without one, and every address it asked is in the counts.
    func testASearchThroughATallyFindsTheSameAndCountsEveryAddress() async throws {
        let description = try Vectors.descriptionXML()
        let hosts = (1...254).filter { $0 != 20 }.map { "192.0.2.\($0)" }
        let recorder = "192.0.2.10"
        let stub = StubTransport { request, _ in
            let host = request.url.host() ?? ""
            guard host == recorder else { throw Self.failure(-1001, at: host) }
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        let tally = ScanTally(stub)

        let found = await Discovery.scan(hosts: hosts, transport: tally)

        XCTAssertEqual(found.map(\.host), [recorder])
        let counts = await tally.counts
        XCTAssertEqual(counts.answered, [200: 1])
        XCTAssertEqual(counts.timedOut, hosts.count - 1)
        XCTAssertEqual(counts.asked, hosts.count)
        expectEqual(await stub.requests.count, hosts.count, "the search asked more or fewer for the tally")
    }
}
