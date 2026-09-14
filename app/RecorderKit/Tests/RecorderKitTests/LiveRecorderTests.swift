import XCTest
@testable import RecorderKit

/// Read-only checks against a real recorder, skipped unless `RECORDER_HOST` names one on the LAN:
///
///     RECORDER_HOST=192.0.2.63 swift test --filter LiveRecorderTests
///
/// Nothing here writes to the recorder. Reservations and recordings are only read, so running it cannot
/// change what the box is going to record. Compare the printed numbers with the same figures from the Python
/// server to see that both implementations agree.
final class LiveRecorderTests: XCTestCase {
    private func liveClient() throws -> RecorderClient {
        guard let host = ProcessInfo.processInfo.environment["RECORDER_HOST"], !host.isEmpty else {
            throw XCTSkip("set RECORDER_HOST to a recorder on the LAN")
        }
        return RecorderClient(host: host)
    }

    func testReadsWhatTheRecorderHas() async throws {
        let client = try liveClient()

        let info = try await client.describe()
        let streamPort = await client.streamPort
        print("recorder: \(info.product) / \(info.friendlyName), EPG \(info.epgCapable), files on port \(streamPort)")
        XCTAssertFalse(info.product.isEmpty)
        XCTAssertFalse(info.udn.isEmpty)

        let reservations = try await client.reservations()
        print("reservations: \(reservations.count)")
        for reservation in reservations.prefix(3) {
            print("  \(RecorderTime.format(reservation.start)) \(reservation.title)")
        }
        XCTAssertTrue(reservations.allSatisfy { !$0.id.isEmpty })

        let titles = try await client.titles(count: 50)
        print("recordings on the first page: \(titles.count), newest \(titles.first?.title ?? "-")")
        XCTAssertTrue(titles.allSatisfy { !$0.id.isEmpty && $0.durationSec > 0 })

        let capacity = try await client.recordDestinationInfo()
        print("free \(capacity.freeBytes / 1_000_000_000) GB of \(capacity.totalBytes / 1_000_000_000) GB")
        XCTAssertGreaterThan(capacity.totalBytes, 0)
        XCTAssertLessThanOrEqual(capacity.freeBytes, capacity.totalBytes)

        let guide = try await client.epgFile("td")
        print("terrestrial EPG file: \(guide?.count ?? 0) bytes")
        XCTAssertGreaterThan(guide?.count ?? 0, 1000)
    }
}
