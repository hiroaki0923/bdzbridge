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

    func testTheDemosGuideIsFilledAndReadAStationAtATime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-guide-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let said = try await refreshGuide(host: demoHost(), folder: folder)
        XCTAssertEqual(said, "デモの番組表を入れました")
        let stations = try await channels(host: demoHost(), folder: folder, broadcasting: "td")
        XCTAssertFalse(stations.isEmpty)
        let today = try await programmes(host: demoHost(), folder: folder, broadcasting: "td",
                                         serviceID: stations[0].serviceID, dayOffset: 0)
        XCTAssertFalse(today.isEmpty, "the demo's guide covers today")
        XCTAssertTrue(today.allSatisfy { $0.span.contains("〜") && $0.details.contains("分") })
        XCTAssertTrue(today.allSatisfy { $0.station == stations[0].name && $0.starts.hasSuffix($0.span.prefix(5)) },
                      "the sheet's station and start are the row's")
        XCTAssertTrue(today.contains { !$0.summary.isEmpty }, "the demo's programmes say what they are")
        XCTAssertEqual(today.filter(\.onAir).count, 1, "one programme is on air on today's list")
        XCTAssertTrue(dayHeading(dayOffset: 0).contains("("))
    }

    /// Just before four in the morning the day on air is still the one before; from four it is the new one.
    func testTodayIsTheBroadcastDayOnAir() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 59))!
        }
        func named(_ day: Date) -> Int { calendar.component(.day, from: day) }
        XCTAssertEqual(named(broadcastDay(0, from: at(8, 1))), 7, "two in the morning is still the 7th's")
        XCTAssertEqual(named(broadcastDay(0, from: at(8, 4))), 8)
        XCTAssertEqual(named(broadcastDay(1, from: at(8, 1))), 8)
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
