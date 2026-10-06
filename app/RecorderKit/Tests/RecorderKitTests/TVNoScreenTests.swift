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

    // MARK: - what it says

    /// What the Shortcuts action is told of a run, every time and in the reader's words: what the queue says
    /// of the round, naming the device it is handed, then what stands in the way of what still waits.
    /// Nothing where nothing waited, or where another sending had taken what did. The television not
    /// answering, at its MAC or at the round's opening; another television; the disk away, said after the
    /// queue's sentence for a row dropped on the way; a registration wanted, none kept or one the television
    /// no longer takes; silence at a create, said in its own sentence only where the queue has none for the
    /// round cut short; answers that say nothing at the opening; a row passed over, which is the queue's to
    /// say. Silence after a row was made or passed over is the queue's to say as well: the television had
    /// answered that run, and is not said not to.
    func testWhatARunSaysIsWhatTheQueueSaysAndThenWhatStandsInTheWay() async throws {
        let row = waiting("サンプル劇場", 50101), later = waiting("サンプル紀行", 50102, in: 3)
        let over = waiting("サンプル天気", 50103, in: -2)
        let cutShort = "途中でテレビの応答がなくなったため、残りは次につながったときに送ります"
        let theDisk = "録画用の USB HDD が見つからないため、テレビへの予約は送っていません"
        let notAnswering = "テレビが応答しないため送っていません。次にテレビが答えたときに送ります"
        let toRegister = "テレビへの登録が必要です。設定の「テレビ」から登録してください"
        let metSilence = "送信の途中でテレビの応答がなくなりました。届いている場合もあるため、"
            + "送り直していません。次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"

        let cases: [(String, NoScreenSending, String?)] = [
            ("nothing waiting", await send(try await home()), nil),
            ("nothing left to send", .sent(PendingQueue.Outcome(slot: .tv)), nil),
            ("silent at the MAC", await run([row]) { await $0.television.goSilent() }, notAnswering),
            ("silent at the opening", await run([row]) { home in
                let television = home.television
                await home.gate.before(Self.disk) { await television.goSilent() }
            }, notAnswering),
            ("another television", await run([row]) { await $0.television.becomeAnother(mac: "f8:4e:17:00:00:0b") },
             "登録したテレビとは別の機器が応答しました。設定の「テレビ」から追加し直してください。"),
            ("one row made", await run([row]), "送信待ちだった「サンプル劇場」をテレビに登録しました"),
            ("the disk away", await run([row]) { await $0.television.unmount() }, theDisk),
            ("a row over, then the disk away", await run([over, row]) { await $0.television.unmount() },
             "テレビ宛の「サンプル天気」は放送が終わっていたため、送らずに削除しました。" + theDisk),
            ("no registration kept", await run([row], credentials: nil), toRegister),
            ("a cookie it no longer takes",
             await run([row], credentials: TVCredentials(clientID: "BDBridge:test", cookie: "run out")), toRegister),
            ("silent at the first create",
             await run([row]) { await $0.television.atTheNextCreate(.carriedOutAndNotAnswered) }, metSilence),
            ("silent at the second create", await run([row, later]) { home in
                let television = home.television
                await home.gate.before(Self.create) {
                    if await television.calls.filter({ $0.hasPrefix(Self.create) }).count == 1 {
                        await television.goSilent()
                    }
                }
            }, "送信待ちだった「サンプル劇場」をテレビに登録しました。"
                + "途中でテレビの応答がなくなったため、残りは次につながったときに送ります"),
            ("one row made, then silent at the next question", await run([row, later]) { home in
                let television = home.television
                await home.gate.before(Self.question) {
                    if await television.calls.filter({ $0.hasPrefix(Self.create) }).count == 1 {
                        await television.goSilent()
                    }
                }
            }, "送信待ちだった「サンプル劇場」をテレビに登録しました。" + cutShort),
            ("one row passed over, then silent",
             .sent(PendingQueue.Outcome(slot: .tv, deferred: [row], stopped: .silent(afterSending: false))),
             "「サンプル劇場」はテレビに送れなかったため、次の機会にもう一度送ります。" + cutShort),
            ("nothing that reads at the opening",
             await run([row]) { await $0.gate.answer(Self.disk, with: Self.unreadable) },
             "テレビの応答を読み取れなかったため、テレビへの予約は送っていません"),
            ("a row passed over", await run([row]) { await $0.gate.answer(Self.stations, with: Self.unreadable) },
             "「サンプル劇場」はテレビに送れなかったため、次の機会にもう一度送ります"),
        ]
        for (name, sending, says) in cases {
            XCTAssertEqual(TVDriver.says(sending, naming: "テレビ"), says, name)
        }
    }

    /// One attempt from a home of `rows`, bent first as a test says.
    private func run(_ rows: [PendingReservation], credentials: TVCredentials? = TVNoScreenTests.kept,
                     _ bend: (Home) async -> Void = { _ in }) async -> NoScreenSending {
        guard let home = try? await home(rows, credentials: credentials) else { return .nothingWaiting }
        await bend(home)
        return await send(home)
    }

    // MARK: - told once

    /// Eight in the evening in Japan on Sunday 1 November 2026, and the next overnight run, at two.
    private static let now = Date(timeIntervalSince1970: 1_793_530_800)
    private static let nextRun = Date(timeIntervalSince1970: 1_793_552_400)

    /// A reservation waiting for the television unless said, starting `minutes` after eight that evening.
    private func row(_ title: String, _ programme: Int, at minutes: Double, for durationSec: Int = 1800,
                     reason: String? = nil, target: DeviceSlot = .tv) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Self.now + minutes * 60, durationSec: durationSec,
                                         repeatCode: "1", broadcastingType: Codes.broadcasting["td"] ?? 0,
                                         serviceID: 1024, qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ",
                                  queuedAt: Date(timeIntervalSince1970: 1_793_000_000), problem: reason, target: target)
    }

    /// One run with no screen, what it came to and the queue read after it, and what it is to tell.
    private struct Run {
        let name: String
        let sending: NoScreenSending
        var waiting: [PendingReservation]? = []
        var queue: String?
        var notYet: String?
        var withdraws = false
    }

    /// The runs one after another from `told`, each held to what it is to tell. What is told after the last.
    ///
    /// Told with the process's time zone set to one that is not Japan's, whatever the machine's is: a start is
    /// to be written out in Japan's, and on a machine in Japan a start written in the machine's own would read
    /// the same.
    @discardableResult
    private func tell(_ runs: [Run], from told: TVTold = TVTold()) -> TVTold {
        let zone = NSTimeZone.default
        NSTimeZone.default = .gmt
        defer { NSTimeZone.default = zone }
        var told = told
        for run in runs {
            let (notices, next) = told.after(run.sending, waiting: run.waiting, before: Self.nextRun, now: Self.now,
                                             naming: "テレビ")
            XCTAssertEqual(notices, TVNotices(queue: run.queue, notYet: run.notYet, withdrawsNotYet: run.withdraws),
                           run.name)
            told = next
        }
        return told
    }

    /// A stop is told once, and again after a run that got past the round's opening, after one with nothing
    /// waiting, and after another stop. A run that learnt nothing of the television -- silent, or answering
    /// with nothing that reads -- leaves what was told as it was, and a television that does not answer is
    /// never told on its own. One silent after a row was made or passed over did learn something: it got
    /// past the opening, and says nothing of the silence beyond what the queue says. What a round made is
    /// news, as the recorder's is. Silence at a create is told each time, in its own sentence only where the
    /// queue has none for the round it cut short.
    func testAStopIsToldOnceUntilSomethingHasChanged() {
        let morning = row("サンプル天気", 50103, at: 420)
        let disk = NoScreenSending.sent(PendingQueue.Outcome(slot: .tv,
                                                             stopped: .cannotRecord(reason: ScalarClient.diskNotFound)))
        let theDisk = "録画用の USB HDD が見つからないため、テレビへの予約は送っていません"
        let went = NoScreenSending.sent(PendingQueue.Outcome(slot: .tv, sent: [morning]))
        let unread = NoScreenSending.sent(PendingQueue.Outcome(slot: .tv, stopped: .saysNothing))
        let unregistered = NoScreenSending.sent(PendingQueue.Outcome(slot: .tv, stopped: .needsPairing))
        let waits: [PendingReservation] = [morning]

        let twice = tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
                          Run(name: "the disk again", sending: disk, waiting: waits)])
        XCTAssertEqual(twice, TVTold(stop: .disk))
        let afterARound = tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
                                Run(name: "a round that went", sending: went, waiting: [],
                                    queue: "送信待ちだった「サンプル天気」をテレビに登録しました"),
                                Run(name: "the disk after a round", sending: disk, waiting: waits, queue: theDisk)])
        XCTAssertEqual(afterARound, TVTold(stop: .disk))
        tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
              Run(name: "nothing waiting", sending: .nothingWaiting, waiting: []),
              Run(name: "the disk after nothing waiting", sending: disk, waiting: waits, queue: theDisk)])
        let silent = tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
                           Run(name: "the television silent", sending: .unreachable, waiting: waits),
                           Run(name: "the disk after a silent run", sending: disk, waiting: waits)])
        XCTAssertEqual(silent, TVTold(stop: .disk))
        tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
              Run(name: "nothing that reads", sending: unread, waiting: waits),
              Run(name: "the disk after nothing that reads", sending: disk, waiting: waits)])
        let another = tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
                            Run(name: "another television", sending: .anotherAnswered, waiting: waits,
                                queue: "登録したテレビとは別の機器が応答しました。設定の「テレビ」から追加し直してください。")])
        XCTAssertEqual(another, TVTold(stop: .another))
        tell([Run(name: "no registration", sending: unregistered, waiting: waits,
                  queue: "テレビへの登録が必要です。設定の「テレビ」から登録してください"),
              Run(name: "no registration again", sending: unregistered, waiting: waits)])
        tell([Run(name: "silent", sending: .unreachable, waiting: waits),
              Run(name: "silent again", sending: .unreachable, waiting: waits)])
        tell([Run(name: "only a row passed over", sending: .sent(PendingQueue.Outcome(slot: .tv, deferred: [morning])),
                  waiting: waits)])

        let cutShort = "途中でテレビの応答がなくなったため、残りは次につながったときに送ります"
        let madeThenSilent = NoScreenSending.sent(PendingQueue.Outcome(slot: .tv, sent: [morning],
                                                                       stopped: .silent(afterSending: false)))
        tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
              Run(name: "made, then silent", sending: madeThenSilent, waiting: [],
                  queue: "送信待ちだった「サンプル天気」をテレビに登録しました。" + cutShort),
              Run(name: "the disk after made, then silent", sending: disk, waiting: waits, queue: theDisk)])
        let passedOverThenSilent = NoScreenSending.sent(PendingQueue.Outcome(slot: .tv, deferred: [morning],
                                                                             stopped: .silent(afterSending: false)))
        tell([Run(name: "the disk", sending: disk, waiting: waits, queue: theDisk),
              Run(name: "passed over, then silent", sending: passedOverThenSilent, waiting: waits),
              Run(name: "the disk after passed over, then silent", sending: disk, waiting: waits, queue: theDisk)])

        let metSilence = "送信の途中でテレビの応答がなくなりました。届いている場合もあるため、"
            + "送り直していません。次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"
        tell([Run(name: "silent at the first create",
                  sending: .sent(PendingQueue.Outcome(slot: .tv, stopped: .silent(afterSending: true))),
                  waiting: waits, queue: metSilence),
              Run(name: "silent at the first create again",
                  sending: .sent(PendingQueue.Outcome(slot: .tv, stopped: .silent(afterSending: true))),
                  waiting: waits, queue: metSilence)])
        let madeThenSilentAtACreate = NoScreenSending.sent(PendingQueue.Outcome(slot: .tv, sent: [morning],
                                                                                stopped: .silent(afterSending: true)))
        tell([Run(name: "silent at the second create", sending: madeThenSilentAtACreate, waiting: [],
                  queue: "送信待ちだった「サンプル天気」をテレビに登録しました。" + cutShort)])
    }

    /// A row that starts before the next run and has not reached the television is told once, by the run
    /// that first finds it so, in a notice of its own that ends with what stands in its way -- the television
    /// silent, a registration wanted, answers that say nothing, silence at a create -- or, where nothing known
    /// does, with opening the app. The queue's notice then says nothing of what the late one carries. A row
    /// late since is told with the one told before, which is still late and starts first: the notice takes
    /// the last one's place. One on air is told: it is still sent. A start after midnight is written with no
    /// leading zero. Rows that start at or after the next run, carry a reason, are the recorder's or are over
    /// are never told; nor is one the round made or found there that the queue read after it still holds.
    func testALateRowIsToldOnceWithWhatStandsInItsWay() {
        let theatre = row("サンプル劇場", 50101, at: 60), journey = row("サンプル紀行", 50102, at: 210)
        let notYet = "テレビにまだ届いていない予約があります（「サンプル劇場」21:00 から）。"
        let notAnswering = "テレビが応答しないため送っていません。次にテレビが答えたときに送ります"

        tell([Run(name: "late, the television silent", sending: .unreachable, waiting: [theatre],
                  notYet: notYet + notAnswering),
              Run(name: "still late, silent again", sending: .unreachable, waiting: [theatre]),
              Run(name: "a second late row", sending: .unreachable, waiting: [theatre, journey],
                  notYet: "テレビにまだ届いていない予約があります（「サンプル劇場」21:00 から、ほか 1 件）。" + notAnswering)])
        tell([Run(name: "late, after midnight", sending: .unreachable, waiting: [row("サンプル深夜便", 50109, at: 330)],
                  notYet: "テレビにまだ届いていない予約があります（「サンプル深夜便」1:30 から）。" + notAnswering)])
        tell([Run(name: "late, no registration",
                  sending: .sent(PendingQueue.Outcome(slot: .tv, stopped: .needsPairing)), waiting: [theatre],
                  notYet: notYet + "テレビへの登録が必要です。設定の「テレビ」から登録してください")])
        tell([Run(name: "late, nothing that reads",
                  sending: .sent(PendingQueue.Outcome(slot: .tv, stopped: .saysNothing)), waiting: [theatre],
                  notYet: notYet + "テレビの応答を読み取れなかったため、テレビへの予約は送っていません")])
        tell([Run(name: "late, silent at a create",
                  sending: .sent(PendingQueue.Outcome(slot: .tv, stopped: .silent(afterSending: true))),
                  waiting: [theatre], notYet: notYet + "送信の途中でテレビの応答がなくなりました。届いている場合もあるため、"
                    + "送り直していません。次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。")])
        tell([Run(name: "late, passed over", sending: .sent(PendingQueue.Outcome(slot: .tv, deferred: [theatre])),
                  waiting: [theatre], notYet: notYet + "アプリを開くと送ります")])
        tell([Run(name: "on air", sending: .unreachable, waiting: [row("サンプル中継", 50107, at: -30, for: 3600)],
                  notYet: "テレビにまだ届いていない予約があります（「サンプル中継」19:30 から）。" + notAnswering)])

        let never = [row("サンプル天気", 50103, at: 420), row("サンプル体操", 50104, at: 360),
                     row("サンプル映画", 50105, at: 120, reason: "この局は録画できません"),
                     row("サンプル討論", 50106, at: 120, target: .recorder), row("サンプル朝市", 50108, at: -120)]
        let none = tell([Run(name: "never late", sending: .unreachable, waiting: never)])
        XCTAssertEqual(none, TVTold())
        tell([Run(name: "made, still read as waiting", sending: .sent(PendingQueue.Outcome(slot: .tv, sent: [theatre])),
                  waiting: [theatre], queue: "送信待ちだった「サンプル劇場」をテレビに登録しました"),
              Run(name: "found there, still read as waiting",
                  sending: .sent(PendingQueue.Outcome(slot: .tv, alreadyThere: [journey])), waiting: [journey],
                  queue: "「サンプル紀行」はテレビにすでに予約がありました")])
    }

    /// The late notice is taken away by the first run that finds none of the rows it told of waiting to go,
    /// and not while one still does, nor by a run that posts a late notice of its own, nor when there was
    /// none to take away. A queue that could not be read tells no row, takes nothing away and leaves what was
    /// told. What is told reads back from its JSON as it was.
    func testTheLateNoticeIsTakenAwayOnceNoneOfItsRowsWaits() throws {
        let theatre = row("サンプル劇場", 50101, at: 60), journey = row("サンプル紀行", 50102, at: 210)
        let notAnswering = "テレビが応答しないため送っていません。次にテレビが答えたときに送ります"
        let both = tell([
            Run(name: "two late", sending: .unreachable, waiting: [theatre, journey],
                notYet: "テレビにまだ届いていない予約があります（「サンプル劇場」21:00 から、ほか 1 件）。" + notAnswering),
            Run(name: "one made", sending: .sent(PendingQueue.Outcome(slot: .tv, sent: [theatre])), waiting: [journey],
                queue: "送信待ちだった「サンプル劇場」をテレビに登録しました"),
            Run(name: "the other made", sending: .sent(PendingQueue.Outcome(slot: .tv, sent: [journey])), waiting: [],
                queue: "送信待ちだった「サンプル紀行」をテレビに登録しました", withdraws: true),
            Run(name: "nothing to take away", sending: .nothingWaiting, waiting: []),
        ])
        XCTAssertEqual(both, TVTold())

        let one = TVTold(rows: [theatre.id])
        tell([Run(name: "another late in its place", sending: .unreachable, waiting: [journey],
                  notYet: "テレビにまだ届いていない予約があります（「サンプル紀行」23:30 から）。" + notAnswering)], from: one)
        let unread = tell([Run(name: "a queue that could not be read", sending: .unreachable, waiting: nil)], from: one)
        XCTAssertEqual(unread, one)

        let told = TVTold(stop: .registration, rows: [theatre.id, journey.id])
        XCTAssertEqual(try JSONDecoder().decode(TVTold.self, from: JSONEncoder().encode(told)), told)
    }

    /// A sending of the screens' own takes the late notice away once none of the rows it told of waits to go
    /// -- gone, held with a reason, or over -- by the rule a run with no screen takes it away by, and the
    /// rows are told no more; the stop told stays. While one of them still waits nothing changes, and with
    /// no row told of there is nothing to take away.
    func testTheScreensSendingTakesTheLateNoticeAwayOnceNoneOfItsRowsWaits() {
        let theatre = row("サンプル劇場", 50101, at: 60), journey = row("サンプル紀行", 50102, at: 210)
        let told = TVTold(stop: .disk, rows: [theatre.id])
        // The same programme, and so the same row, as it would read held, and once it is over.
        let held = row("サンプル劇場", 50101, at: 60, reason: "この局は録画できません")
        let over = row("サンプル劇場", 50101, at: -60)
        let cases: [(String, TVTold, [PendingReservation], TVTold?)] = [
            ("still waiting", told, [theatre, journey], nil),
            ("sent", told, [journey], TVTold(stop: .disk)),
            ("held with a reason", told, [held], TVTold(stop: .disk)),
            ("over", told, [over], TVTold(stop: .disk)),
            ("none told of", TVTold(stop: .disk), [], nil),
        ]
        for (name, before, waiting, after) in cases {
            XCTAssertEqual(before.afterTheScreensSent(waiting: waiting, now: Self.now), after, name)
        }
    }
}
