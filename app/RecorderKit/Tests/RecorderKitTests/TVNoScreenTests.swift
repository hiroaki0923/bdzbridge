import Foundation
import XCTest
@testable import RecorderKit

/// What the overnight run and the Shortcuts action do for the television, which have no screen and no link:
/// one attempt at it (`TVDriver.sendWithNoScreen`), asked of the invented television in standby (`DemoTV`)
/// over a line a test can bend at one request (`TVGate`). Every value is invented, and every row starts hours
/// ahead by the real clock, at a whole second as the cache keeps a start.
final class TVNoScreenTests: XCTestCase {
    private static let kept = TVCredentials(clientID: "BDBridge:test", cookie: "kept")

    // What is asked of a television, by its method.
    private static let mac = "getSystemSupportedFunction", disk = "getStorageList", list = "getScheduleList"
    private static let stations = "getContentList", question = "getConflictScheduleList", create = "addSchedule"

    /// An answer that is not what any of the reads gives.
    private static let unreadable = HTTPResponse(statusCode: 200, body: Data(#"{"result":[],"id":1}"#.utf8))

    private struct Home {
        let television: DemoTV
        let gate: TVGate
        let client: ScalarClient
        let store: GuideStore
    }

    /// An invented television in standby that wakes on `mac`, knows the client and receives the one sample
    /// station, behind a gate, and a queue holding `rows`. The client has `credentials` unless said.
    private func home(_ rows: [PendingReservation] = [], mac: String = DemoTV.mac,
                      credentials: TVCredentials? = TVNoScreenTests.kept) async throws -> Home {
        let television = DemoTV(mac: mac)
        await television.knows(Self.kept.clientID, cookie: "kept")
        await television.receives([DemoTV.Station()])
        let gate = TVGate(television)
        let store = try temporaryStore()
        for row in rows { try await store.queue(row) }
        let client = ScalarClient(host: Stub.host, transport: gate, credentials: MemoryTVCredentials(credentials))
        return Home(television: television, gate: gate, client: client, store: store)
    }

    /// One attempt from `home`, as a run with no screen makes it, against the MAC saved as `mac`.
    private func send(_ home: Home, knownAs mac: String? = DemoTV.mac) async -> NoScreenSending {
        await TVDriver.sendWithNoScreen(home.client, store: home.store, knownAs: mac)
    }

    /// A reservation of the programme `programme` on the sample station, waiting for the television unless
    /// said, `hours` from now.
    private func waiting(_ title: String, _ programme: Int, in hours: Double = 2, reason: String? = nil,
                         for target: DeviceSlot = .tv) -> PendingReservation {
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + hours * 3600).rounded(.down))
        let station = DemoTV.Station()
        let request = ReservationRequest(title: title, start: start, durationSec: 1800, repeatCode: "1",
                                         broadcastingType: Codes.broadcasting["td"] ?? 0,
                                         serviceID: station.serviceID, qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: station.name,
                                  queuedAt: Date(timeIntervalSince1970: 1_793_000_000), problem: reason,
                                  target: target)
    }

    /// Each request the television was sent, as it puts them down: the method, and whether a cookie came.
    private func sent(_ methods: [String], cookie: Bool) -> [String] {
        methods.map { "\($0) cookie=\(cookie ? "yes" : "no") pin=no" }
    }

    // MARK: - the attempt

