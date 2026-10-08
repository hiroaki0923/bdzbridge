import Foundation
import XCTest
import RecorderKit

/// The device check of the recorder's driver (`DriverCheck`), rehearsed on an invented recorder before it is run
/// on the real one: the check's own steps, on a link made as the live test makes it, against a recorder of the
/// bench (`ScriptedRecorder`) that keeps reservations and serves the guide of the vectors (`RecorderReservations`).
/// Nothing goes on the LAN, and the pauses between reads are not waited out.
@MainActor
final class DriverCheckRehearsalTests: XCTestCase {
    /// The recorder works through its guide again as the check makes its reservation, and makes a row of its own
    /// for the very programme the check reserved: on its channel at its start, under a new id, listed ahead of
    /// the check's own. The check changes and deletes its own and nothing else -- the recorder's row is neither
    /// changed nor deleted, the household's is as it was -- and the recorder ends with as many reservations as it
    /// began with. It lists each write a read late, so that the check's reads after each step are gone through.
    func testTheCheckNeverWritesToARowTheRecorderMadeForItself() async throws {
        let recorder = try RecorderReservations(Self.household(), guide: Self.guide(), aReadBehind: true,
                                                itsOwnAfterTheCreate: [Self.itsOwnAtSix()])
        let before = await recorder.rows

        let (failure, lines) = try await rehearse(on: recorder)
        if let failure { XCTFail("the check failed: \(failure)") }
        XCTAssertFalse(lines.contains { $0.hasPrefix("may be left") }, "\(lines)")

        let made = await recorder.made
        let six = try Self.date("2026-09-14T06:00:00+09:00")
        XCTAssertEqual(made.map(\.request.start), [six],
                       "the check should take the programme at six, the first no reservation overlaps")
        expectEqual(await recorder.changed, made.map(\.id), "a row other than the check's own was changed")
        expectEqual(await recorder.deleted, made.map(\.id), "a row other than the check's own was deleted")
        let after = await recorder.rows
        let itsOwn = try XCTUnwrap(after.first(where: { $0.creator == "1100" && $0.request.start == six }))
        XCTAssertEqual(itsOwn.request, try Self.itsOwnAtSix(), "the recorder's own row was written to")
        XCTAssertTrue(after.contains(before[0]), "the household's reservation was written to")
        XCTAssertEqual(after.count, before.count)
    }

    /// A step that fails -- the change meets silence, and the link gives the recorder up -- still has the check
    /// delete its own reservation, through the client the link had, and the recorder ends with the reservations it
    /// began with. The failure is the change's.
    func testTheCheckDeletesItsOwnReservationAfterAStepThatFailed() async throws {
        let recorder = try RecorderReservations(Self.household(), guide: Self.guide(),
                                                silentOn: ["X_UpdateRecordSchedule"])
        let before = await recorder.rows

        let failure = try await rehearse(on: recorder).failure

        let failed = try XCTUnwrap(failure as? DriverCheck.Failed, "the check went on past a change that met silence")
        XCTAssertTrue(failed.description.hasPrefix("not changed"), failed.description)
        let made = await recorder.made
        XCTAssertEqual(made.count, 1)
        expectEqual(await recorder.deleted, made.map(\.id), "the check's own was not cleaned up")
        expectEqual(await recorder.rows, before)
    }

    /// A reservation the recorder takes and lists only after the reads that look for it is looked for again at the
    /// clean-up, and deleted there: the recorder ends with the reservations it began with. The failure is the step
    /// that looked for it.
    func testTheCheckDeletesItsOwnReservationListedOnlyLate() async throws {
        let recorder = try RecorderReservations(Self.household(), guide: Self.guide(), listsACreateAfter: 15)
        let before = await recorder.rows

        let (failure, lines) = try await rehearse(on: recorder)

        let failed = try XCTUnwrap(failure as? DriverCheck.Failed, "the check went on past a reservation not listed")
        XCTAssertTrue(failed.description.hasPrefix("made and not listed"), failed.description)
        let made = await recorder.made
        XCTAssertEqual(made.count, 1)
        expectEqual(await recorder.deleted, made.map(\.id), "the check's own was not cleaned up")
        expectEqual(await recorder.rows, before)
        XCTAssertFalse(lines.contains { $0.hasPrefix("may be left") }, "\(lines)")
    }

    /// One the recorder takes and never lists is said to be left on it, with its time, though the counts agree.
    func testTheCheckSaysWhenItsOwnReservationWasNeverListed() async throws {
        let recorder = try RecorderReservations(Self.household(), guide: Self.guide(), listsACreateAfter: 100)

        let (failure, lines) = try await rehearse(on: recorder)

        XCTAssertNotNil(failure)
        expectEqual(await recorder.deleted, [])
        let six = RecorderTime.format(try Self.date("2026-09-14T06:00:00+09:00"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("may be left on the recorder: a reservation at \(six)")
            && $0.hasSuffix("sent and not found in the list") }, "\(lines)")
    }

