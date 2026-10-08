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

    /// A look was turned away when the requests the system turned away -- failed with a code of its own that is
    /// none of the ways a request that was out comes back -- outnumber all the rest together, answered ones
    /// included. By most and not by every one, since an address the system lets through unasked comes back as
    /// it would with the permission given: the look one phone made behind the system's question, on
    /// 2026-10-06, is a row, and so are an address that drops the port where that one refused it, and two such
    /// addresses. With the permission given the system turns nothing away, and a look of that is not turned
    /// away, nor one in which every address refused. Then each way back that is not the system turning the
    /// request away, among a subnet's turned away and as the only request made, which is how a search reads
    /// the one request it sends again.
    func testALookWasTurnedAwayWhenTheRequestsTheSystemTurnedAwayOutnumberTheRest() {
        func counts(_ counted: (inout ScanTally.Counts) -> Void) -> ScanTally.Counts {
            var counts = ScanTally.Counts()
            counted(&counts)
            return counts
        }
        let turnedAway: [(String, ScanTally.Counts)] = [
            ("the phone's look behind the question: one address let through, refusing, and the rest turned away",
             counts { $0.failed = [-1009: 252, -1004: 1] }),
            ("a drop: one address let through, silent on the port so timing out, and the rest turned away",
             counts { $0.failed[-1009] = 252; $0.timedOut = 1 }),
            ("two exempt hosts, one refusing and one silent, and the rest turned away",
             counts { $0.failed = [-1009: 251, -1004: 1]; $0.timedOut = 1 }),
            ("no network to send on, at every address of a subnet", counts { $0.failed[-1009] = 253 }),
            ("turned away is not one code: any failure that is none of the ways of having been out",
             counts { $0.failed = [-1020: 200, -1009: 50]; $0.other = 3 }),
            ("the one request made, turned away", counts { $0.failed[-1009] = 1 }),
        ]
        for (look, counts) in turnedAway {
            XCTAssertTrue(counts.mostTurnedAway, look)
        }
        let notTurnedAway: [(String, ScanTally.Counts)] = [
            ("nothing asked, so nothing turned away", ScanTally.Counts()),
            ("every address refusing at once", counts { $0.failed[-1004] = 253 }),
            ("no request turned away: the permission given, one answering, most timing out and a few refusing",
             counts { $0.answered[200] = 1; $0.timedOut = 240; $0.failed[-1004] = 12 }),
            ("most out and a few turned away, as when the permission comes while a look goes",
             counts { $0.failed[-1009] = 5; $0.timedOut = 248 }),
            ("as many turned away as the rest, an answer among the rest",
             counts { $0.failed[-1009] = 2; $0.answered[200] = 1; $0.timedOut = 1 }),
        ]
        for (look, counts) in notTurnedAway {
            XCTAssertFalse(counts.mostTurnedAway, look)
        }

        let waysBackNotTurnedAway: [(String, (inout ScanTally.Counts) -> Void)] = [
            ("answered by a recorder", { $0.answered[200] = 1 }),
            ("answered with an error", { $0.answered[500] = 1 }),
            ("timed out", { $0.timedOut = 1 }),
            ("timed out, counted by its code", { $0.failed[-1001] = 1 }),
            ("cancelled for outliving its time", { $0.failed[-999] = 1 }),
            ("refused", { $0.failed[-1004] = 1 }),
            ("its connection dropped", { $0.failed[-1005] = 1 }),
            ("failed with no code of the system's", { $0.other = 1 }),
        ]
        for (way, counted) in waysBackNotTurnedAway {
            var amongTheRest = counts { $0.failed[-1009] = 252 }
            counted(&amongTheRest)
            XCTAssertTrue(amongTheRest.mostTurnedAway, "one request \(way), the rest turned away")
            XCTAssertFalse(counts(counted).mostTurnedAway, "the one request made, \(way)")
        }
    }

    /// One request of a search's kind to one address, read for whether it was turned away: the address's
    /// `description.xml`, asked for once, with the time a search gives an address. Turned away when it failed
    /// with no network to send on, and not when it was answered by anybody, timed out, was cancelled for
    /// outliving its time, or was refused or dropped: the address is one a look saw the system turn away, so
    /// not one it lets through unasked, and its turning a request down comes from the local network. Nor when
    /// it failed with no code of the system's, which says nothing of the system. A tally of the caller's own
    /// that the request goes through has how it came back in a status or a code, for the log.
    func testOneRequestToOneAddressIsReadForWhetherItWasTurnedAway() async {
        let host = "192.0.2.1"
        let waysBack: [(String, Bool, String, @Sendable () throws -> HTTPResponse)] = [
            ("no network to send on", true, "-1009", { throw Self.failure(-1009, at: host) }),
            ("timed out", false, "-1001", { throw Self.failure(-1001, at: host) }),
            ("cancelled for outliving its time", false, "-999", { throw Self.failure(-999, at: host) }),
            ("refused", false, "-1004", { throw Self.failure(-1004, at: host) }),
            ("dropped", false, "-1005", { throw Self.failure(-1005, at: host) }),
            ("failed with no code of the system's", false, "no code", { throw RecorderError.transport("Nobody.") }),
            ("answered by something that is no recorder", false, "404", { HTTPResponse(statusCode: 404) }),
            ("answered with a description", false, "200",
             { HTTPResponse(statusCode: 200, body: Data("サンプル".utf8)) }),
        ]
        for (way, expected, cameBack, comesBack) in waysBack {
            let stub = StubTransport { _, _ in try comesBack() }
            let tally = ScanTally(stub)

            let turnedAway = await Discovery.turnedAway(at: host, transport: tally)

            XCTAssertEqual(turnedAway, expected, way)
            expectEqual(await tally.counts.statusesAndCodes, cameBack, "\(way): not how it came back")
            let requests = await stub.requests
            XCTAssertEqual(requests.map(\.url.absoluteString), ["http://192.0.2.1:64220/description.xml"], way)
            XCTAssertEqual(requests.map(\.method), ["GET"], way)
            XCTAssertEqual(requests.map(\.timeout), [1.2], "\(way): not the time a search gives an address")
        }
    }

    /// The tally keeps the address of the first request the system turned away, for a search to ask again,
    /// and no other: not one an address refused or dropped -- the address the system lets through unasked may
    /// be that one -- nor one answered, timed out, cancelled, or failed with no code of the system's. The
    /// address is in neither the counts nor their summary, which is what goes to the log.
    func testTheTallyKeepsTheFirstAddressTurnedAwayAndNoneThatRefusedNorInItsSummary() async throws {
        let stub = StubTransport { request, _ in
            let host = request.url.host() ?? ""
            switch host {
            case "192.0.2.1": throw Self.failure(-1004, at: host)
            case "192.0.2.2": throw Self.failure(-1005, at: host)
            case "192.0.2.3": throw Self.failure(-1001, at: host)
            case "192.0.2.4": throw Self.failure(-999, at: host)
            case "192.0.2.5": return HTTPResponse(statusCode: 404)
            case "192.0.2.6": throw RecorderError.transport("Nobody here.")
            default: throw Self.failure(-1009, at: host)
            }
        }
        let tally = ScanTally(stub)
        func ask(_ last: Int) async throws {
            let url = try XCTUnwrap(URL(string: "http://192.0.2.\(last):64220/description.xml"))
            _ = try? await tally.send(HTTPRequest(url: url))
        }

        for last in 1...6 { try await ask(last) }
        expectNil(await tally.turnedAwayAt, "an address that turned the request down, or let it out, was kept")
        try await ask(7)
        try await ask(8)

        expectEqual(await tally.turnedAwayAt, "192.0.2.7", "not the first address the system turned away")
        let counts = await tally.counts
        XCTAssertEqual(counts.failed, [-1009: 2, -1005: 1, -1004: 1, -999: 1])
        XCTAssertFalse(counts.summary.contains("192.0.2."), "an address in the summary: \(counts.summary)")
    }

    /// A search that asks two kinds of request keeps the address from the kind it asks again, and from no
    /// other: the address the system lets through unasked may fail at the other port with a code read as
    /// turned away, and asked again it would read as let out. Every request is counted all the same, of
    /// either kind.
    func testATallyKeepingAnAddressFromOnePortKeepsNoneFromAnother() async throws {
        let stub = StubTransport { request, _ in throw Self.failure(-1009, at: request.url.host() ?? "") }
        let tally = ScanTally(stub, keepingAddressFrom: Upnp.port)

        let atEighty = try XCTUnwrap(URL(string: "http://192.0.2.1:80/sony/system"))
        _ = try? await tally.send(HTTPRequest(url: atEighty, method: "POST"))
        expectNil(await tally.turnedAwayAt, "an address was kept from a request at another port")
        let atTheRecordersPort = try XCTUnwrap(URL(string: "http://192.0.2.2:64220/description.xml"))
        _ = try? await tally.send(HTTPRequest(url: atTheRecordersPort))

        expectEqual(await tally.turnedAwayAt, "192.0.2.2", "not the first address turned away at the port named")
        let counts = await tally.counts
        XCTAssertEqual(counts.failed, [-1009: 2], "a request of the other kind was not counted")
        XCTAssertEqual(counts.asked, 2)
    }

    /// A tally starts with no address kept, whatever another kept before it: a search makes one for each look,
    /// and asks again only at an address that look saw turned away.
    func testATallyStartsWithNoAddressKept() async throws {
        let stub = StubTransport { request, _ in
            let host = request.url.host() ?? ""
            throw Self.failure(host == "192.0.2.7" ? -1009 : -1004, at: host)
        }
        func ask(_ last: Int, through tally: ScanTally) async throws {
            let url = try XCTUnwrap(URL(string: "http://192.0.2.\(last):64220/description.xml"))
            _ = try? await tally.send(HTTPRequest(url: url))
        }
        let first = ScanTally(stub)
        try await ask(7, through: first)
        expectEqual(await first.turnedAwayAt, "192.0.2.7", "the first tally kept nothing")

        let second = ScanTally(stub)
        expectNil(await second.turnedAwayAt, "a tally began with an address kept")
        try await ask(1, through: second)
        expectNil(await second.turnedAwayAt, "a tally with nothing turned away had an address kept")
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
