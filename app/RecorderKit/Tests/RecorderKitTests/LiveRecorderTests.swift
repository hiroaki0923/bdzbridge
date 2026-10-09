import XCTest
@testable import RecorderKit

/// Read-only checks against a real recorder, skipped unless `RECORDER_HOST` names one on the LAN:
///
///     RECORDER_HOST=192.0.2.63 swift test --filter LiveRecorderTests
///
/// Nothing here writes to the recorder unless RECORDER_WRITE=1 is set as well: then the tests that say so make a
/// reservation or a keyword condition and delete it again. Otherwise reservations and recordings are only read, so
/// running it cannot change what the box is going to record. Compare the printed numbers with the same figures
/// from the Python server to see that both implementations agree. With RECORDER_MAC set as well, each test wakes
/// the recorder first (`LiveWaking`).
final class LiveRecorderTests: XCTestCase {
    /// When the recorder answered the wake made for this test, if one was.
    private var answeredTheWake: ContinuousClock.Instant?

    override func setUp() async throws {
        answeredTheWake = try await LiveWaking.wakeTheRecorderIfAsked()
    }

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
    /// **Writes to the recorder.** Creates a reservation for a programme a few hours out, changes its
    /// quality, checks the change took, and deletes it again -- the only way to know the update payload is
    /// one the recorder accepts, since a conflict check cannot exercise it. Skipped unless RECORDER_WRITE is
    /// set as well as RECORDER_HOST, and it cleans up even when an assertion fails.
    ///
    /// It cannot tell its reservation by a name: the recorder lists one that follows its programme under the
    /// programme's own title. So it takes a programme at a time no reservation overlaps, asks the conflict check
    /// for none, and writes only to a row that was not listed before, on that channel at that time, made by an
    /// app: never to one of the household's, the recorder's own renumbered ones included.
    func testCreatingChangingAndDeletingAReservation() async throws {
        guard ProcessInfo.processInfo.environment["RECORDER_WRITE"] == "1" else {
            throw XCTSkip("set RECORDER_WRITE=1 to let this write to the recorder")
        }
        let client = try liveClient()
        _ = try await client.describe()
        guard let services = try await client.guide("td") else { throw XCTSkip("no terrestrial channels") }
        let before = try await client.reservations()
        // One read lists at most 200, the latest first: past that the soonest are not seen, and one held at the
        // chosen time could be taken for this test's own.
        guard before.count < 200 else { throw XCTSkip("more reservations than one read lists") }

        let soon = Date().addingTimeInterval(4 * 3600)
        let program = try XCTUnwrap(services
            .flatMap { $0.programs.filter { !$0.isReference && $0.start > soon && !$0.title.isEmpty } }
            .filter { program in !before.contains { $0.start < program.end && program.start < $0.end } }
            .sorted { $0.start < $1.start }.first, "the guide should have a programme no reservation overlaps")

        func request(_ quality: String) -> ReservationRequest {
            ReservationRequest(title: program.title, start: program.start, durationSec: program.durationSec,
                               repeatCode: Codes.repeatCodes["none"]!, broadcastingType: Codes.broadcasting["td"]!,
                               serviceID: program.serviceID, qualityCode: Codes.quality[quality]!,
                               eventID: program.eventID)
        }
        let held = Set(before.map(\.id))
        func mine() async throws -> Reservation? {
            try await client.reservations().first {
                !held.contains($0.id) && $0.createdByApp && $0.serviceID == program.serviceID
                    && $0.start == program.start
            }
        }

        // Nothing the recorder holds is to be put in a clash by a reservation made only to be deleted.
        let clashes = try await client.conflicts(elements: XsrsElements.create(request("LSR")))
        guard clashes.isEmpty else { throw XCTSkip("the conflict check named a clash") }
        try await client.create(request("LSR"))
        print("created one for \(RecorderTime.format(program.start))")
        do {
            let found = try await mine()
            let made = try XCTUnwrap(found, "the reservation should be in the list")
            XCTAssertEqual(made.qualityName, "LSR")

            try await client.updateReservation(id: made.id, request("SR"))
            let after = try await mine()
            let changed = try XCTUnwrap(after, "it should still be there after the change")
            XCTAssertEqual(changed.qualityName, "SR", "the recorder took the new quality")
            XCTAssertEqual(changed.eventID, program.eventID, "and it still follows the programme")
        } catch {
            if let left = try? await mine() { try? await client.deleteReservation(id: left.id) }
            throw error
        }
        let remaining = try await mine()
        let left = try XCTUnwrap(remaining)
        try await client.deleteReservation(id: left.id)
        expectNil(try await mine(), "and it is off the recorder again")
    }