    /// Runs the check on `recorder` at the bench's address, from midnight in Japan on the day the guide of the
    /// vectors begins. What it threw, if it threw, and what it said. Neither is held to carry a title, an id or the
    /// address of the recorder's.
    private func rehearse(on recorder: RecorderReservations) async throws
        -> (failure: (any Error)?, lines: [String]) {
        let (world, driver, link) = DriverCheck.link(to: Stub.host, cache: try temporaryStore())
        let scripted = try ScriptedRecorder(at: Stub.host, udn: DeviceLinkTests.udn, world: world)
        await scripted.keep(recorder)
        world.devices[Stub.host] = scripted
        let midnight = try Self.date("2026-09-14T00:00:00+09:00")
        var lines: [String] = []
        var failure: (any Error)?
        do {
            try await DriverCheck.run(link, driver: driver, world: world, now: midnight, pause: {},
                                      say: { lines.append($0) })
        } catch {
            failure = error
        }
        XCTAssertFalse(lines.isEmpty, "the check said nothing")
        let secrets = await recorder.given.flatMap { [$0.id, $0.request.title] } + [Stub.host]
        for line in lines + (failure.map { [String(describing: $0)] } ?? []) {
            for secret in secrets where line.contains(secret) { XCTFail("the check said \(secret)") }
        }
        return (failure, lines)
    }

    /// What the recorder holds before the check: one the household made from an app, at five, over the first
    /// programme four hours ahead, and one the recorder made for itself the next evening.
    private static func household() throws -> [(creator: String, request: ReservationRequest)] {
        [("2200", try reservation("サンプルニュース", at: "2026-09-14T05:00:00+09:00", minutes: 60, event: 14792)),
         ("1100", try reservation("翌日の番組", at: "2026-09-15T20:00:00+09:00", minutes: 60, event: 14800))]
    }

    /// The one the recorder makes for itself as it works through its guide again: the programme at six.
    private static func itsOwnAtSix() throws -> ReservationRequest {
        try reservation("あさのサンプル", at: "2026-09-14T06:00:00+09:00", minutes: 15, event: 14793)
    }

    /// A reservation of a programme of the vectors' first channel, following it, in DR.
    private static func reservation(_ title: String, at start: String, minutes: Int,
                                    event: Int) throws -> ReservationRequest {
        ReservationRequest(title: title, start: try date(start), durationSec: minutes * 60,
                           repeatCode: try XCTUnwrap(Codes.repeatCodes["none"]),
                           broadcastingType: try XCTUnwrap(Codes.broadcasting["td"]), serviceID: 0x400,
                           qualityCode: try XCTUnwrap(Codes.quality["DR"]), eventID: event)
    }

    private static func date(_ text: String) throws -> Date { try XCTUnwrap(RecorderTime.parse(text)) }

    private static func guide() throws -> Data {
        try Data(contentsOf: Vectors.directory.appendingPathComponent("epg-sample.dat"))
    }
}

