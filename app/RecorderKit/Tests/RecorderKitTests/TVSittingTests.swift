import Foundation
import XCTest
@testable import RecorderKit

/// The sitting's checks rehearsed on the invented television: every one of them, in the order they are run on
/// a real one and by the same code (`TVSitting`), with what each leaves behind looked at from outside it --
/// the rows the household had, as they were and no others; a ledger with nothing left open; each request sent
/// once; and nothing said that names a programme, a station or a row. Then what a check does when something
/// goes wrong on the way, which no sitting can be made to show.
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
        pick(1501, 50103, at(4, 1)),              // free on every day, and before four in the morning
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
        private var lines: [String] = []

        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var text: String { lock.withLock { lines.joined(separator: "\n") } }
    }

    /// The line to the invented television, which a test can have fail at one request: the nth of a method,
    /// counted from nought, is carried out and its answer lost, never arrives, is answered with something
    /// else and not carried out, or arrives just after the household has set something with the remote. It
    /// keeps the method of everything sent, which is what says a request went once, and what the ledger
    /// held as each create arrived.
    private actor Line: HTTPTransport {
        enum Fault: Sendable {
            case answerLost, neverArrives, answered(String), afterTheHouseholdSets(DemoTV.Schedule)
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
        var sitting: TVSitting
        var stranger: ScalarClient
        var said: Said
        var ledger: URL
    }

    /// The invented television, on and holding the household's rows, and a sitting at it with a ledger of
    /// its own that goes when the test ends.
    private func world(mayWrite: Bool = true, power: String = "active",
                       faults: [String: Line.Fault] = [:]) async -> World {
        let television = DemoTV(power: power)
        await television.knows(Self.clientID, cookie: Self.cookie)
        await television.receives(Self.stations)
        await television.put(Self.owners)
        let said = Said()
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderKitTests-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: ledger) }
        let line = Line(television, faults: faults, ledger: ledger)
        func client(_ cookie: String) -> ScalarClient {
            ScalarClient(host: Stub.host, transport: line,
                         credentials: MemoryTVCredentials(TVCredentials(clientID: Self.clientID, cookie: cookie)))
        }
        let sitting = TVSitting(client: client(Self.cookie), picks: Self.picks, ledger: ledger, mayWrite: mayWrite,
                                now: { Self.now }, say: { said.add($0) })
        return World(television: television, line: line, sitting: sitting, stranger: client(Self.neverGiven),
                     said: said, ledger: ledger)
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
        kept += Self.picks.programmes.flatMap { [String($0.serviceID), String($0.eventID)] }
        for word in Set(kept) where text.contains(word) {
            XCTFail("\(word) was said", file: file, line: line)
        }
        XCTAssertNil(text.range(of: "(recording|reminder)\\.[0-9]", options: .regularExpression),
                     "an id of the television's was said", file: file, line: line)
    }

    private func entries(_ world: World) throws -> [String] {
        try TVLedger.read(world.ledger).entries.map { "\($0.serviceID) \($0.eventID) \($0.repeatType)" }
    }

    // MARK: - the rehearsal

    /// Every check, in the sitting's order. After each: the television holds the household's rows, as they
    /// were, and nothing else; the ledger has nothing left open; and what went to the television is the
    /// check's requests, each once. At the end the ledger holds what was sent, in order, each entry written
    /// before its create went out, and nothing that was said names anything.
    func testEveryCheckLeavesTheInventedTelevisionAsItFoundIt() async throws {
        let world = await world()
        let opening = ["getPowerStatus", "getScheduleList", "getContentList"]
        let made = ["addSchedule", "getScheduleList"], takenOff = ["deleteSchedule", "getScheduleList"]
        let three = made + made + ["getConflictScheduleList"] + made
            + ["deleteSchedule", "deleteSchedule", "deleteSchedule", "getScheduleList"]
        let sent: [String: [String]] = [
            "a whole write": ["getPowerStatus", "getStorageList", "getScheduleList", "getContentList",
                              "getConflictScheduleList"] + made + takenOff,
            "a recording where a viewing reservation is": opening + ["getConflictScheduleList"] + made + takenOff,
            "the same programme twice": opening + made + made + takenOff,
            "the repeats": opening + Array(repeating: made + takenOff, count: 6).flatMap { $0 },
            "three at once": opening + three + three,
            "a cookie not taken": opening + made,
            "the stations named": ["getPowerStatus", "getScheduleList", "getContentList"] + made + takenOff
                + ["getContentList"],
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
        // And each written down before its create was sent: what the ledger held as the create arrived.
        expectEqual(await world.line.ledgerAtEachCreate, (1...18).map { "\($0) entries, the last open" })

        let said = world.said.text
        expectNamesNothing(said)
        for line in [
            "stations of td: 5", "stations of bs: 0", "stations of cs: 1",
            "channels among the picks with no station on the television: 1 of 6",
            "rows in a page past the end of td: 0",
            "rows the question names: 0", "the row read back: every field as sent, in DR",
            "the viewing reservation: Wednesday 20:59:59; its uri is the station's own: yes",
            "rows the question names: 0; the viewing reservation among them: no",
            "rows of the programme before: 1 recording, 1 reminder",
            "rows of the programme after: 1 reminder, 2 recording",
            "the second: error 41222, read as already there: yes; rows made: 0",
            "the programme: Wednesday 05:00:00", "round 2, title sent: taken; rows made: 1",
            "round 6, w4 sent: taken; rows made: 1", "  read back: repeatType w4, start Wednesday 05:00:00",
            "the third later, rows the question for the third names: 0",
            "the third earlier, with them in place: the first notOverlapped, the second notOverlapped,"
                + " the third notOverlapped, the viewing reservation notOverlapped",
            "the create with a cookie the television never gave: HTTP 403; rows made: 0",
            "station 1 of 2 (cs): taken; rows made: 1",
            "station 2 of 2 (bs): not in the television's list, so nothing is sent",
            "the list: rows 11, recordings 9, losing to another 0;"
                + " before the first create: rows 11, recordings 9, losing to another 0",
            "the ledger: entries 18, not struck out 0; recordings listed that one of them may have left: 0",
        ] {
            XCTAssertTrue(said.components(separatedBy: "\n").contains(line), "not said: \(line)")
        }
        let asItWas = "the television's list reads as it did before the check"
        XCTAssertEqual(said.components(separatedBy: asItWas).count - 1, Self.making.count)
    }

    // MARK: - what a check does when it may not, and when something goes wrong

    /// Nothing is made unless the sitting may write, the ledger has nothing left open, and the television
    /// says it is on. With no leave nothing is sent at all and the ledger is not touched; with an entry left
    /// open nothing is sent either; in standby the one request is the one that asks. Nor is a whole write
    /// begun on a television whose disk is not there.
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
                (behind, "entries of the ledger not struck out: 1."),
                (standby, "the television says it is standby"),
            ]
            for (world, why) in refusals {
                let refused = await thrown { try await check(world) } as? TVSitting.Refused
                XCTAssertEqual(refused?.why.hasPrefix(why), true, "\(name): \(refused?.why ?? "it ran")")
                expectEqual(await world.television.schedules, Self.owners, name)
            }
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
    /// next check then makes nothing, and the count afterwards says what is wrong. A row that is new and is
    /// no recording is not the check's to delete. And an entry stays open for a create that was taken and
    /// that the list shows nothing of.
    func testACheckThatFailsOnTheWayTakesOffWhatItMade() async throws {
        let refusal = #"{"error":[\#(DemoTV.inventedError),"refused"],"id":1}"#
        let world = await world(faults: ["addSchedule 1": .answered(refusal)])

        let stopped = await thrown { try await world.sitting.threeAtOnce() } as? TVSitting.Stopped

        XCTAssertEqual(stopped?.what, "the second did not make one row")
        expectEqual(await world.line.sent, ["getPowerStatus", "getScheduleList", "getContentList", "addSchedule",
                                            "getScheduleList", "addSchedule", "getScheduleList", "deleteSchedule",
                                            "getScheduleList"])
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertEqual(try entries(world), ["1501 50109 1", "1502 50110 1"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 0)
        XCTAssertTrue(world.said.text.contains("the third later, the second: error \(DemoTV.inventedError)"))

        let blind = await self.world(faults: ["getScheduleList 1": .neverArrives])
        let unknown = await thrown { try await blind.sitting.aWholeWrite() } as? TVSitting.Stopped
        XCTAssertEqual(unknown?.what, "getScheduleList: no answer after a create (taken): what it made is not known,"
                       + " and its entry is left in the ledger")
        expectEqual(await blind.line.sent.suffix(2), ["addSchedule", "getScheduleList"])
        expectEqual(await blind.television.schedules.count, Self.owners.count + 1)
        XCTAssertEqual(try TVLedger.read(blind.ledger).open, 1)

        await blind.line.forget()
        let refused = await thrown { try await blind.sitting.theSameProgrammeTwice() } as? TVSitting.Refused
        XCTAssertEqual(refused?.why.hasPrefix("entries of the ledger not struck out: 1."), true)
        expectEqual(await blind.line.sent, [])
        let left = await thrown { try await blind.sitting.whatIsLeft() } as? TVSitting.Stopped
        XCTAssertEqual(left?.what, "entries of the ledger not struck out: 1; recordings listed that may be the"
                       + " sitting's: 1; the list does not count as it did")

        // A viewing reservation the household sets while a check is under way is new in the list and is not
        // the check's: only recordings are. The check says that the list has changed, and leaves it.
        let set = Self.owned("reminder.46", on: 3, "サンプル名画座", Self.at(7, 21), 5400, programme: 50121)
        let meanwhile = await self.world(faults: ["addSchedule 0": .afterTheHouseholdSets(set)])
        let changed = await thrown { try await meanwhile.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(changed?.what, "the list does not read as it did before the check: rows then 11, now 12,"
                       + " of those gone or read otherwise 0")
        expectEqual(await meanwhile.television.schedules, Self.owners + [set])
        expectEqual(await meanwhile.line.sent.filter { $0 == "deleteSchedule" }.count, 1)
        XCTAssertEqual(try TVLedger.read(meanwhile.ledger).open, 0)

        let taken = #"{"result":[{"annotation":0}],"id":1}"#
        let unseen = await self.world(faults: ["addSchedule 0": .answered(taken)])
        let nothing = await thrown { try await unseen.sitting.theSameProgrammeTwice() } as? TVSitting.Stopped
        XCTAssertEqual(nothing?.what, "a create was taken and the list shows nothing new: its entry is left in the"
                       + " ledger")
        expectEqual(await unseen.line.sent.filter { $0 == "addSchedule" }.count, 1)
        XCTAssertEqual(try TVLedger.read(unseen.ledger).open, 1)

        for text in [stopped?.what, unknown?.what, refused?.why, left?.what, changed?.what, nothing?.what,
                     world.said.text, blind.said.text, meanwhile.said.text, unseen.said.text] {
            expectNamesNothing(text ?? "")
        }
    }

    /// After silence on a create nothing is sent again: the list is read, once, and a row of the check's
    /// own found there is deleted. Whether the create arrived or not, the check ends, the television is as
    /// it was, and the entry is struck out. In the rounds of the repeats the round after is not begun.
    func testAfterSilenceOnACreateNothingIsSentAgain() async throws {
        let head = ["getPowerStatus", "getStorageList", "getScheduleList", "getContentList", "getConflictScheduleList"]
        let cases: [(Line.Fault, [String], Int)] = [
            (.answerLost, ["addSchedule", "getScheduleList", "deleteSchedule", "getScheduleList"], 1),
            (.neverArrives, ["addSchedule", "getScheduleList"], 0),
        ]
        for (fault, after, rows) in cases {
            let world = await world(faults: ["addSchedule 0": fault])
            let stopped = await thrown { try await world.sitting.aWholeWrite() } as? TVSitting.Stopped
            XCTAssertEqual(stopped?.what, "a create met no answer, and nothing is sent again; rows it made: \(rows)")
            expectEqual(await world.line.sent, head + after, "\(fault)")
            expectEqual(await world.television.schedules, Self.owners, "\(fault)")
            XCTAssertEqual(try entries(world), ["1501 50102 1"])
            XCTAssertEqual(try TVLedger.read(world.ledger).open, 0, "\(fault)")
        }

        let world = await world(faults: ["addSchedule 1": .answerLost])
        let stopped = await thrown { try await world.sitting.theRepeats() } as? TVSitting.Stopped
        XCTAssertEqual(stopped?.what, "a create met no answer, and nothing is sent again; rows it made: 1")
        expectEqual(await world.line.sent.filter { $0 == "addSchedule" }.count, 2)
        expectEqual(await world.line.sent.suffix(3), ["getScheduleList", "deleteSchedule", "getScheduleList"])
        expectEqual(await world.television.schedules, Self.owners)
        XCTAssertEqual(try entries(world), ["1502 50104 w3", "1502 50104 title"])
        XCTAssertEqual(try TVLedger.read(world.ledger).open, 0)
    }

    /// No create is sent that the television says would stop a reservation of the household's. Where the
    /// question before a write names one, nothing is made at all; where the question for the third of three
    /// names anything but the two just made, the third is not made, and the two are taken off. Only the
    /// viewing reservation set for the sitting may be named by the check that is about it.
    func testNoCreateIsSentThatWouldStopAReservationOfTheHouseholds() async throws {
        func naming(_ schedule: DemoTV.Schedule) throws -> Line.Fault {
            let row: [String: Any] = [
                "id": schedule.id, "type": schedule.type, "uri": schedule.uri, "title": schedule.title,
                "startDateTime": schedule.startDateTime, "durationSec": schedule.durationSec,
                "repeatType": schedule.repeatType,
            ]
            let answer = try JSONSerialization.data(withJSONObject: ["result": [[row]], "id": 1])
            return .answered(String(decoding: answer, as: UTF8.self))
        }
        let reminder = try XCTUnwrap(Self.owners.last)

        let write = await world(faults: ["getConflictScheduleList 0": try naming(Self.owners[1])])
        let refused = await thrown { try await write.sitting.aWholeWrite() } as? TVSitting.Refused
        XCTAssertEqual(refused?.why, "the television says the reservation would stop one that is not the check's own")
        expectEqual(await write.line.sent.contains("addSchedule"), false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: write.ledger.path))

        let three = await world(faults: ["getConflictScheduleList 1": try naming(reminder)])
        try await three.sitting.threeAtOnce()
        expectEqual(await three.line.sent.suffix(8), [
            "addSchedule", "getScheduleList", "addSchedule", "getScheduleList", "getConflictScheduleList",
            "deleteSchedule", "deleteSchedule", "getScheduleList",
        ])
        XCTAssertEqual(try entries(three).suffix(2), ["1501 50106 1", "1502 50107 1"])
        XCTAssertTrue(three.said.text.contains("the third earlier, rows the question for the third names: 1"
                                               + " (the viewing reservation)\n"))
        XCTAssertTrue(three.said.text.contains("a row that is not the check's own is named, so the third is not made"))

        let beside = await world(faults: ["getConflictScheduleList 0": try naming(reminder)])
        try await beside.sitting.aRecordingWhereAViewingReservationIs()
        expectEqual(await beside.line.sent.filter { $0 == "addSchedule" }.count, 1)
        XCTAssertTrue(beside.said.text.contains("rows the question names: 1, of type reminder;"
                                                + " the viewing reservation among them: yes\n"))

        for world in [write, three, beside] {
            expectEqual(await world.television.schedules, Self.owners)
            expectNamesNothing(world.said.text + (refused?.why ?? ""))
        }
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
}
