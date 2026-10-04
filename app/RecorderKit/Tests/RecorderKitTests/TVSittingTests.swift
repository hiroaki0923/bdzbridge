import Foundation
import XCTest
@testable import RecorderKit

/// The sitting's checks rehearsed on the invented television: every one of them, in the order they are run on
/// a real one and by the same code (`TVSitting`), with what each leaves behind looked at from outside it --
/// the rows the household had, as they were and no others; a ledger with nothing left open; each request sent
/// once; and nothing said that names a programme, a station or a row. Then what a check does when something
/// goes wrong on the way, which no sitting can be made to show, and what the sitting is given before it
/// begins: its leave to write, its viewing reservation, where its files may be kept. The check for a
/// television left in standby is rehearsed by itself, on an invented television that is in standby: it is no
/// part of a sitting held with the television on, and does not run there.
///
/// The household's rows are put beside the slots the checks use and on the programmes they reserve, so that a
/// check that took a slot too near one, or deleted by its programme, would be caught here and not on
/// somebody's television. Every value is invented.
final class TVSittingTests: XCTestCase {
    private static let clientID = "BDBridge:rehearsal"
    private static let cookie = "given-9c41d07e"
    private static let neverGiven = "never-given-5e2d"

    /// A time in Japan in the first week of November 2026, whose 2nd is a Monday.
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let parts = DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    /// The Monday evening the sitting is held on: a programme is far enough ahead from Tuesday at three.
    private static let now = at(2, 19)

    /// Five terrestrial stations, the last with nothing picked on it, and one on CS. A BS station is named
    /// among the picks and is not here: the television does not list it.
    private static let stations = [
        DemoTV.Station(serviceID: 1501, name: "サンプル第一"), DemoTV.Station(serviceID: 1502, name: "サンプル\u{3000}第二"),
        DemoTV.Station(serviceID: 1503, name: "サンプル&第三 放送"), DemoTV.Station(serviceID: 1504, name: "サンプル第四"),
        DemoTV.Station(serviceID: 1505, name: "サンプル第五"),
        DemoTV.Station(scheme: "isdbcs", serviceID: 1601, name: "サンプルCS"),
    ]

    private static func owned(_ id: String, on station: Int, _ title: String, _ start: Date, _ durationSec: Int = 1800,
                              programme: Int? = nil) -> DemoTV.Schedule {
        let type = id.hasPrefix("reminder") ? "reminder" : "recording"
        return DemoTV.Schedule(id: id, type: type, scheme: stations[station].scheme,
                               serviceID: stations[station].serviceID, station: stations[station].name, title: title,
                               start: start, durationSec: durationSec, quality: type == "recording" ? "DR" : nil,
                               eventId: programme)
    }

    /// What the household has on its television before the sitting, and is to have after every check.
    private static let owners = [
        // Beside the slots the checks use: each five minutes outside the three hours of one, and the first
        // inside the three hours of the earliest programme that is far enough ahead.
        owned("recording.31", on: 2, "サンプル天気", at(3, 12, 35), 1200),
        owned("recording.33", on: 1, "サンプル劇場 前編", at(3, 19, 35)),
        owned("recording.44", on: 3, "サンプル紀行", at(4, 16, 55)),
        // At the time of day of the first free programme, on another day: nothing for a repeat goes there.
        owned("recording.36", on: 1, "サンプル将棋", at(6, 17)),
        // For the very programmes the checks reserve, on their stations, at other times: a check that
        // deleted by programme would take these.
        owned("recording.34", on: 0, "サンプル体操", at(5, 10), programme: 50102),
        owned("recording.38", on: 1, "サンプル料理", at(5, 10, 40), programme: 50104),
        owned("recording.39", on: 2, "サンプル音楽館 再", at(6, 9), 3600, programme: 50105),
        owned("recording.42", on: 0, "サンプル映画", at(7, 14), programme: 50109),
        owned("recording.43", on: 5, "サンプル寄席", at(6, 22, 30), 3600, programme: 50112),
        // Two viewing reservations: an older one, and the one set for the sitting, a second before its
        // programme as a television writes one.
        owned("reminder.35", on: 1, "サンプル落語", at(6, 12, 59, 59), 3600, programme: 50120),
        owned("reminder.45", on: 2, "サンプル音楽館", at(4, 20, 59, 59), 3600, programme: 50105),
    ]

    private static func pick(_ serviceID: Int, _ eventID: Int, _ start: Date, _ durationSec: Int = 1800,
                             type: Int = 2) -> TVPick {
        TVPick(broadcastingType: type, serviceID: serviceID, eventID: eventID, start: start, durationSec: durationSec)
    }

    private static let picks = TVPicks(programmes: [
        pick(1501, 50100, at(3, 9)),              // an empty slot, and less than twenty hours ahead
        pick(1501, 50101, at(3, 15)),             // far enough ahead, and a row within three hours of it
        pick(1501, 50102, at(3, 16)),             // the first that is free: but not for a repeat
        pick(1501, 50103, at(4, 3)),              // free on every day, and before four in the morning
        pick(1502, 50104, at(4, 5)),              // the first a repeat can go on
        pick(1504, 50108, at(4, 20, 30), 3600),   // overlaps the two below in part, starting earlier
        pick(1503, 50122, at(4, 20, 25), 2700),   // and so does this, on the viewing reservation's station
        pick(1501, 50106, at(4, 21), 3240), pick(1502, 50107, at(4, 21), 3240),
        pick(1503, 50105, at(4, 21), 3600),       // the programme of the viewing reservation
        pick(1501, 50109, at(5, 20)), pick(1502, 50110, at(5, 20)),
        pick(1504, 50111, at(5, 20, 15), 4800),   // overlaps the two above in part, starting later
        pick(1601, 50112, at(4, 10), 3600, type: 4), pick(1701, 50113, at(4, 10), 3600, type: 3),
    ], named: [TVPicks.Channel(broadcastingType: 4, serviceID: 1601),
               TVPicks.Channel(broadcastingType: 3, serviceID: 1701)])

