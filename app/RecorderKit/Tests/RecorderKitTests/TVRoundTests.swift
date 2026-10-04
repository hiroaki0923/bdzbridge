import Foundation
import XCTest
@testable import RecorderKit

/// The television's way of sending one waiting reservation, as the queue asks it of a device: the round its
/// client opens, and each row sent in it. Asked of the invented television (`DemoTV`), which answers as a real
/// one was seen to, over a line that a test can cut or bend at one request. What was asked of the television,
/// and in what order, is read from that line. Every value is invented.
final class TVRoundTests: XCTestCase {
    private static let kept = TVCredentials(clientID: "BDBridge:test", cookie: "kept")

    /// Nine in the evening in Japan on Sunday 1 November 2026.
    private static let start = Date(timeIntervalSince1970: 1_793_534_400)

    /// Four terrestrial stations, one on BS, and one on CS that the household is not subscribed to.
    private static let stations = (1...4).map { DemoTV.Station(serviceID: 1500 + $0, name: "サンプル放送\($0)") } + [
        DemoTV.Station(scheme: "isdbbs", serviceID: 1701, name: "サンプルBS"),
        DemoTV.Station(scheme: "isdbcs", serviceID: 1801, name: "サンプルCS", subscribed: false),
    ]

    // What is asked of a television, by its method: the disk and the list, which open a round; the stations
    // of a kind of broadcast; and the question before a create, the create, and the list after it.
    private static let disk = "getStorageList", list = "getScheduleList", kind = "getContentList"
    private static let question = "getConflictScheduleList", create = "addSchedule"

