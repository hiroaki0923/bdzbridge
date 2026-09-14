import XCTest
@testable import RecorderKit

final class DiscoveryVectorTests: XCTestCase {
    func testDescriptionParsingMatchesTheVector() throws {
        let vector = try Vectors.load("description.json")
        let expected = vector.dictionary("expected")
        let described = try XCTUnwrap(Discovery.parseDescription(
            vector.string("description_xml"),
            host: expected.string("host"),
            port: try XCTUnwrap(expected.int("port")),
            location: expected.string("location"),
            via: expected.string("via")))

        XCTAssertEqual(described.friendlyName, expected.string("friendly_name"))
        XCTAssertEqual(described.product, expected.string("product"))
        XCTAssertEqual(described.model, expected.string("model"))
        XCTAssertEqual(described.udn, expected.string("udn"))
        XCTAssertEqual(described.epgCapable, expected.bool("epg_capable"))
        XCTAssertEqual(described.host, expected.string("host"))
        XCTAssertEqual(described.port, expected.int("port"))
        XCTAssertEqual(described.location, expected.string("location"))
        XCTAssertEqual(described.via, expected.string("via"))
    }

    func testOtherSonyDevicesAreRejected() {
        let television = "<root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
            + "<manufacturer>Sony Corporation</manufacturer><friendlyName>TV</friendlyName><serviceList><service>"
            + "<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType></service></serviceList>"
            + "</device></root>"
        XCTAssertNil(Discovery.parseDescription(television, host: "h", port: 1, location: "loc", via: "ssdp"))
        XCTAssertNil(Discovery.parseDescription("not xml at all", host: "h", port: 1, location: "loc", via: "ssdp"))
    }
}
