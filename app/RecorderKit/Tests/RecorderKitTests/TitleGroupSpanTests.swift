import Foundation
import XCTest
import RecorderKit

/// The span a programme's recordings cover, which the recordings screen shows under each group: from the start
/// of the first to the end of the last. The recordings are read through a client from what a recorder lists.
final class TitleGroupSpanTests: XCTestCase {
    func testOneRecordingSpansFromItsStartToItsEnd() async throws {
        let titles = try await read([("0x1", "2026-09-13T21:00:00+0900", 1800)])
        let group = try XCTUnwrap(TitleGroup.group(titles).first)

        XCTAssertEqual(group.earliest, titles[0].start)
        XCTAssertEqual(group.lastEnd, titles[0].start.addingTimeInterval(1800),
                       "one recording's span did not end when the recording did")
    }

    /// A long recording started first can end after a short one started later: the span ends with the long one,
    /// while the groups are still ordered by the later start.
    func testTheSpanEndsWithTheLastToEndNotTheLastToStart() async throws {
        let titles = try await read([("0x1", "2026-09-13T21:00:00+0900", 3 * 3600),
                                     ("0x2", "2026-09-13T22:00:00+0900", 1800)])
        let group = try XCTUnwrap(TitleGroup.group(titles).first)

        XCTAssertEqual(group.count, 2, "the two recordings were not one programme")
        XCTAssertEqual(group.earliest, titles[0].start)
        XCTAssertEqual(group.latest, titles[1].start)
        XCTAssertEqual(group.lastEnd, titles[0].start.addingTimeInterval(3 * 3600),
                       "the span ended with the last recording to start, not the last to end")
    }

    /// Recordings of one programme, as a client reads them from a recorder's list.
    private func read(_ items: [(id: String, start: String, durationSec: Int)]) async throws -> [RecordedTitle] {
        let list = "<xsrs>" + items.map { item in
            "<item id=\"\(item.id)\"><title>サンプル</title>"
                + "<scheduledStartDateTime>\(item.start)</scheduledStartDateTime>"
                + "<scheduledDuration>\(item.durationSec)</scheduledDuration></item>"
        }.joined() + "</xsrs>"
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.soap(
            "X_GetTitleList", result: list, totalMatches: items.count)))
        let titles = try await client.allTitles()
        XCTAssertEqual(titles.map(\.id), items.map(\.id), "the recordings were not read as listed")
        return titles
    }
}
