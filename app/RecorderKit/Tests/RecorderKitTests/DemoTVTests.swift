import Foundation
import XCTest
@testable import RecorderKit

/// The invented television where it answers as a real one answered the app's own requests, so that a test
/// that stands on it is told nothing kinder: who loses when a third recording comes at one time, a viewing
/// reservation beside them, a station the household is not subscribed to, a weekly repeat of another day,
/// the disk away. And what a test can have it do that a real one cannot be made to: lose the answer to a
/// create, take one and keep nothing, refuse one with a code. How it lists, pages its stations, numbers what
/// it makes and takes a create only as it is written is in `ScalarClientTests`, beside the client's requests.
///
/// Every value is invented. Each rule says in `DemoTV` what was seen of a real one and what is taken.
final class DemoTVTests: XCTestCase {
    private static let kept = TVCredentials(clientID: "BDBridge:test", cookie: "kept")

    /// Nine in the evening in Japan on Sunday 1 November 2026.
    private static let start = Date(timeIntervalSince1970: 1_793_534_400)

    /// Four terrestrial stations, and one on BS and one on CS that the household is not subscribed to.
    private static let stations = (1...4).map { DemoTV.Station(serviceID: 1500 + $0, name: "サンプル放送\($0)") } + [
        DemoTV.Station(scheme: "isdbbs", serviceID: 1701, name: "サンプルBS", subscribed: false),
        DemoTV.Station(scheme: "isdbcs", serviceID: 1801, name: "サンプルCS", subscribed: false),
    ]

    /// An invented television that knows the client and receives `stations`, and the client to it.
    private func television() async -> (DemoTV, ScalarClient) {
        let television = DemoTV()
        await television.knows(Self.kept.clientID, cookie: "kept")
        await television.receives(Self.stations)
        return (television, ScalarClient(host: Stub.host, transport: television,
                                         credentials: MemoryTVCredentials(Self.kept)))
    }

    /// A reservation as the client sends one: `programme` on the station at `station`, an hour from `start`
    /// unless said. The repeat is put on it as it is given, a weekly code of another day as well, which the
    /// client itself would not write.
    private func body(on station: Int, programme: Int, at start: Date = DemoTVTests.start,
                      for durationSec: Int = 3600, repeating: String = "1") throws -> TVReservationBody {
        let chosen = Self.stations[station]
        let type = try XCTUnwrap(TVScheduleRow.schemes[chosen.scheme].flatMap { Codes.broadcasting[$0] })
        let request = ReservationRequest(title: "サンプル劇場", start: start, durationSec: durationSec, repeatCode: "1",
                                         broadcastingType: type, serviceID: chosen.serviceID, qualityCode: 100,
                                         eventID: programme)
        var body = try XCTUnwrap(TVReservationBody(request, on: TVStation(broadcastingType: type,
                                                                          serviceID: chosen.serviceID,
                                                                          uri: chosen.uri)))
        body.repeatType = repeating
        return body
    }

    /// The list as the client reads it: each row's id and what it says of its overlap, in the list's order.
    private func overlaps(_ tv: ScalarClient) async throws -> [String] {
        try await tv.schedules().map { "\($0.id) \($0.overlapStatus ?? "nothing")" }
    }

    /// Takes the row listed under `id` off, as the client reads it now.
    private func delete(_ id: String, with tv: ScalarClient) async throws {
        let row = try await tv.schedules().first { $0.id == id }
        try await tv.deleteSchedule(try XCTUnwrap(row))
    }

    /// What an operation was refused with: the code of the method's own error, 0 for any other failure, and
    /// nil when it went through.
    private func code(of operation: () async throws -> Void) async -> Int? {
        do {
            try await operation()
            return nil
        } catch let ScalarError.rpc(_, _, code, _) {
            return code
        } catch {
            return 0
        }
    }