    /// With nothing the television could be sent, nothing is asked of it: no row, only the recorder's, only
    /// one with a reason on it, which waits for the reader, or only one whose programme is over -- which is
    /// not dropped here either: no flush runs. With no registration kept on the phone, none at all or one
    /// with no cookie, the MAC is read with no cookie and nothing else goes: the round stops for want of a
    /// registration before its first request that needs one, and the row waits as it was.
    func testNothingWaitingAsksNothingAndNoRegistrationStopsAfterTheMAC() async throws {
        let cases: [(String, [PendingReservation])] = [
            ("nothing waiting", []),
            ("the recorder's alone", [waiting("サンプル紀行", 50102, for: .recorder)]),
            ("a row with a reason on it", [waiting("サンプル劇場", 50101, reason: "この局は録画できません")]),
            ("a row that is over", [waiting("サンプル天気", 50103, in: -2)]),
        ]
        for (name, rows) in cases {
            let home = try await home(rows)
            expectEqual(await send(home), .nothingWaiting, name)
            expectEqual(await home.gate.asked, [], name)
            expectEqual(try await home.store.pendingReservations(), rows, name)
        }

        let row = waiting("サンプル劇場", 50101)
        let unregistered: [(String, TVCredentials?)] = [
            ("no registration", nil), ("a registration with no cookie", TVCredentials(clientID: "BDBridge:test")),
        ]
        for (name, credentials) in unregistered {
            let home = try await home([row], credentials: credentials)
            expectEqual(await send(home), .sent(PendingQueue.Outcome(slot: .tv, stopped: .needsPairing)), name)
            expectEqual(await home.television.calls, sent([Self.mac], cookie: false), name)
            expectEqual(try await home.store.pendingReservations(), [row], name)
        }
    }

    /// A television in standby is asked, in this order and each once: the MAC with no cookie, then the round
    /// with the cookie -- the disk, the list, the stations, the question, the create and the list again. The
    /// reservation is then on it once and gone from the queue. Nothing renews the registration, reads the
    /// power or the model, sets the power or deletes anything. Two rows of one kind read the stations once.
    func testInStandbyTheMACAndTheRoundGoAndNothingElse() async throws {
        let row = waiting("サンプル劇場", 50101)
        let home = try await home([row])

        let sending = await send(home)

        guard case .sent(let outcome) = sending else { return XCTFail("no round ran: \(sending)") }
        XCTAssertEqual(outcome.sent.map(\.id), [row.id])
        XCTAssertNil(outcome.stopped)
        let calls = await home.television.calls
        XCTAssertEqual(calls, sent([Self.mac], cookie: false)
                       + sent([Self.disk, Self.list, Self.stations, Self.question, Self.create, Self.list],
                              cookie: true))
        let never = ["actRegister", "setPowerStatus", "deleteSchedule", "getPowerStatus", "getInterfaceInformation"]
        XCTAssertEqual(calls.filter { call in never.contains { call.hasPrefix("\($0) ") } }, [])
        expectEqual(await home.television.schedules.map(\.eventId), [50101])
        expectEqual(try await home.store.pendingReservations(), [])

        let two = try await self.home([waiting("サンプル劇場", 50101), waiting("サンプル紀行", 50102, in: 3)])
        guard case .sent(let both) = await send(two) else { return XCTFail("no round ran for two") }
        XCTAssertEqual(both.sent.count, 2)
        expectEqual(await two.gate.asked.filter { $0 == Self.stations }.count, 1, "the stations read for each row")
        expectEqual(await two.television.schedules.map(\.eventId), [50101, 50102])
    }

    /// Another television at the address, with the MAC saved: nothing more is sent, no cookie goes, and the
    /// row waits as it was. The MAC a television gives is read as an attach reads it, and held against the
    /// one saved by the rule a connect holds it by: given in capitals with dashes, against the saved one as
    /// the app writes it; given as the app writes it, against one saved in capitals; and with none saved.
    func testAnotherTelevisionIsSentNoCookieAndTheMACIsHeldAsAConnectHoldsIt() async throws {
        let row = waiting("サンプル劇場", 50101)
        let another = try await home([row])
        await another.television.becomeAnother(mac: "f8:4e:17:00:00:0b")

        expectEqual(await send(another), .anotherAnswered)
        expectEqual(await another.television.calls, sent([Self.mac], cookie: false))
        expectEqual(try await another.store.pendingReservations(), [row])

        let cases: [(String, television: String, saved: String?)] = [
            ("given in capitals with dashes", "F8-4E-17-00-00-0A", DemoTV.mac),
            ("saved in capitals", DemoTV.mac, "F8:4E:17:00:00:0A"),
            ("none saved", DemoTV.mac, nil),
        ]
        for (name, television, saved) in cases {
            let home = try await home([row], mac: television)
            let sending = await send(home, knownAs: saved)
            guard case .sent(let outcome) = sending else {
                XCTFail("\(name): \(sending)")
                continue
            }
            XCTAssertEqual(outcome.sent.map(\.id), [row.id], name)
        }
    }