    /// **Writes to the recorder.** Reserves a programme a few hours out on the recorder's USB disk, following the
    /// programme as the app's reservations do, changes its quality as the app changes one, reads it back -- still
    /// on the USB disk, in the new quality, still following the programme -- and deletes it. A change that named
    /// the internal disk would have moved it there; this is what shows the recorder keeps it where a change says.
    /// Before the delete it moves the reservation as a reader would from its sheet: to the internal disk, then back
    /// to the USB disk, which is the move not seen before. After each it reads the reservation back -- its disk,
    /// whether it still follows the programme, whether the recorder gave it a new id -- and a move refused prints
    /// the recorder's code. A move taken and not made ends the moves, saying the move back is not measured.
    ///
    /// It takes a programme at a time no reservation overlaps, so that nothing the recorder already holds can be
    /// found in place of its own or be put in a clash while it lives, and it deletes what it made on any failure.
    /// A recorder that turns the reservation down skips it, saying what it answered. Skipped unless
    /// RECORDER_WRITE=1 as well as RECORDER_HOST, with a USB disk registered on the recorder and connected:
    ///
    ///     RECORDER_HOST=192.0.2.63 RECORDER_WRITE=1 swift test --filter LiveRecorderTests/testAChangeKeepsTheUSBDisk
    ///
    /// It prints no title: the recorder lists a reservation that follows its programme under the programme's own
    /// title, not the one sent, so the reservation is told by its time, its channel and its disk.
    func testAChangeKeepsTheUSBDisk() async throws {
        guard ProcessInfo.processInfo.environment["RECORDER_WRITE"] == "1" else {
            throw XCTSkip("set RECORDER_WRITE=1 to let this write to the recorder")
        }
        let client = try liveClient()
        _ = try await client.describe()
        guard let services = try await client.guide("td") else { throw XCTSkip("no terrestrial channels") }
        let before = try await client.reservations()
        // One read lists at most 200, the latest first: past that the soonest are not seen, and one held at the
        // chosen time could be taken for this test's own.
        guard before.count < 200 else { throw XCTSkip("more reservations than one read lists") }

        let soon = Date().addingTimeInterval(4 * 3600)
        let program = try XCTUnwrap(services
            .flatMap { $0.programs.filter { !$0.isReference && $0.start > soon && !$0.title.isEmpty } }
            .filter { program in !before.contains { $0.start < program.end && program.start < $0.end } }
            .sorted { $0.start < $1.start }.first, "the guide should have a programme no reservation overlaps")
        let request = ReservationRequest(title: "BD Bridge 検証 USB", start: program.start,
                                         durationSec: program.durationSec, repeatCode: Codes.repeatCodes["none"]!,
                                         broadcastingType: Codes.broadcasting["td"]!, serviceID: program.serviceID,
                                         qualityCode: Codes.quality["LSR"]!, eventID: program.eventID,
                                         destination: "USBHDD")

        // Only a row that was not there before, on that channel at that time, made by an app: never one the recorder
        // already held, nor one of its own that it renumbered meanwhile.
        let held = Set(before.map(\.id))
        func mine() async throws -> Reservation? {
            try await client.reservations().first {
                !held.contains($0.id) && $0.createdByApp && $0.serviceID == program.serviceID
                    && $0.start == program.start
            }
        }
        // What it made goes whatever failed; when it cannot be found and deleted, that is said, since the recorder
        // then holds a reservation under a real programme's title that nobody asked for.
        func deleteMine() async {
            do {
                if let left = try await mine() { try await client.deleteReservation(id: left.id) }
            } catch {
                print("may be left on the recorder: the reservation at \(RecorderTime.format(program.start)) on"
                      + " USBHDD (\(Self.code(error)))")
            }
        }

        do {
            let clashes = try await client.conflicts(elements: XsrsElements.create(request))
            print("conflict check to USBHDD, following the programme: accepted, \(clashes.count) clash(es)")
            // Nothing the recorder holds is to be put in a clash by a reservation made only to be deleted.
            guard clashes.isEmpty else { throw XCTSkip("the conflict check named a clash") }
            try await client.create(request)
        } catch {
            await deleteMine()
            guard let refused = error as? RecorderError, case .soap(_, _, let code, _) = refused, code != nil
            else { throw error }
            print("the recorder turned the reservation to USBHDD down: \(refused.explanation)")
            throw XCTSkip("the recorder turned the reservation to USBHDD down")
        }
        print("created to USBHDD for \(RecorderTime.format(program.start)); the recorder lists it under the"
              + " programme's own title")
        do {
            let found = try await mine()
            let made = try XCTUnwrap(found, "the reservation should be in the list")
            print("listed: destination \(made.destination), quality \(made.qualityName ?? "?"),"
                  + " following the programme \(made.eventID == program.eventID)")
            XCTAssertEqual(made.destination, "USBHDD", "the recorder took the USB disk for it")

            let change = try XCTUnwrap(ReservationRequest(changing: made, quality: "SR", repeating: "none"))
            try await client.updateReservation(id: made.id, change)
            let after = try await mine()
            let changed = try XCTUnwrap(after, "it should still be there after the change")
            print("after the change: destination \(changed.destination), quality \(changed.qualityName ?? "?"),"
                  + " following the programme \(changed.eventID == program.eventID)")
            XCTAssertEqual(changed.destination, "USBHDD", "the change kept it on the USB disk")
            XCTAssertEqual(changed.qualityName, "SR", "the recorder took the new quality")
            XCTAssertEqual(changed.eventID, program.eventID, "and it still follows the programme")

            // Moved as the sheet moves it: the change built from the row as found again, its disk named.
            var current = changed
            let moves = [RecorderDisk.internalID, RecorderDisk.usbID]
            for disk in moves {
                let move = try XCTUnwrap(ReservationRequest(changing: current, quality: "SR", repeating: "none",
                                                            destination: disk))
                do {
                    try await client.updateReservation(id: current.id, move)
                } catch where Self.refusedWithACode(error) {
                    print("the move to \(disk) was turned down: \(Self.code(error))")
                    throw TurnedDown(description: "the recorder turned the move to \(disk) down")
                }
                let found = try await mine()
                let moved = try XCTUnwrap(found, "it should still be there after the move to \(disk)")
                print("after the move to \(disk): destination \(moved.destination), quality"
                      + " \(moved.qualityName ?? "?"), following the programme \(moved.eventID == program.eventID),"
                      + " \(moved.id == current.id ? "the same id" : "a new id")")
                XCTAssertEqual(moved.destination, disk, "the recorder did not move it to \(disk)")
                XCTAssertEqual(moved.eventID, program.eventID, "the move to \(disk) stopped it following the programme")
                current = moved
                // A move taken and not made leaves the reservation where the next move would take it, which would
                // then read as that move made.
                guard moved.destination == disk else {
                    if disk != moves.last {
                        print("the move to \(disk) was taken and not made: the move back is not measured")
                    }
                    break
                }
            }
            try await client.deleteReservation(id: current.id)
        } catch {
            await deleteMine()
            throw error
        }
        expectNil(try await mine(), "and it is off the recorder again")
        let after = try await client.reservations()
        print("reservations before \(before.count), after \(after.count)")
        XCTAssertEqual(after.count, before.count, "the recorder holds as many reservations as before")
    }

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

extension LiveRecorderTests {
    /// The clustering that finds duplicate candidates, over every recording the recorder holds. Read-only:
    /// it needs the title list and nothing else. With RECORDER_EPG_DUMP set it writes the recordings and its
    /// own answer out, so the Python implementation can be run over exactly the same input.
    func testDuplicateCandidatesOverEveryRecording() async throws {
        let client = try liveClient()
        _ = try await client.describe()
        let titles = try await client.allTitles()
        let candidates = Duplicates.candidates(titles)

        print("recordings \(titles.count), candidate sets \(candidates.count),"
              + " recordings in them \(candidates.reduce(0) { $0 + $1.count })")
        for group in candidates.prefix(3) {
            print("  \(group.count) x \(group[0].title) (\(group.map(\.durationSec)) sec)")
        }
        XCTAssertTrue(candidates.allSatisfy { $0.count > 1 })

        guard let dump = ProcessInfo.processInfo.environment["RECORDER_EPG_DUMP"], !dump.isEmpty else { return }
        let directory = URL(fileURLWithPath: dump)
        let rows = titles.map { title in
            ["id": title.id, "title": title.title, "start": RecorderTime.format(title.start),
             "duration_sec": title.durationSec, "quality_code": title.qualityCode,
             "protected": title.protected, "is_new": title.isNew, "size_mb": title.sizeMB ?? 0,
             "resume_sec": title.resumeSec ?? 0] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("titles-real.json"))
        try JSONSerialization.data(withJSONObject: candidates.map { $0.map(\.id) }, options: [])
            .write(to: directory.appendingPathComponent("candidates-swift.json"))

        // if the programme text is there from an earlier run, the sets can be compared at full scale too
        let summariesFile = directory.appendingPathComponent("summaries.json")
        guard let data = try? Data(contentsOf: summariesFile),
              let summaries = try JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        let sets = Duplicates.sets(candidates: candidates, summaries: summaries)
        print("sets \(sets.count), total \(String(format: "%.1f", sets.reduce(0) { $0 + $1.sizeGB })) GB")
        let setRows: [[String: Any]] = sets.map { set in
            ["title": set.title, "confidence": set.confidence.rawValue, "size_mb": set.sizeMB,
             "keep": set.keep, "suggest_delete": set.suggestDelete, "reasons": set.reasons,
             "items": set.items.map(\.id)]
        }
        try JSONSerialization.data(withJSONObject: setRows, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("sets-swift.json"))
    }
}

extension LiveRecorderTests {
    /// Looks through the subnet this machine is on, which is the same one the recorder is on. Read-only: one
    /// request for a description per address. Skipped unless RECORDER_HOST names the recorder to expect.
    func testScanningTheSubnetFindsTheRecorder() async throws {
        guard let expected = ProcessInfo.processInfo.environment["RECORDER_HOST"], !expected.isEmpty else {
            throw XCTSkip("set RECORDER_HOST to the recorder to expect")
        }
        let interfaces = LocalNetwork.interfaces()
        print("interfaces: \(interfaces.map { "\($0.name) \($0.address)/\($0.netmask)" })")
        let hosts = LocalNetwork.hostsToScan()
        print("addresses to try: \(hosts.count)")
        XCTAssertTrue(hosts.contains(expected), "the recorder's address should be in the subnet to scan")

        let started = Date()
        let found = await Discovery.scan(hosts: hosts, timeout: 1.5)
        print("found \(found.count) in \(Int(Date().timeIntervalSince(started))) s:"
              + " \(found.map { "\($0.host) \($0.product)" })")
        XCTAssertTrue(found.contains { $0.host == expected }, "the recorder should be among them")
    }
}

extension LiveRecorderTests {
    /// Searching a real day's guide, which is what the search screen does. Read-only.
    func testSearchingTheRealGuide() async throws {
        let client = try liveClient()
        _ = try await client.describe()
        guard let services = try await client.guide("td") else { throw XCTSkip("no terrestrial channels") }

        let store = try GuideStore(path: ":memory:")
        try await store.replace(services, broadcasting: "td")

        for word in ["ニュース", "news", "ドラマ", "出演"] {
            let found = try await store.search(word, since: Date())
            let byField = Dictionary(grouping: found.hits, by: \.match).mapValues(\.count)
            print("\(word): \(found.hits.count)\(found.more ? "+" : "") programmes still to come,"
                  + " by field \(byField), first \(found.hits.first?.program.title ?? "-")")
            XCTAssertTrue(found.hits.allSatisfy { $0.program.end > Date() }, "only what has not finished")
            XCTAssertEqual(found.hits.map(\.match), found.hits.map(\.match).sorted(), "best field first")
        }
        let mixedWidth = try await store.search("ｎｅｗｓ", since: Date())
        let plain = try await store.search("news", since: Date())
        XCTAssertEqual(mixedWidth.hits.map(\.id), plain.hits.map(\.id), "full width and half width should agree")
    }
}

extension LiveRecorderTests {
    /// **Writes to the recorder.** A reservation to the USB slot sent as the app's queue sends one: at once, with
    /// no clash check before it. It is for two moments. One is right after a wake, the recorder having been left
    /// alone until it dropped off the network (RECORDER_MAC as well), when the slot answers as if no disk were
    /// registered though one is connected; the app keeps the disk it knew through that answer, and what waits is
    /// sent there and then. The other is with the disk unplugged, an answer not yet seen.
    ///
    ///     RECORDER_HOST=192.0.2.63 RECORDER_MAC=<the recorder's MAC> RECORDER_WRITE=1 \
    ///         swift test --filter LiveRecorderTests/testAReservationToTheSlotAsItAnswersNow
    ///
    /// The first moment lasts seconds, so nothing is sent before the create but the reservations, the terrestrial
    /// channels and the slot, and no guide is fetched. The reservation is five minutes by time tomorrow in the small
    /// hours on the first terrestrial channel, clear of every reservation and of the time of day of every repeating
    /// one. In order: the slot, the create, the slot, the clash check with the slot for the same item, the slot,
    /// the reservation as listed (its disk, its clash), a change of it to the internal disk and one back to the slot
    /// (its disk after each, or the code), the slot every five seconds until it answers a disk (a minute at most,
    /// and not at all once one has answered), then the delete and the count of reservations before and after. A
    /// create taken and not listed is said, and no change is sent; the rest goes on, and a reservation listed by the
    /// delete is said and deleted. The create counts as sent while the slot answered none only when the reads just
    /// before and just after it both did, and the clash check likewise; otherwise it says what each side answered.
    /// Every line carries the seconds since the recorder answered: its wake, or without one the description asked
    /// first. It deletes what it made on any failure, and prints no title but its own; one of its own left by an
    /// earlier run is named and left alone.
    func testAReservationToTheSlotAsItAnswersNow() async throws {
        guard ProcessInfo.processInfo.environment["RECORDER_WRITE"] == "1" else {
            throw XCTSkip("set RECORDER_WRITE=1 to let this write to the recorder")
        }
        let client = try liveClient()
        let answered: ContinuousClock.Instant
        if let answeredTheWake {
            answered = answeredTheWake
        } else {
            try await client.describe()
            answered = .now
        }
        func say(_ line: String) {
            print(String(format: "%7.2f s: ", (ContinuousClock.now - answered) / .seconds(1)) + line)
        }

        let before = try await client.reservations()
        // One read lists at most 200, the latest first: past that, one held at the chosen time could be missed.
        guard before.count < 200 else { throw XCTSkip("more reservations than one read lists") }
        let terrestrial = try XCTUnwrap(Codes.broadcasting["td"])
        guard let channel = try await client.liveChannelIDs(broadcastingType: terrestrial).first else {
            throw XCTSkip("no terrestrial channel")
        }
        let start = try XCTUnwrap(Self.fiveFreeMinutes(clearOf: before),
                                  "no five minutes clear of every reservation tomorrow between two and five")
        say("reservations: \(before.count); five minutes by time tomorrow in the small hours, clear of all of them")
        // One left by a run that was stopped is never this run's to delete, which finds its own by what was not
        // there before; it is named, so that it is not left on the recorder unknown.
        for left in before where left.title == Self.ownTitle {
            say("left by an earlier run: 「\(Self.ownTitle)」 at \(RecorderTime.format(left.start)), not touched here;"
                + " delete it on the recorder")
        }
        let request = ReservationRequest(title: Self.ownTitle, start: start, durationSec: 300,
                                         repeatCode: try XCTUnwrap(Codes.repeatCodes["none"]),
                                         broadcastingType: terrestrial, serviceID: channel,
                                         qualityCode: try XCTUnwrap(Codes.quality["LSR"]),
                                         destination: RecorderDisk.usbID)

        // Only a row that was not there before, on that channel at that time, made by an app: never one the recorder
        // already held, nor one of its own that it renumbered meanwhile.
        let held = Set(before.map(\.id))
        func mine() async throws -> Reservation? {
            try await client.reservations().first {
                !held.contains($0.id) && $0.createdByApp && $0.serviceID == channel && $0.start == start
            }
        }
        func deleteMine() async {
            do {
                if let left = try await mine() { try await client.deleteReservation(id: left.id) }
            } catch {
                say("may be left on the recorder: 「\(Self.ownTitle)」 at \(RecorderTime.format(start))"
                    + " (\(Self.code(error)))")
            }
        }
        // The slot as the app reads it: none, a registered disk mounted or not, or what stopped the read.
        var firstDisk: Duration?
        func slot(_ when: String) async -> String {
            let read: String
            do {
                let disk = try await RecorderDriver.usbDisk(of: client)
                read = disk.map { $0.mounted ? "a disk" : "a disk not mounted" } ?? "none"
                if disk?.mounted == true, firstDisk == nil { firstDisk = ContinuousClock.now - answered }
            } catch {
                read = Self.code(error)
            }
            say("the slot \(when): \(read)")
            return read
        }
        func counts(_ what: String, before: String, after: String) {
            guard before == "none", after == "none" else {
                return say("\(what) does not count: the slot answered \(before) just before it and \(after) just after")
            }
            say("\(what) went while the slot answered none: it counts")
        }

        let beforeTheCreate = await slot("just before the create")
        var made = false
        var listed = false
        do {
            try await client.create(request)
            made = true
            say("the create to USBHDD: taken")
        } catch where Self.refusedWithACode(error) {
            say("the create to USBHDD: \(Self.code(error))")
        } catch {
            // Silence after sending: the reservation may have been made.
            await deleteMine()
            throw error
        }
        let afterTheCreate = await slot("just after the create")
        counts("the create", before: beforeTheCreate, after: afterTheCreate)

        do {
            do {
                let clashes = try await client.conflicts(elements: XsrsElements.create(request))
                say("the clash check with USBHDD: accepted, \(clashes.count) clash(es)")
            } catch where Self.refusedWithACode(error) {
                say("the clash check with USBHDD: \(Self.code(error))")
            }
            let afterTheCheck = await slot("just after the clash check")
            counts("the clash check", before: afterTheCreate, after: afterTheCheck)

            // Taken and not listed is an answer in itself, a reservation that looks made and is not: it is said, and
            // the changes, which need a row, are not sent; the slot is still read and the reservations still counted.
            if made, let found = try await mine() {
                listed = true
                var current = found
                say("listed: destination \(current.destination), in a clash \(current.conflict)")
                for disk in [RecorderDisk.internalID, RecorderDisk.usbID] {
                    let change = try XCTUnwrap(ReservationRequest(changing: current, quality: "LSR", repeating: "none",
                                                                  destination: disk))
                    do {
                        try await client.updateReservation(id: current.id, change)
                        let found = try await mine()
                        let changed = try XCTUnwrap(found, "it should still be there after the change to \(disk)")
                        say("the change to \(disk): taken, listed on \(changed.destination), in a clash"
                            + " \(changed.conflict), \(changed.id == current.id ? "the same id" : "a new id")")
                        current = changed
                    } catch where Self.refusedWithACode(error) {
                        say("the change to \(disk): \(Self.code(error))")
                    }
                }
            } else if made {
                say("the create was taken and the reservation is not in the list: no change is sent")
            }

            let polling = ContinuousClock.now
            while firstDisk == nil, ContinuousClock.now - polling < .seconds(60) {
                try await Task.sleep(for: .seconds(5))
                _ = await slot("again")
            }
            if let firstDisk {
                say(String(format: "the slot first answered a disk %.2f s after the recorder answered",
                           firstDisk / .seconds(1)))
            } else {
                say("the slot answered no disk within a minute")
            }

            if made, let left = try await mine() {
                if !listed {
                    say("listed now: destination \(left.destination), in a clash \(left.conflict)")
                }
                try await client.deleteReservation(id: left.id)
            } else if listed {
                XCTFail("it should still be there to delete")
            }
        } catch {
            await deleteMine()
            throw error
        }
        expectNil(try await mine(), "and it is off the recorder again")
        let after = try await client.reservations()
        say("reservations before \(before.count), after \(after.count)")
        XCTAssertEqual(after.count, before.count, "the recorder holds as many reservations as before")
    }