    /// What the television answers a request written here, which the client could not be made to write.
    private func answer(of television: DemoTV, _ service: String, _ method: String, _ version: String,
                        _ asked: [String: Any], cookie: String = "kept") async throws -> HTTPResponse {
        let body = try JSONSerialization.data(
            withJSONObject: ["method": method, "id": 1, "params": [asked], "version": version] as [String: Any])
        let url = try XCTUnwrap(URL(string: "http://\(Stub.host):80/sony/\(service)"))
        return try await television.send(HTTPRequest(url: url, method: "POST", headers: ["Cookie": "auth=\(cookie)"],
                                                     body: body))
    }

    // MARK: - who loses

    /// Two recordings at one time on two stations are both taken, and the question names nothing for either.
    /// A third on a third station that overlaps them in part is asked about, and the question names the one of
    /// the two that was made first, in the seven fields of a row it names; nothing is changed by asking. The
    /// third is taken all the same, and the list then reads the first `fullyOverlapped` and the other two
    /// `notOverlapped`. So it is with the third starting later than the two and with it starting earlier,
    /// the two arrangements a real one was put in. It is the one made first and not the one that starts
    /// first: where the second starts before the first, the first is still the one. And with the third
    /// deleted the first reads `notOverlapped` again.
    func testAThirdAtOneTimeCostsTheOneMadeFirstItsRecording() async throws {
        let arrangements: [(String, TimeInterval, TimeInterval)] = [
            ("the third later", 0, 900), ("the third earlier", 0, -1800), ("the second before the first", -600, 900),
        ]
        for (name, second, third) in arrangements {
            let (television, tv) = await television()
            for (station, offset) in [0, second].enumerated() {
                let asked = try body(on: station, programme: 50101 + station, at: Self.start + offset)
                expectEqual(try await tv.wouldPushOut(asked), [], name)
                expectEqual(try await tv.addSchedule(asked), 0, name)
            }
            expectEqual(try await overlaps(tv), ["recording.2 notOverlapped", "recording.1 notOverlapped"], name)

            let asked = try body(on: 2, programme: 50103, at: Self.start + third)
            expectEqual(try await tv.wouldPushOut(asked), [
                TVScheduleRow(id: "recording.1", type: "recording", uri: Self.stations[0].uri,
                              startDateTime: "2026-11-01T21:00:00+0900", durationSec: 3600,
                              title: DemoTV.title(ofProgramme: 50101), repeatType: "1"),
            ], name)
            let named = try await answer(of: television, "recording", "getConflictScheduleList", "1.0", asked.asking)
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: named.body) as? [String: Any])["result"]
            XCTAssertEqual(((rows as? [[[String: Any]]])?.first?.first?.keys).map { $0.sorted() },
                           ["durationSec", "id", "repeatType", "startDateTime", "title", "type", "uri"], name)
            expectEqual(try await overlaps(tv), ["recording.2 notOverlapped", "recording.1 notOverlapped"],
                        "\(name): asking changed something")

            expectEqual(try await tv.addSchedule(asked), 0, "\(name): the third was not taken")
            let all = ["recording.3 notOverlapped", "recording.2 notOverlapped", "recording.1 fullyOverlapped"]
            expectEqual(try await overlaps(tv), all, name)
            expectEqual(await television.schedules.map(\.overlapStatus),
                        ["fullyOverlapped", "notOverlapped", "notOverlapped"], name)

