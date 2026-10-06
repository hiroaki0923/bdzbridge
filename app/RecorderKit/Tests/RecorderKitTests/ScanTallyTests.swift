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

    /// Requests were turned away whole when at least one was made and every one of them failed some way that
    /// is none of the ways a request that was out comes back. The rule is each of those ways being absent,
    /// and not one code: here each in turn is one request among a subnet's that were turned away, and then
    /// the only one made.
    func testRequestsWereTurnedAwayWholeOnlyWhenNotOneWasAnsweredOrOutForItsTime() {
        func counts(_ counted: (inout ScanTally.Counts) -> Void) -> ScanTally.Counts {
            var counts = ScanTally.Counts()
            counted(&counts)
            return counts
        }
        XCTAssertTrue(counts { $0.failed[-1009] = 253 }.turnedAwayWhole,
                      "no network to send on, at every address of a subnet")
        XCTAssertTrue(counts { $0.failed[-1009] = 1 }.turnedAwayWhole, "the one request made")
        XCTAssertTrue(counts { $0.failed = [-1020: 200, -1009: 50]; $0.other = 3 }.turnedAwayWhole,
                      "turned away is not one code: any failure that is none of the ways below")
        XCTAssertFalse(ScanTally.Counts().turnedAwayWhole, "nothing was asked, so nothing was turned away")

        let waysOfHavingBeenOut: [(String, (inout ScanTally.Counts) -> Void)] = [
            ("answered by a recorder", { $0.answered[200] = 1 }),
            ("answered with an error", { $0.answered[500] = 1 }),
            ("timed out", { $0.timedOut = 1 }),
            ("timed out, counted by its code", { $0.failed[-1001] = 1 }),
            ("cancelled for outliving its time", { $0.failed[-999] = 1 }),
            ("refused by an address", { $0.failed[-1004] = 1 }),
            ("dropped by an address", { $0.failed[-1005] = 1 }),
        ]
        for (way, counted) in waysOfHavingBeenOut {
            var amongTheRest = counts { $0.failed[-1009] = 252 }
            counted(&amongTheRest)
            XCTAssertFalse(amongTheRest.turnedAwayWhole, "one request \(way), the rest turned away")
            XCTAssertFalse(counts(counted).turnedAwayWhole, "the one request made, \(way)")
        }
    }

    /// One request of a search's kind to one address, read for whether it was turned away: the address's
    /// `description.xml`, asked for once, with the time a search gives an address. Turned away when it failed
    /// with no network to send on, and not when it was answered by anybody, timed out or was refused.
    func testOneRequestToOneAddressIsReadForWhetherItWasTurnedAway() async {
        let host = "192.0.2.1"
        let waysBack: [(String, Bool, @Sendable () throws -> HTTPResponse)] = [
            ("no network to send on", true, { throw Self.failure(-1009, at: host) }),
            ("timed out", false, { throw Self.failure(-1001, at: host) }),
            ("refused", false, { throw Self.failure(-1004, at: host) }),
            ("answered by something that is no recorder", false, { HTTPResponse(statusCode: 404) }),
            ("answered with a description", false, { HTTPResponse(statusCode: 200, body: Data("サンプル".utf8)) }),
        ]
        for (way, expected, comesBack) in waysBack {
            let stub = StubTransport { _, _ in try comesBack() }

            let turnedAway = await Discovery.turnedAway(at: host, transport: stub)

            XCTAssertEqual(turnedAway, expected, way)
            let requests = await stub.requests
            XCTAssertEqual(requests.map(\.url.absoluteString), ["http://192.0.2.1:64220/description.xml"], way)
            XCTAssertEqual(requests.map(\.method), ["GET"], way)
            XCTAssertEqual(requests.map(\.timeout), [1.2], "\(way): not the time a search gives an address")
        }
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