    /// **Writes to the recorder.** A keyword condition (おまかせ・まる録) to the USB slot, as the app would make one:
    /// one keyword no programme carries, so that it records nothing while it lives, terrestrial alone, every hour,
    /// LSR. Read back as the app reads conditions -- its disk and its qualities -- and deleted, found by the id the
    /// recorder answered or else by its keyword. With RECORDER_HOLD set to a number of seconds it waits that long
    /// before the delete, with the condition on the recorder's own おまかせ・まる録 screen: what that screen shows as
    /// its disk is what the list cannot say, and a condition is never written back, so a disk the recorder took
    /// otherwise than it lists could not be put right in place.
    ///
    ///     RECORDER_HOST=192.0.2.63 RECORDER_WRITE=1 RECORDER_HOLD=120 \
    ///         swift test --filter LiveRecorderTests/testARecorderRuleToTheUSBDisk
    ///
    /// A refusal prints its code and skips. It deletes what it made on any failure, and prints counts, codes, the
    /// disk and the qualities, never a condition's name or keywords but its own. A condition on its keyword left by
    /// an earlier run is named and left alone; stopping the run during the hold leaves its own, and says so first.
    func testARecorderRuleToTheUSBDisk() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RECORDER_WRITE"] == "1" else {
            throw XCTSkip("set RECORDER_WRITE=1 to let this write to the recorder")
        }
        let client = try liveClient()
        _ = try await client.describe()
        let before = try await client.recorderRules()
        print("keyword conditions: \(before.count)")
        // One read lists at most 200: past that, one with this keyword left by an earlier run could be missed.
        guard before.count < 200 else { throw XCTSkip("more conditions than one read lists") }