            try await delete("recording.3", with: tv)
            expectEqual(try await overlaps(tv), ["recording.2 notOverlapped", "recording.1 notOverlapped"],
                        "\(name): with the third gone")
        }
    }

    /// What counts as a third: only a recording that is under way with two others at one moment. One that
    /// overlaps two that follow each other costs nothing. A recording that has lost already is not counted
    /// among those under way and is not named again: the next one costs the first made of those that still
    /// record. What was put counts as what was made does -- a household's own recordings are what a new one
    /// costs -- by its number; and rows that were put read as they were put, three at one time as well,
    /// until a request makes one beside them.
    func testOnlyWhatIsUnderWayAtOneMomentCountsAndWhatWasPutCountsToo() async throws {
        let (television, tv) = await television()
        try await tv.addSchedule(try body(on: 0, programme: 50101))
        try await tv.addSchedule(try body(on: 1, programme: 50102, at: Self.start + 3600))
        let between = try body(on: 2, programme: 50103, at: Self.start + 1800)
        expectEqual(try await tv.wouldPushOut(between), [], "never under way with both")
        try await tv.addSchedule(between)
        expectEqual(try await overlaps(tv), ["recording.3 notOverlapped", "recording.2 notOverlapped",
                                             "recording.1 notOverlapped"])

        // A fourth, at the time of the first and the third: the first loses. A fifth there then costs the
        // third its recording, and the first, which records nothing any more, is not named again.
        try await tv.addSchedule(try body(on: 3, programme: 50104, at: Self.start + 900, for: 1800))
        expectEqual(try await overlaps(tv), ["recording.4 notOverlapped", "recording.3 notOverlapped",
                                             "recording.2 notOverlapped", "recording.1 fullyOverlapped"])
        let fifth = try body(on: 1, programme: 50105, at: Self.start + 1800, for: 600)
        expectEqual(try await tv.wouldPushOut(fifth).map(\.id), ["recording.3"])

        let own = (0..<3).map { index in
            DemoTV.Schedule(id: "recording.\(21 - index)", serviceID: 1501 + index, station: "サンプル放送\(index + 1)",
                            title: "サンプル紀行", start: Self.start)
        }
        await television.put(own)
        expectEqual(try await tv.schedules(), [own[0].row, own[1].row, own[2].row], "rows put did not read as put")
        var lost = own
        lost[2].overlapStatus = "fullyOverlapped"
        await television.put(lost)
        let beside = try body(on: 3, programme: 50106)
        expectEqual(try await tv.wouldPushOut(beside).map(\.id), ["recording.20"],
                    "the lower number of the two put that still record")
        try await tv.addSchedule(beside)
        expectEqual(try await overlaps(tv), ["recording.22 notOverlapped", "recording.21 notOverlapped",
                                             "recording.20 fullyOverlapped", "recording.19 fullyOverlapped"])
    }

    /// A viewing reservation on a station of its own, beside three recordings that each overlap it in part:
    /// the question never names it, for the first of them or for the third, which costs the first its
    /// recording; and with them in place it reads `partlyOverlapped`, as a real one's did. With the
    /// recordings deleted it reads as it did before. A recording of its own programme, which starts a second
    /// after it, is taken and marks it too; one that covers it whole, and one that does not touch it, leave
    /// it as it reads.
    func testAViewingReservationOverlappedInPartIsMarkedAndNeverNamed() async throws {
        let (television, tv) = await television()
        let reminder = DemoTV.Schedule(id: "reminder.9", type: "reminder", serviceID: 1504, station: "サンプル放送4",
                                       title: "サンプル音楽館", start: Self.start - 1, durationSec: 3600, quality: nil,
                                       eventId: 50109)
        await television.put([reminder])

        let first = try body(on: 0, programme: 50101, for: 3240)
        expectEqual(try await tv.wouldPushOut(first), [])
        try await tv.addSchedule(first)
        expectEqual(try await overlaps(tv), ["recording.10 notOverlapped", "reminder.9 partlyOverlapped"])
        try await tv.addSchedule(try body(on: 1, programme: 50102, for: 3240))
        let third = try body(on: 2, programme: 50103, at: Self.start - 1800)
        expectEqual(try await tv.wouldPushOut(third).map(\.id), ["recording.10"], "the viewing reservation is named")
        try await tv.addSchedule(third)
        expectEqual(try await overlaps(tv), ["recording.12 notOverlapped", "recording.11 notOverlapped",
                                             "recording.10 fullyOverlapped", "reminder.9 partlyOverlapped"])

        for row in try await tv.schedules() where row.type == "recording" { try await tv.deleteSchedule(row) }
        expectEqual(try await tv.schedules(), [reminder.row])
        expectEqual(await television.schedules, [reminder])

        let cases: [(String, Int, TimeInterval, Int, String)] = [
            ("its own programme", 3, 0, 3600, "partlyOverlapped"),
            ("one that covers it whole", 0, -1800, 7200, "notOverlapped"),
            ("one that ends as it starts", 0, -3601, 3600, "notOverlapped"),
        ]
        for (name, station, offset, durationSec, expected) in cases {
            let asked = try body(on: station, programme: 50109, at: Self.start + offset, for: durationSec)
            expectEqual(try await tv.wouldPushOut(asked), [], name)
            try await tv.addSchedule(asked)
            let listed = try await tv.schedules()
            XCTAssertEqual(listed.map(\.type), ["recording", "reminder"], name)
            XCTAssertEqual(listed.last?.overlapStatus, expected, name)
            try await tv.deleteSchedule(try XCTUnwrap(listed.first))
        }
        expectEqual(await television.schedules, [reminder])
    }

    /// What was made by a request goes on being worked out when the rows are put back as they were read, with
    /// one the household set among them: the first of three still reads as losing, and reads `notOverlapped`
    /// again once the third is deleted. A row put back changed is a row that was put, and reads as it is put.
    func testARowPutBackAsItWasReadIsTheRowItWas() async throws {
        let (television, tv) = await television()
        for station in 0..<3 { try await tv.addSchedule(try body(on: station, programme: 50101 + station)) }
        let set = DemoTV.Schedule(id: "recording.4", serviceID: 1504, station: "サンプル放送4", title: "サンプル紀行",
                                  start: Self.start + 86_400)

        await television.put(await television.schedules + [set])
        expectEqual(try await overlaps(tv), ["recording.4 notOverlapped", "recording.3 notOverlapped",
                                             "recording.2 notOverlapped", "recording.1 fullyOverlapped"])
        try await delete("recording.3", with: tv)
        expectEqual(try await overlaps(tv), ["recording.4 notOverlapped", "recording.2 notOverlapped",
                                             "recording.1 notOverlapped"], "what it read as was put on it for good")

        try await tv.addSchedule(try body(on: 2, programme: 50103))
        var changed = await television.schedules
        XCTAssertEqual(changed.map(\.overlapStatus), ["fullyOverlapped", "notOverlapped", "notOverlapped",
                                                      "notOverlapped"])
        changed[0].title = "サンプル討論"
        await television.put(changed)
        try await delete("recording.5", with: tv)
        expectEqual(try await overlaps(tv), ["recording.4 notOverlapped", "recording.2 notOverlapped",
                                             "recording.1 fullyOverlapped"], "a row put back changed")
    }

    // MARK: - what it refuses

    /// A station the household is not subscribed to is listed among the others, and the question about a
    /// reservation on it is answered with nothing; the create is error 7, and nothing is made and no number
    /// used. The same for a weekly repeat that is not the code of the day the programme starts on, on each
    /// day of a week: the day's own code is taken and every other is error 7, the question answered for
    /// both. Once, by its name, daily, Monday to Friday and Monday to Saturday are taken on every day. And a
    /// start before four in the morning is the day's it is on by the calendar.
    func testAStationNotSubscribedAndAnotherDaysWeeklyCodeAreError7() async throws {
        let (television, tv) = await television()
        expectEqual(try await tv.stations(of: 3).map(\.serviceID), [1701])
        expectEqual(try await tv.stations(of: 4).map(\.serviceID), [1801])
        for station in [4, 5] {
            let asked = try body(on: station, programme: 50101)
            expectEqual(try await tv.wouldPushOut(asked), [], "station \(station)")
            expectEqual(await code { try await tv.addSchedule(asked) }, 7, "station \(station)")
        }
        expectEqual(await television.schedules, [])

        // Noon on Monday 2 November 2026, and the six days after it.
        let monday = Self.start + 15 * 3600
        for day in 0..<7 {
            let start = monday + TimeInterval(day * 86_400)
            for code in 1...7 {
                let asked = try body(on: 0, programme: 50200 + day, at: start, repeating: "w\(code)")
                expectEqual(try await tv.wouldPushOut(asked), [], "day \(day + 1), w\(code)")
                expectEqual(await self.code { try await tv.addSchedule(asked) }, code == day + 1 ? nil : 7,
                            "day \(day + 1), w\(code)")
            }
            expectEqual(await television.schedules.map(\.repeatType), ["w\(day + 1)"], "day \(day + 1)")
            for (index, other) in ["1", "title", "d", "w15", "w16"].enumerated() {
                let asked = try body(on: 1, programme: 50300 + index, at: start, repeating: other)
                expectEqual(await code { try await tv.addSchedule(asked) }, nil, "day \(day + 1), \(other)")
            }
            for row in try await tv.schedules() { try await tv.deleteSchedule(row) }
        }
        expectEqual(await television.schedules.map(\.id), [])

        // One in the morning on the Tuesday, which a guide counts to Monday's day.
        let small = monday + 13 * 3600
        expectEqual(await code { try await tv.addSchedule(try body(on: 0, programme: 50400, at: small,
                                                                   repeating: "w1")) }, 7)
        expectEqual(await code { try await tv.addSchedule(try body(on: 0, programme: 50400, at: small,
                                                                   repeating: "w2")) }, nil)
        expectEqual(await television.schedules.map(\.id), ["recording.43"], "a create refused used a number")
    }

    /// With its disk away the television says so as a real one did, in two fields and no sizes, and goes on
    /// answering its list, its stations and the question. A create is answered with the error no real one
    /// gives, and nothing is made: no real one has been sent a create with its disk away. With the disk back
    /// it says its sizes again and takes the create.
    func testWithItsDiskAwayItSaysSoAndTakesNoCreate() async throws {
        let (television, tv) = await television()
        let asked = try body(on: 0, programme: 50101)
        expectEqual(try await tv.storage(), TVStorage(mounted: true, freeMB: 400, totalMB: 1000))

        await television.unmount()
        expectEqual(try await tv.storage(), TVStorage(mounted: false, freeMB: nil, totalMB: nil))
        let said = try await answer(of: television, "system", "getStorageList", "1.1", ["uri": "usb:recStorage"])
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: said.body) as? [String: Any])["result"]
                       as? NSArray, [[["uri": "usb:recStorage", "mounted": "unmounted"]]] as NSArray)
        expectEqual(try await tv.schedules(), [])
        expectEqual(try await tv.stations(of: 2).count, 4)
        expectEqual(try await tv.wouldPushOut(asked), [])
        expectEqual(await code { try await tv.addSchedule(asked) }, DemoTV.inventedError)
        expectEqual(await television.schedules, [], "something was made with the disk away")

        await television.unmount(false)
        expectEqual(try await tv.storage(), TVStorage(mounted: true, freeMB: 400, totalMB: 1000))
        expectEqual(try await tv.addSchedule(asked), 0)
        expectEqual(await television.schedules.map(\.id), ["recording.1"])
    }

    // MARK: - what a test has it do

    /// The next create can be made to come to one of three things, once. Carried out and not answered: the
    /// client meets silence, and the row is there. Answered and not kept: the client is told it was taken,
    /// and nothing is there. Answered with a code: the client is given that error, and nothing is there.
    /// The create after it is answered as ever, and what made nothing used no number. A create that is
    /// refused before it gets that far -- one not written as it should be, one with a cookie the television
    /// does not know, one with the disk away -- does not use the one time up.
    func testTheNextCreateIsLostOrNotKeptOrRefusedOnce() async throws {
        let cases: [(DemoTV.NextCreate, DeviceFailure?, Int?, [String])] = [
            (.carriedOutAndNotAnswered, .silent, nil, ["recording.1", "recording.2"]),
            (.answeredAndNotKept, nil, nil, ["recording.1"]),
            (.answered(code: 41222), .alreadyThere, 41222, ["recording.1"]),
            (.answered(code: 7), nil, 7, ["recording.1"]),
        ]
        for (once, failure, refused, held) in cases {
            let (television, tv) = await television()
            let asked = try body(on: 0, programme: 50101)
            await television.atTheNextCreate(once)

            var unwritten = asked.creating
            unwritten["quality"] = "DR"
            let first = try await answer(of: television, "recording", "addSchedule", "1.1", unwritten)
            XCTAssertTrue(String(decoding: first.body, as: UTF8.self).contains("\(DemoTV.inventedError)"), "\(once)")
            let stale = try await answer(of: television, "recording", "addSchedule", "1.1", asked.creating,
                                         cookie: "stale")
            XCTAssertEqual(stale.statusCode, 403, "\(once)")
            await television.unmount()
            expectEqual(await code { try await tv.addSchedule(asked) }, DemoTV.inventedError, "\(once)")
            await television.unmount(false)
            expectEqual(await television.schedules, [], "\(once)")

            var met: DeviceFailure?
            var code: Int?
            var annotation: Int?
            do {
                annotation = try await tv.addSchedule(asked)
            } catch let error as ScalarError {
                met = error.failure
                if case .rpc(_, _, let answered, _) = error { code = answered }
            }
            if once == .answeredAndNotKept {
                XCTAssertEqual(annotation, 0, "\(once)")
            } else if let failure {
                XCTAssertEqual(met, failure, "\(once)")
            }
            XCTAssertEqual(code, refused, "\(once)")
            expectEqual(await television.schedules.count, once == .carriedOutAndNotAnswered ? 1 : 0, "\(once)")

            expectEqual(try await tv.addSchedule(try body(on: 1, programme: 50102)), 0, "\(once): the one after")
            expectEqual(await television.schedules.map(\.id), held, "\(once)")
            expectEqual(await television.calls.filter { $0 == "addSchedule cookie=yes pin=no" }.count, 5, "\(once)")
        }
    }

    /// The body of each request is kept as it came, beside what `calls` says of it and in step with it:
    /// the client's requests to the byte, one that met silence as well, and nothing for a request with no
    /// body. `calls` reads as it always did.
    func testTheBodyOfEachRequestIsKeptBesideItsCall() async throws {
        let (television, tv) = await television()
        _ = try await tv.powerStatus()
        _ = try await tv.storage()
        try await tv.addSchedule(try body(on: 0, programme: 50101))
        await television.goSilent()
        _ = try? await tv.schedules()
        await television.goSilent(false)
        let url = try XCTUnwrap(URL(string: "http://\(Stub.host):80/sony/system"))
        _ = try await television.send(HTTPRequest(url: url, method: "POST", headers: [:], body: nil))

        expectEqual(await television.calls, [
            "getPowerStatus cookie=no pin=no", "getStorageList cookie=yes pin=no", "addSchedule cookie=yes pin=no",
            "getScheduleList cookie=yes pin=no", " cookie=no pin=no",
        ])
        expectEqual(await television.bodies, [
            #"{"id":1,"method":"getPowerStatus","params":[],"version":"1.0"}"#,
            #"{"id":2,"method":"getStorageList","params":[{"uri":"usb:recStorage"}],"version":"1.1"}"#,
            #"{"id":3,"method":"addSchedule","params":[{"durationSec":3600,"eventId":"50101","repeatType":"1","#
                + #""startDateTime":"2026-11-01T21:00:00+0900","title":"サンプル劇場","type":"recording","#
                + #""uri":"tv:isdbt?trip=65534.65533.1501&srvName=サンプル放送1"}],"version":"1.1"}"#,
            #"{"id":4,"method":"getScheduleList","params":[{"cnt":130,"stIdx":0}],"version":"1.1"}"#,
            "",
        ])
    }

    /// Its power is changed as with its remote, after it is made: what it says of itself follows, and so
    /// does whether it shows its PIN to a client it does not list.
    func testItsPowerIsChangedAfterItIsMade() async {
        let television = DemoTV()
        let tv = ScalarClient(host: Stub.host, transport: television, credentials: MemoryTVCredentials())
        expectEqual(await tv.presence(), .standby(model: DemoTV.model))
        expectEqual(await tv.enrol(clientID: "BDBridge:test", nickname: "BD Bridge", pin: nil),
                    .failed(ScalarClient.screenIsOff))

        await television.turn("active")
        expectEqual(await television.power, "active")
        expectEqual(await tv.presence(), .on(model: DemoTV.model))
        expectEqual(await tv.enrol(clientID: "BDBridge:test", nickname: "BD Bridge", pin: nil), .pinNeeded)

        await television.turn("standby")
        expectEqual(await tv.presence(), .standby(model: DemoTV.model))
    }
}
