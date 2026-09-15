import XCTest
@testable import RecorderKit

final class XmlTests: XCTestCase {
    func testNamespacesAreDroppedAndFirstMatchWins() throws {
        let root = try XmlNode.parse(
            "<root xmlns:av=\"urn:x\"><device><friendlyName>first</friendlyName>"
            + "<av:X_TAG>value</av:X_TAG><deviceList><device><friendlyName>second</friendlyName></device></deviceList>"
            + "</device></root>")
        XCTAssertEqual(root.firstDescendantText("friendlyName"), "first")
        XCTAssertEqual(root.firstDescendantText("X_TAG"), "value")
        XCTAssertEqual(root.descendants("friendlyName").count, 2)
        XCTAssertNil(root.firstDescendant("missing"))
    }

    func testChildTextDropsControlCharactersAndFallsBackToTheDefault() throws {
        // A tab is the control character that actually turns up, and it is dropped. A carriage return never
        // reaches us because the parser normalises it to a newline, and a raw C0 byte would make the document
        // invalid before we saw it.
        let item = try XmlNode.parse("<item id=\"x\"><title>a\u{0009}b</title><empty></empty></item>")
        XCTAssertEqual(item.childText("title"), "ab")
        XCTAssertEqual(item.childText("empty", default: "HDD"), "HDD")
        XCTAssertEqual(item.childText("absent", default: "HDD"), "HDD")
        XCTAssertEqual(item.attributes["id"], "x")
    }

    func testResultItemsOfAnEmptyResponse() throws {
        XCTAssertEqual(try XsrsParse.items(inResult: "").count, 0)
        XCTAssertEqual(try XsrsParse.items(inResult: "   ").count, 0)
    }

    func testAribSymbolsAreSpelledOut() {
        XCTAssertEqual(Arib.clean("ニュース\u{E0FE}\u{E0FD}"), "ニュース[字][手]")
        XCTAssertEqual(Arib.clean("\u{1F19E}\u{1F1A7}ニュース"), "[4K][HDR]ニュース")
        XCTAssertEqual(Arib.clean("謎の\u{E999}記号\u{0000}"), "謎の記号")
    }
}

final class WakeOnLanTests: XCTestCase {
    func testAMacIsAcceptedInEveryShapeARecorderOrAPersonWritesIt() {
        for written in ["F8:4E:17:00:00:00", "f8:4e:17:00:00:00", "F8-4E-17-00-00-00", "f84e17000000"] {
            XCTAssertEqual(WakeOnLan.normalise(written), "f8:4e:17:00:00:00", written)
        }
        XCTAssertNil(WakeOnLan.normalise("f8:4e:17:00:00"))
        XCTAssertNil(WakeOnLan.normalise(""))
        XCTAssertNil(WakeOnLan.normalise("not a mac at all"))
    }

    func testTheMagicPacketIsSixOnesThenTheAddressSixteenTimes() throws {
        let packet = try XCTUnwrap(WakeOnLan.magicPacket(for: "f8:4e:17:00:00:00"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let address: [UInt8] = [0xF8, 0x4E, 0x17, 0x00, 0x00, 0x00]
        for repeatIndex in 0..<16 {
            let start = 6 + repeatIndex * 6
            XCTAssertEqual(Array(packet[start..<(start + 6)]), address, "copy \(repeatIndex)")
        }
        XCTAssertNil(WakeOnLan.magicPacket(for: "nope"))
    }

    func testTheSubnetBroadcastComesBeforeTheAllOnesOne() {
        let addresses = LocalNetwork.broadcastAddresses()
        XCTAssertEqual(addresses.last, "255.255.255.255")
        XCTAssertEqual(Set(addresses).count, addresses.count, "no address twice")
    }
}