        let keyword = Self.ownKeyword
        // One left by a run that was stopped is never this run's to delete, which finds its own by the id answered;
        // it is named, so that it is not left on the recorder unknown.
        let leftOver = before.filter { $0.keywords == [keyword] }.count
        if leftOver > 0 {
            print("left by an earlier run: \(leftOver) condition(s) on 「\(keyword)」, not touched here; delete them on"
                  + " the recorder's おまかせ・まる録 screen")
        }
        let request = RecorderRuleRequest(keywords: [keyword], broadcastingScope: "TRD",
                                          qualityCode: try XCTUnwrap(Codes.quality["LSR"]),
                                          destination: RecorderDisk.usbID)
        // Only a condition that was not there before: never one the recorder already held, whatever its keyword.
        let held = Set(before.map(\.id))
        func mine(_ id: String) async throws -> RecorderRule? {
            let rules = try await client.recorderRules()
            return rules.first { $0.id == id && !held.contains($0.id) }
                ?? rules.first { !held.contains($0.id) && $0.keywords == [keyword] }
        }
        func deleteMine(_ id: String) async {
            do {
                if let left = try await mine(id) { try await client.deleteRecorderRule(id: left.id) }
            } catch {
                print("may be left on the recorder: the condition on 「\(keyword)」 (\(Self.code(error)))")
            }
        }

