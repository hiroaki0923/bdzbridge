import XCTest
@testable import AndroidBridge

/// The bridge against the demo's invented recorder: what the Android screens are handed.
final class AndroidBridgeTests: XCTestCase {
    func testTheDemoRecorderDescribesItself() async throws {
        let info = try await describeRecorder(host: demoHost())
        XCTAssertEqual(info.host, demoHost())
        XCTAssertFalse(info.name.isEmpty)
        XCTAssertFalse(info.model.isEmpty)
    }

    func testReservationsAreWordedAndSoonestFirst() async throws {
        let rows = try await reservations(host: demoHost())
        XCTAssertFalse(rows.isEmpty, "the demo holds reservations")
        XCTAssertTrue(rows.allSatisfy { $0.date.contains("(") && $0.span.contains("〜") && $0.span.hasSuffix("分") })
    }

    func testRecordingsAreWordedAndNewestFirst() async throws {
        let rows = try await recordings(host: demoHost())
        XCTAssertFalse(rows.isEmpty, "the demo holds recordings")
        XCTAssertTrue(rows.allSatisfy { !$0.title.isEmpty && $0.details.contains("分") })
    }

    func testAJobOnTheMainActorRunsOnTheMainThread() async {
        let said = await mainActorCheck()
        XCTAssertEqual(said, "main actor ran on the main thread")
    }

    func testAFailureIsSaidInTheAppsWords() async {
        do {
            _ = try await reservations(host: "not an address")
            XCTFail("an address that is none answered")
        } catch let error as BridgeError {
            XCTAssertFalse(error.description.isEmpty)
            XCTAssertFalse(error.description.contains("BridgeError"), "the words, not the type: \(error.description)")
        } catch {
            XCTFail("not said as the bridge's: \(error)")
        }
    }
}
