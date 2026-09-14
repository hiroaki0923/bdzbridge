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
    /// Station logos and the grouping of real recorded titles, which is where the heuristic earns its keep.
    /// Writes both out when RECORDER_EPG_DUMP is set, so the Python side can be run over the same input.
    func testDecodesTheLogosAndGroupsTheRecordings() async throws {
        let client = try liveClient()
        _ = try await client.describe()
        let dump = ProcessInfo.processInfo.environment["RECORDER_EPG_DUMP"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        }

        for broadcasting in ["td", "bs"] {
            guard let file = try await client.logoFile(broadcasting) else {
                print("\(broadcasting): no logo file")
                continue
            }
            let logos = try LogoFile.decode(file)
            print("\(broadcasting): \(file.count) bytes, \(logos.count) logos,"
                  + " channels \(logos.prefix(5).map(\.channelNo))")
            try dump.map { try file.write(to: $0.appendingPathComponent("logo-\(broadcasting).dat")) }
            XCTAssertFalse(logos.isEmpty)
            XCTAssertTrue(logos.allSatisfy { $0.serviceID > 0 && $0.channelNo > 0 && $0.png.count > 100 })
        }

        let titles = try await client.allTitles()
        let groups = Dictionary(grouping: titles, by: { Series.key($0.title) })
        let largest = groups.max { $0.value.count < $1.value.count }
        print("recordings: \(titles.count) in \(groups.count) groups;"
              + " largest \(largest?.value.count ?? 0) x \(largest.map { Series.name($0.value[0].title) } ?? "-")")
        XCTAssertFalse(titles.isEmpty)
        XCTAssertTrue(groups.keys.allSatisfy { !$0.isEmpty }, "every recording should land in a named group")

        if let dump {
            let rows = titles.map { title in
                ["title": title.title, "series_name": Series.name(title.title),
                 "series_key": Series.key(title.title), "same_title_key": Series.sameTitleKey(title.title)]
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            try data.write(to: dump.appendingPathComponent("titles-swift.json"))
        }
    }

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

extension LiveRecorderTests {
    /// Proves the payload a reservation would be created with is one the recorder accepts, without recording
    /// anything: X_GetConflictList takes the very same payload and only reports what would clash. A payload
    /// the recorder disliked would come back as UPnP error 402.
    func testTheReservationPayloadIsOneTheRecorderAccepts() async throws {
        let client = try liveClient()
        _ = try await client.describe()
        guard let services = try await client.guide("td") else { throw XCTSkip("no terrestrial channels") }

        let soon = Date().addingTimeInterval(3 * 3600)
        let candidates = services
            .flatMap { service in service.programs.filter { !$0.isReference && $0.start > soon && !$0.title.isEmpty } }
            .sorted { $0.start < $1.start }
        let program = try XCTUnwrap(candidates.first, "the guide should reach a few hours ahead")

        let request = ReservationRequest(
            title: program.title, start: program.start, durationSec: program.durationSec,
            repeatCode: Codes.repeatCodes["none"]!, broadcastingType: Codes.broadcasting["td"]!,
            serviceID: program.serviceID, qualityCode: Codes.quality["LSR"]!, eventID: program.eventID)

        let conflicts = try await client.conflicts(elements: XsrsElements.create(request))
        print("would record \(RecorderTime.format(program.start)) \(program.title):"
              + " \(conflicts.count) clash(es)\(conflicts.isEmpty ? "" : " with \(conflicts.map(\.title))")")
        XCTAssertTrue(conflicts.allSatisfy { !$0.id.isEmpty })
    }
}

extension LiveRecorderTests {
    /// The app marks a programme as reserved by matching broadcasting type, service and programme id, so this
    /// checks that the recorder really does describe both sides the same way. Read-only.
    func testReservationsMatchProgrammesInTheGuide() async throws {
        let client = try liveClient()
        _ = try await client.describe()
        let reservations = try await client.reservations()

        var programmes: Set<String> = []
        for broadcasting in ["td", "bs", "cs", "bs4k"] {
            guard let type = Codes.broadcasting[broadcasting],
                  let services = try await client.guide(broadcasting) else { continue }
            for service in services {
                for programme in service.programs where !programme.isReference {
                    programmes.insert("\(type)-\(service.serviceID)-\(programme.eventID)")
                }
            }
        }

        let following = reservations.filter { $0.eventID != nil }
        let matched = following.filter { programmes.contains("\($0.broadcastingType)-\($0.serviceID)-\($0.eventID!)") }
        print("reservations \(reservations.count), following a programme \(following.count),"
              + " found in the guide \(matched.count) of \(programmes.count) programmes")
        for reservation in following where !matched.contains(where: { $0.id == reservation.id }) {
            print("  no programme for \(RecorderTime.format(reservation.start)) \(reservation.title)"
                  + " (\(Codes.broadcasting(code: reservation.broadcastingType) ?? "?"))")
        }
        XCTAssertGreaterThan(matched.count, 0, "reserved programmes are marked by this match")
    }
}
