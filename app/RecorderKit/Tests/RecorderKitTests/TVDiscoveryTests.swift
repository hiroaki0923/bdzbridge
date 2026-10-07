import Foundation
import XCTest
@testable import RecorderKit

/// Looking through the subnet for a television that has moved, by the MAC it wakes on: what each address is
/// asked, which answer is taken, and that the look ends -- at the television, or at a deadline of its own where
/// a request never comes back. Through a stub that answers by address; nothing here leaves the machine.
final class TVDiscoveryTests: XCTestCase {
    /// What a television answers `getSystemSupportedFunction` with, its MAC spelled as given.
    private static func wakesOn(_ mac: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"result":[[{"option":"WOL","value":"\#(mac)"}]],"id":1}"#.utf8))
    }

    /// The television whose MAC is the one asked for is found, the two compared as the app keeps a MAC, however
    /// either is spelled. Another television's MAC is not it, and neither is a device that answers otherwise.
    /// The rest of the subnet is not asked once it has answered.
    func testATelevisionIsFoundByTheMACItWakesOn() async {
        let transport = StubTransport { request, _ in
            switch request.url.host() {
            case "192.0.2.10": return Self.wakesOn("f8:4e:17:00:00:0b")
            case "192.0.2.11": return HTTPResponse(statusCode: 404)
            case "192.0.2.12": return HTTPResponse(statusCode: 200, body: Data("<html></html>".utf8))
            case "192.0.2.70": return Self.wakesOn("F8-4E-17-00-00-0A")
            case "192.0.2.71": return Self.wakesOn("f8:4e:17:00:00:0a")
            default:
                try await Task.sleep(for: .milliseconds(50))
                throw RecorderError.transport("no route")
            }
        }
        // The other spelling's address is left to the second look.
        let hosts = (1...200).filter { $0 != 71 }.map { "192.0.2.\($0)" }

        let found = await TVDiscovery.find(mac: DemoTV.mac, among: hosts, transport: transport, timeout: 0.5,
                                           atOnce: 8)

        XCTAssertEqual(found, "192.0.2.70")
        let asked = await transport.requests.count
        XCTAssertLessThan(asked, hosts.count, "the rest of the subnet was asked once the television had answered")

        let typed = await TVDiscovery.find(mac: "F8-4E-17-00-00-0A", among: ["192.0.2.71"], transport: transport)
        XCTAssertEqual(typed, "192.0.2.71", "the MAC asked for was compared as it was spelled")
        let another = await TVDiscovery.find(mac: "f8:4e:17:00:00:0c", among: (1...20).map { "192.0.2.\($0)" },
                                             transport: transport, timeout: 0.5)
        XCTAssertNil(another, "another television was taken for the one asked for")
    }

    /// Each address is asked one thing, the thing an attach asks first: `getSystemSupportedFunction` 1.0, at
    /// `/sony/system` on port 80, which needs no registration. With no cookie and no PIN.
    func testEachAddressIsAskedWhichTelevisionItIsAndNothingElse() async throws {
        let transport = StubTransport { _, _ in Self.wakesOn("f8:4e:17:00:00:0b") }
        let hosts = ["192.0.2.10", "192.0.2.11", "192.0.2.12"]

        let found = await TVDiscovery.find(mac: DemoTV.mac, among: hosts, transport: transport)

        XCTAssertNil(found)
        let sent = await transport.requests
        XCTAssertEqual(sent.count, hosts.count, "an address was asked more than once")
        XCTAssertEqual(Set(sent.compactMap { $0.url.host() }), Set(hosts))
        for request in sent {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.url.port, 80)
            XCTAssertEqual(request.url.path, "/sony/system")
            XCTAssertNil(request.headers["Cookie"], "a cookie went to the subnet")
            XCTAssertNil(request.headers["Authorization"], "a PIN went to the subnet")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
            XCTAssertEqual(body["method"] as? String, "getSystemSupportedFunction")
            XCTAssertEqual(body["version"] as? String, "1.0")
        }
    }

    /// A request that never comes back still ends the look, by the deadline each probe is raced against, as a
    /// look for a recorder is.
    func testARequestThatNeverAnswersStillEndsTheLook() async {
        let transport = StubTransport { request, _ in
            if request.url.host() == "192.0.2.9" {
                try await Task.sleep(for: .seconds(60))   // cancelled by the deadline, never by itself
            }
            throw RecorderError.transport("no route")
        }
        let started = Date()

        let found = await TVDiscovery.find(mac: DemoTV.mac, among: ["192.0.2.9", "192.0.2.10"], transport: transport,
                                           timeout: 0.2)

        XCTAssertNil(found)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline, not the request, ended the look")
    }

    /// A probe that begins once its look is over sends nothing, as the probes not yet begun when the look finds
    /// the television: here the whole look is cancelled before it begins, and no address hears anything.
    func testAProbeBegunOnceTheLookIsOverSendsNothing() async throws {
        let transport = StubTransport { _, _ in Self.wakesOn(DemoTV.mac) }
        let look = Task {
            try? await Task.sleep(for: .seconds(60))   // ended by the cancellation below, so the look begins after it
            return await TVDiscovery.find(mac: DemoTV.mac, among: ["192.0.2.10", "192.0.2.11"], transport: transport)
        }
        look.cancel()

        let found = await look.value
        // A probe's request goes from a task of its own, which the look does not wait for: given the time, it would
        // have been heard by now.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(found)
        expectEqual(await transport.requests.count, 0, "a probe begun after the look was over sent its request")
    }
}
