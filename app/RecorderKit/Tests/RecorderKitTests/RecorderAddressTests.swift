import XCTest
@testable import RecorderKit

/// A typed address used to be forced into a URL, and anything that was not quite an address crashed the app
/// -- at every launch after, because it had already been saved. These are the shapes a hand types.
final class RecorderAddressTests: XCTestCase {
    /// Nothing the reader can type, or an older version of the app can have saved, stops the app. Each of
    /// these is an error before anything is sent, and not one that reads as silence, which would start the
    /// waking.
    func testAnAddressNoURLCanBeBuiltOnIsAnErrorAndNotACrash() async throws {
        let bad = ["192.0.2.10:64220", " 192.0.2.10", "192.0.2.10\n", "192.0.2.10 ", "192.0 .2.10",
                   "192:0:2:10", "http://192.0.2.10", "192.0.2.10/", "[2001:db8::10]", "fe80::1%en0",
                   "レコーダー", "１９２．０．２．１０", "", "%41"]
        for host in bad {
            let transport = StubTransport(always: HTTPResponse(statusCode: 200))
            let client = RecorderClient(host: host, transport: transport)
            do {
                _ = try await client.describe()
                XCTFail("\(host.debugDescription) should not describe anything")
            } catch let error as RecorderError {
                XCTAssertEqual(error, .badAddress(host: host), host.debugDescription)
                XCTAssertFalse(error.unreachable, "no magic packet for \(host.debugDescription)")
                XCTAssertTrue(error.explanation.contains("IP アドレス"), error.explanation)
            }
            // the SOAP calls and the guide files build their URLs the same way
            await XCTAssertThrowsBadAddress(try await client.reservations(), host)
            await XCTAssertThrowsBadAddress(try await client.epgFile("td"), host)
            let sent = await transport.requests
            XCTAssertTrue(sent.isEmpty, "\(host.debugDescription) sent \(sent.map(\.url))")
        }
    }

    /// A name has to keep working: some people reach their recorder by one their router or VPN gives it.
    func testAnAddressANameOrAnIPv6AddressAllBecomeURLs() async throws {
        let expected = ["192.0.2.10": "http://192.0.2.10:64220/description.xml",
                        "bdz.local": "http://bdz.local:64220/description.xml",
                        "bdz-living.example.ts.net": "http://bdz-living.example.ts.net:64220/description.xml",
                        "2001:db8::10": "http://[2001:db8::10]:64220/description.xml"]
        for (host, url) in expected {
            let transport = StubTransport(always: HTTPResponse(statusCode: 404))
            let client = RecorderClient(host: host, transport: transport)
            _ = try? await client.describe()
            let sent = await transport.requests.map(\.url.absoluteString)
            XCTAssertEqual(sent, [url], host)
            XCTAssertTrue(RecorderAddress.isUsable(host), host)
        }
        let client = RecorderClient(host: "2001:db8::10", streamPort: 60151)
        let file = try await client.guideFileURL(named: "EPG_TRDEPG_FILE.dat")
        XCTAssertEqual(file.absoluteString, "http://[2001:db8::10]:60151//EPG_TRDEPG_FILE.dat")
    }

    func testWhatIsPlainlyNotPartOfTheAddressIsTakenOff() {
        let tidied = [" 192.0.2.10", "192.0.2.10\n", "\t192.0.2.10 \r\n", "192.0. 2.10", "　192.0.2.10",
                      "１９２．０．２．１０", "192。0。2。10", "http://192.0.2.10", "HTTP://192.0.2.10/",
                      "https://192.0.2.10//", "ｈｔｔｐ：／／１９２．０．２．１０／"]
        for typed in tidied {
            XCTAssertEqual(RecorderAddress.tidy(typed), .init(host: "192.0.2.10", port: nil), typed.debugDescription)
        }
        XCTAssertEqual(RecorderAddress.tidy(" bdz.local/ ").host, "bdz.local")
        XCTAssertEqual(RecorderAddress.tidy("2001:db8::10").host, "2001:db8::10")
    }

    /// Kept apart rather than dropped, so that the screen can say a port is not needed.
    func testATypedPortIsKeptApartFromTheHost() {
        for typed in ["192.0.2.10:64220", "http://192.0.2.10:64220/", "192.0.2.10：６４２２０"] {
            XCTAssertEqual(RecorderAddress.tidy(typed), .init(host: "192.0.2.10", port: "64220"), typed)
        }
        XCTAssertEqual(RecorderAddress.tidy("bdz.local:8080"), .init(host: "bdz.local", port: "8080"))
        XCTAssertEqual(RecorderAddress.tidy("[2001:db8::10]:64220"), .init(host: "2001:db8::10", port: "64220"))
        XCTAssertEqual(RecorderAddress.tidy("[2001:db8::10]"), .init(host: "2001:db8::10", port: nil))
    }

    /// Tidying does not guess. What is left after it is either an address or something the screen has to
    /// send back to the reader.
    func testWhatTidyingCannotMendIsNotUsable() {
        for typed in ["192:0:2:10", "192.0.2.10:", "192.0.2.10:port", "192.0.2.10:64220/description.xml",
                      "レコーダー", "", "http://", ":64220"] {
            XCTAssertFalse(RecorderAddress.isUsable(RecorderAddress.tidy(typed).host), typed)
        }
    }

    private func XCTAssertThrowsBadAddress<T>(_ body: @autoclosure () async throws -> T, _ host: String,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("\(host.debugDescription) should throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RecorderError, .badAddress(host: host), host.debugDescription,
                           file: file, line: line)
        }
    }
}
