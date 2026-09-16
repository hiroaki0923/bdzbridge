import XCTest
@testable import RecorderKit

final class DiscoveryScanTests: XCTestCase {
    func testTheSubnetIsWorkedOutFromTheInterface() {
        let wifi = LocalNetwork.Interface(name: "en0", address: "192.0.2.85", netmask: "255.255.255.0")
        let hosts = LocalNetwork.hosts(around: wifi)

        XCTAssertEqual(hosts.count, 253, "254 usable addresses, without this device")
        XCTAssertEqual(hosts.first, "192.0.2.1")
        XCTAssertEqual(hosts.last, "192.0.2.254")
        XCTAssertFalse(hosts.contains("192.0.2.85"), "no point asking ourselves")
        XCTAssertFalse(hosts.contains("192.0.2.0"))
        XCTAssertFalse(hosts.contains("192.0.2.255"))
    }

    func testAWideMaskIsNarrowedToTheAddressesNearby() {
        let wide = LocalNetwork.Interface(name: "en0", address: "10.1.2.3", netmask: "255.255.0.0")
        let hosts = LocalNetwork.hosts(around: wide, maxHosts: 100)

        XCTAssertLessThanOrEqual(hosts.count, 100, "a /16 would be sixty-five thousand requests")
        XCTAssertTrue(hosts.contains("10.1.2.4"))
        XCTAssertTrue(hosts.contains("10.1.1.209"))
    }

    func testScanningFindsOnlyRecorders() async throws {
        let description = try Vectors.load("description.json").string("description_xml")
        let television = "<root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
            + "<manufacturer>Sony Corporation</manufacturer><friendlyName>TV</friendlyName></device></root>"
        let transport = StubTransport { request, _ in
            switch request.url.host() {
            case "192.0.2.10": HTTPResponse(statusCode: 200, body: Data(description.utf8))
            case "192.0.2.20": HTTPResponse(statusCode: 200, body: Data(television.utf8))
            case "192.0.2.30": HTTPResponse(statusCode: 404)
            default: throw RecorderError.transport("no route")
            }
        }
        let hosts = (1...40).map { "192.0.2.\($0)" }

        let seen = Counter()
        let found = await Discovery.scan(hosts: hosts, transport: transport, timeout: 0.1,
                                         progress: { done, _ in seen.bump(done) })

        XCTAssertEqual(found.map(\.host), ["192.0.2.10"])
        XCTAssertEqual(found.first?.product, "BDZ-FBT4100")
        XCTAssertEqual(found.first?.via, "scan")
        let asked = await transport.requests.count
        XCTAssertEqual(seen.highest, hosts.count, "every address is reported as tried")
        XCTAssertEqual(asked, hosts.count)
    }

    /// A request the session never gives up on must not hold the whole scan: seen on an iPhone, stuck at
    /// its last address.
    func testAProbeThatNeverAnswersStillEnds() async throws {
        let description = try Vectors.load("description.json").string("description_xml")
        let transport = StubTransport { request, _ in
            if request.url.host == "192.0.2.9" {
                try await Task.sleep(for: .seconds(60))   // cancelled by the deadline, never by itself
            }
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        let started = Date()
        let handedOver = HandedOver()
        let found = await Discovery.scan(hosts: ["192.0.2.9", "192.0.2.10"], transport: transport, timeout: 0.2,
                                         found: { recorder in Task { await handedOver.add(recorder.host) } })
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline, not the sleep, ends the probe")
        XCTAssertEqual(found.map(\.host), ["192.0.2.10"])
        let hosts = await handedOver.hosts
        XCTAssertEqual(hosts, ["192.0.2.10"], "a recorder is handed over as soon as it answers")
    }

    func testThisDeviceReportsItsOwnInterfaces() {
        // whatever the machine running the tests happens to have, an address and a mask should parse
        for interface in LocalNetwork.interfaces() {
            XCTAssertNotNil(LocalNetwork.packed(interface.address), interface.name)
            XCTAssertNotNil(LocalNetwork.packed(interface.netmask), interface.name)
        }
    }
}

/// The progress callback may be called from anywhere, so the test counts behind a lock.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump(_ to: Int) { lock.withLock { value = max(value, to) } }
    var highest: Int { lock.withLock { value } }
}

/// What the scan handed over while it was still running, gathered where a @Sendable closure may write.
private actor HandedOver {
    private(set) var hosts: [String] = []
    func add(_ host: String) { hosts.append(host) }
}