    /// Silence at the MAC, and an answer to it that does not read, are a television that did not answer:
    /// no round, and the row as it was, with no reason. A create that is carried out and whose answer is lost
    /// stops the round there, with nothing sent after it and nothing written on the row; the next attempt
    /// finds it in the television's list and sends no create.
    func testSilenceLosesNothingAndACreateThatMetItIsFoundNextTime() async throws {
        let row = waiting("サンプル劇場", 50101)
        let silent = try await home([row])
        await silent.television.goSilent()
        expectEqual(await send(silent), .unreachable)
        expectEqual(await silent.gate.asked, [Self.mac])
        expectEqual(try await silent.store.pendingReservations(), [row])

        let unread = try await home([row])
        await unread.gate.answer(Self.mac, with: Self.unreadable)
        expectEqual(await send(unread), .unreachable, "an answer that does not read")
        expectEqual(try await unread.store.pendingReservations(), [row])

        let lost = try await home([row])
        await lost.television.atTheNextCreate(.carriedOutAndNotAnswered)
        let first = await send(lost)
        guard case .sent(let outcome) = first else { return XCTFail("no round ran: \(first)") }
        XCTAssertEqual(outcome.stopped, .silent(afterSending: true))
        expectEqual(await lost.gate.asked.last, Self.create, "something was sent after the create")
        expectEqual(await lost.gate.asked.filter { $0 == Self.create }.count, 1)
        expectEqual(try await lost.store.pendingReservations(), [row])

        let creates = await lost.gate.asked.filter { $0 == Self.create }.count
        let second = await send(lost)
        guard case .sent(let found) = second else { return XCTFail("no round ran the second time: \(second)") }
        XCTAssertEqual(found.alreadyThere.map(\.id), [row.id])
        expectEqual(await lost.gate.asked.filter { $0 == Self.create }.count, creates, "a create was sent again")
        expectEqual(await lost.television.schedules.map(\.eventId), [50101])
        expectEqual(try await lost.store.pendingReservations(), [])
    }

    /// There is nobody to consent with no screen. A row held for what it would stop from recording -- the
    /// very reason the television would give now -- waits for the reader beside a row that goes by itself:
    /// the free one is made, and the held one keeps its reason with no question or create sent for it.
    func testARowHeldForWhatItWouldStopWaitsWithNoScreen() async throws {
        var held = waiting("サンプル映画", 50105)
        let holding = [
            DemoTV.Schedule(id: "recording.21", serviceID: 1032, station: "サンプル放送", title: "サンプル寄席",
                            start: held.request.start),
            DemoTV.Schedule(id: "recording.22", serviceID: 1040, station: "サンプル放送2", title: "サンプル音楽館",
                            start: held.request.start),
        ]
        held.problem = ScalarClient.wouldStop(naming: [holding[0].row])
        let free = waiting("サンプル紀行", 50102, in: 4)
        let home = try await home([held, free])
        await home.television.put(holding)

        let sending = await send(home)

        guard case .sent(let outcome) = sending else { return XCTFail("no round ran: \(sending)") }
        XCTAssertEqual(outcome.sent.map(\.id), [free.id])
        XCTAssertEqual(outcome.held, [held])
        expectEqual(try await home.store.pendingReservations(), [held])
        let asked = await home.gate.asked
        XCTAssertEqual(asked.filter { $0 == Self.question }.count, 1, "the held row was asked about")
        XCTAssertEqual(asked.filter { $0 == Self.create }.count, 1, "the held row was sent")
        expectEqual(await home.television.schedules.map(\.id), ["recording.21", "recording.22", "recording.23"])
    }
}