        let id: String
        do {
            id = try await client.createRecorderRule(request)
        } catch {
            await deleteMine("")
            guard Self.refusedWithACode(error) else { throw error }
            print("the recorder turned the condition to USBHDD down: \(Self.code(error))")
            throw XCTSkip("the recorder turned the condition to USBHDD down")
        }
        print("created to USBHDD")
        do {
            let found = try await mine(id)
            let made = try XCTUnwrap(found, "the condition should be in the list")
            print("listed: recordDestinationID \(made.destination), quality \(made.qualityName ?? "-"), 4K quality"
                  + " \(made.qualityName4K ?? "-"), under \(made.id == id ? "the id answered" : "another id")")
            if let hold = environment["RECORDER_HOLD"].flatMap({ Int($0) }), hold > 0 {
                print("holding \(hold) s: the condition is on the recorder's おまかせ・まる録 screen now; stopping the run"
                      + " before the hold is over leaves it there, to be deleted on that screen")
                try await Task.sleep(for: .seconds(hold))
            }
            let still = try await mine(id)
            let left = try XCTUnwrap(still, "it should still be there to delete")
            try await client.deleteRecorderRule(id: left.id)
        } catch {
            await deleteMine(id)
            throw error
        }
        expectNil(try await mine(id), "and it is off the recorder again")
        let after = try await client.recorderRules()
        print("keyword conditions before \(before.count), after \(after.count)")
        XCTAssertEqual(after.count, before.count, "the recorder holds as many conditions as before")
    }

    /// The title of the test's own reservation, which a time-only reservation keeps: what tells it apart on the
    /// recorder's screen, and the only title these tests print.
    fileprivate static let ownTitle = "BD Bridge 検証 USB"
    /// A keyword no programme carries, so that the test's own condition records nothing while it lives.
    fileprivate static let ownKeyword = "BDBridge検証USB"

    /// Five minutes tomorrow from two in the morning, Japan time, moved on five minutes at a time until no
    /// reservation overlaps them; nil when none are clear by five. A repeating reservation is listed once, at its
    /// next time, which is today's when the test runs before the morning: so the five minutes are kept clear of its
    /// time of day on every day, tomorrow's among them.
    fileprivate static func fiveFreeMinutes(clearOf reservations: [Reservation], now: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        let once = Codes.repeatCodes["none"]
        let day: TimeInterval = 24 * 3600
        func overlaps(_ reservation: Reservation, _ start: Date, _ end: Date) -> Bool {
            guard reservation.repeatCode != once else { return reservation.start < end && start < reservation.end }
            // The time it comes round last at or before `start`, and the one after; Japan keeps no summer time.
            let last = (start.timeIntervalSince(reservation.start) / day).rounded(.down)
            return [last, last + 1].contains { days in
                let shifted = reservation.start.addingTimeInterval(days * day)
                return shifted < end && start < shifted.addingTimeInterval(TimeInterval(reservation.durationSec))
            }
        }
        var start = tomorrow.addingTimeInterval(2 * 3600)
        while start < tomorrow.addingTimeInterval(5 * 3600) {
            let end = start.addingTimeInterval(300)
            if !reservations.contains(where: { overlaps($0, start, end) }) { return start }
            start = end
        }
        return nil
    }

    /// A refusal with a code of the recorder's own, as against silence or an answer that could not be read.
    fileprivate static func refusedWithACode(_ error: Error) -> Bool {
        guard let error = error as? RecorderError, case .soap(_, _, let code, _) = error else { return false }
        return code != nil
    }

    /// What stopped a request, as the action and its code: never the answer's body.
    fileprivate static func code(_ error: Error) -> String {
        guard let error = error as? RecorderError else { return "\(type(of: error))" }
        switch error {
        case .soap(let action, let status, let code, _): return "\(action) refused, HTTP \(status), code \(code ?? "-")"
        case .transport: return "no answer"
        default: return "\(error.failure)"
        }
    }
}

