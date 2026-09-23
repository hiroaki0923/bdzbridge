import XCTest
@testable import RecorderKit

final class DiscoveryScanTests: XCTestCase {
    func testTheSubnetIsWorkedOutFromTheInterface() {
        let wifi = LocalNetwork.Interface(name: "en0", address: "192.0.2.85", netmask: "255.255.255.0",
                                          broadcasts: true)
        let hosts = LocalNetwork.hosts(around: wifi)

        XCTAssertEqual(hosts.count, 253, "254 usable addresses, without this device")
        XCTAssertEqual(hosts.first, "192.0.2.1")
        XCTAssertEqual(hosts.last, "192.0.2.254")
        XCTAssertFalse(hosts.contains("192.0.2.85"), "no point asking ourselves")
        XCTAssertFalse(hosts.contains("192.0.2.0"))
        XCTAssertFalse(hosts.contains("192.0.2.255"))
    }

    func testAWideMaskIsNarrowedToTheAddressesNearby() {
        let wide = LocalNetwork.Interface(name: "en0", address: "10.1.2.3", netmask: "255.255.0.0",
                                          broadcasts: true)
        let hosts = LocalNetwork.hosts(around: wide, maxHosts: 100)

        XCTAssertLessThanOrEqual(hosts.count, 100, "a /16 would be sixty-five thousand requests")
        XCTAssertTrue(hosts.contains("10.1.2.4"))
        XCTAssertTrue(hosts.contains("10.1.1.209"))
    }

    /// Cellular and VPN tunnels are not where a recorder lives, and aiming the permission check at one of them
    /// always says yes, because local network privacy is never asked about there.
    func testOnlyWiFiAndEthernetCountAsTheLocalNetwork() {
        let wifi = LocalNetwork.Interface(name: "en0", address: "192.0.2.85", netmask: "255.255.255.0",
                                          broadcasts: true)
        let cellular = LocalNetwork.Interface(name: "pdp_ip0", address: "198.51.100.7",
                                              netmask: "255.255.255.255", broadcasts: false)
        let vpn = LocalNetwork.Interface(name: "utun4", address: "203.0.113.9", netmask: "255.255.255.0",
                                         broadcasts: false)
        let flaggedTunnel = LocalNetwork.Interface(name: "utun5", address: "203.0.113.10",
                                                   netmask: "255.255.255.0", broadcasts: true)

        XCTAssertTrue(wifi.isLAN)
        XCTAssertFalse(cellular.isLAN)
        XCTAssertFalse(vpn.isLAN)
        XCTAssertFalse(flaggedTunnel.isLAN, "a tunnel is left out by its name too, whatever its flags say")
    }

    /// The carrier moves a phone's cellular address whenever it likes, at home as anywhere, and each move
    /// was taken for a change of network: another half-minute of waking a recorder the app had given up on.
    /// Wi-Fi coming or going, and a VPN, still change it.
    func testACellularAddressIsNotPartOfTheNetworkSignature() {
        let wifi = LocalNetwork.Interface(name: "en0", address: "192.0.2.85", netmask: "255.255.255.0",
                                          broadcasts: true)
        let cellular = LocalNetwork.Interface(name: "pdp_ip0", address: "198.51.100.7",
                                              netmask: "255.255.255.255", broadcasts: false)
        let moved = LocalNetwork.Interface(name: "pdp_ip0", address: "198.51.100.99",
                                           netmask: "255.255.255.255", broadcasts: false)
        let vpn = LocalNetwork.Interface(name: "utun4", address: "203.0.113.9", netmask: "255.255.255.0",
                                         broadcasts: false)

        XCTAssertEqual(LocalNetwork.signature(of: [wifi, cellular]), LocalNetwork.signature(of: [wifi, moved]))
        XCTAssertEqual(LocalNetwork.signature(of: [cellular]), LocalNetwork.signature(of: [moved]))
        XCTAssertNotEqual(LocalNetwork.signature(of: [wifi, cellular]), LocalNetwork.signature(of: [cellular]),
                          "leaving the Wi-Fi is a change")
        XCTAssertNotEqual(LocalNetwork.signature(of: [cellular]), LocalNetwork.signature(of: [cellular, vpn]),
                          "a VPN coming up is a change")
    }

