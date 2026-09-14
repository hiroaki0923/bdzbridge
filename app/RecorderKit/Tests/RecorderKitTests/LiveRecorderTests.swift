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
    /// The same shape `bdzbridge/tools/portkit.py` writes, so the two decoders can be compared row by row.
    private func decoded(_ services: [GuideService]) -> [[String: Any]] {
        services.flatMap { service in
            service.programs.map { program -> [String: Any] in
                var row: [String: Any] = [
                    "service_id": program.serviceID, "event_id": program.eventID,
                    "start": RecorderTime.format(program.start), "end": RecorderTime.format(program.end),
                    "duration_sec": program.durationSec,
                ]
                if program.isReference {
                    row["reference"] = true
                    row["ref_service_id"] = program.referenceServiceID ?? 0
                    row["ref_event_id"] = program.referenceEventID ?? 0
                } else {
                    row["title"] = program.title
                    row["description"] = program.summary
                    row["extended"] = program.extended
                    row["genres"] = program.genres.map { [$0.level1, $0.level2] }
                    row["copy_control"] = program.copyControl
                    row["parental_rating"] = program.parentalRating
                }
                return row
            }
        }
    }

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

    /// Decodes the guide the recorder is serving right now. Set RECORDER_EPG_DUMP to also write the raw file,
    /// so the Python decoder can be run over the very same bytes: the file is rebuilt daily, so downloading it
    /// twice is not a fair comparison.
    func testDecodesTheGuideTheRecorderIsServing() async throws {
        let client = try liveClient()
        _ = try await client.describe()

        for broadcasting in ["td", "bs"] {
            guard let file = try await client.epgFile(broadcasting) else {
                print("\(broadcasting): no channels")
                continue
            }
            let services = try Epg.decode(file)
            if let dump = ProcessInfo.processInfo.environment["RECORDER_EPG_DUMP"], !dump.isEmpty {
                let directory = URL(fileURLWithPath: dump)
                try file.write(to: directory.appendingPathComponent("epg-\(broadcasting).dat"))
                let rows = try JSONSerialization.data(withJSONObject: decoded(services), options: [.sortedKeys])
                try rows.write(to: directory.appendingPathComponent("epg-\(broadcasting)-swift.json"))
            }

            let programs = services.reduce(0) { $0 + $1.programs.count }
            let references = services.reduce(0) { $0 + $1.programs.filter(\.isReference).count }
            print("\(broadcasting): \(file.count) bytes, \(services.count) services, \(programs) programmes,"
                  + " \(references) references")
            for service in services.prefix(3) {
                print("  \(service.serviceID) \(service.name): \(service.programs.count)")
                if let first = service.programs.first(where: { !$0.isReference }) {
                    print("    \(RecorderTime.format(first.start)) \(first.title)")
                }
            }

            // the cache has to swallow a real day's guide without complaint, and quickly enough to do it on a phone
            let store = try GuideStore(path: ":memory:")
            let started = Date()
            let stored = try await store.replace(services, broadcasting: broadcasting)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let counts = try await store.counts()[broadcasting]
            print("  cached \(stored) rows in \(elapsed) ms:"
                  + " \(counts?.channels ?? 0) channels, \(counts?.programs ?? 0) programmes")
            XCTAssertEqual(stored, programs)
            XCTAssertEqual(counts?.programs, programs - references)
            let firstDay = try await store.day(Date(), broadcasting: broadcasting)
            print("  today: \(firstDay.count) programmes, first \(firstDay.first?.title ?? "-")")

            XCTAssertFalse(services.isEmpty)
            XCTAssertGreaterThan(programs, services.count)
            XCTAssertTrue(services.allSatisfy { !$0.name.isEmpty }, "every service should name itself")
            let dated = services.flatMap(\.programs)
            XCTAssertTrue(dated.allSatisfy { $0.end >= $0.start }, "no programme should end before it starts")
        }
    }
}