    /// What the sitting said, kept in place of the terminal.
    private final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String] = []

        func add(_ line: String) { lock.withLock { held.append(line) } }
        var lines: [String] { lock.withLock { held } }
        var text: String { lines.joined(separator: "\n") }
    }

    /// The line to the invented television, which a test can have fail at one request: the nth of a method,
    /// counted from nought, is carried out and its answer lost, never arrives, is answered with something
    /// else and not carried out, is carried out and answered with something else, arrives just after the
    /// household has set something with the remote or taken something off with it, arrives just after the
    /// television has put its newest recording under another number or has put something else under an id it
    /// had given, is carried out and what it took off then listed again under a new number, or arrives just
    /// after the ledger was taken away or written over with another. It keeps the method of everything sent,
    /// which is what says a request went once, and what the ledger held as each create arrived.
    private actor Line: HTTPTransport {
        enum Fault: Sendable {
            case answerLost, neverArrives, answered(String), carriedOutAndAnswered(String)
            case afterTheHouseholdSets(DemoTV.Schedule), afterTheHouseholdTakesOff(String)
            case afterTheNewestIsRenumbered, carriedOutAndListedAgain, afterTheLedgerBecomes(TVLedger?)
            /// The row the television holds under this schedule's id is this schedule from here on.
            case afterWhatIsUnderItsIDBecomes(DemoTV.Schedule)
        }

        private let television: DemoTV
        private let faults: [String: Fault]
        private let ledger: URL
        private var counts: [String: Int] = [:]
        private(set) var sent: [String] = []
        private(set) var ledgerAtEachCreate: [String] = []

        init(_ television: DemoTV, faults: [String: Fault], ledger: URL) {
            self.television = television
            self.faults = faults
            self.ledger = ledger
        }

        func forget() { sent = [] }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let object = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            let method = object?["method"] as? String ?? ""
            let nth = counts[method, default: 0]
            counts[method] = nth + 1
            sent.append(method)
            if method == "addSchedule" {
                let held = try? TVLedger.read(ledger)
                ledgerAtEachCreate.append("\(held?.entries.count ?? 0) entries, the last "
                                          + (held?.entries.last?.struck == false ? "open" : "not open"))
            }
            switch faults["\(method) \(nth)"] {
            case .afterTheHouseholdSets(let schedule):
                await television.put(await television.schedules + [schedule])
                return try await television.send(request)
            case .afterTheNewestIsRenumbered:
                var held = await television.schedules
                let recordings = held.indices.filter { held[$0].type == "recording" }
                if let newest = recordings.max(by: { held[$0].number < held[$1].number }) {
                    held[newest].id = "recording.\(held[newest].number + 1)"
                }
                await television.put(held)
                return try await television.send(request)
            case .carriedOutAndListedAgain:
                let held = await television.schedules
                let answer = try await television.send(request)
                let kept = await television.schedules
                let number = (held.map(\.number).max() ?? 0) + 1
                let again = held.filter { !kept.contains($0) }.map { gone in
                    var listed = gone
                    listed.id = "recording.\(number)"
                    return listed
                }
                await television.put(kept + again)
                return answer
            case .afterTheHouseholdTakesOff(let id):
                await television.put(await television.schedules.filter { $0.id != id })
                return try await television.send(request)
            case .afterWhatIsUnderItsIDBecomes(let other):
                await television.put(await television.schedules.map { $0.id == other.id ? other : $0 })
                return try await television.send(request)
            case .afterTheLedgerBecomes(let other):
                if let other { try other.write(to: ledger) } else { try FileManager.default.removeItem(at: ledger) }
                return try await television.send(request)
            case .carriedOutAndAnswered(let body):
                _ = try await television.send(request)
                return HTTPResponse(statusCode: 200, body: Data(body.utf8))
            case .answerLost:
                _ = try await television.send(request)
                throw RecorderError.transport("The request timed out.")
            case .neverArrives: throw RecorderError.transport("The request timed out.")
            case .answered(let body): return HTTPResponse(statusCode: 200, body: Data(body.utf8))
            case nil: return try await television.send(request)
            }
        }
    }

    private struct World {
        var television: DemoTV
        var line: Line
        /// The line the sitting's client sends on, with `line` underneath it.
        var kept: TVLine
        var sitting: TVSitting
        var client: ScalarClient
        var stranger: ScalarClient
        var said: Said
        var ledger: URL
    }

    /// The start the owner names the sitting's viewing reservation by: its programme's, a second after the
    /// television lists the reservation itself.
    private static let reminder = at(4, 21)

    /// The invented television, on and holding the household's rows, and a sitting at it with a ledger of
    /// its own that goes when the test ends, with what was kept beside it. The sitting is told the viewing
    /// reservation set for it unless a test says otherwise, and the household has `owners` and the clock says
    /// `now` unless it does.
    private func world(mayWrite: Bool = true, power: String = "active", faults: [String: Line.Fault] = [:],
                       owners: [DemoTV.Schedule] = TVSittingTests.owners, reminder: Date? = TVSittingTests.reminder,
                       now: Date = TVSittingTests.now) async -> World {
        let television = DemoTV(power: power)
        await television.knows(Self.clientID, cookie: Self.cookie)
        await television.receives(Self.stations)
        await television.put(owners)
        let said = Said()
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderKitTests-\(UUID().uuidString).json")
        addTeardownBlock {
            for file in [ledger, TVSitting.saidFile(beside: ledger)] { try? FileManager.default.removeItem(at: file) }
        }
        let line = Line(television, faults: faults, ledger: ledger)
        // As the live tests build one: the sitting's client on a line that keeps what goes over it, and the
        // sitting handed both.
        let kept = TVLine(line)
        func client(_ cookie: String, on transport: any HTTPTransport) -> ScalarClient {
            ScalarClient(host: Stub.host, transport: transport,
                         credentials: MemoryTVCredentials(TVCredentials(clientID: Self.clientID, cookie: cookie)))
        }
        let own = client(Self.cookie, on: kept)
        let sitting = TVSitting(client: own, line: kept, picks: Self.picks, ledger: ledger, mayWrite: mayWrite,
                                reminder: reminder, now: { now }, say: { said.add($0) })
        return World(television: television, line: line, kept: kept, sitting: sitting, client: own,
                     stranger: client(Self.neverGiven, on: line), said: said, ledger: ledger)
    }

    /// The checks that make something, by name, each as it is run.
    private static let making: [(String, @Sendable (World) async throws -> Void)] = [
        ("a whole write", { try await $0.sitting.aWholeWrite() }),
        ("a recording where a viewing reservation is", { try await $0.sitting.aRecordingWhereAViewingReservationIs() }),
        ("the same programme twice", { try await $0.sitting.theSameProgrammeTwice() }),
        ("the repeats", { try await $0.sitting.theRepeats() }),
        ("three at once", { try await $0.sitting.threeAtOnce() }),
        ("a cookie not taken", { try await $0.sitting.aCreateWithACookieNotTaken(sentBy: $0.stranger) }),
        ("the stations named", { try await $0.sitting.theStationsNamed() }),
    ]

    private func thrown(_ check: () async throws -> Void) async -> (any Error)? {
        do {
            try await check()
            return nil
        } catch {
            return error
        }
    }

    /// Fails if `text` names a programme, a station or a row of this world, or carries what is secret of it:
    /// a title, the sitting's own included, a station's name, a uri, an id, the number of a station or of a
    /// programme, the cookies, the client id, the address, the MAC.
    private func expectNamesNothing(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        var kept = Self.owners.flatMap { [$0.title, $0.station, $0.uri] } + Self.stations.flatMap { [$0.name, $0.uri] }
        kept += [TVSitting.title, TVSitting.title.replacingOccurrences(of: " ", with: "\u{3000}"), Self.cookie,
                 Self.neverGiven, Self.clientID, Stub.host, DemoTV.mac, "1505"]
        kept += Self.picks.programmes.flatMap {
            [String($0.serviceID), String($0.eventID), DemoTV.title(ofProgramme: $0.eventID)]
        }
        for word in Set(kept) where text.contains(word) {
            XCTFail("\(word) was said", file: file, line: line)
        }
        XCTAssertNil(text.range(of: "(recording|reminder)\\.[0-9]", options: .regularExpression),
                     "an id of the television's was said", file: file, line: line)
    }

    private func entries(_ world: World) throws -> [String] {
        try TVLedger.read(world.ledger).entries.map { "\($0.serviceID) \($0.eventID) \($0.repeatType)" }
    }

    private func count(_ method: String, in world: World) async -> Int {
        await world.line.sent.filter { $0 == method }.count
    }

    /// An answer to the question that names `schedule`, in the seven fields a television names a row with.
    private func naming(_ schedule: DemoTV.Schedule) throws -> Line.Fault {
        let row: [String: Any] = [
            "id": schedule.id, "type": schedule.type, "uri": schedule.uri, "title": schedule.title,
            "startDateTime": schedule.startDateTime, "durationSec": schedule.durationSec,
            "repeatType": schedule.repeatType,
        ]
        let answer = try JSONSerialization.data(withJSONObject: ["result": [[row]], "id": 1])
        return .answered(String(decoding: answer, as: UTF8.self))
    }

    /// What every check sends before anything of its own, the question, the create and the list of one
    /// reservation made, and the delete and the list of one taken off.
    private static let opening = ["getPowerStatus", "getScheduleList", "getContentList"]
    private static let made = ["getConflictScheduleList", "addSchedule", "getScheduleList"]
    private static let takenOff = ["deleteSchedule", "getScheduleList"]

    /// What a check says after its deletes when not everything is as it is to be, by its three counts.
    private static func afterTheDeletes(unanswered: Int, left: Int, new: Int) -> String {
        "deletes that were not answered as taken: \(unanswered); rows the check made that are still listed after"
            + " their delete: \(left); recordings listed that were not there before the check: \(new). "
            + (new == 0 ? "Their entries are left in the ledger" : "Nothing is struck out while one of those is"
                + " listed: the entries of everything taken off are left in the ledger")
    }

    /// What it says of a create after which the list held one recording more that the create did not make.
    private static func notTheCreates(answered answer: String, own: Int) -> String {
        "recordings new in the list that the create did not make: 1. They are on another channel than it was sent"
            + " for, or it was answered as already there and made nothing: they are not the check's and are left"
            + " alone; the create (\(answer)) made rows of its own: \(own), and its entry is left in the ledger"
    }

    /// And what it says at its end of a list that holds one row more than the household's eleven.
    private static let oneRowMore = "the list does not read as it did before the check: rows then 11, now 12, of"
        + " those gone or read otherwise 0"

    // MARK: - the rehearsal

    /// Every check, in the sitting's order. After each: the television holds the household's rows, as they
    /// were, and nothing else; the ledger has nothing left open; and what went to the television is the
    /// check's requests, each once, with the question in front of every create there is. At the end the
    /// ledger holds what was sent, in order, each entry written before its create went out, and nothing that
    /// was said names anything.
    func testEveryCheckLeavesTheInventedTelevisionAsItFoundIt() async throws {
        let world = await world()
        let opening = Self.opening, made = Self.made, takenOff = Self.takenOff
        let three = made + made + made + ["deleteSchedule", "deleteSchedule", "deleteSchedule", "getScheduleList"]
        let sent: [String: [String]] = [
            "a whole write": ["getPowerStatus", "getStorageList", "getScheduleList", "getContentList"] + made
                + takenOff,
            "a recording where a viewing reservation is": opening + made + takenOff,
            "the same programme twice": opening + made + made + takenOff,
            "the repeats": opening + Array(repeating: made + takenOff, count: 5).flatMap { $0 } + made,
            "three at once": opening + three + three,
            "a cookie not taken": opening + made,
            "the stations named": opening + made + takenOff + ["getContentList"],
        ]

        try await world.sitting.theStations()
        expectEqual(await world.line.sent, Array(repeating: "getContentList", count: 6))
        for (name, check) in Self.making {
            await world.line.forget()
            let ended = await thrown { try await check(world) }
            XCTAssertNil(ended, "\(name) did not run to its end")
            expectEqual(await world.line.sent, sent[name], name)
            expectEqual(await world.television.schedules, Self.owners, "after \(name)")
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 0, "after \(name)")
        }
        await world.line.forget()
        try await world.sitting.whatIsLeft()
        expectEqual(await world.line.sent, ["getScheduleList"])

        // Each on the first programme that suits it, and none on one too soon or too near a row.
        XCTAssertEqual(try entries(world), [
            "1501 50102 1", "1503 50105 1", "1501 50102 1", "1501 50102 1",
            "1502 50104 w3", "1502 50104 title", "1502 50104 d", "1502 50104 w15", "1502 50104 w16", "1502 50104 w4",
            "1501 50109 1", "1502 50110 1", "1504 50111 1", "1501 50106 1", "1502 50107 1", "1504 50108 1",
            "1501 50102 1", "1601 50112 1",
        ])
        XCTAssertEqual(try TVLedger.read(world.ledger).before, TVLedger.Counts(rows: 11, recordings: 9, overlapped: 0))
        XCTAssertEqual(try TVLedger.read(world.ledger).begun, Self.now)
        // And each written down before its create was sent: what the ledger held as the create arrived.
        expectEqual(await world.line.ledgerAtEachCreate, (1...18).map { "\($0) entries, the last open" })

        let said = world.said.text
        expectNamesNothing(said)
        for line in [
            "stations of td: 5", "stations of bs: 0", "stations of cs: 1",
            "channels among the picks with no station on the television: 1 of 6",
            "rows in a page past the end of td: 0",
            "rows the question names: 0", "the create: taken, annotation 0; rows made: 1",
            "the row read back: every field as sent, in DR; its title is the one sent with its spaces widened: no",
            "the viewing reservation: Wednesday 20:59:59; its uri is the station's own: yes",
            "rows the question names: 0; the viewing reservation among them: no",
            "rows of the programme before: 1 recording, 1 reminder",
            "rows of the programme after: 1 reminder, 2 recording",
            "the first: rows the question names: 0", "the second: rows the question names: 0",
            "the second: error 41222, read as already there: yes; rows made: 0",
            "the programme: Wednesday 05:00:00", "round 2, title: rows the question names: 0",
            "round 2, title sent: taken, annotation 0; rows made: 1",
            "  read back: repeatType w16, start Wednesday 05:00:00",
            "round 6, w4 sent: error 7; rows made: 0",
            "the third later, the second: rows the question names: 0",
            "the third later, rows the question for the third names: 1 (the first)",
            "the third later: every row named is the check's own, so the third is made",
            "the third later, with them in place: the first fullyOverlapped, the second notOverlapped,"
                + " the third notOverlapped",
            "the third earlier, rows the question for the third names: 1 (the first)",
            "the third earlier, with them in place: the first fullyOverlapped, the second notOverlapped,"
                + " the third notOverlapped, the viewing reservation partlyOverlapped",
            "the create with a cookie the television never gave: HTTP 403; rows made: 0",
            "station 1 of 2 (cs): rows the question names: 0",
            "station 1 of 2 (cs): taken, annotation 0; rows made: 1",
            "station 2 of 2 (bs): not in the television's list, so nothing is sent",
            "the list: rows 11, recordings 9, losing to another 0;"
                + " before the first create: rows 11, recordings 9, losing to another 0",
            "the ledger: entries 18, not struck out 0; recordings listed that one of them may have left: 0",
        ] {
            XCTAssertTrue(said.components(separatedBy: "\n").contains(line), "not said: \(line)")
        }
        // The one line that says the last check passed, said once, at its end.
        XCTAssertEqual(world.said.lines.last, "nothing of the sitting is left")
        XCTAssertEqual(world.said.lines.filter { $0 == "nothing of the sitting is left" }.count, 1)
        let asItWas = "the television's list reads as it did before the check"
        XCTAssertEqual(said.components(separatedBy: asItWas).count - 1, Self.making.count)
    }

    // MARK: - what a check does when it may not, and when something goes wrong

    /// Nothing is made unless the sitting may write, the ledger has nothing left open, and the television
    /// says it is on. With no leave nothing is sent at all and the ledger is not touched; with an entry left
    /// open nothing is sent either, and that is no check that merely did not run: it is thrown as what stops
    /// the sitting, since something of it may be on the television. In standby the one request is the one
    /// that asks. Nor is a whole write begun on a television whose disk is not there.
    func testNothingIsMadeWithoutLeaveOrBesideAnOpenEntryOrInStandby() async throws {
        let unasked = await world(mayWrite: false)
        let behind = await world()
        var open = TVLedger()
        open.entries = [TVLedger.Entry(broadcastingType: 2, serviceID: 1501, eventID: 50102, start: Self.at(3, 16),
                                       durationSec: 1800, repeatType: "1")]
        try open.write(to: behind.ledger)
        let standby = await world(power: "standby")

        for (name, check) in Self.making {
            let refusals = [
                (unasked, "writing to the television was not asked for"),
                (standby, "the television says it is standby"),
            ]
            for (world, why) in refusals {
                let refused = await thrown { try await check(world) } as? TVSitting.Refused
                XCTAssertEqual(refused?.why.hasPrefix(why), true, "\(name): \(refused?.why ?? "it ran")")
                expectEqual(await world.television.schedules, Self.owners, name)
            }
            let stopped = await thrown { try await check(behind) } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what.hasPrefix("entries of the ledger not struck out: 1. Something of the"
                                                   + " sitting may be on the television"), true,
                           "\(name): \(stopped?.what ?? "it ran, or was merely refused")")
            expectEqual(await behind.television.schedules, Self.owners, name)
        }
        expectEqual(await unasked.line.sent, [], "something was sent with no leave to write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unasked.ledger.path))
        expectEqual(await behind.line.sent, [], "something was sent beside an entry left open")
        XCTAssertEqual(try TVLedger.read(behind.ledger), open)
        expectEqual(await standby.line.sent, Self.making.map { _ in "getPowerStatus" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: standby.ledger.path))

        let unmounted = #"{"result":[[{"uri":"usb:recStorage","mounted":"unmounted"}]],"id":1}"#
        let diskless = await world(faults: ["getStorageList 0": .answered(unmounted)])
        let refused = await thrown { try await diskless.sitting.aWholeWrite() } as? TVSitting.Refused
        XCTAssertEqual(refused?.why, "the television has no disk to record to")
        expectEqual(await diskless.line.sent, ["getPowerStatus", "getStorageList"])
    }

    /// A check that fails on the way takes off what it had made before it ends: with the second of three
    /// refused, the first is deleted and seen gone, and nothing more is made. Where the list cannot be read
    /// after a create, so that what was made is not known, nothing is deleted and the entry stays open: the
    /// next check then makes nothing and fails, and the count afterwards says what is wrong. A row that is
    /// new and is no recording is not the check's to delete. And an entry stays open for a create that was
    /// taken and that the list shows nothing of.
    func testACheckThatFailsOnTheWayTakesOffWhatItMade() async throws {
        let refusal = #"{"error":[\#(DemoTV.inventedError),"refused"],"id":1}"#
        let world = await world(faults: ["addSchedule 1": .answered(refusal)])

        let stopped = await thrown { try await world.sitting.threeAtOnce() } as? TVSitting.Stopped

        XCTAssertEqual(stopped?.what, "the second did not make one row")
        expectEqual(await world.line.sent, Self.opening + Self.made + Self.made + Self.takenOff)
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertEqual(try entries(world), ["1501 50109 1", "1502 50110 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 0)
        XCTAssertTrue(world.said.text.contains("the third later, the second: error \(DemoTV.inventedError)"))

        let blind = await self.world(faults: ["getScheduleList 1": .neverArrives])
        let unknown = await thrown { try await blind.sitting.aWholeWrite() } as? TVSitting.Stopped
        XCTAssertEqual(unknown?.what, "getScheduleList: no answer after a create (taken, annotation 0): what it made"
                       + " is not known, and its entry is left in the ledger")
        expectEqual(await blind.line.sent.suffix(2), ["addSchedule", "getScheduleList"])
        expectEqual(await blind.television.schedules.count, Self.owners.count + 1)
        XCTAssertEqual(try TVLedger.read(blind.ledger).open, 1)

        await blind.line.forget()
        let behind = await thrown { try await blind.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(behind?.what.hasPrefix("entries of the ledger not struck out: 1."), true)
        expectEqual(await blind.line.sent, [])
        let left = await thrown { try await blind.sitting.whatIsLeft() } as? TVSitting.Stopped
        XCTAssertEqual(left?.what, "entries of the ledger not struck out: 1; recordings listed that may be the"
                       + " sitting's: 1; the list does not count as it did")
        XCTAssertFalse(blind.said.text.contains("nothing of the sitting is left"))

        // A viewing reservation the household sets while a check is under way is new in the list and is not
        // the check's: only recordings are. The check says that the list has changed, and leaves it.
        let set = Self.owned("reminder.46", on: 3, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)
        let meanwhile = await self.world(faults: ["addSchedule 0": .afterTheHouseholdSets(set)])
        let changed = await thrown { try await meanwhile.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(changed?.what, Self.oneRowMore)
        expectEqual(await meanwhile.television.schedules, Self.owners + [set])
        expectEqual(await count("deleteSchedule", in: meanwhile), 1)
        XCTAssertEqual(try TVLedger.read(meanwhile.ledger).open, 0)

        let taken = #"{"result":[{"annotation":0}],"id":1}"#
        let unseen = await self.world(faults: ["addSchedule 0": .answered(taken)])
        let nothing = await thrown { try await unseen.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(nothing?.what, "a create (taken, annotation 0) shows nothing new in the list: its entry is"
                       + " left in the ledger")
        expectEqual(await count("addSchedule", in: unseen), 1)
        XCTAssertEqual(try TVLedger.read(unseen.ledger).open, 1)

        for text in [stopped?.what, unknown?.what, behind?.what, left?.what, changed?.what, nothing?.what,
                     world.said.text, blind.said.text, meanwhile.said.text, unseen.said.text] {
            expectNamesNothing(text ?? "")
        }
    }

    /// A recording somebody else sets while a create is out is not the check's, though its id is new: the
    /// check's own are the new recordings on the channel it sent the create for. The household's, on another
    /// station, is left where it is; the check's own row is taken off; nothing more is made; and the entry
    /// stays open, so that nothing goes on until somebody has looked at the television. It stays open as well
    /// where the household has taken its recording off again by the time the check's own row is seen gone,
    /// and the list reads as it did: the check saw a recording it cannot account for.
    func testARecordingSomebodyElseSetsMeanwhileIsLeftAlone() async throws {
        let set = Self.owned("recording.46", on: 3, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)
        let world = await world(faults: ["addSchedule 0": .afterTheHouseholdSets(set)])

        let stopped = await thrown { try await world.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped

        XCTAssertEqual(stopped?.what, Self.notTheCreates(answered: "taken, annotation 0", own: 1) + "; and "
                       + Self.afterTheDeletes(unanswered: 0, left: 0, new: 1))
        expectEqual(await world.television.schedules, Self.owners + [set], "the household's recording was deleted")
        expectEqual(await world.line.sent, Self.opening + Self.made + Self.takenOff)
        XCTAssertEqual(try entries(world), ["1501 50102 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 1)
        expectNamesNothing((stopped?.what ?? "") + world.said.text)

        let passing = await self.world(faults: ["addSchedule 0": .afterTheHouseholdSets(set),
                                                "deleteSchedule 0": .afterTheHouseholdTakesOff(set.id)])
        let seen = await thrown { try await passing.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(seen?.what, Self.notTheCreates(answered: "taken, annotation 0", own: 1))
        expectEqual(await passing.television.schedules, Self.owners)
        XCTAssertEqual(try TVLedger.read(passing.ledger).open, 1)
    }

    /// A create the television answers as a reservation already there made nothing, as was measured, so no
    /// row is the check's own after it. Where somebody reserved the very programme a moment before, the one
    /// recording new on the channel is theirs: it is not deleted, the entry stays open, and the check ends.
    /// The same for a recording set on the channel while the second create of one programme is out: the
    /// check's own first row is taken off, the other is left where it is, and nothing is struck out.
    func testARecordingNewAfterACreateAnsweredAsAlreadyThereIsNotTheChecks() async throws {
        let theirs = Self.owned("recording.46", on: 0, "サンプル体操", Self.at(3, 16), programme: 50102)
        let world = await world(faults: ["addSchedule 0": .afterTheHouseholdSets(theirs)])

        let stopped = await thrown { try await world.sitting.aWholeWrite() } as? TVSitting.Stopped

        XCTAssertEqual(stopped?.what, Self.notTheCreates(answered: "error 41222", own: 0) + "; and " + Self.oneRowMore)
        expectEqual(await world.television.schedules, Self.owners + [theirs], "the household's recording was deleted")
        expectEqual(await world.line.sent, ["getPowerStatus", "getStorageList", "getScheduleList", "getContentList"]
                    + Self.made)
        XCTAssertEqual(try entries(world), ["1501 50102 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 1)

        let beside = Self.owned("recording.47", on: 0, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)
        let twice = await self.world(faults: ["addSchedule 1": .afterTheHouseholdSets(beside)])
        let second = await thrown { try await twice.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(second?.what, Self.notTheCreates(answered: "error 41222", own: 0) + "; and "
                       + Self.afterTheDeletes(unanswered: 0, left: 0, new: 1))
        expectEqual(await twice.television.schedules, Self.owners + [beside], "the household's recording was deleted")
        expectEqual(await twice.line.sent, Self.opening + Self.made + Self.made + Self.takenOff)
        XCTAssertEqual(try TVLedger.read(twice.ledger).open, 2)

        for (what, said) in [(stopped?.what, world.said.text), (second?.what, twice.said.text)] {
            expectNamesNothing((what ?? "") + said)
        }
    }

    /// An entry is struck out only when its delete was answered without an error and its row is gone from
    /// the list. A delete that is carried out and whose answer is lost, one that is refused with the row
    /// still there, and one that is refused because the television has put the row under another number --
    /// so that the number the check knew is gone from the list and the row is not: each leaves the entry
    /// open and ends the check, and the next check makes nothing. In the rounds of the repeats the round
    /// after is not begun on top of what may be left.
    func testAnEntryIsStruckOutOnlyWhenItsDeleteWasAnsweredAndItsRowIsGone() async throws {
        let noSuchRow = #"{"error":[41200,"no such schedule"],"id":1}"#
        let changed = "; and " + Self.oneRowMore
        let cases: [(Line.Fault, String, Int, String)] = [
            (.answerLost, Self.afterTheDeletes(unanswered: 1, left: 0, new: 0), 0, "no answer"),
            (.answered(noSuchRow), Self.afterTheDeletes(unanswered: 1, left: 1, new: 1) + changed, 1, "error 41200"),
            (.afterTheNewestIsRenumbered, Self.afterTheDeletes(unanswered: 1, left: 0, new: 1) + changed, 1,
             "error 41200"),
        ]
        for (fault, what, left, answer) in cases {
            let world = await world(faults: ["deleteSchedule 0": fault])
            let stopped = await thrown { try await world.sitting.theRepeats() } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what, what, "\(fault)")
            expectEqual(await world.line.sent, Self.opening + Self.made + Self.takenOff, "\(fault)")
            expectEqual(await world.television.schedules.count, Self.owners.count + left, "\(fault)")
            XCTAssertEqual(try entries(world), ["1502 50104 w3"], "\(fault)")
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 1, "\(fault)")
            XCTAssertTrue(world.said.text.hasSuffix("  a delete: \(answer)"), "\(fault)")

            await world.line.forget()
            let behind = await thrown { try await world.sitting.threeAtOnce() } as? TVSitting.Stopped
            XCTAssertEqual(behind?.what.hasPrefix("entries of the ledger not struck out: 1."), true, "\(fault)")
            expectEqual(await world.line.sent, [], "\(fault)")
            expectNamesNothing((stopped?.what ?? "") + world.said.text)
        }
    }

    /// Nothing is struck out while the list holds a recording it did not have when the check began. A
    /// television that answers a delete as taken and then lists the reservation again under a new number
    /// cannot be told from one on which somebody set a recording while the check waited. Either way the
    /// recording is left alone, the entry stays open though its delete was answered and its number is gone,
    /// the round after is not begun, and the next check makes nothing. And with three taken off of which one
    /// is still listed, none of the three is struck out.
    func testNothingIsStruckOutWhileARecordingIsListedThatWasNotThereBefore() async throws {
        let set = Self.owned("recording.47", on: 3, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)
        let what = Self.afterTheDeletes(unanswered: 0, left: 0, new: 1) + "; and " + Self.oneRowMore
        let cases: [(String, Line.Fault)] = [
            ("listed again", .carriedOutAndListedAgain), ("set meanwhile", .afterTheHouseholdSets(set)),
        ]
        for (name, fault) in cases {
            let world = await world(faults: ["deleteSchedule 0": fault])
            let stopped = await thrown { try await world.sitting.theRepeats() } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what, what, name)
            expectEqual(await world.line.sent, Self.opening + Self.made + Self.takenOff, name)
            let left = await world.television.schedules.suffix(1)
            XCTAssertEqual(left.map(\.id), ["recording.47"], name)
            XCTAssertEqual(left.map(\.repeatType), [name == "listed again" ? "w3" : "1"], name)
            expectEqual(await world.television.schedules.dropLast(), Self.owners[...], name)
            XCTAssertEqual(try entries(world), ["1502 50104 w3"], name)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 1, name)

            await world.line.forget()
            let behind = await thrown { try await world.sitting.threeAtOnce() } as? TVSitting.Stopped
            XCTAssertEqual(behind?.what.hasPrefix("entries of the ledger not struck out: 1."), true, name)
            expectEqual(await world.line.sent, [], name)
            expectNamesNothing((stopped?.what ?? "") + world.said.text)
        }

        let noSuchRow = #"{"error":[41200,"no such schedule"],"id":1}"#
        let three = await world(faults: ["deleteSchedule 1": .answered(noSuchRow)])
        let stopped = await thrown { try await three.sitting.threeAtOnce() } as? TVSitting.Stopped
        XCTAssertEqual(stopped?.what, Self.afterTheDeletes(unanswered: 1, left: 1, new: 1) + "; and " + Self.oneRowMore)
        expectEqual(await three.line.sent, Self.opening + Self.made + Self.made + Self.made
                    + ["deleteSchedule", "deleteSchedule", "deleteSchedule", "getScheduleList"])
        expectEqual(await three.television.schedules.count, Self.owners.count + 1)
        XCTAssertEqual(try TVLedger.read(three.ledger).open, 3)
    }

    /// An entry is struck out only while it is in the file as the check wrote it. With the ledger taken away
    /// while a check is under way, or written over with another's -- a second command run at the same
    /// moment -- the place the check wrote at is gone, or holds an entry that is somebody else's. Nothing is
    /// struck out, the file is left as it was found, and the check ends saying so, with what it made taken
    /// off before the ledger was looked at.
    func testAnEntryIsStruckOutOnlyWhileItIsInTheFileAsTheCheckWroteIt() async throws {
        var theirs = TVLedger()
        theirs.entries = [TVLedger.Entry(broadcastingType: 2, serviceID: 1502, eventID: 50110, start: Self.at(5, 20),
                                         durationSec: 1800, repeatType: "1")]
        theirs.before = TVLedger.Counts(rows: 11, recordings: 9, overlapped: 0)
        theirs.begun = Self.now
        let cases: [(String, TVLedger?)] = [("taken away", nil), ("written over", theirs)]
        for (name, other) in cases {
            let world = await world(faults: ["deleteSchedule 0": .afterTheLedgerBecomes(other)])
            let stopped = await thrown { try await world.sitting.aWholeWrite() } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what, "the ledger is not the one this check wrote in: an entry it wrote down is"
                           + " not there as it was written, and nothing is struck out", name)
            expectEqual(await world.line.sent, ["getPowerStatus", "getStorageList", "getScheduleList", "getContentList"]
                        + Self.made + Self.takenOff, name)
            expectEqual(await world.television.schedules, Self.owners, name)
            XCTAssertEqual(FileManager.default.fileExists(atPath: world.ledger.path), other != nil, name)
            if let other { XCTAssertEqual(try TVLedger.read(world.ledger), other, name) }
        }
    }

    /// After silence on a create nothing is sent again: the list is read, once, and a row of the check's
    /// own found there is deleted. Whether the create arrived or not, the check ends and the television is
    /// as it was. Where the list showed the row, its entry is struck out with its delete; where it showed
    /// nothing, the entry stays open, since a television may carry out afterwards a create it never
    /// answered, and the next check makes nothing. In the rounds of the repeats the round after is not begun.
    func testAfterSilenceOnACreateNothingIsSentAgain() async throws {
        let head = ["getPowerStatus", "getStorageList", "getScheduleList", "getContentList", "getConflictScheduleList"]
        let silence = "a create met no answer, and nothing is sent again; rows it made: "
        let cases: [(Line.Fault, [String], String, Int)] = [
            (.answerLost, ["addSchedule", "getScheduleList", "deleteSchedule", "getScheduleList"], silence + "1", 0),
            (.neverArrives, ["addSchedule", "getScheduleList"],
             silence + "0. The television may yet carry it out: its entry is left in the ledger", 1),
        ]
        for (fault, after, what, open) in cases {
            let world = await world(faults: ["addSchedule 0": fault])
            let stopped = await thrown { try await world.sitting.aWholeWrite() } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what, what, "\(fault)")
            expectEqual(await world.line.sent, head + after, "\(fault)")
            expectEqual(await world.television.schedules, Self.owners, "\(fault)")
            XCTAssertEqual(try entries(world), ["1501 50102 1"])
            XCTAssertEqual(try TVLedger.read(world.ledger).open, open, "\(fault)")

            await world.line.forget()
            let next = await thrown { try await world.sitting.theSameProgrammeTwice() }
            XCTAssertEqual((next as? TVSitting.Stopped)?.what.hasPrefix("entries of the ledger not struck out"),
                           open == 1 ? true : nil, "\(fault)")
            expectEqual(await count("addSchedule", in: world), open == 1 ? 0 : 2, "\(fault)")
        }

        let world = await world(faults: ["addSchedule 1": .answerLost])
        let stopped = await thrown { try await world.sitting.theRepeats() } as? TVSitting.Stopped
        XCTAssertEqual(stopped?.what, "a create met no answer, and nothing is sent again; rows it made: 1")
        expectEqual(await count("addSchedule", in: world), 2)
        expectEqual(await world.line.sent.suffix(3), ["getScheduleList", "deleteSchedule", "getScheduleList"])
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertEqual(try entries(world), ["1502 50104 w3", "1502 50104 title"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 0)
    }

    /// What a create's answer says is said: the number in it, which is nought on every create a television
    /// has taken so far, so that another is seen when it comes, and that there was none.
    func testWhatACreatesAnswerSaysIsSaid() async throws {
        let cases = [
            (#"[{"annotation":1}]"#, "the create: taken, annotation 1; rows made: 1"),
            ("[{}]", "the create: taken, with no annotation; rows made: 1"),
            ("[]", "the create: taken, with no annotation; rows made: 1"),
        ]
        for (answer, line) in cases {
            let fault = Line.Fault.carriedOutAndAnswered(#"{"result":\#(answer),"id":1}"#)
            let world = await world(faults: ["addSchedule 0": fault])
            try await world.sitting.aWholeWrite()
            XCTAssertTrue(world.said.text.components(separatedBy: "\n").contains(line), "not said: \(line)")
            expectEqual(await world.television.schedules, Self.owners, answer)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 0, answer)
        }
    }

    /// The television is asked before every create what the reservation would stop from recording, and no
    /// create is sent that it says would stop a reservation of the household's. Where the question before a
    /// check's first create names one, the check does not run: nothing is made and nothing is written down.
    /// Where it is the question before a later create, the check stops there and what it made is taken off.
    /// Where the question for the third of three names anything but the two just made, the third is not
    /// made, and the two are taken off. Only the viewing reservation set for the sitting may be named, by
    /// the check that is about it. And an answer that cannot be read is no leave to send the create.
    func testNoCreateIsSentThatWouldStopAReservationOfTheHouseholds() async throws {
        let theirs = try naming(Self.owners[1])
        let why = "the television says the reservation would stop one that is not the check's own"
        for (name, check) in Self.making {
            let world = await world(faults: ["getConflictScheduleList 0": theirs])
            let ended = await thrown { try await check(world) }
            if name == "the stations named" {
                XCTAssertNil(ended, name)
                XCTAssertTrue(world.said.text.contains("station 1 of 2 (cs): a row that is not the check's own is"
                                                       + " named, so nothing is made\n"), name)
            } else {
                XCTAssertEqual((ended as? TVSitting.Refused)?.why, why, name)
            }
            expectEqual(await count("getConflictScheduleList", in: world), 1, name)
            expectEqual(await count("addSchedule", in: world), 0, name)
            expectEqual(await world.television.schedules, Self.owners, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.ledger.path), name)
            expectNamesNothing(world.said.text)
        }

        let later: [(String, String, Int, @Sendable (World) async throws -> Void)] = [
            ("getConflictScheduleList 1", "the second: ", 1, { try await $0.sitting.theSameProgrammeTwice() }),
            ("getConflictScheduleList 2", "round 3, d: ", 2, { try await $0.sitting.theRepeats() }),
            ("getConflictScheduleList 1", "the third later, the second: ", 1, { try await $0.sitting.threeAtOnce() }),
        ]
        for (question, label, creates, check) in later {
            let world = await world(faults: [question: theirs])
            let stopped = await thrown { try await check(world) } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what, "\(label)\(why), so it is not made")
            expectEqual(await count("addSchedule", in: world), creates, label)
            expectEqual(await count("deleteSchedule", in: world), creates, label)
            expectEqual(await world.television.schedules, Self.owners, label)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 0, label)
        }

        let reminder = try XCTUnwrap(Self.owners.last)
        let three = await world(faults: ["getConflictScheduleList 5": try naming(reminder)])
        try await three.sitting.threeAtOnce()
        expectEqual(await three.line.sent.suffix(10), Self.made + Self.made + [
            "getConflictScheduleList", "deleteSchedule", "deleteSchedule", "getScheduleList",
        ])
        XCTAssertEqual(try entries(three).suffix(2), ["1501 50106 1", "1502 50107 1"])
        XCTAssertTrue(three.said.text.contains("the third earlier, rows the question for the third names: 1"
                                               + " (the viewing reservation)\n"))
        XCTAssertTrue(three.said.text.contains("a row that is not the check's own is named, so the third is not made"))

        let third = await world(faults: ["getConflictScheduleList 2": theirs])
        try await third.sitting.threeAtOnce()
        expectEqual(await count("addSchedule", in: third), 5)
        XCTAssertTrue(third.said.text.contains("the third later, rows the question for the third names: 1"
                                               + " (another recording)\nthe third later: a row that is not the"
                                               + " check's own is named, so the third is not made\n"))

        let beside = await world(faults: ["getConflictScheduleList 0": try naming(reminder)])
        try await beside.sitting.aRecordingWhereAViewingReservationIs()
        expectEqual(await count("addSchedule", in: beside), 1)
        XCTAssertTrue(beside.said.text.contains("rows the question names: 1, of type reminder;"
                                                + " the viewing reservation among them: yes\n"))

        let unreadable = await world(faults: ["getConflictScheduleList 0": .answered(#"{"result":[],"id":1}"#)])
        let unread = await thrown { try await unreadable.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(unread?.what, "getConflictScheduleList: an answer that cannot be read")
        expectEqual(await count("addSchedule", in: unreadable), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadable.ledger.path))

        for world in [three, third, beside, unreadable] {
            expectEqual(await world.television.schedules, Self.owners)
            expectNamesNothing(world.said.text)
        }
    }

    /// The one clash a television was measured to answer: with two reservations at one time on two stations,
    /// the question for a third that overlaps them names the first of the two, and the third is taken all
    /// the same. The row named is the check's own, so the third is made, that is said, and all three are
    /// taken off: the television is as it was found and the ledger has nothing open.
    func testTheThirdIsMadeWhenTheQuestionNamesTheChecksOwnFirst() async throws {
        let first = DemoTV.Schedule(id: "recording.46", serviceID: 1501, station: Self.stations[0].name,
                                    title: DemoTV.title(ofProgramme: 50109), start: Self.at(5, 20), eventId: 50109)
        let world = await world(faults: ["getConflictScheduleList 2": try naming(first)])

        try await world.sitting.threeAtOnce()

        let three = Self.made + Self.made + Self.made
            + ["deleteSchedule", "deleteSchedule", "deleteSchedule", "getScheduleList"]
        expectEqual(await world.line.sent, Self.opening + three + three)
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertEqual(try entries(world), ["1501 50109 1", "1502 50110 1", "1504 50111 1", "1501 50106 1",
                                            "1502 50107 1", "1504 50108 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 0)
        for line in [
            "the third later, rows the question for the third names: 1 (the first)",
            "the third later: every row named is the check's own, so the third is made",
            "the third later, the third: taken, annotation 0; rows made: 1",
            "the third later, with them in place: the first fullyOverlapped, the second notOverlapped,"
                + " the third notOverlapped",
            "the third earlier, rows the question for the third names: 1 (the first)",
        ] {
            XCTAssertTrue(world.said.text.components(separatedBy: "\n").contains(line), "not said: \(line)")
        }
        expectNamesNothing(world.said.text)
    }

    /// One repeat at a time: the reservation is on the invented television, with the repeat that was named,
    /// while it is being looked at and not after, and what the check sends is the question, the create and
    /// the list, then the delete and the list -- once each. A name that is no repeat's is refused with
    /// nothing sent.
    func testOneRepeatIsOnTheTelevisionWhileItIsLookedAtAndNotAfter() async throws {
        for (which, code) in [("weekly", "w3"), ("title", "title"), ("daily", "d"), ("weekdays", "w15"),
                              ("weekdaysAndSaturday", "w16")] {
            let world = await world()
            let seen = Said()
            try await world.sitting.oneRepeat(which) {
                let made = await world.television.schedules.filter { !Self.owners.contains($0) }
                seen.add(made.map(\.repeatType).joined(separator: " "))
            }
            XCTAssertEqual(seen.lines, [code], "\(which): what was on the television while it was looked at")
            expectEqual(await world.line.sent, Self.opening + Self.made + Self.takenOff, which)
            expectEqual(await world.television.schedules, Self.owners, which)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 0, which)
            expectNamesNothing(world.said.text)
        }

        let world = await world()
        let refused = await thrown { try await world.sitting.oneRepeat("fortnightly") {} } as? TVSitting.Refused
        XCTAssertNotNil(refused, "a repeat nobody named was tried")
        expectEqual(await world.line.sent, [], "something was sent for a repeat nobody named")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.ledger.path))
    }

    /// On each station named the question comes before the create as well. A question the television
    /// answers with an error of its own is what the app would meet first for such a station: it is said, no
    /// create is sent, and the next station is still asked about. Silence there ends the check.
    func testAStationNamedIsAskedAboutBeforeAnythingIsMadeOnIt() async throws {
        let refusal = #"{"error":[\#(DemoTV.inventedError),"refused"],"id":1}"#
        let refused = await world(faults: ["getConflictScheduleList 0": .answered(refusal)])
        try await refused.sitting.theStationsNamed()
        expectEqual(await refused.line.sent, Self.opening + ["getConflictScheduleList", "getContentList"])
        XCTAssertTrue(refused.said.text.contains("station 1 of 2 (cs): the question: error \(DemoTV.inventedError),"
                                                 + " so no create is sent\n"))
        XCTAssertTrue(refused.said.text.contains("station 2 of 2 (bs): not in the television's list"))

        let silent = await world(faults: ["getConflictScheduleList 0": .neverArrives])
        let stopped = await thrown { try await silent.sitting.theStationsNamed() } as? TVSitting.Stopped
        XCTAssertEqual(stopped?.what, "getConflictScheduleList: no answer")
        expectEqual(await silent.line.sent, Self.opening + ["getConflictScheduleList"])

        for world in [refused, silent] {
            expectEqual(await world.television.schedules, Self.owners)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.ledger.path))
            expectNamesNothing(world.said.text)
        }
    }

    // MARK: - the check for a television in standby

    /// What the standby check sends before anything is queued, what a round opens on, and all that is sent
    /// before the round's question.
    private static let standbyOpening = ["getPowerStatus", "getStorageList", "getScheduleList", "getContentList"]
    private static let roundOpening = ["getStorageList", "getScheduleList"]
    private static let toTheQuestion = standbyOpening + roundOpening + ["getContentList"]
    /// What it sends as it ends, once it has begun and where no request met silence.
    private static let standbyEnding = ["getPowerStatus"]
    /// And what it then says, of a television that has stayed as it was.
    private static let stillInStandby = "the television says it is: standby"

    /// What the queue says of a round, as the check says it: its counts, and its stop.
    private static func round(sent: Int = 0, there: Int = 0, held: Int = 0, _ reason: String? = nil,
                              passedOver: Int = 0, remarks: Int = 0, stop: String = "not stopped") -> String {
        "sent \(sent), found there already \(there), held with a reason \(held)" + (reason.map { " (\($0))" } ?? "")
            + ", passed over \(passedOver), dropped as over 0, held from before 0, said of what was made \(remarks);"
            + " \(stop)"
    }

    /// What the check says the first flush sent, when the round got as far as its question: the disk, the
    /// list and the stations, each answered, and then `after`.
    private static func firstFlushSent(_ after: String) -> String {
        "the first flush sent: getStorageList answered, getScheduleList answered, getContentList answered, \(after)"
    }

    /// What it says of a flush after which the list held one recording more that the flush did not make.
    private static func notTheFlushes(_ answer: String, own: Int) -> String {
        "recordings new in the list that the first flush did not make: 1. They are on another channel than it"
            + " was sent for or of another programme, or it took no create and made nothing: they are not the"
            + " check's and are left alone; the first flush (\(answer)) made rows of its own: \(own), and its"
            + " entry is left in the ledger"
    }

    /// The check for a television left in standby, on the invented one in standby with the household's rows
    /// in place. One waiting row goes through the queue's own flush: the round's six requests, the question
    /// in front of the create. The same row flushed again is found on the television, with the disk and the
    /// list asked and nothing else. One create went in all, its entry in the ledger before it. What each
    /// flush sent is said, a request at a time, and at the end what the television says it is.
    ///
    /// The programme is not the first with an empty slot: the household holds a recording of that one, which
    /// the round would have taken for the row. Nor is it the next, which starts at three in the morning:
    /// the check reserves nothing of the small hours. It is the first after those with an empty slot of
    /// which the household holds no recording.
    ///
    /// Afterwards the household's rows are as they were, the ledger has nothing open, nothing that was said
    /// names anything, and the count afterwards passes.
    func testAWaitingRowGoesThroughTheRoundInStandbyAndIsFoundThereTheSecondTime() async throws {
        let world = await world(power: "standby")

        try await world.sitting.aWaitingRowInStandby()

        expectEqual(await world.line.sent, Self.toTheQuestion + Self.made + ["getScheduleList"]
                    + Self.roundOpening + ["getScheduleList"] + Self.takenOff + Self.standbyEnding)
        expectEqual(await count("addSchedule", in: world), 1, "the same row was sent a second time")
        expectEqual(await world.line.ledgerAtEachCreate, ["1 entries, the last open"])
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertEqual(try entries(world), ["1502 50110 1", "1502 50110 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 0)
        expectEqual(world.said.lines, [
            "the disk: mounted", "the list: rows 11, recordings 9, losing to another 0",
            "the first flush sent: getStorageList answered, getScheduleList answered, getContentList answered,"
                + " getConflictScheduleList answered, addSchedule answered, getScheduleList answered",
            "the first flush: \(Self.round(sent: 1))", "the first flush: rows made: 1",
            "the row read back: every field as sent, in DR; its title is the one sent with its spaces widened: no",
            "the second flush sent: getStorageList answered, getScheduleList answered",
            "the second flush: \(Self.round(there: 1))", "the second flush: rows made: 0",
            "the television's list reads as it did before the check",
            "the television says it is: standby",
        ])
        expectNamesNothing(world.said.text)

        await world.television.turn("active")
        await world.line.forget()
        try await world.sitting.whatIsLeft()
        expectEqual(await world.line.sent, ["getScheduleList"])
        XCTAssertEqual(world.said.lines.last, "nothing of the sitting is left")
    }

    /// The standby check makes nothing without leave, with nothing sent at all; nor on a television that
    /// says it is on, where the one request is the one that asks; nor beside an entry left open, which fails
    /// with nothing sent. None of those is a check that began, and none asks anything at its end. Nor does
    /// it make anything on a television whose disk is not there: nothing is written down, and beyond the
    /// disk the one thing asked is what the television says it is, as the check ends. Where the disk goes
    /// between the check's look at it and the round's, it is the round that stops, before its list: nothing
    /// is asked about and nothing made, and the entry written for the flush is struck out, the list showing
    /// nothing new.
    func testTheStandbyCheckMakesNothingWithoutLeaveOrOnATelevisionThatIsOnOrHasNoDisk() async throws {
        let check: @Sendable (World) async throws -> Void = { try await $0.sitting.aWaitingRowInStandby() }
        let diskless = await world(power: "standby")
        await diskless.television.unmount()
        let refusals: [(World, String, [String], [String])] = [
            (await world(mayWrite: false, power: "standby"), "writing to the television was not asked for", [], []),
            (await world(), "the television says it is active, and this is a check for one that is in standby",
             ["getPowerStatus"], []),
            (diskless, "the television has no disk to record to", ["getPowerStatus", "getStorageList"]
                + Self.standbyEnding, ["the disk: not mounted", Self.stillInStandby]),
        ]
        for (world, why, sent, said) in refusals {
            let refused = await thrown { try await check(world) } as? TVSitting.Refused
            XCTAssertEqual(refused?.why, why)
            expectEqual(await world.line.sent, sent, why)
            XCTAssertEqual(world.said.lines, said, why)
            expectEqual(await world.television.schedules, Self.owners, why)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.ledger.path), why)
        }

        let behind = await world(power: "standby")
        var open = TVLedger()
        open.entries = [TVLedger.Entry(broadcastingType: 2, serviceID: 1501, eventID: 50103, start: Self.at(4, 3),
                                       durationSec: 1800, repeatType: "1")]
        try open.write(to: behind.ledger)
        let stopped = await thrown { try await check(behind) } as? TVSitting.Stopped
        XCTAssertEqual(stopped?.what.hasPrefix("entries of the ledger not struck out: 1."), true)
        expectEqual(await behind.line.sent, [], "something was sent beside an entry left open")
        XCTAssertEqual(behind.said.lines, [])

        let unmounted = #"{"result":[[{"uri":"usb:recStorage","mounted":"unmounted"}]],"id":1}"#
        let gone = await world(power: "standby", faults: ["getStorageList 1": .answered(unmounted)])
        let ended = await thrown { try await check(gone) } as? TVSitting.Stopped
        XCTAssertEqual(ended?.what, "the first flush did not make one row")
        expectEqual(await gone.line.sent, Self.standbyOpening + ["getStorageList", "getScheduleList"]
                    + Self.standbyEnding)
        expectEqual(gone.said.lines.suffix(4), [
            "the first flush sent: getStorageList answered",
            "the first flush: " + Self.round(stop: "stopped: no disk to record to"), "the first flush: rows made: 0",
            Self.stillInStandby,
        ])
        expectEqual(await gone.television.schedules, Self.owners)
        XCTAssertEqual(try entries(gone), ["1502 50110 1"])
        XCTAssertEqual(try TVLedger.read(gone.ledger).open, 0)
    }

    /// A round that goes wrong leaves what a create that failed leaves, by the same rules, and what the
    /// round sent is said whichever way it went.
    ///
    /// A create carried out and not answered stops the round: nothing is sent again, by the round or by the
    /// check; the list is read once, the row found there is taken off, and its entry struck out with its
    /// delete. One that never arrived leaves nothing in the list and its entry open, since a television may
    /// carry out afterwards what it never answered. So does one answered as taken that the list does not
    /// have. A recording somebody sets on another station while the round is out is not the check's: it is
    /// left where it is, the check's own row is taken off, and the entry stays open. Where somebody reserved
    /// the very programme a moment before, the round finds theirs and says the row was there already: no row
    /// is the check's own then, theirs is not deleted, and the entry stays open. And a row the round holds
    /// because the television names a reservation of the household's makes nothing, its entry struck out,
    /// with the reason said by its kind and not as it was written, which has the household's title in it.
    /// Where the round could not read its list after the create and stopped, the row left unsaid, the row
    /// the check's own list shows is the check's and is taken off, and the check fails: the round did not
    /// say it made one. After an entry left open the next check makes nothing.
    ///
    /// Each ends with the television asked what it says it is, but for the two whose create met no answer:
    /// after silence nothing is sent but the list and the delete of the check's own row.
    func testARoundThatGoesWrongLeavesWhatACreateThatFailedLeaves() async throws {
        let elsewhere = Self.owned("recording.46", on: 3, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)
        let theirs = Self.owned("recording.46", on: 1, "サンプル夜話", Self.at(5, 20), programme: 50110)
        let taken = #"{"result":[{"annotation":0}],"id":1}"#, unreadable = #"{"result":[],"id":1}"#
        let silence = "the first flush met no answer, and nothing is sent again; rows it made: "
        let afterSilence = Self.round(stop: "stopped by silence, at a create or after it")
        let unanswered = "getConflictScheduleList answered, addSchedule no answer"
        let answered = "getConflictScheduleList answered, addSchedule answered, getScheduleList answered"
        let made = Self.made + ["getScheduleList"]
        let cases: [(String, [String: Line.Fault], String, String, String, [String], [DemoTV.Schedule], Int)] = [
            ("carried out and not answered", ["addSchedule 0": .answerLost], unanswered, afterSilence, silence + "1",
             ["getConflictScheduleList", "addSchedule", "getScheduleList"] + Self.takenOff, [], 0),
            ("never arrived", ["addSchedule 0": .neverArrives], unanswered, afterSilence,
             silence + "0. The television may yet carry it out: its entry is left in the ledger",
             ["getConflictScheduleList", "addSchedule", "getScheduleList"], [], 1),
            ("answered as taken and not listed", ["addSchedule 0": .answered(taken)], answered,
             Self.round(held: 1, "answered as taken, and not in the list"),
             "the first flush (\(Self.round(held: 1, "answered as taken, and not in the list"))) shows nothing new"
                + " in the list: its entry is left in the ledger", made + Self.standbyEnding, [], 1),
            ("a recording set on another station meanwhile", ["addSchedule 0": .afterTheHouseholdSets(elsewhere)],
             answered, Self.round(sent: 1), Self.notTheFlushes(Self.round(sent: 1), own: 1) + "; and "
                + Self.afterTheDeletes(unanswered: 0, left: 0, new: 1),
             made + Self.takenOff + Self.standbyEnding, [elsewhere], 1),
            ("the very programme reserved a moment before", ["addSchedule 0": .afterTheHouseholdSets(theirs)],
             "getConflictScheduleList answered, addSchedule error 41222, getScheduleList answered",
             Self.round(there: 1), Self.notTheFlushes(Self.round(there: 1), own: 0) + "; and " + Self.oneRowMore,
             made + Self.standbyEnding, [theirs], 1),
            ("a reservation of the household's named", ["getConflictScheduleList 0": try naming(Self.owners[1])],
             "getConflictScheduleList answered", Self.round(held: 1, "it would stop another from recording"),
             "the first flush did not make one row", ["getConflictScheduleList", "getScheduleList"]
                + Self.standbyEnding, [], 0),
            ("the list after the create not read by the round", ["getScheduleList 2": .answered(unreadable)],
             answered, Self.round(stop: "stopped: answers that say nothing"),
             "the first flush did not make one row", made + Self.takenOff + Self.standbyEnding, [], 0),
        ]
        for (name, faults, sent, said, what, afterTheStations, left, open) in cases {
            let world = await world(power: "standby", faults: faults)
            let stopped = await thrown { try await world.sitting.aWaitingRowInStandby() }
            XCTAssertEqual((stopped as? TVSitting.Stopped)?.what, what, name)
            XCTAssertTrue(world.said.lines.contains(Self.firstFlushSent(sent)), "\(name): \(world.said.text)")
            XCTAssertTrue(world.said.lines.contains("the first flush: \(said)"), "\(name): \(world.said.text)")
            expectEqual(await world.line.sent, Self.toTheQuestion + afterTheStations, name)
            // What the television says it is, said last where it was asked, and not said after silence.
            XCTAssertEqual(world.said.lines.filter { $0.hasPrefix("the television says it is") },
                           said == afterSilence ? [] : [Self.stillInStandby], name)
            XCTAssertEqual(world.said.lines.last == Self.stillInStandby, said != afterSilence, name)
            expectEqual(await world.television.schedules, Self.owners + left, name)
            XCTAssertEqual(try entries(world), ["1502 50110 1"], name)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, open, name)
            expectNamesNothing(what + world.said.text)

            guard open == 1 else { continue }
            await world.line.forget()
            let next = await thrown { try await world.sitting.aWaitingRowInStandby() }
            XCTAssertEqual((next as? TVSitting.Stopped)?.what.hasPrefix("entries of the ledger not struck out: 1."),
                           true, name)
            expectEqual(await world.line.sent, [], name)
        }

        // A second flush that does not find the row fails the check, and the first flush's row is taken off
        // all the same: here the disk is gone by the second round, which stops on it.
        let unmounted = #"{"result":[[{"uri":"usb:recStorage","mounted":"unmounted"}]],"id":1}"#
        let twice = await world(power: "standby", faults: ["getStorageList 2": .answered(unmounted)])
        let second = await thrown { try await twice.sitting.aWaitingRowInStandby() }
        XCTAssertEqual((second as? TVSitting.Stopped)?.what, "the same row a second time was not found on the"
                       + " television")
        expectEqual(await twice.line.sent, Self.toTheQuestion + made + ["getStorageList", "getScheduleList"]
                    + Self.takenOff + Self.standbyEnding)
        XCTAssertTrue(twice.said.lines.contains("the second flush sent: getStorageList answered"))
        expectEqual(await twice.television.schedules, Self.owners)
        XCTAssertEqual(try TVLedger.read(twice.ledger).open, 0)
    }

    /// Where a flush took no create, nothing that is new in the list afterwards is the check's own. Here the
    /// round stops at the disk, and somebody has reserved the very programme from another device after the
    /// check read its list: a recording that is new, on the pick's own station and of the pick's own
    /// programme. It is left where it is, nothing is deleted, and the entry stays open.
    func testNothingNewAfterAFlushThatTookNoCreateIsTheChecksOwn() async throws {
        let unmounted = #"{"result":[[{"uri":"usb:recStorage","mounted":"unmounted"}]],"id":1}"#
        let theirs = Self.owned("recording.46", on: 1, "サンプル夜話", Self.at(5, 20), programme: 50110)
        let world = await world(power: "standby", faults: ["getContentList 0": .afterTheHouseholdSets(theirs),
                                                           "getStorageList 1": .answered(unmounted)])
        let atTheDisk = Self.round(stop: "stopped: no disk to record to")

        let stopped = await thrown { try await world.sitting.aWaitingRowInStandby() } as? TVSitting.Stopped

        XCTAssertEqual(stopped?.what, Self.notTheFlushes(atTheDisk, own: 0) + "; and " + Self.oneRowMore)
        expectEqual(await world.television.schedules, Self.owners + [theirs], "the household's recording was deleted")
        expectEqual(await world.line.sent, Self.standbyOpening + ["getStorageList", "getScheduleList"]
                    + Self.standbyEnding)
        XCTAssertEqual(try entries(world), ["1502 50110 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 1)
        expectNamesNothing((stopped?.what ?? "") + world.said.text)
    }

    /// After a flush whose create was taken, the check's own row is the new recording on the pick's station
    /// that is of the pick's programme, and no other. A recording of another programme that somebody sets on
    /// that station while the flush is out is theirs: it is left where it is, the check's own row is taken
    /// off, and the entry stays open.
    func testARecordingOfAnotherProgrammeNewAfterAFlushIsNotTheChecks() async throws {
        let theirs = Self.owned("recording.46", on: 1, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)
        let world = await world(power: "standby", faults: ["addSchedule 0": .afterTheHouseholdSets(theirs)])

        let stopped = await thrown { try await world.sitting.aWaitingRowInStandby() } as? TVSitting.Stopped

        XCTAssertEqual(stopped?.what, Self.notTheFlushes(Self.round(sent: 1), own: 1) + "; and "
                       + Self.afterTheDeletes(unanswered: 0, left: 0, new: 1))
        expectEqual(await world.television.schedules, Self.owners + [theirs], "the household's recording was deleted")
        expectEqual(await world.line.sent, Self.toTheQuestion + Self.made + ["getScheduleList"] + Self.takenOff
                    + Self.standbyEnding)
        expectEqual(await count("deleteSchedule", in: world), 1)
        XCTAssertEqual(try entries(world), ["1502 50110 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 1)
        expectNamesNothing((stopped?.what ?? "") + world.said.text)
    }

    /// A flush that sent no create made nothing, whatever the queue says of its round: whether it sent one
    /// is read from the line. Here the round's question is answered with an error code, as a television in
    /// standby may answer it. The round passes the row over, which is what it says as well of a create whose
    /// answer it could not read, and no create goes out. With nothing new in the list the entry is struck
    /// out, and the check fails for not having made its row. And where somebody has reserved the very
    /// programme from another device while the flush was out, that recording -- new, on the pick's own
    /// station and of the pick's own programme -- is theirs: it is left where it is, no delete is sent, and
    /// the entry stays open.
    func testAFlushThatSentNoCreateMadeNothingWhateverTheQueueSaysOfIt() async throws {
        let hasToBeOn = #"{"error":[40005,"display off"],"id":1}"#
        let theirs = Self.owned("recording.46", on: 1, "サンプル夜話", Self.at(5, 20), programme: 50110)
        let passedOver = Self.round(passedOver: 1)
        let cases: [(String, [String: Line.Fault], String, [DemoTV.Schedule], Int)] = [
            ("nothing new in the list", ["getConflictScheduleList 0": .answered(hasToBeOn)],
             "the first flush did not make one row", [], 0),
            ("the very programme reserved from another device meanwhile",
             ["getContentList 1": .afterTheHouseholdSets(theirs), "getConflictScheduleList 0": .answered(hasToBeOn)],
             Self.notTheFlushes(passedOver, own: 0) + "; and " + Self.oneRowMore, [theirs], 1),
        ]
        for (name, faults, what, left, open) in cases {
            let world = await world(power: "standby", faults: faults)

            let stopped = await thrown { try await world.sitting.aWaitingRowInStandby() } as? TVSitting.Stopped

            XCTAssertEqual(stopped?.what, what, name)
            XCTAssertTrue(world.said.lines.contains(Self.firstFlushSent("getConflictScheduleList error 40005")),
                          "\(name): \(world.said.text)")
            XCTAssertTrue(world.said.lines.contains("the first flush: \(passedOver)"), "\(name): \(world.said.text)")
            expectEqual(await world.line.sent, Self.toTheQuestion + ["getConflictScheduleList", "getScheduleList"]
                        + Self.standbyEnding, name)
            expectEqual(await count("deleteSchedule", in: world), 0, "\(name): a delete was sent")
            expectEqual(await world.television.schedules, Self.owners + left, name)
            XCTAssertEqual(try entries(world), ["1502 50110 1"], name)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, open, name)
            expectNamesNothing((stopped?.what ?? "") + world.said.text)
        }
    }

    /// A row the check holds is read again from the row the list has under its id only while that row is
    /// still it: on its channel and of its programme. Where the television has put another reservation
    /// under the id between two reads -- another programme on the same station, or the same programme id on
    /// another station -- that reservation is not the check's: no delete is sent for it, it is still there
    /// afterwards, and the check ends saying so by a count, its entry left open. Nothing that is new in
    /// that list is taken for the check's own either, and the entry of what was just sent stays open with
    /// it. The next check then makes nothing.
    ///
    /// With the television on and two rows held, the one whose id has gone to another reservation is sent
    /// no delete and the other, still the check's own, is taken off; what the create just sent made stays,
    /// and nothing is struck out.
    ///
    /// And a row that is still the check's own and reads otherwise than it did -- its programme moved by
    /// five minutes -- is read again, and its delete is sent as it was last read.
    func testARowTheCheckHoldsIsReadAgainOnlyFromARowThatIsStillIt() async throws {
        let gone = "rows the check made whose id the list now has for another channel or programme: 1. They are not"
            + " the check's any more: no delete is sent for them, and their entries are left in the ledger"
        let unknown = ": what it made is not known, and its entry is left in the ledger"
        let others = [
            ("another programme on its station",
             Self.owned("recording.46", on: 1, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)),
            ("its programme's id on another station",
             Self.owned("recording.46", on: 3, "サンプル夜話", Self.at(5, 20), programme: 50110)),
        ]
        // The list the check reads after its second flush is the sixth it is sent in all.
        for (name, other) in others {
            let world = await world(power: "standby",
                                    faults: ["getScheduleList 5": .afterWhatIsUnderItsIDBecomes(other)])

            let stopped = await thrown { try await world.sitting.aWaitingRowInStandby() } as? TVSitting.Stopped

            XCTAssertEqual(stopped?.what, gone + " after the second flush (\(Self.round(there: 1)))" + unknown
                           + "; and " + Self.oneRowMore, name)
            expectEqual(await world.television.schedules, Self.owners + [other], "\(name): it was deleted")
            expectEqual(await world.line.sent, Self.toTheQuestion + Self.made + ["getScheduleList"]
                        + Self.roundOpening + ["getScheduleList"] + Self.standbyEnding, name)
            expectEqual(await count("deleteSchedule", in: world), 0, "\(name): a delete was sent")
            XCTAssertEqual(try entries(world), ["1502 50110 1", "1502 50110 1"], name)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 2, name)
            XCTAssertEqual(world.said.lines.last, Self.stillInStandby, name)
            expectNamesNothing((stopped?.what ?? "") + world.said.text)

            await world.line.forget()
            let next = await thrown { try await world.sitting.aWaitingRowInStandby() } as? TVSitting.Stopped
            XCTAssertEqual(next?.what.hasPrefix("entries of the ledger not struck out: 2."), true, name)
            expectEqual(await world.line.sent, [], name)
        }

        // The list after the third create of three, the first two held: the first's id has gone.
        let other = others[0].1
        let three = await world(faults: ["getScheduleList 3": .afterWhatIsUnderItsIDBecomes(other)])
        let stopped = await thrown { try await three.sitting.threeAtOnce() } as? TVSitting.Stopped
        XCTAssertEqual(stopped?.what, gone + " after a create (taken, annotation 0)" + unknown + "; and "
                       + Self.afterTheDeletes(unanswered: 0, left: 0, new: 2))
        expectEqual(await three.line.sent, Self.opening + Self.made + Self.made + Self.made + Self.takenOff)
        let left = await three.television.schedules
        expectEqual(Array(left.dropLast()), Self.owners + [other], "it was deleted, or the second was not")
        XCTAssertEqual(left.last.map { "\($0.id) \($0.serviceID) \($0.eventId ?? 0)" }, "recording.48 1504 50111")
        XCTAssertEqual(try entries(three), ["1501 50109 1", "1502 50110 1", "1504 50111 1"])
        XCTAssertEqual(try TVLedger.read(three.ledger).open, 3)
        expectNamesNothing((stopped?.what ?? "") + three.said.text)

        let moved = Self.owned("recording.46", on: 1, DemoTV.title(ofProgramme: 50110), Self.at(5, 20, 5),
                               programme: 50110)
        let followed = await world(power: "standby",
                                   faults: ["getScheduleList 5": .afterWhatIsUnderItsIDBecomes(moved)])
        try await followed.sitting.aWaitingRowInStandby()
        expectEqual(await count("deleteSchedule", in: followed), 1)
        expectEqual(await followed.television.schedules, Self.owners)
        XCTAssertEqual(try TVLedger.read(followed.ledger).open, 0)
    }

    /// The second flush is to send no create, and the check fails where it sent one, though the queue says
    /// of the row just what it says when none was sent. Here the round's opening does not find the row, its
    /// list answered empty that once: the round asks about the reservation and sends a create, which the
    /// television answers as held already, finds the row in its list after that, and tells it as found
    /// there. The check says what the flush sent, takes its row off, and stops for the create.
    func testASecondFlushThatSendsACreateFailsTheCheckThoughItsRowIsToldAsFoundThere() async throws {
        let empty = #"{"result":[[]],"id":1}"#
        let world = await world(power: "standby", faults: ["getScheduleList 4": .answered(empty)])

        let stopped = await thrown { try await world.sitting.aWaitingRowInStandby() } as? TVSitting.Stopped

        XCTAssertEqual(stopped?.what, "the second flush sent a create: the row was to be found on the television at"
                       + " the round's opening, with nothing sent for it")
        expectEqual(await world.line.sent, Self.toTheQuestion + Self.made + ["getScheduleList"]
                    + Self.roundOpening + ["getContentList"] + Self.made + ["getScheduleList"] + Self.takenOff
                    + Self.standbyEnding)
        expectEqual(world.said.lines.suffix(4), [
            "the second flush sent: getStorageList answered, getScheduleList answered, getContentList answered,"
                + " getConflictScheduleList answered, addSchedule error 41222, getScheduleList answered",
            "the second flush: \(Self.round(there: 1))", "the second flush: rows made: 0", Self.stillInStandby,
        ])
        expectEqual(await count("addSchedule", in: world), 2)
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 0)
        expectNamesNothing((stopped?.what ?? "") + world.said.text)
    }

    /// As it ends the standby check asks once more what the television says it is, and says it. Whatever
    /// that is fails nothing: a television that says it has come on is said so and the check passes. Nor
    /// does a read that fails, which is said by its kind and not thrown. And after a request that met no
    /// answer nothing is asked: here the answer to the check's own delete is lost, the list is read once
    /// after it as after any delete, and that is the last thing sent.
    func testTheStandbyCheckEndsBySayingWhatTheTelevisionSaysItIsUnlessARequestMetNoAnswer() async throws {
        let active = #"{"result":[{"status":"active"}],"id":1}"#
        let refusal = #"{"error":[\#(DemoTV.inventedError),"refused"],"id":1}"#
        let cases: [(Line.Fault, String)] = [
            (.answered(active), "the television says it is: active"),
            (.answered(refusal), "what the television says it is was not read: error \(DemoTV.inventedError)"),
            (.neverArrives, "what the television says it is was not read: no answer"),
        ]
        for (fault, line) in cases {
            let world = await world(power: "standby", faults: ["getPowerStatus 1": fault])
            try await world.sitting.aWaitingRowInStandby()
            XCTAssertEqual(world.said.lines.last, line)
            XCTAssertEqual(world.said.lines.dropLast().last, "the television's list reads as it did before the check")
            expectEqual(await count("getPowerStatus", in: world), 2, line)
            expectEqual(await world.television.schedules, Self.owners, line)
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 0, line)
        }

        let silent = await world(power: "standby", faults: ["deleteSchedule 0": .answerLost])
        let stopped = await thrown { try await silent.sitting.aWaitingRowInStandby() } as? TVSitting.Stopped
        XCTAssertEqual(stopped?.what, Self.afterTheDeletes(unanswered: 1, left: 0, new: 0))
        expectEqual(Array(await silent.line.sent.suffix(2)), Self.takenOff)
        expectEqual(await count("getPowerStatus", in: silent), 1, "the television was asked after silence")
        XCTAssertEqual(silent.said.lines.last, "  a delete: no answer")
        XCTAssertEqual(try TVLedger.read(silent.ledger).open, 1)
    }

    /// What a flush sent is read from the line the sitting was handed, so the standby check does not run on
    /// a line its client does not send on: every flush would be said to have sent nothing, and a second
    /// flush that sent a create would pass for one that sent none. It is refused once the television has
    /// been asked what it says it is and the line has kept nothing of that, before anything else is sent.
    func testTheStandbyCheckDoesNotRunOnALineItsClientDoesNotSendOn() async throws {
        let world = await world(power: "standby")
        let said = world.said, now = Self.now
        let apart = TVSitting(client: world.client, line: TVLine(world.line), picks: Self.picks, ledger: world.ledger,
                              mayWrite: true, now: { now }, say: { said.add($0) })

        let refused = await thrown { try await apart.aWaitingRowInStandby() } as? TVSitting.Refused

        XCTAssertEqual(refused?.why, "the sitting was handed a line that its client does not send on")
        expectEqual(await world.line.sent, ["getPowerStatus"])
        XCTAssertEqual(world.said.lines, [])
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.ledger.path))
    }

    /// A programme that starts in the small hours in Japan, from midnight until five, is none the standby
    /// check reserves: to the second at either end, whatever the day, and by Japan's clock whatever zone
    /// the machine that runs the check is in.
    func testAProgrammeThatStartsInTheSmallHoursIsNoneTheStandbyCheckReserves() throws {
        let cases: [(Date, Bool)] = [
            (Self.at(3, 23, 59, 59), false), (Self.at(4, 0), true), (Self.at(4, 3), true),
            (Self.at(4, 4, 59, 59), true), (Self.at(4, 5), false), (Self.at(4, 12), false), (Self.at(7, 2, 30), true),
        ]
        let own = NSTimeZone.default
        defer { NSTimeZone.default = own }
        for zone in ["Asia/Tokyo", "UTC", "Pacific/Honolulu"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            for (start, expected) in cases {
                XCTAssertEqual(TVSitting.startsInTheSmallHours(start), expected, "\(TVSitting.when(start)) in \(zone)")
            }
        }
    }

    /// The line a sitting's client sends on hands each request on as it came and the answer back as it
    /// came, and keeps of each the name of its method and the kind of its answer, in the order sent: an
    /// answer, the method's own error by its code, a status that is not 200 by its number, and no answer
    /// for a request the transport underneath threw for. Nothing else of a request or of an answer is kept:
    /// not a title or a station's name in a body, the address, or the cookie. And what a body gives as its
    /// method is kept only when it is letters of the alphabet: a title there, an id, an address or no body
    /// at all are a request that names no method.
    func testTheLineKeepsOfEachRequestItsMethodAndTheKindOfItsAnswerAndNothingElse() async throws {
        func ok(_ body: String) -> HTTPResponse { HTTPResponse(statusCode: 200, body: Data(body.utf8)) }
        let title = Self.owners[1].title, station = Self.stations[0].name
        let lost = RecorderError.transport("Could not connect to http://\(Stub.host)/sony/recording")
        let cases: [(method: String?, answer: HTTPResponse?, kept: String)] = [
            ("getScheduleList", ok(#"{"result":[[{"id":"recording.46","title":"\#(title)"}]],"id":1}"#),
             "getScheduleList answered"),
            ("addSchedule", ok(#"{"error":[40005,"\#(station)"],"id":2}"#), "addSchedule error 40005"),
            ("getStorageList", HTTPResponse(statusCode: 403, body: Data(title.utf8)), "getStorageList HTTP 403"),
            ("deleteSchedule", nil, "deleteSchedule no answer"),
            ("getContentList", ok(station), "getContentList answered"),
            ("getPowerStatus", ok(#"{"error":["\#(title)"],"id":6}"#), "getPowerStatus answered"),
            (title, ok(#"{"result":[],"id":7}"#), "a request that names no method answered"),
            ("recording.46", nil, "a request that names no method no answer"),
            (Stub.host, HTTPResponse(statusCode: 500), "a request that names no method HTTP 500"),
            ("", ok(#"{"result":[],"id":10}"#), "a request that names no method answered"),
            (nil, ok(#"{"result":[],"id":11}"#), "a request that names no method answered"),
        ]
        let answers = cases.map(\.answer)
        let stub = StubTransport { _, index in
            guard let answer = answers[index] else { throw lost }
            return answer
        }
        let line = TVLine(stub)
        let url = try XCTUnwrap(URL(string: "http://\(Stub.host)/sony/recording"))
        let headers = ["Content-Type": "application/json", "Cookie": "auth=\(Self.cookie)"]

        for (index, sent) in cases.enumerated() {
            let asked: [String: Any] = ["method": sent.method ?? "", "id": index + 1, "version": "1.0",
                                        "params": [["title": title, "uri": Self.stations[0].uri]]]
            let body = sent.method == nil ? nil : try JSONSerialization.data(withJSONObject: asked)
            let request = HTTPRequest(url: url, method: "POST", headers: headers, body: body, timeout: 7)
            do {
                let answer = try await line.send(request)
                XCTAssertEqual(answer.statusCode, sent.answer?.statusCode, sent.kept)
                XCTAssertEqual(answer.body, sent.answer?.body, sent.kept)
            } catch {
                XCTAssertNil(sent.answer, sent.kept)
                XCTAssertEqual(error as? RecorderError, lost, sent.kept)
            }
            let handedOn = await stub.requests.last
            XCTAssertEqual(handedOn?.url, url, sent.kept)
            XCTAssertEqual(handedOn?.headers, headers, sent.kept)
            XCTAssertEqual(handedOn?.body, body, sent.kept)
            XCTAssertEqual(handedOn?.timeout, 7, sent.kept)
        }

        let kept = await line.sent
        XCTAssertEqual(kept.map(\.said), cases.map(\.kept))
        XCTAssertEqual(kept.filter { $0.answer == TVLine.noAnswer }.count, 2)
        expectEqual(await stub.requests.count, cases.count, "a request was sent more or less than once")
        expectNamesNothing(kept.map(\.said).joined(separator: "\n"))
    }

    /// What the queue said of a round is said by its counts and its stop, and a reason on a row by its
    /// kind: never as it was written, which names the household's reservations by their titles, nor what the
    /// device said of the rows it made, which names them too. And it says that no create was taken only
    /// where it shows so: a row found there already, or held with a reason that comes before a create or
    /// with an error from one; a round stopped for the disk, or by silence before a create. A row sent, one
    /// passed over, one held because its create was answered as taken, one held for a reason not known
    /// here, and any other stop do not say so.
    func testWhatTheQueueSaidOfARoundIsSaidByItsCountsAndSaysWhetherACreateWasTaken() {
        let row = PendingReservation(request: ReservationRequest(title: "サンプル劇場", start: Self.at(4, 21),
                                                                 durationSec: 1800, repeatCode: "1",
                                                                 broadcastingType: 2, serviceID: 1501,
                                                                 qualityCode: 100, eventID: 50106),
                                     serviceName: "サンプル第一", queuedAt: Self.now, target: .tv)
        func outcome(_ change: (inout PendingQueue.Outcome) -> Void) -> PendingQueue.Outcome {
            var outcome = PendingQueue.Outcome(slot: .tv)
            change(&outcome)
            return outcome
        }
        func held(_ reason: String?) -> PendingQueue.Outcome {
            var held = row
            held.problem = reason
            return outcome { $0.refused = [held] }
        }
        let cases: [(PendingQueue.Outcome, String, Bool)] = [
            (outcome { $0.sent = [row] }, Self.round(sent: 1), false),
            (outcome {
                $0.sent = [row]
                $0.remarks = [ScalarClient.leftMarked("サンプル劇場", [Self.owners[1].row])]
            }, Self.round(sent: 1, remarks: 1), false),
            (outcome { $0.alreadyThere = [row] }, Self.round(there: 1), true),
            (held(ScalarClient.wouldStop(naming: [Self.owners[1].row])),
             Self.round(held: 1, "it would stop another from recording"), true),
            (held(ScalarClient.stationNotListed), Self.round(held: 1, "its station is not in the television's list"),
             true),
            (held(ScalarClient.refusals[7]), Self.round(held: 1, "turned down with error 7"), true),
            (held(ScalarClient.saidThereNotListed),
             Self.round(held: 1, "answered as there already, and not in the list"), true),
            (held(ScalarClient.needsAProgramme), Self.round(held: 1, "not one a television is sent"), true),
            (held(ScalarClient.repeatNotTaken), Self.round(held: 1, "not one a television is sent"), true),
            (held(ScalarClient.reservedOnceOnly),
             Self.round(held: 1, "a repeat of a programme the television has reserved once"), true),
            (held(ScalarClient.reservedOnFewerDays),
             Self.round(held: 1, "a repeat of a programme the television has reserved on fewer days"), true),
            (held(ScalarClient.acceptedNotListed), Self.round(held: 1, "answered as taken, and not in the list"),
             false),
            (held("「サンプル劇場」は予約できません。"), Self.round(held: 1, "a reason of another kind"), false),
            (held(nil), Self.round(held: 1, "no reason"), false),
            (outcome { $0.deferred = [row] }, Self.round(passedOver: 1), false),
            (outcome { $0.stopped = .cannotRecord(reason: ScalarClient.diskNotFound) },
             Self.round(stop: "stopped: no disk to record to"), true),
            (outcome { $0.stopped = .silent(afterSending: false) },
             Self.round(stop: "stopped by silence, before a create"), true),
            (outcome { $0.stopped = .silent(afterSending: true) },
             Self.round(stop: "stopped by silence, at a create or after it"), false),
            (outcome { $0.stopped = .needsPairing }, Self.round(stop: "stopped: the registration is wanted again"),
             false),
            (outcome { $0.stopped = .saysNothing }, Self.round(stop: "stopped: answers that say nothing"), false),
            (outcome {
                $0.deferred = [row]
                $0.stopped = .saysNothing
            }, Self.round(passedOver: 1, stop: "stopped: answers that say nothing"), false),
            (outcome {
                $0.deferred = [row]
                $0.stopped = .silent(afterSending: false)
            }, Self.round(passedOver: 1, stop: "stopped by silence, before a create"), false),
        ]
        for (outcome, said, tookNoCreate) in cases {
            XCTAssertEqual(TVSitting.said(ofARound: outcome), said)
            XCTAssertEqual(TVSitting.tookNoCreate(outcome), tookNoCreate, said)
            expectNamesNothing(TVSitting.said(ofARound: outcome))
        }
    }

    // MARK: - the viewing reservation of the sitting

    /// The viewing reservation a check is about is the one the owner names by its start, and no other. With
    /// none named, none listed at that start, or two, the check does not run, and nothing is asked about or
    /// made. It is found within a minute of the start named, a television listing one a second early, and
    /// no further off. It is not the newest in the list: with a newer one of the household's there, for a
    /// programme the picks have, it is still the named one's programme that is reserved.
    func testTheViewingReservationIsTheOneTheOwnerNames() async throws {
        let about: [(String, @Sendable (World) async throws -> Void)] = [Self.making[1], Self.making[4]]
        let twin = Self.owned("reminder.47", on: 0, "サンプル名画座", Self.at(4, 21, 0, 30), 3600, programme: 50106)
        let none = "viewing reservations listed that start within a minute of the start that was named: 0,"
        let worlds: [(String, World, String)] = [
            ("none named", await world(reminder: nil),
             "the sitting was not told which viewing reservation is its own"),
            ("none at the start named", await world(reminder: Self.at(5, 21)), none),
            ("one sixty-one seconds off", await world(reminder: Self.at(4, 21, 1)), none),
            ("two within a minute", await world(owners: Self.owners + [twin]),
             "viewing reservations listed that start within a minute of the start that was named: 2,"),
        ]
        for (name, world, why) in worlds {
            for (check, run) in about {
                await world.line.forget()
                let refused = await thrown { try await run(world) } as? TVSitting.Refused
                XCTAssertEqual(refused?.why.hasPrefix(why), true, "\(name), \(check): \(refused?.why ?? "it ran")")
                expectEqual(await world.line.sent, ["getPowerStatus", "getScheduleList"], "\(name), \(check)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: world.ledger.path), "\(name), \(check)")
                expectNamesNothing(refused?.why ?? "")
            }
        }

        let minute = await world(reminder: Self.at(4, 21, 0, 59))
        try await minute.sitting.aRecordingWhereAViewingReservationIs()
        XCTAssertEqual(try entries(minute), ["1503 50105 1"])

        // The household's own viewing reservation, newer than the sitting's, for a programme that is picked.
        let newer = Self.owned("reminder.47", on: 0, "サンプル名画座", Self.at(5, 19, 59, 59), programme: 50109)
        let beside = await world(owners: Self.owners + [newer])
        try await beside.sitting.aRecordingWhereAViewingReservationIs()
        XCTAssertEqual(try entries(beside), ["1503 50105 1"], "a recording was made of another viewing reservation")
        expectEqual(await beside.television.schedules, Self.owners + [newer])

        // And the household's older one, named by mistake: its programme is none the sitting may reserve.
        let older = await world(reminder: Self.at(6, 13))
        let refused = await thrown { try await older.sitting.aRecordingWhereAViewingReservationIs() }
        XCTAssertEqual((refused as? TVSitting.Refused)?.why, "the viewing reservation's programme is not among the"
                       + " picks")
        expectEqual(await count("addSchedule", in: older), 0)

        for (text, date) in [("2026-11-04 21:00", Self.at(4, 21)), ("2026-11-05 00:05", Self.at(5, 0, 5))] {
            XCTAssertEqual(TVSitting.reminderStart(text), date, text)
        }
        for text in ["", "21:00", "2026-11-04", "2026-11-04 21:00:00", "2026-11-04T21:00", "2026-11-31 21:00",
                     "2026-11-04 9:00", "2026/11/04 21:00", "サンプル音楽館"] {
            XCTAssertNil(TVSitting.reminderStart(text), text)
        }
    }

    /// The slot rule holds where a viewing reservation is and inside the arrangements of three as it does
    /// everywhere else. A viewing reservation less than twenty hours ahead, or with a row of the household's
    /// within three hours of its programme: the check about it does not run. Three programmes whose slot has
    /// such a row near it are not an arrangement: with no other among the picks, the check does not run.
    /// In each case nothing is asked about, nothing is made and nothing is written down.
    func testTheSlotRuleHoldsWhereAViewingReservationIsAndForThreeAtOnce() async throws {
        let reminder: @Sendable (World) async throws -> Void = Self.making[1].1
        let three: @Sendable (World) async throws -> Void = Self.making[4].1
        // Half an hour after midnight: inside three hours of the viewing reservation's programme and of the
        // three that start earlier, and outside those of the three that start later, the evening after.
        let near = Self.owned("recording.47", on: 3, "サンプル名画座", Self.at(5, 0, 30))
        // Ten to midnight the evening after: inside three hours of the three that start later, alone.
        let nearTheLater = Self.owned("recording.47", on: 3, "サンプル名画座", Self.at(5, 23, 50))
        let tooSoon = "the viewing reservation is less than twenty hours ahead, or something else is listed"
        let cases: [(String, World, @Sendable (World) async throws -> Void, String)] = [
            ("a second less than twenty hours ahead", await world(now: Self.at(4, 1, 0, 1)), reminder, tooSoon),
            ("a row within three hours", await world(owners: Self.owners + [near]), reminder, tooSoon),
            ("a row within three hours of the three that start later",
             await world(owners: Self.owners + [nearTheLater]), three,
             "no three programmes among the picks, the third starting later, are in an empty slot"),
            ("a row within three hours of the three that start earlier", await world(owners: Self.owners + [near]),
             three, "no three programmes among the picks, the third starting earlier, are beside"),
            ("the three that start earlier less than twenty hours ahead", await world(now: Self.at(4, 1, 0, 1)),
             three, "no three programmes among the picks, the third starting earlier, are beside"),
        ]
        for (name, world, check, why) in cases {
            let refused = await thrown { try await check(world) } as? TVSitting.Refused
            XCTAssertEqual(refused?.why.hasPrefix(why), true, "\(name): \(refused?.why ?? "it ran")")
            expectEqual(await world.line.sent, Self.opening, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.ledger.path), name)
        }

        // Twenty hours ahead to the second, and the row five minutes further off: both run.
        let justFarEnough = await world(now: Self.at(4, 1))
        try await justFarEnough.sitting.aRecordingWhereAViewingReservationIs()
        let justOutside = Self.owned("recording.47", on: 3, "サンプル名画座", Self.at(5, 1))
        let clear = await world(owners: Self.owners + [justOutside])
        try await clear.sitting.aRecordingWhereAViewingReservationIs()
        XCTAssertEqual(try entries(clear), ["1503 50105 1"])
    }

    // MARK: - the count afterwards

    /// The count afterwards fails on a ledger no check has written in, with nothing sent: a file that is
    /// not there, as when the last command names another, or one with nothing counted before a first create.
    /// It would otherwise say of whatever is on the television that nothing of the sitting is left.
    func testTheCountAfterwardsFailsOnALedgerNoCheckWroteIn() async throws {
        let absent = await world()
        var struck = TVLedger()
        struck.entries = [TVLedger.Entry(broadcastingType: 2, serviceID: 1501, eventID: 50102, start: Self.at(3, 16),
                                         durationSec: 1800, repeatType: "1", struck: true)]
        let uncounted = await world()
        try struck.write(to: uncounted.ledger)

        for (name, world) in [("no file", absent), ("nothing counted", uncounted)] {
            let stopped = await thrown { try await world.sitting.whatIsLeft() } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what.hasPrefix("the ledger holds nothing of a sitting"), true,
                           "\(name): \(stopped?.what ?? "it passed")")
            expectEqual(await world.line.sent, [], name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.ledger.path))
    }

    /// A ledger is one sitting's. It keeps when its first entry was written down, which no later entry
    /// changes, and one begun more than a day ago is another sitting's, named again by mistake: beside it no
    /// check makes anything and the count afterwards counts nothing. Each fails, with nothing sent and the
    /// file left as it was. A day to the second is still the sitting's.
    func testALedgerBegunMoreThanADayAgoIsAnotherSittings() async throws {
        func begun(_ secondsAgo: TimeInterval) -> TVLedger {
            var ledger = TVLedger()
            ledger.entries = [TVLedger.Entry(broadcastingType: 2, serviceID: 1501, eventID: 50102,
                                             start: Self.at(3, 16), durationSec: 1800, repeatType: "1", struck: true)]
            ledger.before = TVLedger.Counts(rows: 11, recordings: 9, overlapped: 0)
            ledger.begun = Self.now.addingTimeInterval(-secondsAgo)
            return ledger
        }
        let anothers = await world()
        try begun(86_401).write(to: anothers.ledger)
        let last: @Sendable (World) async throws -> Void = { try await $0.sitting.whatIsLeft() }
        for (name, check) in Self.making + [("what is left", last)] {
            let stopped = await thrown { try await check(anothers) } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what, "the ledger was begun more than a day ago, and has entries not struck out: 0."
                           + " It is another sitting's: a sitting writes in a file of its own, one that is not"
                           + " there before its first check", "\(name): it ran, or was merely refused")
        }
        expectEqual(await anothers.line.sent, [], "something was sent beside another sitting's ledger")
        XCTAssertEqual(try TVLedger.read(anothers.ledger), begun(86_401))

        let aDayOld = await world()
        try begun(86_400).write(to: aDayOld.ledger)
        try await aDayOld.sitting.aWholeWrite()
        try await aDayOld.sitting.whatIsLeft()
        let kept = try TVLedger.read(aDayOld.ledger)
        XCTAssertEqual(kept.begun, Self.now.addingTimeInterval(-86_400), "a later entry changed when it was begun")
        XCTAssertEqual(kept.entries.count, 2)
    }

    // MARK: - what a check chooses from

    /// A slot is empty when it is twenty hours or more ahead and nothing listed is within three hours either
    /// side of it, to the second. For a repeat nothing may be at that time of day on any day; and a listed
    /// row that repeats, or does not say, is held to be at its time of day on every day.
    func testASlotIsEmptyWithNothingListedWithinThreeHoursOfIt() {
        let start = Self.at(4, 21), end = Self.at(4, 22)
        func row(_ start: Date, _ durationSec: Int = 1800, repeating: String? = "1") -> TVScheduleRow {
            TVScheduleRow(id: "recording.31", type: "recording", uri: Self.stations[0].uri,
                          startDateTime: TVReservationBody.start(start), durationSec: durationSec,
                          repeatType: repeating)
        }
        let cases: [(String, [TVScheduleRow], Bool, Date, Bool)] = [
            ("nothing listed", [], false, Self.now, true),
            ("twenty hours ahead to the second", [], false, Self.at(4, 1), true),
            ("a second less than twenty hours ahead", [], false, Self.at(4, 1, 0, 1), false),
            ("a row that ends three hours before", [row(Self.at(4, 17, 30))], false, Self.now, true),
            ("a row that ends a second after that", [row(Self.at(4, 17, 30), 1801)], false, Self.now, false),
            ("a row that starts three hours after", [row(Self.at(5, 1))], false, Self.now, true),
            ("a row that starts a second before that", [row(Self.at(5, 0, 59, 59))], false, Self.now, false),
            ("a row inside it", [row(Self.at(4, 21, 15))], false, Self.now, false),
            ("a row at that time of day on another day", [row(Self.at(6, 21))], false, Self.now, true),
            ("the same, for a repeat", [row(Self.at(6, 21))], true, Self.now, false),
            ("a row the day before that runs into that time of day, for a repeat",
             [row(Self.at(3, 17), 3601)], true, Self.now, false),
            ("a row that stops short of it, for a repeat", [row(Self.at(3, 17), 3600)], true, Self.now, true),
            ("a row at another time of day, for a repeat", [row(Self.at(6, 10))], true, Self.now, true),
            ("a listed repeat at that time of day on another day", [row(Self.at(6, 21), repeating: "w5")],
             false, Self.now, false),
            ("a listed row that says no repeat, the same", [row(Self.at(6, 21), repeating: nil)],
             false, Self.now, false),
            ("a listed repeat at another time of day", [row(Self.at(6, 10), repeating: "d")], false, Self.now, true),
        ]
        for (name, listed, everyDay, now, expected) in cases {
            XCTAssertEqual(TVSitting.isFree(from: start, to: end, in: listed, everyDay: everyDay, now: now), expected,
                           name)
        }
    }

    /// The picks are what a reservation is made of and nothing that says what a programme is: of the guide's
    /// terrestrial programmes and those of the stations named, the ones still to start, with a length, that
    /// are no subchannel's reference. The file holds five numbers to a programme, and no title or name.
    func testThePicksCarryNoTitleAndNoStationsName() throws {
        func programme(_ service: Int, _ event: Int, _ start: Date, _ durationSec: Int = 1800,
                       reference: Int? = nil) -> GuideProgram {
            GuideProgram(serviceID: service, eventID: event, start: start,
                         end: start.addingTimeInterval(TimeInterval(durationSec)), title: "サンプル劇場",
                         referenceServiceID: reference, referenceEventID: reference)
        }
        let guide = [
            "td": [GuideService(serviceID: 1501, name: "サンプル第一", programs: [
                programme(1501, 50100, Self.at(2, 18, 59)), programme(1501, 50101, Self.at(3, 15)),
                programme(1501, 50102, Self.at(3, 16), reference: 1502),
                programme(1501, 50103, Self.at(3, 17), 4 * 3600 + 1), programme(1501, 50104, Self.at(3, 22), 0),
            ])],
            "cs": [GuideService(serviceID: 1601, name: "サンプルCS", programs: [programme(1601, 50112, Self.at(3, 10))]),
                   GuideService(serviceID: 1602, name: "サンプルCS2", programs: [programme(1602, 50113, Self.at(3, 10))])],
        ]
        let named = try XCTUnwrap(TVPicks.Channel("cs:1601"))

        let picks = TVPicks(guide: guide, named: [named], after: Self.now)

        XCTAssertEqual(picks, TVPicks(programmes: [Self.pick(1601, 50112, Self.at(3, 10), type: 4),
                                                  Self.pick(1501, 50101, Self.at(3, 15))], named: [named]))
        XCTAssertEqual(named, TVPicks.Channel(broadcastingType: 4, serviceID: 1601))
        for text in ["cs", "cs:", ":1601", "radio:1601", "cs:1601:2", "cs:サンプル"] {
            XCTAssertNil(TVPicks.Channel(text), text)
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderKitTests-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try picks.write(to: file)
        XCTAssertEqual(try TVPicks.read(file), picks)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for programme in try XCTUnwrap(written["programmes"] as? [[String: Any]]) {
            XCTAssertEqual(Set(programme.keys), ["broadcastingType", "serviceID", "eventID", "start", "durationSec"])
        }
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("サンプル"))
    }
    /// The picks are read from a recorder, and what goes wrong on the way is said by its kind and nothing
    /// else: no answer, something that is no recorder, an address nothing can be sent to, an answer that
    /// could not be read. An error as it comes has the recorder's address in it, and a test prints what it
    /// throws.
    func testWhatGoesWrongWithTheRecorderIsSaidByItsKind() async throws {
        let description = try Vectors.descriptionXML()
        let silent = StubTransport { request, _ in
            throw RecorderError.transport("Could not connect to \(request.url.absoluteString)")
        }
        let guideless = StubTransport { request, _ in
            request.url.path == "/description.xml"
                ? HTTPResponse(statusCode: 200, body: Data(description.utf8)) : HTTPResponse(statusCode: 500)
        }
        let other = StubTransport(always: HTTPResponse(statusCode: 200, body: Data("<html/>".utf8)))
        let cases: [(String, String, StubTransport)] = [
            ("no answer", Stub.host, silent), ("not a recorder", Stub.host, other),
            ("an answer that could not be read", Stub.host, guideless),
            ("an address nothing can be sent to", "192.0.2.10/guide", silent),
        ]
        for (kind, host, transport) in cases {
            let recorder = RecorderClient(host: host, transport: transport, busyRetryDelay: 0...0)
            let ended = await thrown { _ = try await TVPicks.picked(from: recorder, after: Self.now) }
            XCTAssertEqual((ended as? TVSitting.Stopped)?.what, "the recorder's guide was not read: \(kind)")
            expectNamesNothing((ended as? TVSitting.Stopped)?.what ?? "")
        }
        expectEqual(await guideless.requests.first?.url.path, "/description.xml")
    }

    // MARK: - what a sitting is given

    /// The name of the test that called, read as the live tests' wrapper reads it: by a default argument,
    /// with the check in a closure behind it.
    private func caller(_ test: String = #function, _ check: () async throws -> Void) async rethrows -> String {
        try await check()
        return test
    }

    /// Leave to write is the name of the very test that runs, as `#function` gives it to what the test
    /// calls, and nothing else is: not a yes, not another test's name, not this one's with anything around
    /// it.
    func testLeaveToWriteIsTheNameOfTheTestThatRuns() async {
        let test = await caller {}
        XCTAssertEqual(test, "testLeaveToWriteIsTheNameOfTheTestThatRuns()")
        XCTAssertTrue(TVSitting.mayWrite("testLeaveToWriteIsTheNameOfTheTestThatRuns", running: test))
        let others: [String?] = [
            nil, "", "1", "true", "yes", "testThreeAtOnce", "testLeaveToWrite",
            "testLeaveToWriteIsTheNameOfTheTestThatRuns()", "LiveTVTests/testLeaveToWriteIsTheNameOfTheTestThatRuns",
        ]
        for leave in others {
            XCTAssertFalse(TVSitting.mayWrite(leave, running: test), leave ?? "none")
        }
    }

    /// A file of the sitting is kept at an absolute path where git would not pick it up: outside the working
    /// tree, or under its `notes/`. A relative path, the package's directory, the tree's own, any directory
    /// of it that is tracked, and a path that only starts under `notes/` are all refused.
    func testAFileOfTheSittingIsKeptWhereGitDoesNotTrackIt() {
        let tree = URL(fileURLWithPath: "/Users/sample/bdzbridge")
        let cases: [(String, Bool)] = [
            ("ledger.json", false), ("notes/ledger.json", false), ("./ledger.json", false), ("~/ledger.json", false),
            ("/Users/sample/bdzbridge/ledger.json", false), ("/Users/sample/bdzbridge/docs/ledger.json", false),
            ("/Users/sample/bdzbridge/app/RecorderKit/ledger.json", false),
            ("/Users/sample/bdzbridge/app/notes/ledger.json", false), ("/Users/sample/bdzbridge/notes", false),
            ("/Users/sample/bdzbridge/notes/../app/ledger.json", false),
            ("/Users/sample/bdzbridge/notes/ledger.json", true),
            ("/Users/sample/bdzbridge/notes/sitting/ledger.json", true),
            ("/Users/sample/bdzbridge/app/../notes/ledger.json", true),
            ("/Users/sample/bdzbridge-notes/ledger.json", true), ("/Users/sample/ledger.json", true),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(TVSitting.mayKeep(at: path, tree: tree), expected, path)
        }
        // What a sitting says is kept beside its ledger, so where the one may be kept the other may.
        let said = TVSitting.saidFile(beside: URL(fileURLWithPath: "/Users/sample/bdzbridge/notes/ledger.json"))
        XCTAssertEqual(said.path, "/Users/sample/bdzbridge/notes/ledger.json.said")
        XCTAssertTrue(TVSitting.mayKeep(at: said.path, tree: tree))

        // And in the tree this test was built in: beside this file and at the tree's top it may not be
        // kept, under its notes and in the system's temporary directory it may.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        XCTAssertFalse(TVSitting.mayKeep(at: here.appendingPathComponent("ledger.json").path))
        XCTAssertFalse(TVSitting.mayKeep(at: TVSitting.tree.appendingPathComponent("ledger.json").path))
        XCTAssertTrue(TVSitting.mayKeep(at: TVSitting.tree.appendingPathComponent("notes/ledger.json").path))
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("ledger.json")
        XCTAssertTrue(TVSitting.mayKeep(at: elsewhere.path))
    }

    /// What a sitting at a real television says is kept as well as said, in a file beside the ledger: each
    /// line is at the end of it by the time the line has been said, so that a check can be followed while it
    /// runs by whatever sees a command's output only when the command has ended. A later command's lines
    /// follow those of the one before it, in the order they were said.
    func testWhatACheckSaysIsKeptBesideTheLedgerLineByLine() async throws {
        let world = await world()
        let file = TVSitting.saidFile(beside: world.ledger)
        XCTAssertEqual(file.path, world.ledger.path + ".said")
        let said = world.said, kept = Said(), now = Self.now
        // A sitting as a command begins one: with a printer of its own, here reading the file back as well.
        func command() -> TVSitting {
            let printer = TVSitting.printer(beside: world.ledger)
            return TVSitting(client: world.client, line: world.kept, picks: Self.picks, ledger: world.ledger,
                             mayWrite: true, now: { now }) { line in
                said.add(line)
                printer(line)
                kept.add((try? String(contentsOf: file, encoding: .utf8)) ?? "no file")
            }
        }

        try await command().theSameProgrammeTwice()
        try await command().whatIsLeft()

        let lines = said.lines
        XCTAssertEqual(lines.first, "the first: rows the question names: 0")
        XCTAssertEqual(lines.last, "nothing of the sitting is left")
        XCTAssertEqual(kept.lines, lines.indices.map { lines[...$0].map { $0 + "\n" }.joined() })
    }

    /// What answers at an address is said by its kind, and a television's model is no part of it.
    func testWhatAnswersAtAnAddressIsSaidByItsKind() {
        let cases: [(TVPresence, String)] = [
            (.nothing, "nothing"), (.notATelevision, "something that is not a television"),
            (.standby(model: DemoTV.model), "a television, in standby"), (.on(model: DemoTV.model), "a television, on"),
        ]
        for (presence, kind) in cases {
            XCTAssertEqual(TVSitting.said(ofWhatAnswers: presence), kind)
        }
    }

    /// A reservation with a repeat is left on the television to be looked at for the seconds asked for, and
    /// never for more than two minutes or less than none, whatever number is given: a check that waits is a
    /// check that can be cut off with its reservation still there.
    func testAReservationIsLeftToBeLookedAtForTwoMinutesAtMost() {
        let cases: [(TimeInterval, TimeInterval)] = [
            (-5, 0), (0, 0), (30, 30), (120, 120), (120.5, 120), (100_000_000_000, 120), (.infinity, 120),
            (-.infinity, 0), (.nan, 0),
        ]
        let line = TVLine(DemoTV())
        let client = ScalarClient(host: Stub.host, transport: line, credentials: MemoryTVCredentials())
        for (asked, expected) in cases {
            XCTAssertEqual(TVSitting.looking(asked), expected, "\(asked)")
            let sitting = TVSitting(client: client, line: line, picks: TVPicks(),
                                    ledger: URL(fileURLWithPath: "/dev/null"), mayWrite: false, look: asked) { _ in }
            XCTAssertEqual(sitting.look, expected, "\(asked)")
        }
    }

    // MARK: - what is said of a row that was made

    /// A row that was made is held against what was sent by the names of its fields, and its title by a yes
    /// or a no: whether it reads as the one sent with its spaces widened. A title as it was sent, another
    /// title altogether -- a television listing the reservation under its programme's own -- and none at
    /// all are a no. Nothing of a title is said either way.
    func testTheRowReadBackIsHeldAgainstWhatWasSent() throws {
        let station = TVStation(broadcastingType: 2, serviceID: 1501, uri: Self.stations[0].uri)
        let request = ReservationRequest(title: TVSitting.title, start: Self.at(4, 21), durationSec: 1800,
                                         repeatCode: "1", broadcastingType: 2, serviceID: 1501, qualityCode: 100,
                                         eventID: 50106)
        let body = try XCTUnwrap(TVReservationBody(request, on: station))
        let widened = "BD\u{3000}Bridge\u{3000}確認"
        func row(_ title: String?, quality: String? = "DR", start: Date = Self.at(4, 21)) -> TVScheduleRow {
            TVScheduleRow(id: "recording.46", type: "recording", uri: station.uri,
                          startDateTime: TVReservationBody.start(start), durationSec: 1800, title: title,
                          repeatType: "1", quality: quality, eventId: "50106")
        }
        let asSent = "every field as sent, in DR; its title is the one sent with its spaces widened: "
        let cases = [
            (row(widened), asSent + "yes"), (row(TVSitting.title), asSent + "no"),
            (row("サンプル名画座"), asSent + "no"), (row(nil), asSent + "no"),
            (row(widened, quality: nil, start: Self.at(4, 21, 0, 1)),
             "not as sent: startDateTime, quality; its title is the one sent with its spaces widened: yes"),
        ]
        for (row, expected) in cases {
            XCTAssertEqual(TVSitting.held(row, against: body), expected, row.title ?? "no title")
            expectNamesNothing(TVSitting.held(row, against: body))
        }
    }
}