extension LiveRecorderTests {
    /// **Writes to the recorder.** A reservation made, changed and deleted as the app makes, changes and deletes
    /// one: through a link with the recorder's driver (`RecorderDriver.reserve`, `update`, `cancel`), sent through
    /// the app's own transport, with a world of the tests' own as the link's host -- a cache in a temporary folder,
    /// and the app's timings for the USB slot rather than the moments the other tests of links give. It prints how
    /// soon the list shows the reservation, the change and the delete, which is what a later change that looks for
    /// a reservation by its programme, or waits for the list to show a change, is to be built on. The steps are
    /// `DriverCheck.run`, rehearsed on an invented recorder first (`DriverCheckRehearsalTests`).
    ///
    ///     RECORDER_HOST=192.0.2.63 RECORDER_MAC=<the recorder's MAC> RECORDER_WRITE=1 \
    ///         swift test --filter LiveRecorderTests/testTheDriverMakesChangesAndDeletesAReservation
    ///
    /// Skipped unless all three are set: the recorder leaves the network soon after it was last asked, and is woken
    /// first (`LiveWaking`). The MAC goes to that wake alone. The link is given none, so nothing it does puts a
    /// packet on the LAN, and what its host puts down (`LinkWorld.events`, which holds the MAC the recorder reports)
    /// is never printed.
    @MainActor
    func testTheDriverMakesChangesAndDeletesAReservation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RECORDER_WRITE"] == "1" else {
            throw XCTSkip("set RECORDER_WRITE=1 to let this write to the recorder")
        }
        guard let host = environment["RECORDER_HOST"], !host.isEmpty, environment["RECORDER_MAC"]?.isEmpty == false
        else {
            throw XCTSkip("set RECORDER_HOST and RECORDER_MAC as well: the recorder is woken first")
        }
        let (world, driver, link) = DriverCheck.link(to: host, cache: try temporaryStore())
        world.devices[host] = URLSessionTransport()
        try await DriverCheck.run(link, driver: driver, world: world, now: Date(),
                                  pause: { try await Task.sleep(for: .seconds(1)) }, say: { print($0) })
    }
}

/// The steps of the device check of the recorder's driver, written once for the recorder
/// (`LiveRecorderTests.testTheDriverMakesChangesAndDeletesAReservation`) and for its rehearsal on an invented one
/// (`DriverCheckRehearsalTests`), so that what is rehearsed is what runs. Everything goes through the link and its
/// driver as the app's screens ask it, except the guide, which a refresh fetches on the link's client as the app's
/// does, and the clean-up at the end, which is the client's alone: it has to go on after the link has given up.
///
/// **Which row is the check's own.** It cannot be told by a name: the recorder lists a reservation that follows its
/// programme under the programme's own title. So every write after the create, and the clean-up, acts only on a row
/// that was not in the list read before the create, is on the chosen channel at the chosen start, and was made by
/// an app (`Reservation.createdByApp`). The recorder makes the reservations it made for itself again, all at once
/// and under new ids, so a row of its own for the same programme can appear while the check runs, and the channel
/// and the start alone would take it. The driver finds the row it is handed by its id, and by its channel and start
/// only once the id has gone (`current`), so a change or a delete is asked only right after a read in which the
/// check's own is listed, and the check stops, cleaning up, when it is not. That narrows what the driver could
/// take for the check's own, and does not close it: the driver reads the list again itself before it writes, and
/// an id gone between the two reads would still be found by its channel and start.
///
/// The mark of an app is no guard on its own: the recorder has been seen to put it on reservations no app made
/// (docs/xsrs-api.md), so a row it makes for itself for the same programme can meet the whole rule. What holds is
/// that the check's own is the one new row there. When a read lists more than one -- after the create, after the
/// change or after the delete, or at the clean-up -- which is the check's own cannot be told: the check writes
/// nothing more, deletes none of them, and says that a reservation may be left at that time. And the check keeps
/// the ids of the rows it has taken for its own: once its own delete has gone through, a row at that time whose
/// id it never held is not its own, and the clean-up leaves it and says so.
///
/// One corner stays open. A list that lags behind the create, not yet listing the check's own, can list a row the
/// recorder has just made for itself for the same programme, marked as an app's: the one new row there, it is
/// taken for the check's own, and changed and deleted. No id is held by then to tell the two apart, the create
/// handing none back.
///
/// It says counts, seconds and whether something was found: never a title, an id, an address or a MAC.
@MainActor
enum DriverCheck {
    /// A step that did not come out as it should, in words that carry no title, id, address or MAC.
    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    /// A link to the recorder at `host` made as the app makes its own, with a world of the tests' own as its host
    /// and `cache` as the phone's: no MAC, so that it wakes nothing, and the app's timings for the slot. What
    /// answers at `host` is for the caller to put in the world.
    static func link(to host: String, cache: GuideStore) -> (world: LinkWorld, driver: RecorderDriver,
                                                             link: DeviceLink) {
        let world = LinkWorld()
        world.cache = cache
        world.slotReadAgainAfter = RecorderDriver.slotReadAgainAfter
        world.slotSettling = .afterAWaking
        let driver = RecorderDriver()
        let link = DeviceLink(host: host, session: SessionState(), driver: driver, environment: world.environment)
        link.owner = world
        return (world, driver, link)
    }

