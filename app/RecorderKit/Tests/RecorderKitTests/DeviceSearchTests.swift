import Foundation
import XCTest
@testable import RecorderKit

/// The one search for both kinds of device: each address asked for a recorder's description and a television's
/// interface at once, what is taken for either, that the look ends, and what a press came to as it is said.
/// Through a stub that answers by address and port; the addresses are reserved for documentation and nothing
/// leaves the machine.
final class DeviceSearchTests: XCTestCase {
    /// What a device answers `getInterfaceInformation` with, of the category given.
    private static func interface(_ category: String, model: String = DemoTV.model) -> HTTPResponse {
        let fields = #"{"productCategory":"\#(category)","productName":"BRAVIA","modelName":"\#(model)","#
            + #""serverName":"","interfaceVersion":"5.7.0"}"#
        return HTTPResponse(statusCode: 200, body: Data(#"{"result":[\#(fields)],"id":1}"#.utf8))
    }

    private static func silence() -> RecorderError { RecorderError.transport("The request timed out.") }

    /// A recorder answers its description, a television says it is one with its model, and nothing else is
    /// taken: not a device of another category at port 80, not a page that is not there, not silence.
    func testARecorderAndATelevisionAreTakenAndNothingElse() async throws {
        let description = try Vectors.descriptionXML()
        let transport = StubTransport { request, _ in
            switch (request.url.host() ?? "", request.url.port) {
            case ("192.0.2.10", Upnp.port): return HTTPResponse(statusCode: 200, body: Data(description.utf8))
            case ("192.0.2.30", 80): return Self.interface("tv")
            case ("192.0.2.31", 80): return Self.interface("audio", model: "STR-SAMPLE")
            case ("192.0.2.32", 80): return HTTPResponse(statusCode: 404)
            default: throw Self.silence()
            }
        }
        let hosts = ["192.0.2.10", "192.0.2.30", "192.0.2.31", "192.0.2.32", "192.0.2.33"]

        let found = await DeviceSearch.scan(hosts: hosts, transport: transport, timeout: 0.2)

        XCTAssertEqual(found.recorders.map(\.host), ["192.0.2.10"])
        XCTAssertEqual(found.recorders.first?.product, "BDZ-FBT4100")
        XCTAssertEqual(found.televisions, [TVSighting(host: "192.0.2.30", model: DemoTV.model)])
    }

    /// Each address is asked two things, once each: the recorder's `description.xml` at its port, and
    /// `getInterfaceInformation` 1.0 at `/sony/system` on port 80, which needs no registration, with no cookie
    /// and no PIN. Nothing else goes to a television, which is asked here as a real one would be.
    func testEachAddressIsAskedOnceOfEachKindAndATelevisionNothingElse() async throws {
        let television = DemoTV(power: "active")
        let transport = StubTransport { request, _ in
            guard request.url.port == 80 else { throw Self.silence() }
            return try await television.send(request)
        }
        let hosts = ["192.0.2.10", "192.0.2.11", "192.0.2.12"]

        let found = await DeviceSearch.scan(hosts: hosts, transport: transport, timeout: 0.5)

        XCTAssertEqual(found.televisions.map(\.host), hosts)
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 2 * hosts.count, "an address was asked more or fewer than two things")
        let recorders = sent.filter { $0.url.port == Upnp.port }
        let televisions = sent.filter { $0.url.port == 80 }
        XCTAssertEqual(recorders.compactMap { $0.url.host() }.sorted(), hosts)
        XCTAssertEqual(televisions.compactMap { $0.url.host() }.sorted(), hosts)
        for request in recorders {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.path, "/description.xml")
        }
        for request in televisions {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.url.path, "/sony/system")
            XCTAssertNil(request.headers["Cookie"], "a cookie went to the subnet")
            XCTAssertNil(request.headers["Authorization"], "a PIN went to the subnet")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
            XCTAssertEqual(body["method"] as? String, "getInterfaceInformation")
            XCTAssertEqual(body["version"] as? String, "1.0")
        }
        expectEqual(await television.calls, Array(repeating: "getInterfaceInformation cookie=no pin=no",
                                                  count: hosts.count),
                    "a television was asked something else: its power, a registration, to switch on")
    }

    /// The two requests of an address go out together: with the recorder's request held, the television's is
    /// out all the same, so that an address takes as long as the slower of the two and not their sum.
    func testAnAddressIsAskedBothThingsAtOnce() async throws {
        let gate = Gate()
        let transport = StubTransport { request, _ in
            if request.url.port == Upnp.port { await gate.wait() }
            throw Self.silence()
        }

        let look = Task { await DeviceSearch.scan(hosts: ["192.0.2.10"], transport: transport, timeout: 2) }
        try await until("the television's request was not out while the recorder's was held") {
            await transport.requests.contains { $0.url.port == 80 }
        }
        await gate.open()
        _ = await look.value
    }

    /// A request that never comes back still ends the look, by the deadline each probe is raced against, of
    /// either kind: here a recorder's at one address and a television's at another.
    func testARequestOfEitherKindThatNeverAnswersStillEndsTheLook() async {
        let transport = StubTransport { request, _ in
            switch (request.url.host() ?? "", request.url.port) {
            case ("192.0.2.9", Upnp.port), ("192.0.2.10", 80):
                try await Task.sleep(for: .seconds(10))   // ended by the deadline, never by itself
            default: break
            }
            throw Self.silence()
        }
        let started = Date()

        let found = await DeviceSearch.scan(hosts: ["192.0.2.9", "192.0.2.10"], transport: transport, timeout: 0.2)

        XCTAssertEqual(found, DeviceSightings(recorders: [], televisions: []))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline, not the request, ended the look")
    }

    /// The progress counts addresses, each done once both its requests are, out of as many as there are
    /// addresses. What is found is handed over as soon as its own request has answered, while the look still
    /// goes on: a recorder at an address whose port 80 has not answered yet, and a television, before an
    /// address that is held.
    func testProgressCountsAddressesAndEachSightingIsHandedOverAsItAnswers() async throws {
        let description = try Vectors.descriptionXML()
        let gate = Gate()
        let transport = StubTransport { request, _ in
            switch (request.url.host() ?? "", request.url.port) {
            case ("192.0.2.10", Upnp.port): return HTTPResponse(statusCode: 200, body: Data(description.utf8))
            case ("192.0.2.10", 80), ("192.0.2.9", _): await gate.wait()
            case ("192.0.2.30", 80): return Self.interface("tv")
            default: break
            }
            throw Self.silence()
        }
        let hosts = ["192.0.2.9", "192.0.2.10", "192.0.2.30", "192.0.2.40"]
        let seen = Seen()

        let look = Task {
            await DeviceSearch.scan(hosts: hosts, transport: transport, timeout: 2,
                                    progress: { done, total in Task { await seen.progressed(done, of: total) } },
                                    found: { sighting in Task { await seen.handedOver(sighting) } })
        }
        try await until("what had answered was not handed over while the look went on") {
            await seen.sightings.count == 2
        }
        expectEqual(Set(await seen.sightings.map(\.host)), ["192.0.2.10", "192.0.2.30"])
        await gate.open()
        let found = await look.value
        try await until("the last address's progress never came") { await seen.highest == hosts.count }

        XCTAssertEqual(found.recorders.map(\.host), ["192.0.2.10"])
        XCTAssertEqual(found.televisions.map(\.host), ["192.0.2.30"])
        expectEqual(await seen.totals, [hosts.count], "the progress was not out of the addresses")
        expectEqual(await seen.highest, hosts.count, "not every address was counted done")
    }

    /// What a press came to, in the words under the button: the recorder's sentence as it has always been
    /// when recorders are all that was found, the television's when they are, both in one sentence, and none.
    /// The causes are said under none alone, and only nothing found and no Wi-Fi are failures.
    func testWhatAPressCameToIsSaidByWhatItFound() {
        XCTAssertEqual(DeviceSearch.Outcome.found(recorders: 1, televisions: 0).text, "レコーダーが 1 台見つかりました")
        XCTAssertEqual(DeviceSearch.Outcome.found(recorders: 0, televisions: 2).text, "テレビが 2 台見つかりました")
        XCTAssertEqual(DeviceSearch.Outcome.found(recorders: 2, televisions: 1).text,
                       "レコーダーが 2 台、テレビが 1 台見つかりました")
        XCTAssertEqual(DeviceSearch.Outcome.nothing.text, "レコーダーもテレビも見つかりませんでした")
        XCTAssertEqual(DeviceSearch.Outcome.noWiFi.text,
                       "Wi-Fi に接続されていません。レコーダーやテレビと同じ Wi-Fi につないでから、もう一度お試しください。")
        XCTAssertEqual(DeviceSearch.Outcome.nothing.causes.count, 5)
        XCTAssertTrue(DeviceSearch.Outcome.nothing.causes.contains { $0.hasPrefix("テレビの電源が切れている。") })
        XCTAssertEqual(DeviceSearch.Outcome.found(recorders: 1, televisions: 1).causes, [])
        XCTAssertEqual(DeviceSearch.Outcome.noWiFi.causes, [])
        XCTAssertFalse(DeviceSearch.Outcome.found(recorders: 0, televisions: 1).failed)
        XCTAssertTrue(DeviceSearch.Outcome.nothing.failed)
        XCTAssertTrue(DeviceSearch.Outcome.noWiFi.failed)
    }

    /// Waits for `condition`, a few seconds at most: for what the search's own tasks get round to.
    private func until(_ what: String, within seconds: Double = 3, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while await !condition() {
            guard Date() < end else { return XCTFail(what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private extension Sighting {
    var host: String {
        switch self {
        case .recorder(let recorder): recorder.host
        case .television(let television): television.host
        }
    }
}

/// Holds whoever waits on it until it is opened, and lets through at once whoever comes after.
private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        for one in waiting { one.resume() }
        waiting = []
    }
}

/// What the search's callbacks were handed, gathered where a @Sendable closure may write.
private actor Seen {
    private(set) var sightings: [Sighting] = []
    private(set) var highest = 0
    private(set) var totals: Set<Int> = []

    func handedOver(_ sighting: Sighting) { sightings.append(sighting) }

    func progressed(_ done: Int, of total: Int) {
        highest = max(highest, done)
        totals.insert(total)
    }
}
