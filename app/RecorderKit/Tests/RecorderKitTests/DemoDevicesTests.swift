import XCTest
@testable import RecorderKit

/// The demo's surroundings (`DemoDevices.swift`): its guide written into a cache, and its devices as a search
/// meets them.
@MainActor
final class DemoDevicesTests: XCTestCase {
    func testTheGuideIsWrittenWithALogoForEachStationAndTheRestNotedAsHavingNone() async throws {
        let store = try GuideStore(path: ":memory:")
        var drawn: [(String, Int)] = []
        try await DemoLineUp.seed(store) { text, index in
            drawn.append((text, index))
            return Data("png \(index)".utf8)
        }
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.channels, DemoLineUp.terrestrial.count)
        XCTAssertEqual(counts["bs"]?.channels, DemoLineUp.satellite.count)
        XCTAssertGreaterThan(counts["td"]?.programs ?? 0, 0)
        XCTAssertNotNil(counts["cs"]?.checked, "a type the line-up has none of is noted as answered for")
        XCTAssertNotNil(counts["bs4k"]?.checked)
        XCTAssertEqual(drawn.map(\.0), (DemoLineUp.terrestrial + DemoLineUp.satellite).map(\.logo))
        XCTAssertEqual(drawn.map(\.1), Array(DemoLineUp.terrestrial.indices) + Array(DemoLineUp.satellite.indices),
                       "each station's place in its own line-up, for its colour")
    }

    func testTheSearchMeetsTheDemosDevicesAndNothingElse() async throws {
        let television = DemoTV()
        let devices = DemoDevices(recorder: DemoRecorder(), television: television)
        let description = try await devices.send(HTTPRequest(
            url: try XCTUnwrap(URL(string: "http://\(DemoRecorder.host):\(Upnp.port)/description.xml"))))
        XCTAssertEqual(description.statusCode, 200)
        for url in ["http://\(DemoRecorder.host)/sony/system", "http://\(DemoTV.host):\(Upnp.port)/description.xml",
                    "http://192.0.2.1:\(Upnp.port)/description.xml"] {
            do {
                _ = try await devices.send(HTTPRequest(url: try XCTUnwrap(URL(string: url))))
                XCTFail("\(url) answered")
            } catch RecorderError.transport {
            }
        }
        XCTAssertNotEqual(DemoTV.host, DemoRecorder.host)
        XCTAssertTrue(DemoTV.host.hasPrefix("192.0.2."), "an address reserved for documentation")
    }
}