/// The reservations of an invented recorder, as `ScriptedRecorder` answers them once it keeps them: listed in the
/// XML the client reads, the latest start first and the newest made first among those that start together; made,
/// changed and deleted; and, beside them, the terrestrial guide of the vectors. Anything else is refused. It can
/// meet a request with silence, list what was there at the read before rather than now, as a recorder a moment
/// behind itself, leave what a create made out of the list for a number of reads, and work through its guide
/// again right after a create, as a recorder does: what it made for itself is made again, all under new ids. What
/// was made, changed and deleted is put down.
actor RecorderReservations {
    /// One reservation as it keeps it: the id it gave, who made it (`Reservation.creator`) and what was asked.
    struct Row: Sendable, Equatable {
        var id: String
        var creator: String
        var request: ReservationRequest
    }

    /// What it holds, in the order made.
    private(set) var rows: [Row] = []
    /// What each create made, as it was made; and the ids each change and each delete went to.
    private(set) var made: [Row] = []
    private(set) var changed: [String] = []
    private(set) var deleted: [String] = []
    /// Every row it has held, for a test of what may not be said.
    private(set) var given: [Row] = []
    /// What it held at the last read of the list.
    private var atTheLastRead: [Row]
    private let guide: Data
    private let silentOn: Set<String>
    private let aReadBehind: Bool
    private let listsACreateAfter: Int
    /// For each row a create made and the list leaves out still, how many more reads leave it out.
    private var unlisted: [String: Int] = [:]
    private let itsOwnAfterTheCreate: [ReservationRequest]?

    /// Holds `rows`, serves `guide`, meets the SOAP actions of `silentOn` with silence, lists a read behind when
    /// `aReadBehind`, leaves what a create made out of the next `listsACreateAfter` reads, and after a create
    /// makes its own as `itsOwnAfterTheCreate`, when that is given.
    init(_ rows: [(creator: String, request: ReservationRequest)], guide: Data, silentOn: Set<String> = [],
         aReadBehind: Bool = false, listsACreateAfter: Int = 0, itsOwnAfterTheCreate: [ReservationRequest]? = nil) {
        self.rows = rows.enumerated().map { Row(id: Self.id($0.offset), creator: $0.element.creator,
                                                request: $0.element.request) }
        given = self.rows
        atTheLastRead = self.rows
        self.guide = guide
        self.silentOn = silentOn
        self.aReadBehind = aReadBehind
        self.listsACreateAfter = listsACreateAfter
        self.itsOwnAfterTheCreate = itsOwnAfterTheCreate
    }

    func answer(_ request: HTTPRequest) throws -> HTTPResponse {
        if request.url.lastPathComponent == "EPG_TRDEPG_FILE.dat" { return HTTPResponse(statusCode: 200, body: guide) }
        guard let action = request.headers["SOAPACTION"]?.split(separator: "#").last.map({ String($0.dropLast()) })
        else { return HTTPResponse(statusCode: 500) }
        if silentOn.contains(action) { throw RecorderError.transport("The request timed out.") }
        let call = try XmlNode.parse(request.body ?? Data())
        switch action {
        case "X_GetRecordScheduleList":
            let listed = (aReadBehind ? atTheLastRead : rows).filter { unlisted[$0.id] == nil }
            atTheLastRead = rows
            unlisted = unlisted.compactMapValues { $0 > 1 ? $0 - 1 : nil }
            return Stub.soap(action, result: Self.list(listed), totalMatches: listed.count)
        case "X_GetConflictList":
            return Stub.soap(action, result: "")
        case "X_CreateRecordSchedule":
            guard let asked = Self.asked(in: call) else { return Stub.fault("402") }
            let row = add("2200", asked.request)
            made.append(row)
            if listsACreateAfter > 0 { unlisted[row.id] = listsACreateAfter }
            if let itsOwn = itsOwnAfterTheCreate {
                rows.removeAll { $0.creator == "1100" }
                for request in itsOwn { add("1100", request) }
            }
            return Stub.soap(action)
        case "X_UpdateRecordSchedule":
            guard let asked = Self.asked(in: call), let index = rows.firstIndex(where: { $0.id == asked.id }) else {
                return Stub.fault("804")
            }
            rows[index].request = asked.request
            changed.append(asked.id)
            return Stub.soap(action)
        case "X_DeleteRecordSchedule":
            guard let id = call.firstDescendantText("RecordScheduleID"),
                  let index = rows.firstIndex(where: { $0.id == id }) else { return Stub.fault("804") }
            rows.remove(at: index)
            deleted.append(id)
            return Stub.soap(action)
        default:
            return HTTPResponse(statusCode: 500)
        }
    }

    @discardableResult
    private func add(_ creator: String, _ request: ReservationRequest) -> Row {
        let row = Row(id: Self.id(given.count), creator: creator, request: request)
        rows.append(row)
        given.append(row)
        return row
    }

    /// The list's `Result` for `rows`: each as a create would send it, with its id and its creator.
    private static func list(_ rows: [Row]) -> String {
        let open = "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\">"
        let listed = rows.enumerated().sorted { one, other in
            one.element.request.start == other.element.request.start ? one.offset > other.offset
                : one.element.request.start > other.element.request.start
        }
        let items = listed.map { _, row in
            XsrsElements.update(id: row.id, row.request).replacingOccurrences(of: open, with: "")
                .replacingOccurrences(of: "</item></xsrs>",
                                      with: "<reservationCreatorID>\(row.creator)</reservationCreatorID></item>")
        }
        return open + items.joined() + "</xsrs>"
    }

    /// The reservation a create or a change sent, and the id it was sent to.
    private static func asked(in call: XmlNode) -> (id: String, request: ReservationRequest)? {
        guard let elements = call.firstDescendantText("Elements"),
              let item = try? XsrsParse.items(inResult: elements).first,
              let sent = XsrsParse.reservation(item) else { return nil }
        return (sent.id, ReservationRequest(title: sent.title, start: sent.start, durationSec: sent.durationSec,
                                            repeatCode: sent.repeatCode, broadcastingType: sent.broadcastingType,
                                            serviceID: sent.serviceID, qualityCode: sent.qualityCode,
                                            eventID: sent.eventID, destination: sent.destination))
    }

    private static func id(_ number: Int) -> String { String(format: "0x%016lx", 0xa9430 + number) }
}