    /// An answer that is not what any of the reads gives, and one with an error of the method's own.
    private static let unreadable = HTTPResponse(statusCode: 200, body: Data(#"{"result":[],"id":1}"#.utf8))
    private static func refused(_ code: Int) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"error":[\#(code),"invented"],"id":1}"#.utf8))
    }
    /// What a television answers a request whose cookie it does not take.
    private static let cookieNotTaken = HTTPResponse(statusCode: 403)
    /// A code no television gives: what an answer nothing here knows is made of.
    private static let unknown = DemoTV.inventedError

    private struct Bench {
        let television: DemoTV
        let line: Line
        let tv: ScalarClient
    }

    /// An invented television that knows the client, receives `stations` and holds `schedules`, behind a line
    /// with `faults`, and the client to it.
    private func bench(holding schedules: [DemoTV.Schedule] = [],
                       receiving stations: [DemoTV.Station] = TVRoundTests.stations,
                       faults: [String: Line.Fault] = [:], registered: Bool = true) async -> Bench {
        let television = DemoTV()
        await television.knows(Self.kept.clientID, cookie: "kept")
        await television.receives(stations)
        await television.put(schedules)
        let line = Line(television, faults: faults)
        let credentials = MemoryTVCredentials(registered ? Self.kept : nil)
        return Bench(television: television, line: line,
                     tv: ScalarClient(host: Stub.host, transport: line, credentials: credentials))
    }

    /// A reservation waiting for the television: `programme` on the station at `station`, an hour from the
    /// start unless said. `service` and `type` put it on a channel that is none of the stations'.
    private func row(_ title: String, _ programme: Int?, on station: Int = 0, at offset: TimeInterval = 0,
                     for durationSec: Int = 3600, repeating: String = "1", reason: String? = nil,
                     service: Int? = nil, type: Int? = nil) -> PendingReservation {
        let chosen = Self.stations[station]
        let kind = TVScheduleRow.schemes[chosen.scheme].flatMap { Codes.broadcasting[$0] } ?? 0
        let request = ReservationRequest(title: title, start: Self.start + offset, durationSec: durationSec,
                                         repeatCode: repeating, broadcastingType: type ?? kind,
                                         serviceID: service ?? chosen.serviceID, qualityCode: 100,
                                         eventID: programme)
        return PendingReservation(request: request, serviceName: chosen.name,
                                  queuedAt: Date(timeIntervalSince1970: 1_793_000_000), problem: reason, target: .tv)
    }

    /// Something the household has on its television: a recording, or a reminder when its id says so, on the
    /// station at `station`, an hour from the start unless said, and once unless a repeat is said.
    private func owned(_ id: String, on station: Int, _ title: String, at offset: TimeInterval = 0,
                       for durationSec: Int = 3600, programme: Int? = nil,
                       repeating: String = "1") -> DemoTV.Schedule {
        let chosen = Self.stations[station]
        let reminder = id.hasPrefix("reminder")
        return DemoTV.Schedule(id: id, type: reminder ? "reminder" : "recording", scheme: chosen.scheme,
                               serviceID: chosen.serviceID, station: chosen.name, title: title,
                               start: Self.start + offset, durationSec: durationSec, repeatType: repeating,
                               quality: reminder ? nil : "DR", eventId: programme)
    }

    private struct NotOpened: Error {}

    /// Opens a round for `waiting` on a television that lets one be opened: the round, and the rows found
    /// there already.
    private func open(_ bench: Bench, for waiting: [PendingReservation] = [], file: StaticString = #filePath,
                      line: UInt = #line) async throws -> (round: TVRound, there: Set<String>) {
        guard case .open(let round, let there) = await bench.tv.openRound(for: waiting) else {
            XCTFail("the round did not open", file: file, line: line)
            throw NotOpened()
        }
        return (round, there)
    }

    /// What kept a round from opening, or nil when it opened.
    private func stop(opening bench: Bench, for waiting: [PendingReservation] = []) async -> SendingStop? {
        guard case .stopped(let stop) = await bench.tv.openRound(for: waiting) else { return nil }
        return stop
    }

    /// What one row came to, and what was asked of the television for it, in order.
    private struct Came: Equatable {
        var sent: RowSent
        var asked: [String]

        init(_ sent: RowSent, asked: [String]) {
            self.sent = sent
            self.asked = asked
        }
    }

    /// Sends one row in `round`, which is left as the row left it.
    private func send(_ row: PendingReservation, consented: Bool = false, in round: inout TVRound,
                      on bench: Bench) async -> Came {
        await bench.line.forget()
        let (sent, next) = await bench.tv.send(row, consented: consented, in: round)
        round = next
        return Came(sent, asked: await bench.line.sent)
    }

    /// What the television holds, in the order it was put or made: each row's id and what its list says of
    /// its overlap.
    private func held(_ bench: Bench) async -> [String] {
        await bench.television.schedules.map { "\($0.id) \($0.overlapStatus)" }
    }

    // MARK: - opening a round

    /// A round opens on the disk and then the list, and on nothing else. It hands back the rows the
    /// television holds already -- one with a reason on it as well -- each by its channel and its programme:
    /// under another title and at another start it is still found, and a reminder to watch the programme, the
    /// programme's number on another station, and a recording at the row's own time and under its own title
    /// that is no programme's are not. With the disk away the round does not open, the list is not read, and
    /// the reason is the disk's sentence. Silence, a cookie that is not taken and an answer that cannot be
    /// read each keep it from opening, and nothing is asked after them; with no registration on the phone
    /// nothing is asked at all.
    func testARoundOpensOnTheDiskThenTheListAndFindsWhatIsThereAlready() async throws {
        let household = [
            owned("recording.11", on: 0, "サンプル天気\u{3000}拡大版", at: 900, programme: 50101),
            owned("reminder.12", on: 1, "サンプル劇場", programme: 50102),
            owned("recording.13", on: 3, "サンプル紀行", programme: 50103),
            owned("recording.14", on: 3, "サンプル討論"),
        ]
        let waiting = [
            row("サンプル天気", 50101, on: 0, reason: "この局は録画できません"), row("サンプル劇場", 50102, on: 1),
            row("サンプル紀行", 50103, on: 2), row("サンプル討論", 50104, on: 3),
        ]
        let bench = await bench(holding: household)

        let (round, there) = try await open(bench, for: waiting)

        XCTAssertEqual(there, [waiting[0].id])
        XCTAssertEqual(round.listed.map(\.id), ["recording.14", "recording.13", "recording.11", "reminder.12"])
        expectEqual(await bench.line.sent, [Self.disk, Self.list])

        await bench.television.unmount()
        await bench.line.forget()
        expectEqual(await stop(opening: bench, for: waiting),
                    .cannotRecord(reason: "録画用の USB HDD が見つからないため、テレビへの予約は送っていません"))
        expectEqual(await bench.line.sent, [Self.disk], "something was asked with the disk away")

        let both = [Self.disk, Self.list]
        let stops: [(String, [String: Line.Fault], SendingStop, [String])] = [
            ("silence at the disk", ["\(Self.disk) 0": .neverArrives], .silent(afterSending: false), [Self.disk]),
            ("silence at the list", ["\(Self.list) 0": .neverArrives], .silent(afterSending: false), both),
            ("a cookie not taken at the disk", ["\(Self.disk) 0": .answered(Self.cookieNotTaken)], .needsPairing,
             [Self.disk]),
            ("a cookie not taken at the list", ["\(Self.list) 0": .answered(Self.cookieNotTaken)], .needsPairing,
             both),
            ("a disk that cannot be read", ["\(Self.disk) 0": .answered(Self.unreadable)], .saysNothing,
             [Self.disk]),
            ("a list that cannot be read", ["\(Self.list) 0": .answered(Self.unreadable)], .saysNothing, both),
            ("a list answered with an error", ["\(Self.list) 0": .answered(Self.refused(Self.unknown))],
             .saysNothing, both),
        ]
        for (name, faults, expected, asked) in stops {
            let bench = await self.bench(holding: household, faults: faults)
            expectEqual(await stop(opening: bench, for: waiting), expected, name)
            expectEqual(await bench.line.sent, asked, name)
        }
        let stranger = await self.bench(holding: household, registered: false)
        expectEqual(await stop(opening: stranger, for: waiting), .needsPairing, "no registration")
        expectEqual(await stranger.line.sent, [], "no registration")
    }

    // MARK: - one row

    /// One row is asked about, made, and looked for: the stations of its kind of broadcast, the question of
    /// what it would stop, the create, and the list -- each once, in that order -- and it is made because the
    /// list has it, under whatever title the television gave it. The stations of a kind are read once in a
    /// round: the next row of that kind asks for none, and a row of another kind asks for its own kind's.
    /// A create the television answers as taken and does not list is not made: the row is held, and says so.
    func testARowIsAskedAboutThenMadeThenLookedForInTheList() async throws {
        let bench = await bench()
        var round = try await open(bench).round
        let whole = [Self.kind, Self.question, Self.create, Self.list]

        expectEqual(await send(row("サンプル劇場", 50101, on: 0), in: &round, on: bench),
                    Came(.made(saying: nil), asked: whole))
        expectEqual(await bench.television.schedules, [
            DemoTV.Schedule(id: "recording.1", serviceID: 1501, station: "サンプル放送1",
                            title: DemoTV.title(ofProgramme: 50101), start: Self.start, durationSec: 3600,
                            eventId: 50101),
        ])
        XCTAssertEqual(round.listed.map(\.id), ["recording.1"], "the round does not stand on the list it just read")

        expectEqual(await send(row("サンプル紀行", 50102, on: 1, at: 7200), in: &round, on: bench),
                    Came(.made(saying: nil), asked: [Self.question, Self.create, Self.list]))
        expectEqual(await send(row("サンプル映画", 50103, on: 4, at: 14_400), in: &round, on: bench),
                    Came(.made(saying: nil), asked: whole))
        expectEqual(await sources(asked: bench), ["tv:isdbt", "tv:isdbbs"])

        await bench.television.atTheNextCreate(.answeredAndNotKept)
        expectEqual(await send(row("サンプル討論", 50104, on: 2, at: 21_600), in: &round, on: bench),
                    Came(.refused(reason: "テレビは受け付けたと答えましたが、一覧にありません。"),
                         asked: [Self.question, Self.create, Self.list]))
        expectEqual(await held(bench), ["recording.1 notOverlapped", "recording.2 notOverlapped",
                                        "recording.3 notOverlapped"])
    }

    /// The kinds of broadcast whose stations the television was asked for, in order.
    private func sources(asked bench: Bench) async -> [String] {
        await bench.television.bodies.compactMap { body in
            let sent = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard sent?["method"] as? String == Self.kind else { return nil }
            return (sent?["params"] as? [[String: Any]])?.first?["source"] as? String
        }
    }

    /// What a television is not sent is held with its reason before anything is asked: a reservation with
    /// no programme id, and a repeat that is not sent for its programme -- Monday's weekly code and Monday to
    /// Friday, on a Sunday's programme. Not even the stations are read for them.
    func testWhatATelevisionIsNotSentIsHeldAndNothingIsAsked() async throws {
        let bench = await bench()
        var round = try await open(bench).round
        let notSent: [(PendingReservation, String)] = [
            (row("サンプル体操", nil), "番組を指定しない、時刻だけの予約は、テレビにはまだ送れません。"),
            (row("サンプル将棋", 50101, repeating: "w1"), "この番組には、選んだ毎回録画の設定でテレビに予約できません。"),
            (row("サンプル料理", 50102, repeating: "w15"), "この番組には、選んだ毎回録画の設定でテレビに予約できません。"),
        ]
        for (waiting, reason) in notSent {
            expectEqual(await send(waiting, in: &round, on: bench), Came(.refused(reason: reason), asked: []),
                        waiting.request.title)
        }
        expectEqual(await send(row("サンプル寄席", 50103, repeating: "w7"), in: &round, on: bench).sent,
                    .made(saying: nil), "the programme's own weekday")
        expectEqual(await bench.television.schedules.map(\.repeatType), ["w7"])
    }

    /// The create's answer alone settles nothing: the list does. Answered as held already (41222), the row is
    /// found there when the list has a recording of its programme, and held when it has none -- or has only
    /// a reminder to watch it. Either way the list is read, and nothing is sent a second time.
    func testACreateAnsweredAsHeldAlreadyIsSettledByTheList() async throws {
        let asked = [Self.kind, Self.question, Self.create, Self.list]
        let notListed = "テレビはこの番組を予約済みと答えましたが、録画予約の一覧に見つかりませんでした。"
        let waiting = row("サンプル劇場", 50101, on: 0)

        // The household set the same programme with the remote after the round was opened.
        let listed = await bench()
        var round = try await open(listed).round
        await listed.television.put([owned("recording.5", on: 0, "サンプル劇場\u{3000}再", programme: 50101)])
        expectEqual(await send(waiting, in: &round, on: listed), Came(.alreadyThere, asked: asked))
        expectEqual(await held(listed), ["recording.5 notOverlapped"])

        let reminder = owned("reminder.6", on: 0, "サンプル劇場", at: -1, programme: 50101)
        for (name, household) in [("nothing listed", []), ("a reminder listed", [reminder])] {
            let bench = await bench(holding: household)
            var round = try await open(bench).round
            await bench.television.atTheNextCreate(.answered(code: 41222))
            expectEqual(await send(waiting, in: &round, on: bench), Came(.refused(reason: notListed), asked: asked),
                        name)
            expectEqual(await bench.television.schedules, household, name)
        }
    }

    /// A reservation that asks for a repeat is not on the television already because its programme is
    /// reserved there once: taken for there, it would leave the queue with every later programme unreserved
    /// and nothing said. At the opening it is not handed back, where every other pairing is: once asked and
    /// once held; once asked and a repeat held, which loses nothing; a repeat asked and a repeat held, the
    /// same one or another. Sent, it is held with a reason of its own before anything is asked, so that the
    /// queue's flush sends nothing beyond the two requests of the opening, and the row stays in the queue
    /// with the reason on it. And where the recording of the programme once is on the television only after
    /// the opening, the create is answered as held already, the list has the recording, and the row is held
    /// with the same reason: not taken for there already.
    func testARepeatIsNotThereAlreadyBecauseItsProgrammeIsReservedOnce() async throws {
        let reason = "テレビにはこの番組の 1 回だけの予約がすでにあります。"
            + "毎回録画にするには、テレビの予約を削除してから「もう一度送る」を選んでください。"
        let pairs: [(name: String, asked: String, held: String, there: Bool)] = [
            ("once asked, once held", "1", "1", true),
            ("once asked, a repeat held", "1", "w7", true),
            ("a repeat asked, the same repeat held", "w7", "w7", true),
            ("a repeat asked, another repeat held", "S001", "d", true),
            ("a repeat asked, once held", "w7", "1", false),
        ]
        // Each pair a week after the one before, on a Sunday at nine as the first is, which Sunday's weekly
        // code suits.
        let waiting = pairs.enumerated().map { index, pair in
            row("サンプル番組\(index)", 50101 + index, on: index % 4, at: TimeInterval(index) * 604_800,
                repeating: pair.asked)
        }
        let household = pairs.enumerated().map { index, pair in
            owned("recording.\(11 + index)", on: index % 4, "サンプル番組\u{3000}\(index)再",
                  at: TimeInterval(index) * 604_800, programme: 50101 + index, repeating: pair.held)
        }

        let bench = await bench(holding: household)
        let opened = try await open(bench, for: waiting)
        for (index, pair) in pairs.enumerated() {
            XCTAssertEqual(opened.there.contains(waiting[index].id), pair.there, pair.name)
        }
        var round = opened.round
        expectEqual(await send(waiting[4], in: &round, on: bench), Came(.refused(reason: reason), asked: []))

        let queued = await self.bench(holding: household)
        let store = try temporaryStore()
        for row in waiting { try await store.queue(row) }
        let outcome = await PendingQueue.flush(client: queued.tv, store: store, now: Self.start - 86_400)
        XCTAssertEqual(outcome.alreadyThere.map(\.id), waiting.prefix(4).map(\.id))
        XCTAssertEqual(outcome.refused.map(\.id), [waiting[4].id])
        expectEqual(await queued.line.sent, [Self.disk, Self.list])
        expectEqual(try await store.pendingReservations().map(\.problem), [reason])
        expectEqual(await queued.television.schedules, household)

        // The household set the programme once with the remote after the round was opened.
        let later = await self.bench()
        round = try await open(later, for: waiting).round
        await later.television.put([household[4]])
        expectEqual(await send(waiting[4], in: &round, on: later),
                    Came(.refused(reason: reason), asked: [Self.kind, Self.question, Self.create, Self.list]))
        expectEqual(await later.television.schedules, [household[4]])
    }

    // MARK: - the stations

    /// A row whose station is not in a list that was read is held, and nothing is asked about it: the list is
    /// read once, and the next row of that kind is sent on it. So is a row of a kind of broadcast the
    /// television is not asked for at all. A list answered on its first page with an error of the method's
    /// own that says no state of the television is a kind the television lists nothing of: its rows are held
    /// the same, and it is not asked for again.
    func testARowWhoseStationIsNotInTheListIsHeld() async throws {
        let reason = "テレビのチャンネル一覧にこの局が見つかりませんでした。"
        let bench = await bench()
        var round = try await open(bench).round

        expectEqual(await send(row("サンプル体操", 50101, service: 1599), in: &round, on: bench),
                    Came(.refused(reason: reason), asked: [Self.kind]))
        expectEqual(await send(row("サンプル劇場", 50102, on: 0), in: &round, on: bench),
                    Came(.made(saying: nil), asked: [Self.question, Self.create, Self.list]))
        expectEqual(await send(row("サンプル将棋", 50103, type: 5), in: &round, on: bench),
                    Came(.refused(reason: reason), asked: []), "a kind the television has no name for")

        let none = await self.bench(faults: ["\(Self.kind) 0": .answered(Self.refused(3))])
        round = try await open(none).round
        expectEqual(await send(row("サンプル映画", 50104, on: 4), in: &round, on: none),
                    Came(.refused(reason: reason), asked: [Self.kind]), "a kind the television lists nothing of")
        expectEqual(await send(row("サンプル寄席", 50105, on: 4, at: 7200), in: &round, on: none),
                    Came(.refused(reason: reason), asked: []), "a kind the television lists nothing of, again")
        expectEqual(await none.television.schedules, [])
    }

    /// A row of a kind whose list could not be read is passed over, not held: nothing says its station is
    /// missing. The kind is not asked for again in the round, and its rows do not count toward stopping it:
    /// two of them running, and the round goes on to a row of another kind. So it is for an answer that
    /// cannot be read, and for a failure on a page after the first -- an error there is no end of a list, and
    /// a station on that page is not taken for one the television lacks. And so it is for a first page
    /// answered with an error that says a state of the television, that it has to be on or is in no state
    /// for the request: that is not a kind it lacks, and nothing is written on a row for it.
    func testARowWhoseKindCouldNotBeReadIsPassedOverAndNotHeld() async throws {
        let satellites = (0..<61).map { DemoTV.Station(scheme: "isdbbs", serviceID: 1700 + $0, name: "サンプルBS\($0)") }
        let failures: [(String, [String: Line.Fault], [String])] = [
            ("a first page that cannot be read", ["\(Self.kind) 0": .answered(Self.unreadable)], [Self.kind]),
            ("a later page that cannot be read", ["\(Self.kind) 1": .answered(Self.unreadable)],
             [Self.kind, Self.kind]),
            ("a later page answered with an error", ["\(Self.kind) 1": .answered(Self.refused(3))],
             [Self.kind, Self.kind]),
            ("a first page answered that the television has to be on",
             ["\(Self.kind) 0": .answered(Self.refused(40005))], [Self.kind]),
            ("a first page answered with an illegal state", ["\(Self.kind) 0": .answered(Self.refused(7))],
             [Self.kind]),
        ]
        for (name, faults, asked) in failures {
            let bench = await bench(receiving: satellites + Self.stations.prefix(4), faults: faults)
            var round = try await open(bench).round

            expectEqual(await send(row("サンプル映画", 50101, on: 4, service: 1755), in: &round, on: bench),
                        Came(.passedOver, asked: asked), name)
            XCTAssertEqual(round.saidNothing, 0, "\(name): counted among the rows that say nothing")
            expectEqual(await send(row("サンプル寄席", 50102, on: 4, at: 7200, service: 1701), in: &round, on: bench),
                        Came(.passedOver, asked: []), name)
            expectEqual(await send(row("サンプル劇場", 50103, on: 0), in: &round, on: bench),
                        Came(.made(saying: nil), asked: [Self.kind, Self.question, Self.create, Self.list]), name)
            expectEqual(await held(bench), ["recording.1 notOverlapped"], name)
        }
    }

    // MARK: - what it would stop, and the reader's consent

    /// A reservation that the television says would stop another from recording is held with the reason that
    /// names it, and no create is sent. With the reader's consent the television is asked all the same, and
    /// the create goes only when the reason on the row is the very reason the fresh answer makes: a row with
    /// no reason, with a reason that names another reservation, the same title on another day, or the same
    /// title at the same minute on another station, or held for something else, is held with the new reason
    /// and nothing is sent. Made with consent, the reservation named loses its recording, and nothing more is
    /// said of it: the reader was told.
    func testNothingIsMadeThatWouldStopAnotherUnlessTheReaderConsentedToExactlyThat() async throws {
        let household = [owned("recording.21", on: 1, "サンプル紀行"), owned("recording.22", on: 2, "サンプル討論")]
        let reason = "この予約を入れると、次の予約は録画されません: 「サンプル紀行」（サンプル放送2 11/1 21:00）。"
            + "「もう一度送る」を選ぶと、それでも予約します。"
        // What the reader would have consented to had the television named the other of the two, a
        // reservation of the same title a day later, or one of the same title at the same minute on another
        // station, as a programme sent out on two stations at once is.
        let other = ScalarClient.wouldStop(naming: [household[1].row])
        let nextDay = ScalarClient.wouldStop(naming: [owned("recording.21", on: 1, "サンプル紀行", at: 86_400).row])
        let elsewhere = ScalarClient.wouldStop(naming: [owned("recording.24", on: 2, "サンプル紀行").row])
        let asking = [Self.kind, Self.question]
        let untouched = ["recording.21 notOverlapped", "recording.22 notOverlapped"]
        let cases: [(name: String, consented: Bool, written: String?, comes: Came, holds: [String])] = [
            ("no consent", false, nil, Came(.refused(reason: reason), asked: asking), untouched),
            ("consent, and nothing on the row", true, nil, Came(.refused(reason: reason), asked: asking), untouched),
            ("consent to another reservation", true, other, Came(.refused(reason: reason), asked: asking), untouched),
            ("consent to the same title on another day", true, nextDay,
             Came(.refused(reason: reason), asked: asking), untouched),
            ("consent to the same title at the same minute on another station", true, elsewhere,
             Came(.refused(reason: reason), asked: asking), untouched),
            ("consent on a row held for its station", true, "テレビのチャンネル一覧にこの局が見つかりませんでした。",
             Came(.refused(reason: reason), asked: asking), untouched),
            ("consent to exactly that", true, reason,
             Came(.made(saying: nil), asked: asking + [Self.create, Self.list]),
             ["recording.21 fullyOverlapped", "recording.22 notOverlapped", "recording.23 notOverlapped"]),
        ]
        for (name, consented, written, comes, holds) in cases {
            let bench = await bench(holding: household)
            var round = try await open(bench).round

            expectEqual(await send(row("サンプル劇場", 50101, on: 0, reason: written), consented: consented,
                                   in: &round, on: bench), comes, name)
            expectEqual(await held(bench), holds, name)
        }
        XCTAssertTrue(reason.hasPrefix(ScalarClient.wouldStop + ": "), "a row held for the clash is known by this")

        // The reservation the reader consented to losing has gone since, and nothing would be stopped now:
        // the television is still asked, and the create goes.
        let bench = await bench(holding: [household[1]])
        var round = try await open(bench).round
        expectEqual(await send(row("サンプル劇場", 50101, on: 0, reason: reason), consented: true, in: &round, on: bench),
                    Came(.made(saying: nil), asked: asking + [Self.create, Self.list]))
    }

    /// Every row the question names holds the reservation, whatever its type: a reminder to watch, which no
    /// television has been seen to name, is named as one, and nothing is made until the reader consents to
    /// that. And an answer to the question that cannot be read is never taken for nothing named: the row is
    /// passed over, with consent as well, and no create is sent.
    func testAReminderNamedHoldsTheRowAndAnUnreadableAnswerIsNotNothingNamed() async throws {
        let reminder = owned("reminder.9", on: 3, "サンプル音楽館", at: -1, programme: 50109)
        let naming = try JSONSerialization.data(withJSONObject: ["result": [[reminder.named]], "id": 1])
        let named = ["\(Self.question) 0": Line.Fault.answered(HTTPResponse(statusCode: 200, body: naming))]
        let reason = "この予約を入れると、次の予約は録画されません: 視聴予約「サンプル音楽館」（サンプル放送4 11/1 21:00）。"
            + "「もう一度送る」を選ぶと、それでも予約します。"
        let asking = [Self.kind, Self.question]

        let held = await bench(holding: [reminder], faults: named)
        var round = try await open(held).round
        expectEqual(await send(row("サンプル劇場", 50101, on: 0), in: &round, on: held),
                    Came(.refused(reason: reason), asked: asking))
        expectEqual(await held.television.schedules, [reminder])

        let consented = await bench(holding: [reminder], faults: named)
        round = try await open(consented).round
        expectEqual(await send(row("サンプル劇場", 50101, on: 0, reason: reason), consented: true, in: &round,
                               on: consented).asked, asking + [Self.create, Self.list])

        for consent in [false, true] {
            let bench = await bench(faults: ["\(Self.question) 0": .answered(Self.unreadable)])
            round = try await open(bench).round
            expectEqual(await send(row("サンプル劇場", 50101, on: 0, reason: consent ? reason : nil), consented: consent,
                                   in: &round, on: bench), Came(.passedOver, asked: asking), "consent: \(consent)")
            expectEqual(await bench.television.schedules, [], "consent: \(consent)")
        }
    }

    // MARK: - silence, and answers that say nothing

    /// Silence at the create stops the round, and nothing is sent after it: not the list, not a second
    /// create, not the next row. The row waits as it was, with nothing written on it. The next round finds
    /// it in the television's list, takes it off the queue as found there, and sends no create for it: the
    /// reservation was made once.
    func testAfterSilenceAtTheCreateNothingIsSentAndTheNextRoundFindsTheRow() async throws {
        let bench = await bench()
        let store = try temporaryStore()
        for waiting in [row("サンプル劇場", 50101, on: 0), row("サンプル紀行", 50102, on: 1, at: 7200)] {
            try await store.queue(waiting)
        }
        let now = Self.start - 86_400
        await bench.television.atTheNextCreate(.carriedOutAndNotAnswered)

        let met = await PendingQueue.flush(client: bench.tv, store: store, now: now)

        XCTAssertEqual(met.stopped, .silent(afterSending: true))
        expectEqual(await bench.line.sent, [Self.disk, Self.list, Self.kind, Self.question, Self.create])
        XCTAssertEqual([met.sent, met.alreadyThere, met.refused, met.deferred, met.held].map(\.count),
                       [0, 0, 0, 0, 0])
        expectEqual(try await store.pendingReservations().map(\.problem), [nil, nil])

        await bench.line.forget()
        let next = await PendingQueue.flush(client: bench.tv, store: store, now: now)

        XCTAssertEqual(next.alreadyThere.map(\.request.title), ["サンプル劇場"])
        XCTAssertEqual(next.sent.map(\.request.title), ["サンプル紀行"])
        XCTAssertNil(next.stopped)
        expectEqual(await bench.line.sent,
                    [Self.disk, Self.list, Self.kind, Self.question, Self.create, Self.list])
        expectEqual(await bench.television.schedules.map(\.eventId), [50101, 50102])
        expectEqual(try await store.pendingReservations(), [])
    }

    /// Silence stops the round at whatever step it comes, and so does a cookie the television does not take;
    /// the row is left as it was and nothing is asked after either. Silence is told as coming after the
    /// create when the create went out and was not answered as held already: at the create itself, and at
    /// the list read after a create that was taken. Before the create, and after one answered as held
    /// already, nothing of this round's may have been made.
    func testSilenceAndACookieNotTakenStopTheRoundAtAnyStep() async throws {
        let silent = SendingStop.silent(afterSending: false), afterSending = SendingStop.silent(afterSending: true)
        let toTheQuestion = [Self.kind, Self.question], toTheCreate = [Self.kind, Self.question, Self.create]
        let toTheEnd = toTheCreate + [Self.list]
        let refused = Line.Fault.answered(Self.cookieNotTaken)
        let steps: [(String, String, Line.Fault, Bool, SendingStop, [String], Int)] = [
            ("silence at the stations", "\(Self.kind) 0", .neverArrives, false, silent, [Self.kind], 0),
            ("a cookie not taken at the stations", "\(Self.kind) 0", refused, false, .needsPairing, [Self.kind], 0),
            ("silence at the question", "\(Self.question) 0", .neverArrives, false, silent, toTheQuestion, 0),
            ("a cookie not taken at the question", "\(Self.question) 0", refused, false, .needsPairing,
             toTheQuestion, 0),
            ("silence at the create", "\(Self.create) 0", .neverArrives, false, afterSending, toTheCreate, 0),
            ("a cookie not taken at the create", "\(Self.create) 0", refused, false, .needsPairing, toTheCreate, 0),
            ("silence at the list after a create", "\(Self.list) 1", .neverArrives, false, afterSending, toTheEnd, 1),
            ("a cookie not taken at the list after a create", "\(Self.list) 1", refused, false, .needsPairing,
             toTheEnd, 1),
            ("silence at the list after a create answered as held already", "\(Self.list) 1", .neverArrives, true,
             silent, toTheEnd, 0),
        ]
        for (name, request, fault, saidThere, stop, asked, made) in steps {
            let bench = await bench(faults: [request: fault])
            var round = try await open(bench).round
            if saidThere { await bench.television.atTheNextCreate(.answered(code: 41222)) }

            expectEqual(await send(row("サンプル劇場", 50101, on: 0), in: &round, on: bench),
                        Came(.stopped(stop, passedOver: false), asked: asked), name)
            expectEqual(await bench.television.schedules.count, made, name)
        }
    }

    /// A list that cannot be read after a create answered as taken ends the round at that row, the first
    /// such row as well: the round no longer has the list it stands on, and what the next reservation did
    /// beyond its own row would be read from a list from before this create. The row is told as one passed
    /// over, nothing is written on it, and nothing is asked about the reservation after it. The next round
    /// finds the row in the television's list and sends no create for it. After a create answered as held
    /// already nothing was made, and the list the round holds still stands: there the row is passed over,
    /// and the round goes on to the next.
    func testAListThatCannotBeReadAfterACreateThatWasTakenEndsTheRound() async throws {
        let whole = [Self.kind, Self.question, Self.create, Self.list]
        let answers = [("that cannot be read", Self.unreadable), ("with an error", Self.refused(Self.unknown))]
        for (name, answer) in answers {
            let bench = await bench(faults: ["\(Self.list) 1": .answered(answer)])
            let store = try temporaryStore()
            for waiting in [row("サンプル劇場", 50101, on: 0), row("サンプル紀行", 50102, on: 1, at: 7200)] {
                try await store.queue(waiting)
            }
            let now = Self.start - 86_400

            let met = await PendingQueue.flush(client: bench.tv, store: store, now: now)

            XCTAssertEqual(met.stopped, .saysNothing, name)
            XCTAssertEqual(met.deferred.map(\.request.title), ["サンプル劇場"], name)
            XCTAssertEqual([met.sent, met.alreadyThere, met.refused, met.held].map(\.count), [0, 0, 0, 0], name)
            expectEqual(await bench.line.sent, [Self.disk, Self.list] + whole, name)
            expectEqual(try await store.pendingReservations().map(\.problem), [nil, nil], name)
            expectEqual(await bench.television.schedules.map(\.eventId), [50101], name)

            await bench.line.forget()
            let next = await PendingQueue.flush(client: bench.tv, store: store, now: now)

            XCTAssertEqual(next.alreadyThere.map(\.request.title), ["サンプル劇場"], name)
            XCTAssertEqual(next.sent.map(\.request.title), ["サンプル紀行"], name)
            expectEqual(await bench.line.sent, [Self.disk, Self.list] + whole, name)
            expectEqual(await bench.television.schedules.map(\.eventId), [50101, 50102], name)
        }

        let heldAlready = await bench(faults: ["\(Self.list) 1": .answered(Self.unreadable)])
        var round = try await open(heldAlready).round
        await heldAlready.television.atTheNextCreate(.answered(code: 41222))
        expectEqual(await send(row("サンプル劇場", 50101, on: 0), in: &round, on: heldAlready),
                    Came(.passedOver, asked: whole))
        expectEqual(await send(row("サンプル紀行", 50102, on: 1, at: 7200), in: &round, on: heldAlready),
                    Came(.made(saying: nil), asked: [Self.question, Self.create, Self.list]))
    }

    /// An answer that says nothing about the row -- a code nothing here knows, at the create or at the
    /// question, and a list that cannot be read after a create answered as held already -- passes the row
    /// over, with nothing to write on it, and the round goes on. A second such row running stops the round.
    ///
    /// A row the television answered about in between starts the count again: one made, found there, held
    /// for what it would stop, turned down by a code, held because its create was answered as taken and
    /// the list does not have it, or held because its create was answered as held already and the list has
    /// its programme reserved once where it asks for a repeat. A row that nothing was asked about neither
    /// counts nor starts it again: one whose station is not in the list, one with no programme id, one
    /// whose repeat is not sent, one whose programme the television had reserved once when the round
    /// opened, and one passed over for stations that could not be read. After a row answered with nothing,
    /// such a row, and another answered with nothing, the round stops.
    func testASecondRowRunningThatSaysNothingStopsTheRound() async throws {
        enum Kind {
            case unknownAtTheCreate, unknownAtTheQuestion, heldAlreadyAndListUnreadable
            case made, foundThere, wouldStopAnother, turnedDown, takenAndNotListed, reservedOnceSince
            case stationNotListed, noProgramme, repeatNotSent, reservedOnce, kindUnread
        }
        // The kinds of row that the question is not asked about, and those whose create is followed by the list.
        let notAskedAbout: Set<Kind> = [.stationNotListed, .noProgramme, .repeatNotSent, .reservedOnce, .kindUnread]
        let listed: Set<Kind> = [.made, .foundThere, .heldAlreadyAndListUnreadable, .takenAndNotListed,
                                 .reservedOnceSince]
        let stopped = RowSent.stopped(.saysNothing, passedOver: true)
        func held(_ reason: String) -> RowSent { .refused(reason: reason) }
        let clash = ScalarClient.wouldStop(naming: [owned("recording.71", on: 1, "サンプル紀行", at: 7200).row])
        let rounds: [(String, [Kind], [RowSent])] = [
            ("two running", [.unknownAtTheCreate, .unknownAtTheCreate], [.passedOver, stopped]),
            ("at the question, then at the create", [.unknownAtTheQuestion, .unknownAtTheCreate],
             [.passedOver, stopped]),
            ("at the list after a create answered as held already, then at the create",
             [.heldAlreadyAndListUnreadable, .unknownAtTheCreate], [.passedOver, stopped]),
            ("one made in between", [.unknownAtTheCreate, .made, .unknownAtTheCreate, .made],
             [.passedOver, .made(saying: nil), .passedOver, .made(saying: nil)]),
            ("one found there in between", [.unknownAtTheCreate, .foundThere, .unknownAtTheCreate],
             [.passedOver, .alreadyThere, .passedOver]),
            ("one held for what it would stop in between",
             [.unknownAtTheCreate, .wouldStopAnother, .unknownAtTheCreate], [.passedOver, held(clash), .passedOver]),
            ("one turned down by a code in between", [.unknownAtTheCreate, .turnedDown, .unknownAtTheCreate],
             [.passedOver, held(ScalarClient.refusals[7] ?? ""), .passedOver]),
            ("one taken and not listed in between", [.unknownAtTheCreate, .takenAndNotListed, .unknownAtTheCreate],
             [.passedOver, held(ScalarClient.acceptedNotListed), .passedOver]),
            ("one whose programme is reserved once after the round opened in between",
             [.unknownAtTheCreate, .reservedOnceSince, .unknownAtTheCreate],
             [.passedOver, held(ScalarClient.reservedOnceOnly), .passedOver]),
            ("one whose station is not in the list in between",
             [.unknownAtTheCreate, .stationNotListed, .unknownAtTheCreate],
             [.passedOver, held(ScalarClient.stationNotListed), stopped]),
            ("one with no programme id in between", [.unknownAtTheCreate, .noProgramme, .unknownAtTheCreate],
             [.passedOver, held(ScalarClient.needsAProgramme), stopped]),
            ("one whose repeat is not sent in between", [.unknownAtTheCreate, .repeatNotSent, .unknownAtTheCreate],
             [.passedOver, held(ScalarClient.repeatNotTaken), stopped]),
            ("one whose programme is reserved once in between",
             [.unknownAtTheCreate, .reservedOnce, .unknownAtTheCreate],
             [.passedOver, held(ScalarClient.reservedOnceOnly), stopped]),
            ("one of a kind that could not be read in between",
             [.unknownAtTheCreate, .kindUnread, .unknownAtTheCreate], [.passedOver, .passedOver, stopped]),
            ("two of a kind that could not be read, then one", [.kindUnread, .kindUnread, .unknownAtTheCreate],
             [.passedOver, .passedOver, .passedOver]),
        ]
        for (name, kinds, expected) in rounds {
            // The stations on BS cannot be read; the terrestrial ones, asked for first or not at all, can.
            var faults = ["\(Self.kind) \(kinds.first == .kindUnread ? 0 : 1)": Line.Fault.answered(Self.unreadable)]
            // What the household holds before the round opens: the programme of a row reserved once, and
            // two recordings at the time of a row that would stop one of them.
            var household: [DemoTV.Schedule] = []
            for (index, kind) in kinds.enumerated() {
                let offset = TimeInterval(index * 7200)
                // The list is read once to open the round, and once after each create before this row's that
                // was answered as taken or as held already.
                let lists = kinds.prefix(index).filter(listed.contains).count + 1
                if kind == .unknownAtTheQuestion {
                    let questions = kinds.prefix(index).filter { !notAskedAbout.contains($0) }.count
                    faults["\(Self.question) \(questions)"] = .answered(Self.refused(Self.unknown))
                }
                if kind == .heldAlreadyAndListUnreadable {
                    faults["\(Self.list) \(lists)"] = .answered(Self.unreadable)
                }
                if kind == .reservedOnce {
                    household.append(owned("recording.6\(index)", on: 0, "サンプル番組\u{3000}\(index)", at: offset,
                                           programme: 50101 + index))
                }
                if kind == .wouldStopAnother {
                    household += [owned("recording.7\(index)", on: 1, "サンプル紀行", at: offset),
                                  owned("recording.8\(index)", on: 2, "サンプル討論", at: offset)]
                }
            }
            let bench = await bench(holding: household, faults: faults)
            var round = try await open(bench).round
            var came: [RowSent] = []
            for (index, kind) in kinds.enumerated() {
                let offset = TimeInterval(index * 7200)
                let title = "サンプル番組\(index)", programme = 50101 + index
                var waiting = row(title, programme, on: 0, at: offset)
                switch kind {
                case .unknownAtTheCreate: await bench.television.atTheNextCreate(.answered(code: Self.unknown))
                case .heldAlreadyAndListUnreadable: await bench.television.atTheNextCreate(.answered(code: 41222))
                case .turnedDown: await bench.television.atTheNextCreate(.answered(code: 7))
                case .takenAndNotListed: await bench.television.atTheNextCreate(.answeredAndNotKept)
                case .foundThere:
                    let there = owned("recording.9\(index)", on: 0, "サンプル紀行", at: offset, programme: programme)
                    await bench.television.put(await bench.television.schedules + [there])
                case .reservedOnceSince:
                    // Set once with the remote after the round opened: the create is answered as held
                    // already, and the list read after it has the programme once.
                    let once = owned("recording.5\(index)", on: 0, "サンプル紀行", at: offset, programme: programme)
                    await bench.television.put(await bench.television.schedules + [once])
                    waiting = row(title, programme, at: offset, repeating: "d")
                case .stationNotListed: waiting = row(title, programme, at: offset, service: 1599)
                case .noProgramme: waiting = row(title, nil, at: offset)
                // Monday to Friday is not sent for a programme of a Sunday, nor for one before four on Monday.
                case .repeatNotSent: waiting = row(title, programme, at: offset, repeating: "w15")
                case .reservedOnce: waiting = row(title, programme, at: offset, repeating: "d")
                case .kindUnread: waiting = row(title, programme, on: 4, at: offset)
                case .unknownAtTheQuestion, .made, .wouldStopAnother: break
                }
                came.append(await send(waiting, in: &round, on: bench).sent)
            }
            XCTAssertEqual(came, expected, name)
        }
    }

    /// A code the television turns a reservation down with holds the row, with the reason for that code:
    /// asked again it would be answered the same. Error 7 is what a real one answered a create on a station
    /// the household is not subscribed to. Nothing was made, and the list is not read for it. The same code
    /// from the question is no such thing: it says nothing about the row.
    func testACodeThatTurnsTheReservationDownHoldsTheRow() async throws {
        let reason = "テレビがこの予約を受け付けませんでした（7）。契約していない局の番組などは予約できません。"
        let bench = await bench()
        var round = try await open(bench).round

        expectEqual(await send(row("サンプル映画", 50101, on: 5), in: &round, on: bench),
                    Came(.refused(reason: reason), asked: [Self.kind, Self.question, Self.create]))
        expectEqual(await bench.television.schedules, [])

        let asked = await self.bench(faults: ["\(Self.question) 0": .answered(Self.refused(7))])
        round = try await open(asked).round
        expectEqual(await send(row("サンプル劇場", 50102, on: 0), in: &round, on: asked),
                    Came(.passedOver, asked: [Self.kind, Self.question]))
    }

    // MARK: - what making it did beyond the row

    /// What a create did beyond its own row is read from the list before it and the list after: that the row
    /// made is itself marked as overlapping, whatever the mark; and each row that was not marked before and
    /// is now, by its name -- a reminder as a viewing reservation -- but for the rows the television named
    /// when it was asked, which the reader consented to. With a recording among those rows the sentence says
    /// that it may not be recorded; with reminders alone, only that they overlap. A row marked already, one
    /// that was not in the list before, and one whose mark has gone say nothing.
    func testWhatACreateDidBeyondItsRowIsReadFromTheListBeforeAndAfter() {
        func listed(_ id: String, _ title: String, _ overlap: String?, at start: String = "2026-11-01T21:00:00+0900",
                    programme: String? = nil) -> TVScheduleRow {
            TVScheduleRow(id: id, type: id.hasPrefix("reminder") ? "reminder" : "recording",
                          uri: Self.stations[1].uri, startDateTime: start, durationSec: 3600, title: title,
                          overlapStatus: overlap, eventId: programme)
        }
        let clear = "notOverlapped", lost = "fullyOverlapped", part = "partlyOverlapped"
        func made(_ overlap: String?) -> TVScheduleRow { listed("recording.31", "サンプル番組\u{3000}50101", overlap) }
        func other(_ overlap: String?) -> TVScheduleRow { listed("recording.21", "サンプル紀行", overlap) }
        func reminder(_ overlap: String?) -> TVScheduleRow {
            listed("reminder.9", "サンプル音楽館", overlap, at: "2026-11-01T20:59:59+0900")
        }
        let marked = "「サンプル劇場」はほかの予約と重なっていて、録画されないことがあります"
        func overlapped(_ names: String) -> String { "「サンプル劇場」を登録したため、\(names)がほかの予約と重なりました" }
        func mayLose(_ names: String) -> String {
            "「サンプル劇場」を登録したため、\(names)がほかの予約と重なり、録画されないことがあります"
        }
        let recording = "「サンプル紀行」（サンプル放送2 11/1 21:00）"
        let viewing = "視聴予約「サンプル音楽館」（サンプル放送2 11/1 21:00）"

        let cases: [(String, [TVScheduleRow], [TVScheduleRow], [TVScheduleRow], String?)] = [
            ("nothing marked", [other(clear), reminder(clear)], [made(clear), other(clear), reminder(clear)], [], nil),
            ("the row made, losing", [], [made(lost)], [], marked),
            ("the row made, overlapped in part", [], [made(part)], [], marked),
            ("the row made, saying nothing of its overlap", [], [made(nil)], [], nil),
            ("a recording marked that was not named", [other(clear)], [made(clear), other(lost)], [],
             mayLose(recording)),
            ("a recording marked that said nothing before", [other(nil)], [made(clear), other(lost)], [],
             mayLose(recording)),
            ("a recording marked that was named", [other(clear)], [made(clear), other(lost)], [other(clear)], nil),
            ("a recording that was marked already", [other(lost)], [made(clear), other(lost)], [], nil),
            ("a recording that was not in the list before", [], [made(clear), other(lost)], [], nil),
            ("a recording whose mark has gone", [other(lost)], [made(clear), other(clear)], [], nil),
            ("a reminder marked", [reminder(clear)], [made(clear), reminder(part)], [], overlapped(viewing)),
            ("both marked, the recording named", [other(clear), reminder(clear)],
             [made(clear), other(lost), reminder(part)], [other(clear)], overlapped(viewing)),
            ("both marked, the reminder named", [other(clear), reminder(clear)],
             [made(clear), other(lost), reminder(part)], [reminder(clear)], mayLose(recording)),
            ("both marked, neither named", [other(clear), reminder(clear)],
             [made(clear), other(lost), reminder(part)], [], mayLose(recording + "、" + viewing)),
            ("a reminder and then a recording marked", [reminder(clear), other(clear)],
             [made(clear), reminder(part), other(part)], [], mayLose(viewing + "、" + recording)),
            ("the row made and another", [reminder(clear)], [made(lost), reminder(part)], [],
             marked + "。" + overlapped(viewing)),
        ]
        for (name, before, after, named, expected) in cases {
            XCTAssertEqual(ScalarClient.remark(on: "サンプル劇場", made: after[0], before: before, after: after,
                                               named: named), expected, name)
        }
    }

    /// The same through a round. A recording beside a reminder to watch, which it overlaps in part, is made,
    /// and said to have left the viewing reservation overlapping: the television does not name it when asked,
    /// and marks it afterwards, as a real one was seen to. It is said once: the next row in the round is held
    /// against the list as that create left it. A row the list shows as made and marked is said to be both.
    /// And the queue says either after its sentence for what was sent.
    func testARowMadeSaysWhatTheListShowsItDid() async throws {
        let reminder = owned("reminder.9", on: 3, "サンプル音楽館", at: -1, programme: 50109)
        let cost = "「サンプル劇場」を登録したため、視聴予約「サンプル音楽館」（サンプル放送4 11/1 21:00）"
            + "がほかの予約と重なりました"
        let whole = [Self.kind, Self.question, Self.create, Self.list]
        let waiting = row("サンプル劇場", 50101, on: 0, for: 3240)

        let beside = await bench(holding: [reminder])
        var round = try await open(beside).round
        expectEqual(await send(waiting, in: &round, on: beside), Came(.made(saying: cost), asked: whole))
        expectEqual(await held(beside), ["reminder.9 partlyOverlapped", "recording.10 notOverlapped"])
        expectEqual(await send(row("サンプル紀行", 50102, on: 1, at: 7200), in: &round, on: beside).sent,
                    .made(saying: nil), "what the row before it left marked was said again")

        var losing = DemoTV.Schedule(id: "recording.1", serviceID: 1501, station: "サンプル放送1",
                                     title: DemoTV.title(ofProgramme: 50101), start: Self.start, durationSec: 3240,
                                     eventId: 50101)
        losing.overlapStatus = "fullyOverlapped"
        let list = try JSONSerialization.data(withJSONObject: ["result": [[losing.fields]], "id": 1])
        let marked = await bench(faults: ["\(Self.list) 1": .answered(HTTPResponse(statusCode: 200, body: list))])
        round = try await open(marked).round
        expectEqual(await send(waiting, in: &round, on: marked),
                    Came(.made(saying: "「サンプル劇場」はほかの予約と重なっていて、録画されないことがあります"), asked: whole))

        let queued = await bench(holding: [reminder])
        let store = try temporaryStore()
        try await store.queue(waiting)
        let outcome = await PendingQueue.flush(client: queued.tv, store: store, now: Self.start - 86_400)
        XCTAssertEqual(outcome.remarks, [cost])
        XCTAssertEqual(outcome.says(naming: "テレビ"), "送信待ちだった「サンプル劇場」をテレビに登録しました。" + cost)
    }

    // MARK: - the sentences

    /// The sentences that are kept in the phone's database, letter for letter, and how a row of the
    /// television's list is named in them: its title as the television has it, and in brackets the station
    /// as its uri calls it, whatever is in that name, and the day and time it starts in Japan, to the nearest
    /// minute, written the same whatever the phone's settings; a reminder as a viewing reservation; several
    /// in the order given. A row whose uri names no station is named by its title and its start, one whose
    /// start cannot be read by its title and its station, and one with neither by its title alone.
    func testTheReasonsAndTheNamesInThemAreWrittenAsTheyAreKept() {
        XCTAssertEqual(ScalarClient.stationNotListed, "テレビのチャンネル一覧にこの局が見つかりませんでした。")
        XCTAssertEqual(ScalarClient.wouldStop, "この予約を入れると、次の予約は録画されません")
        XCTAssertEqual(ScalarClient.acceptedNotListed, "テレビは受け付けたと答えましたが、一覧にありません。")
        XCTAssertEqual(ScalarClient.saidThereNotListed,
                       "テレビはこの番組を予約済みと答えましたが、録画予約の一覧に見つかりませんでした。")
        XCTAssertEqual(ScalarClient.reservedOnceOnly, "テレビにはこの番組の 1 回だけの予約がすでにあります。"
                       + "毎回録画にするには、テレビの予約を削除してから「もう一度送る」を選んでください。")
        XCTAssertEqual(ScalarClient.diskNotFound, "録画用の USB HDD が見つからないため、テレビへの予約は送っていません")
        XCTAssertEqual(ScalarClient.refusals.keys.sorted(), [7])
        XCTAssertEqual(ScalarClient.slot, .tv)

        // On the first station unless a uri is given: one that ends at its three numbers, one whose name is
        // empty, and one whose name holds what a uri is cut at.
        let numbers = "tv:isdbt?trip=65534.65533.1501"
        func listed(_ type: String, _ title: String?, _ start: String, uri: String? = nil) -> TVScheduleRow {
            TVScheduleRow(id: "\(type).31", type: type, uri: uri ?? Self.stations[0].uri, startDateTime: start,
                          durationSec: 1800, title: title)
        }
        let names: [(TVScheduleRow, String)] = [
            (listed("recording", "サンプル劇場", "2026-11-01T21:00:00+0900"), "「サンプル劇場」（サンプル放送1 11/1 21:00）"),
            (listed("recording", "サンプル番組\u{3000}7\u{1F211}", "2026-11-02T07:05:00+0900"),
             "「サンプル番組\u{3000}7\u{1F211}」（サンプル放送1 11/2 07:05）"),
            (listed("recording", "サンプル深夜便", "2026-11-02T01:30:00+0900"),
             "「サンプル深夜便」（サンプル放送1 11/2 01:30）"),
            (listed("recording", "サンプル劇場", "2026-11-01T21:00:00+09:00"), "「サンプル劇場」（サンプル放送1 11/1 21:00）"),
            (listed("reminder", "サンプル音楽館", "2026-11-01T20:59:59+0900"),
             "視聴予約「サンプル音楽館」（サンプル放送1 11/1 21:00）"),
            (listed("reminder", "サンプル音楽館", "2026-12-31T23:59:59+0900"),
             "視聴予約「サンプル音楽館」（サンプル放送1 1/1 00:00）"),
            (listed("recording", nil, "2026-11-01T21:00:00+0900"), "「」（サンプル放送1 11/1 21:00）"),
            (listed("recording", "サンプル劇場", "2026-11-01T21:00:00+0900",
                    uri: numbers + "&srvName=サンプル\u{3000}放送 & 2?trip=1.2.3&srvName=4"),
             "「サンプル劇場」（サンプル\u{3000}放送 & 2?trip=1.2.3&srvName=4 11/1 21:00）"),
            (listed("recording", "サンプル劇場", "2026-11-01T21:00:00+0900", uri: numbers),
             "「サンプル劇場」（11/1 21:00）"),
            (listed("recording", "サンプル劇場", "2026-11-01T21:00:00+0900", uri: numbers + "&srvName="),
             "「サンプル劇場」（11/1 21:00）"),
            (listed("recording", "サンプル劇場", "あした"), "「サンプル劇場」（サンプル放送1）"),
            (listed("reminder", "サンプル音楽館", "あした"), "視聴予約「サンプル音楽館」（サンプル放送1）"),
            (listed("recording", "サンプル劇場", "あした", uri: numbers), "「サンプル劇場」"),
        ]
        for (row, name) in names {
            XCTAssertEqual(ScalarClient.name(of: row), name)
        }
        XCTAssertEqual(ScalarClient.wouldStop(naming: [names[4].0, names[0].0]),
                       "この予約を入れると、次の予約は録画されません: 視聴予約「サンプル音楽館」（サンプル放送1 11/1 21:00）、"
                        + "「サンプル劇場」（サンプル放送1 11/1 21:00）。「もう一度送る」を選ぶと、それでも予約します。")
    }
}

/// The line to the invented television, which a test can have fail at one request: the nth of a method,
/// counted from nought, never arrives, or is answered here with something else and not carried out. It keeps
/// the method of everything sent, in order, whether or not it arrived.
private actor Line: HTTPTransport {
    enum Fault: Sendable {
        case neverArrives
        case answered(HTTPResponse)
    }

    private let television: DemoTV
    private let faults: [String: Fault]
    private var counts: [String: Int] = [:]
    private(set) var sent: [String] = []

    /// `faults`: what happens to a request, by its method and which of that method's it is, as `"<method> <n>"`.
    init(_ television: DemoTV, faults: [String: Fault]) {
        self.television = television
        self.faults = faults
    }

    func forget() { sent = [] }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let object = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
        let method = object?["method"] as? String ?? ""
        let nth = counts[method, default: 0]
        counts[method] = nth + 1
        sent.append(method)
        switch faults["\(method) \(nth)"] {
        case .neverArrives?: throw RecorderError.transport("The request timed out.")
        case .answered(let response)?: return response
        case nil: return try await television.send(request)
        }
    }
}