    func testThePermissionCheckIsAimedAtANeighbour() {
        let wifi = LocalNetwork.Interface(name: "en0", address: "192.0.2.85", netmask: "255.255.255.0",
                                          broadcasts: true)
        XCTAssertEqual(LocalNetwork.neighbour(on: wifi), "192.0.2.1")

        let router = LocalNetwork.Interface(name: "en0", address: "192.0.2.1", netmask: "255.255.255.0",
                                            broadcasts: true)
        XCTAssertEqual(LocalNetwork.neighbour(on: router), "192.0.2.2", "never this device itself")

        let alone = LocalNetwork.Interface(name: "en0", address: "192.0.2.85", netmask: "255.255.255.255",
                                           broadcasts: true)
        XCTAssertNil(LocalNetwork.neighbour(on: alone), "a /32 has no neighbours")
        let pair = LocalNetwork.Interface(name: "en0", address: "192.0.2.84", netmask: "255.255.255.254",
                                          broadcasts: true)
        XCTAssertNil(LocalNetwork.neighbour(on: pair))
    }

    func testThisDevicesLocalNetworkLeavesTunnelsOut() {
        for interface in LocalNetwork.lanInterfaces() {
            XCTAssertTrue(interface.broadcasts, interface.name)
            XCTAssertFalse(interface.name.hasPrefix("utun"), interface.name)
        }
        let broadcasts = LocalNetwork.broadcastAddresses()
        for interface in LocalNetwork.interfaces() where !interface.isLAN {
            XCTAssertFalse(broadcasts.contains(interface.address), "\(interface.name) is not a place to broadcast to")
        }
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

    /// A recorder the router has given another address is found by the MAC the app keeps for waking it, which
    /// is the tail of its UDN, and not mistaken for any other recorder on the LAN.
    func testARecorderThatMovedIsFoundByTheMACAtTheEndOfItsUDN() async throws {
        let description = try Vectors.load("description.json").string("description_xml")
        let recorder = { (mac: String) -> HTTPResponse in
            let udn = "uuid:00000000-0000-0000-0000-" + mac
            let xml = description.replacingOccurrences(of: "uuid:00000000-0000-0000-0000-000000000000", with: udn)
            return HTTPResponse(statusCode: 200, body: Data(xml.utf8))
        }
        let another = recorder("f84e17000001")   // somebody else's recorder, or a second one
        let ours = recorder("f84e17000000")
        let transport = StubTransport { request, _ in
            switch request.url.host() {
            case "192.0.2.10": return another
            case "192.0.2.70": return ours
            default:
                try await Task.sleep(for: .milliseconds(50))
                throw RecorderError.transport("no route")
            }
        }
        let hosts = (1...200).map { "192.0.2.\($0)" }

        let found = await Discovery.find(mac: "F8-4E-17-00-00-00", among: hosts, transport: transport,
                                         timeout: 0.5, atOnce: 8)
        XCTAssertEqual(found?.host, "192.0.2.70")
        let asked = await transport.requests.count
        XCTAssertLessThan(asked, hosts.count, "the rest of the subnet is not asked once it has answered")

        let nobody = await Discovery.find(mac: "f8:4e:17:00:00:02", among: (1...20).map { "192.0.2.\($0)" },
                                          transport: transport, timeout: 0.5)
        XCTAssertNil(nobody, "a recorder with another MAC is not the one")
    }

    func testAUDNIsMatchedOnlyByTheMACItEndsWith() throws {
        let description = try Vectors.load("description.json").string("description_xml")
        var recorder = try XCTUnwrap(Discovery.parseDescription(description, host: "192.0.2.63",
                                                                location: "", via: "scan"))
        recorder.udn = "uuid:00000000-0000-0000-0000-f84e17000000"
        XCTAssertTrue(recorder.hasMAC("f8:4e:17:00:00:00"))
        XCTAssertTrue(recorder.hasMAC("F84E17000000"))
        XCTAssertFalse(recorder.hasMAC("f8:4e:17:00:00:01"))
        XCTAssertFalse(recorder.hasMAC("not a mac"))
        recorder.udn = "uuid:x"
        XCTAssertFalse(recorder.hasMAC("f8:4e:17:00:00:00"), "a UDN of another shape says nothing")
    }

    /// DHCP moves a recorder within its subnet, so that is the only place worth looking; from any other
    /// network there is nothing to find and nobody else's LAN to scan.
    func testARecorderThatMovedIsLookedForOnlyOnTheSubnetItWasOn() {
        let wifi = LocalNetwork.Interface(name: "en0", address: "192.0.2.85", netmask: "255.255.255.0",
                                          broadcasts: true)
        let home = LocalNetwork.hostsToScan(near: "192.0.2.63", on: [wifi])
        XCTAssertEqual(home, LocalNetwork.hosts(around: wifi))
        XCTAssertTrue(home.contains("192.0.2.63"), "it may be back where it was by now")

        XCTAssertEqual(LocalNetwork.hostsToScan(near: "198.51.100.63", on: [wifi]), [], "another network")
        XCTAssertEqual(LocalNetwork.hostsToScan(near: "192.0.2.63", on: []), [], "no Wi-Fi at all")
        XCTAssertEqual(LocalNetwork.hostsToScan(near: "recorder.local", on: [wifi]), [])
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