    /// The check, in its eight steps: connected and the list read; a programme taken from the guide; the clash
    /// check; the reservation made; changed; deleted; whatever happened, the check's own deleted if it is still,
    /// again or only now listed, and alone there; and as many reservations at the end as at the start. A step that
    /// fails ends it there, after the clean-up, and is thrown; so is a skip, and so are more new rows than one at
    /// the chosen time. `now` is when the programme is to be four hours ahead of, `pause` what goes by between two
    /// reads of a step, and `say` where its lines go.
    static func run(_ link: DeviceLink, driver: RecorderDriver, world: LinkWorld, now: Date,
                    pause: @MainActor () async throws -> Void, say: @MainActor (String) -> Void) async throws {
        // A sentence of the recorder's or of the line's, with the recorder's address taken out of it.
        func said(_ sentence: String?) -> String {
            (sentence ?? "nothing said").replacingOccurrences(of: link.host, with: "<the recorder>")
        }
        // What a reservation came to, without the row kept, whose title it would print.
        func words(_ reserved: Reserved) -> String {
            switch reserved {
            case .made: "made"
            case .wouldStop: "held for what it would stop"
            case .waiting(_, let saying): "kept on the phone: \(said(saying))"
            case .notDone(let why): "not done: \(said(why))"
            }
        }
        func seconds(since moment: ContinuousClock.Instant) -> String {
            String(format: "%.2f s", (ContinuousClock.now - moment) / .seconds(1))
        }
        // One read of the list after a pause, as a screen reads it.
        func readAgain() async throws -> [Reservation] {
            try await pause()
            guard let list = await driver.reservations() else {
                throw Failed(description: "a read of the list failed: \(said(world.problem))")
            }
            return list
        }

        // 1. Connected as the app connects, its attach and all, and the list read through the driver.
        await link.connect()
        guard link.session.connected, let client = link.client as? RecorderClient, let cache = world.cache else {
            throw Failed(description: "not connected: \(said(world.problem))")
        }
        guard let before = await driver.reservations() else {
            throw Failed(description: "the list could not be read: \(said(world.problem))")
        }
        // One read lists at most 200, the latest first: past that the soonest are not seen, and one held at the
        // chosen time could be taken for the check's own.
        guard before.count < 200 else { throw XCTSkip("more reservations than one read lists") }
        // Read only: whether the recorder's own can be found by their programme at all.
        let itsOwn = before.filter(\.createdByRecorder)
        say("reservations: \(before.count); the recorder's own: \(itsOwn.filter { $0.eventID != nil }.count)"
            + " with a programme id, \(itsOwn.filter { $0.eventID == nil }.count) without")

        // 2. The terrestrial guide put into the cache by a refresh, and the programme taken from it as a sheet is
        // handed one: the first four or more hours ahead at a time no reservation overlaps.
        // What a fetch that met nothing throws names the address it was sent to, so it is said in words.
        let refreshed: GuideRefresh.Outcome
        do {
            refreshed = try await GuideRefresh.run(client: client, store: cache, types: ["td"])
        } catch {
            throw Failed(description: "no terrestrial guide: \(said(LiveRecorderTests.code(error)))")
        }
        if let failed = refreshed.failed.first {
            throw Failed(description: "no terrestrial guide: \(said(failed.reason))")
        }
        let soon = now.addingTimeInterval(4 * 3600)
        let candidates = try await cache.programs(broadcasting: "td", since: soon, limit: 5000)
        guard let program = candidates.first(where: { program in
            program.start >= soon && !program.title.isEmpty
                && !before.contains { $0.start < program.end && program.start < $0.end }
        }) else { throw Failed(description: "the guide has no programme ahead that no reservation overlaps") }

        let held = Set(before.map(\.id))
        let channel = Codes.broadcasting[program.broadcasting]
        func isOurs(_ row: Reservation) -> Bool {
            !held.contains(row.id) && row.createdByApp && row.broadcastingType == channel
                && row.serviceID == program.serviceID && row.start == program.start
        }
        // Set once a read has listed more than one row the rule takes: from then on nothing is written or deleted.
        var notToldApart = false
        // The ids of the rows the check has taken for its own, after the create and after the change.
        var taken: Set<String> = []
        // The check's own in `list`, or nil; more than one such row ends the check.
        func ours(in list: [Reservation]?) throws -> Reservation? {
            let matching = list?.filter(isOurs) ?? []
            guard matching.count < 2 else {
                notToldApart = true
                throw Failed(description: "\(matching.count) new reservations at the chosen time:"
                             + " which is the check's own cannot be told")
            }
            return matching.first
        }

        var failure: (any Error)?
        // Whether the create went out, made or met by silence; and whether a delete of the check's own went through.
        var sent = false
        var gone = false
        do {
            // 3. Nothing the recorder holds is to be put in a clash by a reservation made only to be deleted.
            guard let clashes = await driver.conflicts(for: program, quality: "LSR", repeating: "none",
                                                       disk: RecorderDisk.internalID) else {
                throw Failed(description: "the clash check was not answered: \(said(world.problem))")
            }
            say("the clash check on the internal disk: \(clashes.count) clash(es)")
            guard clashes.isEmpty else { throw XCTSkip("the conflict check named a clash") }

            // 4. Made, and looked for in the list handed back, then in a read every second for ten: how soon a new
            // reservation is listed, and whether it carries the programme id it would be looked for by.
            let asked = ContinuousClock.now
            let came = await driver.reserve(program, quality: "LSR", repeating: "none", disk: RecorderDisk.internalID)
            switch came.reserved {
            case .made: sent = true
            case .notDone(let why): sent = why == RecorderDriver.reservationMayHaveArrived
            case .waiting, .wouldStop: break
            }
            guard case .made = came.reserved else { throw Failed(description: "not made: \(words(came.reserved))") }
            let made = ContinuousClock.now
            let handedBack = came.list?.contains(where: isOurs) == true
            say("made in \(seconds(since: asked)); in the list handed back: \(handedBack)")
            var found = try ours(in: came.list)
            var reads = 0
            while found == nil, reads < 10 {
                reads += 1
                found = try ours(in: try await readAgain())
                if found != nil { say("listed at read \(reads), \(seconds(since: made)) after it was made") }
            }
            guard var current = found else { throw Failed(description: "made and not listed in ten reads") }
            taken.insert(current.id)
            say("it carries the programme id: \(current.eventID == program.eventID)")

            // 5. Changed, and the list read until it shows the change: the one handed back, then a read every second
            // for ten. Each must still list it.
            let change = await driver.update(current, quality: "SR", repeating: "none", disk: nil)
            switch change.altered {
            case .done?: break
            case .notDone(let why)?: throw Failed(description: "not changed: \(said(why))")
            case nil: throw Failed(description: "not changed: taken for another device's")
            }
            let changed = ContinuousClock.now
            var list = change.list
            reads = 0
            while true {
                if let list {
                    guard let listed = try ours(in: list) else {
                        throw Failed(description: "no longer listed after the change")
                    }
                    current = listed
                    taken.insert(listed.id)
                    if listed.qualityName == "SR" { break }
                }
                guard reads < 10 else { throw Failed(description: "the change not listed in ten reads") }
                reads += 1
                list = try await readAgain()
            }
            say(reads == 0 ? "the change shown in the list handed back"
                : "the change shown at read \(reads), \(seconds(since: changed)) after it was made")

            // 6. Deleted, and then whether it comes back in a read every second for ten: in what each read hands
            // back, not in the list the delete handed back, from which the driver takes the row out itself; and
            // by an id the check held, a new row at that time being none of its own.
            let deletion = await driver.cancel(current)
            switch deletion.deleted {
            case .done?: break
            case .notDone(let why)?: throw Failed(description: "not deleted: \(said(why))")
            case nil: throw Failed(description: "not deleted: taken for another device's")
            }
            gone = true
            let deleted = ContinuousClock.now
            var back: String?
            for read in 1...10 {
                let again = try ours(in: try await readAgain())
                if back == nil, let again, taken.contains(again.id) {
                    back = "listed again at read \(read), \(seconds(since: deleted)) after the delete"
                }
            }
            say(back ?? "not listed again in ten reads after the delete")
        } catch {
            failure = error
        }

        // 7. Whatever happened, any row of the check's own still or again listed is deleted: through the client, by
        // the id just read, so that it goes on after the link has given up and never falls back on a row's channel
        // and start. One that went out and was neither listed nor deleted yet is waited for as step 4 waits, and
        // said to be left, with its time, when it is still not listed. Nothing is deleted once a read has listed
        // more than one row the rule takes, here or in a step before, and a reservation is said to be left. Once its
        // own delete has gone through, a row whose id the check never held is not its own: it is left, and said.
        let mayBeLeft = "may be left on the recorder: a reservation at \(RecorderTime.format(program.start))"
            + " on the internal disk"
        var last: [Reservation]?
        do {
            var listed = try await client.reservations()
            var left = listed.filter(isOurs)
            var reads = 0
            while left.isEmpty, sent, !gone, !notToldApart, reads < 10 {
                reads += 1
                try await pause()
                listed = try await client.reservations()
                left = listed.filter(isOurs)
            }
            let neverHeld = gone ? Set(left.map(\.id)).subtracting(taken) : []
            left.removeAll { neverHeld.contains($0.id) }
            if !neverHeld.isEmpty {
                say(mayBeLeft + ", \(neverHeld.count) new at that time that the check never held: not deleted")
            }
            if notToldApart || left.count > 1 {
                say(mayBeLeft + ", among more than one new reservation at that time: none was deleted")
                if failure == nil {
                    failure = Failed(description: "\(left.count) new reservations at the chosen time at the clean-up:"
                                     + " which is the check's own cannot be told")
                }
            } else {
                if left.isEmpty, sent, !gone { say(mayBeLeft + ", sent and not found in the list") }
                for row in left { try await client.deleteReservation(id: row.id) }
                if !left.isEmpty {
                    say("cleaned up: \(left.count) of the check's own deleted")
                    listed = try await client.reservations()
                }
                if listed.contains(where: { isOurs($0) && !neverHeld.contains($0.id) }) {
                    say(mayBeLeft + ", listed after its delete")
                }
            }
            last = listed
        } catch {
            say(mayBeLeft + " (\(said(LiveRecorderTests.code(error))))")
        }

        // 8. As many as at the start.
        say("reservations before \(before.count), after \(last.map { "\($0.count)" } ?? "not read")")
        if let failure { throw failure }
        guard last?.count == before.count else {
            throw Failed(description: "the recorder does not hold as many reservations as before")
        }
    }
}

/// A write the recorder turned down, said by its code alone where a thrown `RecorderError` would print the body.
private struct TurnedDown: Error, CustomStringConvertible {
    var description: String
}
