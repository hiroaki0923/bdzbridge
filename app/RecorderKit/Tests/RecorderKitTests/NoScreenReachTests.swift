import Foundation
import XCTest
@testable import RecorderKit

/// The attempt of the runs with no screen, the overnight refresh and the Shortcuts action
/// (`RecorderDriver.reachWithNoScreen`). The app's tests of those runs hand them no MAC, since a packet would go
/// out on whatever network they run on; here the packet is the test's own and goes nowhere.
final class NoScreenReachTests: XCTestCase {
    /// What the run did, in order: the packets it sent and the asks it made. Written from the packet's closure,
    /// which cannot wait, and from the transport.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func put(_ event: String) { lock.withLock { list.append(event) } }
        var all: [String] { lock.withLock { list } }
    }

    /// The recorder of the vectors, answering each ask of who it is with the next of `answers` and the last
    /// for ever after: a status, or nil for silence.
    private func recorder(_ answers: [Int?], _ events: Events) throws -> StubTransport {
        let description = try Vectors.descriptionXML()
        return StubTransport { _, index in
            events.put("ask")
            guard let status = answers[min(index, answers.count - 1)] else {
                throw RecorderError.transport("The request timed out.")
            }
            return HTTPResponse(statusCode: status, body: status == 200 ? Data(description.utf8) : Data())
        }
    }

    /// The attempt, with a packet out when `packet` and none otherwise -- no MAC written down -- and a wait
    /// that gives up after a fifth of a second rather than a minute.
    private func reach(_ transport: StubTransport, at host: String = Stub.host, packet: Bool,
                       _ events: Events) async -> Bool {
        await RecorderDriver.reachWithNoScreen(RecorderClient(host: host, transport: transport), limit: 0.2,
                                               interval: .milliseconds(10), sendPacket: {
                                                   if packet { events.put("packet") }
                                                   return packet
                                               })
    }

    /// The packet first and the ask after. An error on the first ask -- here a page that is no recorder's, as
    /// one still starting up may give -- is waited for, as silence is, until the recorder says who it is.
    func testAnErrorOnTheFirstAskIsWaitedForAfterThePacket() async throws {
        let events = Events()
        let answered = await reach(try recorder([404, 200], events), packet: true, events)

        XCTAssertTrue(answered)
        XCTAssertEqual(events.all, ["packet", "ask", "ask"])
    }

    /// Silence is waited for until the limit, and the run gives up.
    func testSilenceIsWaitedForUntilTheLimit() async throws {
        let events = Events()
        let answered = await reach(try recorder([nil], events), packet: true, events)

        XCTAssertFalse(answered)
        XCTAssertEqual(events.all.first, "packet")
        XCTAssertGreaterThan(events.all.filter { $0 == "ask" }.count, 2, "silence was not waited for")
    }

    /// With no packet out nothing is coming up, and nothing is waited for.
    func testWithNoPacketNothingIsWaitedFor() async throws {
        let events = Events()
        let answered = await reach(try recorder([nil], events), packet: false, events)

        XCTAssertFalse(answered)
        XCTAssertEqual(events.all, ["ask"])
    }

    /// At an address that is not one nothing could be asked, and nothing is waited for either.
    func testAnAddressThatIsNotOneIsNotWaitedFor() async throws {
        let events = Events()
        let answered = await reach(try recorder([200], events), at: "192.0.2.10:64220", packet: true, events)

        XCTAssertFalse(answered)
        XCTAssertEqual(events.all, ["packet"], "asked, or waited for, at an address that is not one")
    }

    /// Whether the recorder that answered a run with no screen is the one the phone's cache is of is answered
    /// three ways. One that has not said who it is cannot be told apart: it is taken neither for the cache's own
    /// nor for another. The first a cache hears from, and the one the cache is of, are the one known. One that
    /// says which it is, over a cache that is another's, is another.
    func testWhetherTheRecorderThatAnsweredIsTheOneKnownIsAnsweredThreeWays() async throws {
        let description = HTTPResponse(statusCode: 200, body: Data(try Vectors.descriptionXML().utf8))
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: description))
        let store = try temporaryStore()
        expectEqual(await RecorderDriver.isTheOneKnown(client, to: store), .cannotBeTold,
                    "a recorder that has not said who it is")

        let recorder = try await client.describe()
        expectEqual(await RecorderDriver.isTheOneKnown(client, to: store), .yes, "the first a cache hears from")
        expectEqual(try await store.claim(for: recorder), .first)
        expectEqual(await RecorderDriver.isTheOneKnown(client, to: store), .yes, "the recorder the cache is of")

        var other = recorder
        other.udn = "uuid:00000000-0000-0000-0000-f84e17000002"
        expectEqual(try await store.claim(for: other), .another)
        expectEqual(await RecorderDriver.isTheOneKnown(client, to: store), .another,
                    "a recorder over a cache that is another's")
    }

    /// A night's packet goes once, before the recorder is asked who it is, and no other follows a recorder that
    /// answers that first ask: the rest of the night -- the slot, the free space, the guide's files, each
    /// refused here -- sends none. The packet is put down in the same list as what the recorder is asked.
    func testANightSendsItsPacketOnceBeforeItAsksWhoIsThere() async throws {
        let events = Events()
        let description = try Vectors.descriptionXML()
        let transport = StubTransport { request, _ in
            guard request.url.lastPathComponent == "description.xml" else {
                events.put("ask")
                return HTTPResponse(statusCode: 500, body: Data())
            }
            events.put("description.xml")
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }

        let stored = await RecorderDriver.refreshWithNoScreen(
            RecorderClient(host: Stub.host, transport: transport), store: try temporaryStore(),
            sendPacket: {
                events.put("packet")
                return true
            }, found: { _ in })

        XCTAssertFalse(stored)
        XCTAssertEqual(Array(events.all.prefix(2)), ["packet", "description.xml"])
        XCTAssertEqual(events.all.filter { $0 == "packet" }.count, 1, "another packet went out")
        XCTAssertEqual(events.all.filter { $0 == "description.xml" }.count, 1, "the recorder was waited for")
        XCTAssertTrue(events.all.contains("ask"), "the night ended as it reached the recorder")
    }

    /// The Shortcuts action's packet. With nothing waiting that could be sent none goes and nothing is asked: the
    /// queue is read first, so that no recorder is woken for nothing. With a reservation waiting the packet goes
    /// once, before the recorder is asked who it is, and no other follows a recorder that answers that first
    /// ask; the round is then run, its read of the recorder's list refused here. The action is asked at the
    /// moment the reservation's programme starts, a moment of the test's own.
    func testTheActionSendsItsPacketOnceBeforeItAsksWhoIsThereAndNoneWithNothingWaiting() async throws {
        let events = Events()
        let description = try Vectors.descriptionXML()
        let transport = StubTransport { request, _ in
            guard request.url.lastPathComponent == "description.xml" else {
                events.put("ask")
                return HTTPResponse(statusCode: 500, body: Data())
            }
            events.put("description.xml")
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        let store = try temporaryStore()
        let row = pending()
        func action() async -> NoScreenSending {
            await RecorderDriver.sendWithNoScreen(
                RecorderClient(host: Stub.host, transport: transport), store: store, now: row.request.start,
                sendPacket: {
                    events.put("packet")
                    return true
                })
        }

        let withNothing = await action()
        XCTAssertEqual(withNothing, .nothingWaiting)
        XCTAssertEqual(events.all, [], "a packet went out, or the recorder was asked, with nothing waiting")

        try await store.queue(row)
        let sending = await action()
        guard case .sent = sending else { return XCTFail("the round was not run: \(sending)") }
        XCTAssertEqual(Array(events.all.prefix(2)), ["packet", "description.xml"])
        XCTAssertEqual(events.all.filter { $0 == "packet" }.count, 1, "another packet went out")
        XCTAssertEqual(events.all.filter { $0 == "description.xml" }.count, 1, "the recorder was waited for")
        XCTAssertTrue(events.all.contains("ask"), "the action ended as it reached the recorder")
    }

    private static let held = "予約の登録中にレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "自動では送り直しません。予約一覧で確かめ、届いていなければ「もう一度送る」を選んでください。"
    private static let atACreate = SendingStop.silent(afterSending: true)
    private static let atARead = SendingStop.silent(afterSending: false)

    /// What a round with no screen tells, in the notification and in the Shortcuts action's answer. Nothing where
    /// it has no news: nothing at all, only what was held before, only a reservation the recorder was too busy
    /// for, or silence before anything was sent. Otherwise the queue's sentences, the device named in them or
    /// not as it is handed in.
    ///
    /// A round that stopped at silence at a reservation's create says that the reservation is held, in the
    /// sentence written on its row: alone when nothing else happened, and last after the other sentences, where
    /// the queue ends a round cut short with its clause that the rest goes the next time the recorder answers.
    /// That clause is not said then. After silence at a read it is, as the queue says it: nothing is held.
    func testWhatARoundWithNoScreenTellsEndsWithTheHeldSentenceAfterSilenceAtACreate() {
        let one = [pending("朝の番組", eventID: 1)], busy = [pending("昼の番組", eventID: 2)]
        let (held, atACreate, atARead) = (Self.held, Self.atACreate, Self.atARead)
        let clause = "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります"
        let sent = "送信待ちだった「朝の番組」を登録しました", sentTo = "送信待ちだった「朝の番組」をレコーダーに登録しました"
        let passedOver = "「昼の番組」は送れなかったため、次の機会にもう一度送ります"
        let passedOverTo = "「昼の番組」はレコーダーに送れなかったため、次の機会にもう一度送ります"
        typealias Outcome = PendingQueue.Outcome
        let rounds: [(name: String, outcome: Outcome, unnamed: String?, named: String?)] = [
            ("nothing", Outcome(slot: .recorder), nil, nil),
            ("only what was held before", Outcome(slot: .recorder, held: one), nil, nil),
            ("only one passed over", Outcome(slot: .recorder, deferred: busy), nil, nil),
            ("silence at a read alone", Outcome(slot: .recorder, stopped: atARead), nil, nil),
            ("one passed over, then silence at a read", Outcome(slot: .recorder, deferred: busy, stopped: atARead),
             nil, nil),
            ("sent", Outcome(slot: .recorder, sent: one), sent, sentTo),
            ("found there already", Outcome(slot: .recorder, alreadyThere: one),
             "「朝の番組」はすでに予約されていました", "「朝の番組」はレコーダーにすでに予約がありました"),
            ("over", Outcome(slot: .recorder, expired: one),
             "「朝の番組」は放送が終わっていたため、送らずに削除しました",
             "レコーダー宛の「朝の番組」は放送が終わっていたため、送らずに削除しました"),
            ("refused now", Outcome(slot: .recorder, refused: one),
             "「朝の番組」はレコーダーが受け付けませんでした。理由は予約タブにあります",
             "「朝の番組」はレコーダーに登録できませんでした。理由は予約タブにあります"),
            ("sent, and one passed over", Outcome(slot: .recorder, sent: one, deferred: busy),
             sent + "。" + passedOver, sentTo + "。" + passedOverTo),
            ("sent, then silence at a read", Outcome(slot: .recorder, sent: one, stopped: atARead),
             sent + "。" + clause, sentTo + "。" + clause),
            ("sent, then the list could not say", Outcome(slot: .recorder, sent: one,
                                                         stopped: .notKnownThere(listRead: true)), sent, sentTo),
            ("silence at a create alone", Outcome(slot: .recorder, stopped: atACreate), held, held),
            ("held before, then silence at a create", Outcome(slot: .recorder, held: one, stopped: atACreate),
             held, held),
            ("sent, then silence at a create", Outcome(slot: .recorder, sent: one, stopped: atACreate),
             sent + "。" + held, sentTo + "。" + held),
            ("one passed over, then silence at a create",
             Outcome(slot: .recorder, deferred: busy, stopped: atACreate),
             passedOver + "。" + held, passedOverTo + "。" + held),
        ]
        for round in rounds {
            XCTAssertEqual(RecorderDriver.tells(round.outcome, naming: nil), round.unnamed, round.name)
            XCTAssertEqual(RecorderDriver.tells(round.outcome, naming: "レコーダー"), round.named, round.name)
        }
        XCTAssertEqual(RecorderDriver.heldAfterSilence, held, "the sentence written on the rows is another")
    }

    /// A round with news that passed over a reservation held after silence at an earlier create ends by saying
    /// how many such there are, and to look at the list: what is told of it takes the place of what the earlier
    /// round told, which said that the reservation is held. One, and two. Counted by the reason on the row, as
    /// it is matched there: a row passed over for another reason is not counted, and with only such rows
    /// nothing is added. Last, after the queue's clause for a round cut short at a read. The recorder is named
    /// in it whether the queue's sentences name a device or not.
    ///
    /// Not with no news -- only such a row passed over, or that and a reservation the recorder was too busy
    /// for, or silence at a read -- where nothing is told. Not of a row the round found on the recorder, which
    /// is held no longer: found there, it is said as found, and only what is still passed over is counted. And
    /// not by a round that itself stopped at silence at a create, with such a row behind it: the sentence
    /// written on the row says that a reservation is held, and is said once.
    ///
    /// The Shortcuts action answers with what the round tells, so it says the same; of a round with no news
    /// and such a row it says what it said.
    func testARoundWithNewsEndsBySayingHowManyReservationsAreStillHeldAfterSilenceAtAnEarlierCreate() {
        let one = [pending("朝の番組", eventID: 1)], busy = [pending("昼の番組", eventID: 2)]
        let before = [pending("夜の番組", eventID: 3, problem: RecorderDriver.heldAfterSilence)]
        let another = [pending("深夜の番組", eventID: 4, problem: RecorderDriver.heldAfterSilence)]
        let refused = [pending("夕方の番組", eventID: 5, problem: "前に断られた理由")]
        let forAnother = [pending("早朝の番組", eventID: 6, problem: RecorderDriver.heldForAnotherRecorder)]
        let (held, atACreate, atARead) = (Self.held, Self.atACreate, Self.atARead)
        func still(_ count: Int) -> String { "レコーダーに届いたか確かめていない予約が \(count) 件あります。予約一覧で確かめてください" }
        let clause = "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります"
        let sent = "送信待ちだった「朝の番組」を登録しました", sentTo = "送信待ちだった「朝の番組」をレコーダーに登録しました"
        let found = "「夜の番組」はすでに予約されていました", foundOn = "「夜の番組」はレコーダーにすでに予約がありました"
        let passedOver = "「昼の番組」は送れなかったため、次の機会にもう一度送ります"
        typealias Outcome = PendingQueue.Outcome
        let rounds: [(name: String, outcome: Outcome, unnamed: String?, named: String?)] = [
            ("sent, one held after silence passed over", Outcome(slot: .recorder, sent: one, held: before),
             sent + "。" + still(1), sentTo + "。" + still(1)),
            ("sent, two passed over", Outcome(slot: .recorder, sent: one, held: before + another),
             sent + "。" + still(2), sentTo + "。" + still(2)),
            ("sent, one held for other reasons passed over", Outcome(slot: .recorder, sent: one, held: refused),
             sent, sentTo),
            ("sent, one held for another recorder passed over",
             Outcome(slot: .recorder, sent: one, held: forAnother), sent, sentTo),
            ("sent, one of each passed over",
             Outcome(slot: .recorder, sent: one, held: refused + before + forAnother),
             sent + "。" + still(1), sentTo + "。" + still(1)),
            ("sent, then silence at a read, one passed over",
             Outcome(slot: .recorder, sent: one, held: before, stopped: atARead),
             sent + "。" + clause + "。" + still(1), sentTo + "。" + clause + "。" + still(1)),
            ("only one passed over", Outcome(slot: .recorder, held: before), nil, nil),
            ("one the recorder was too busy for, one passed over",
             Outcome(slot: .recorder, deferred: busy, held: before), nil, nil),
            ("silence at a read, one passed over", Outcome(slot: .recorder, held: before, stopped: atARead),
             nil, nil),
            ("the one held found on the recorder", Outcome(slot: .recorder, alreadyThere: before), found, foundOn),
            ("one found on the recorder, another passed over",
             Outcome(slot: .recorder, held: another, alreadyThere: before),
             found + "。" + still(1), foundOn + "。" + still(1)),
            ("silence at a create, one passed over", Outcome(slot: .recorder, held: before, stopped: atACreate),
             held, held),
            ("sent, then silence at a create, one passed over",
             Outcome(slot: .recorder, sent: one, held: before, stopped: atACreate),
             sent + "。" + held, sentTo + "。" + held),
        ]
        for round in rounds {
            XCTAssertEqual(RecorderDriver.tells(round.outcome, naming: nil), round.unnamed, round.name)
            XCTAssertEqual(RecorderDriver.tells(round.outcome, naming: "レコーダー"), round.named, round.name)
        }
        XCTAssertEqual(RecorderDriver.says(.sent(Outcome(slot: .recorder, sent: one, held: before)), naming: nil),
                       sent + "。" + still(1), "the action's answer")
        XCTAssertNil(RecorderDriver.says(.sent(Outcome(slot: .recorder, held: before)), naming: nil),
                     "the action's answer for a round with no news")
        XCTAssertEqual(RecorderDriver.says(.sent(Outcome(slot: .recorder, deferred: busy, held: before)), naming: nil),
                       passedOver, "the action's answer for a round with no news and a reservation passed over")
    }

    /// The Shortcuts action's answer for a round is what the round tells. A round with no news is still
    /// answered for whoever ran the action: a reservation the recorder was too busy for as the queue says it,
    /// silence before anything was sent as what waits being left as it is, and nothing where nothing happened.
    func testTheActionsAnswerForARoundIsWhatItTellsAndWhatTheQueueSaysOfOneWithNoNews() {
        let busy = [pending("昼の番組", eventID: 2)]
        typealias Outcome = PendingQueue.Outcome
        let answers: [(name: String, outcome: Outcome, said: String?)] = [
            ("nothing", Outcome(slot: .recorder), nil),
            ("sent", Outcome(slot: .recorder, sent: [pending("朝の番組", eventID: 1)]),
             "送信待ちだった「朝の番組」を登録しました"),
            ("only one passed over", Outcome(slot: .recorder, deferred: busy),
             "「昼の番組」は送れなかったため、次の機会にもう一度送ります"),
            ("silence at a read alone", Outcome(slot: .recorder, stopped: Self.atARead),
             "途中でレコーダーの応答がなくなりました。送信待ちの予約はそのまま残しています。"),
            ("silence at a create alone", Outcome(slot: .recorder, stopped: Self.atACreate), Self.held),
            ("one passed over, then silence at a create",
             Outcome(slot: .recorder, deferred: busy, stopped: Self.atACreate),
             "「昼の番組」は送れなかったため、次の機会にもう一度送ります。" + Self.held),
        ]
        for answer in answers {
            XCTAssertEqual(RecorderDriver.says(.sent(answer.outcome), naming: nil), answer.said, answer.name)
        }
    }

    // MARK: - told once

    /// Eight in the evening in Japan on Sunday 1 November 2026, and the next overnight run, at two.
    private static let now = Date(timeIntervalSince1970: 1_793_530_800)
    private static let nextRun = Date(timeIntervalSince1970: 1_793_552_400)

    private static let notAnswering = "レコーダーが応答しないため送っていません。次にレコーダーが答えたときに送ります"
    private static let another = "これまでとは別のレコーダーが応答したため、送信待ちの予約はそのまま残しています。"
        + "アプリを開いて確かめてください。"

    /// The first sentence of the notice of reservations not yet at the recorder, for one and so many more.
    private static func notYet(_ title: String, at start: String, andOthers others: Int = 0) -> String {
        "レコーダーにまだ届いていない予約があります（「\(title)」\(start) から\(others > 0 ? "、ほか \(others) 件" : "")）。"
    }

    /// A reservation waiting for the recorder unless said, an hour long, starting `minutes` after eight that
    /// evening.
    private func row(_ title: String, _ programme: Int, at minutes: Double, reason: String? = nil,
                     target: DeviceSlot = .recorder) -> PendingReservation {
        pending(title, eventID: programme, start: Self.now + minutes * 60, problem: reason, target: target)
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

    /// The runs one after another from `told`, each held to what it is to tell in the recorder's words, the
    /// queue's sentences naming `device`. What is told after the last.
    ///
    /// Told with the process's time zone set to one that is not Japan's, as the television's are: a start is
    /// written out in Japan's whatever the machine's is.
    @discardableResult
    private func tell(_ runs: [Run], from told: TVTold = TVTold(), naming device: String? = nil) -> TVTold {
        let zone = NSTimeZone.default
        NSTimeZone.default = .gmt
        defer { NSTimeZone.default = zone }
        var told = told
        for run in runs {
            let (notices, next) = told.after(run.sending, waiting: run.waiting, before: Self.nextRun, now: Self.now,
                                             naming: device, words: .recorder)
            XCTAssertEqual(notices, TVNotices(queue: run.queue, notYet: run.notYet, withdrawsNotYet: run.withdraws),
                           run.name)
            told = next
        }
        return told
    }

    /// A reservation that starts before the next overnight run and has not reached the recorder is told once,
    /// by the run that first finds it so, in a notice of its own: the recorder's first sentence, and what stands
    /// in its way -- here nobody reached, so that it goes the next time the recorder answers. Not again while it
    /// is still late. With a second late one both are told, the earlier first. The notice is taken away by the
    /// first run that finds none of its reservations waiting, here the round that made them, and there is
    /// nothing to take away after that. A queue that could not be read tells nothing and takes nothing away.
    func testAReservationDueBeforeTheNextNightIsToldOnceAndTheNoticeGoesOnceItHasGone() {
        let theatre = row("サンプル劇場", 0x3101, at: 60), journey = row("サンプル紀行", 0x3102, at: 210)
        let both = tell([
            Run(name: "nobody reached", sending: .unreachable, waiting: [theatre],
                notYet: Self.notYet("サンプル劇場", at: "21:00") + Self.notAnswering),
            Run(name: "nobody reached again", sending: .unreachable, waiting: [theatre]),
            Run(name: "a second late one", sending: .unreachable, waiting: [theatre, journey],
                notYet: Self.notYet("サンプル劇場", at: "21:00", andOthers: 1) + Self.notAnswering),
            Run(name: "a queue that could not be read", sending: .unreachable, waiting: nil),
        ])
        XCTAssertEqual(both, TVTold(rows: [theatre.id, journey.id]))
        let gone = tell([
            Run(name: "both made", sending: .sent(PendingQueue.Outcome(slot: .recorder, sent: [theatre, journey])),
                waiting: [], queue: "送信待ちだった「サンプル劇場」ほか 1 件を登録しました", withdraws: true),
            Run(name: "nothing to take away", sending: .nothingWaiting, waiting: []),
        ], from: both)
        XCTAssertEqual(gone, TVTold())

        tell([Run(name: "after midnight", sending: .unreachable, waiting: [row("サンプル深夜便", 0x3109, at: 330)],
                  notYet: Self.notYet("サンプル深夜便", at: "1:30") + Self.notAnswering)])
        tell([Run(name: "on air", sending: .unreachable, waiting: [row("サンプル中継", 0x3107, at: -30)],
                  notYet: Self.notYet("サンプル中継", at: "19:30") + Self.notAnswering)])
    }

    /// Only a reservation that still waits to go to the recorder before the next run is late. Never told: one
    /// that starts at the next run or after it; one that carries a reason -- refused before, held after silence
    /// at its create, held for another recorder -- which waits for the reader; the television's; one whose
    /// programme is over. Nor one this round made or found on the recorder that the queue read after it still
    /// holds.
    func testAReservationWithAReasonOrOverOrLaterOrTheTelevisionsOrMadeByThisRunIsNotLate() {
        let never = [row("サンプル天気", 0x3103, at: 360), row("サンプル体操", 0x3104, at: 420),
                     row("サンプル映画", 0x3105, at: 120, reason: "前に断られた理由"),
                     row("サンプル寄席", 0x3110, at: 120, reason: Self.held),
                     row("サンプル音楽館", 0x3111, at: 120, reason: RecorderDriver.heldForAnotherRecorder),
                     row("サンプル討論", 0x3106, at: 120, target: .tv), row("サンプル朝市", 0x3108, at: -120)]
        let none = tell([Run(name: "never late", sending: .unreachable, waiting: never)])
        XCTAssertEqual(none, TVTold())

        let theatre = row("サンプル劇場", 0x3101, at: 60), journey = row("サンプル紀行", 0x3102, at: 210)
        tell([Run(name: "made, still read as waiting",
                  sending: .sent(PendingQueue.Outcome(slot: .recorder, sent: [theatre])), waiting: [theatre],
                  queue: "送信待ちだった「サンプル劇場」を登録しました"),
              Run(name: "found there, still read as waiting",
                  sending: .sent(PendingQueue.Outcome(slot: .recorder, alreadyThere: [journey])), waiting: [journey],
                  queue: "「サンプル紀行」はすでに予約されていました")])
    }

    /// What stands in a late reservation's way, by what the run came to. Another recorder: the sentence said
    /// of one with no screen, in the notice and not beside it. Nobody reached, and a round that stopped at
    /// silence: the recorder is not answering. At a create too, where the reservation whose create it was is
    /// held with its reason and is not late, and the one behind it is: the notice is of that one, beside the
    /// round's own telling that a reservation is held. A round that went through and left one waiting, the
    /// recorder having been too busy for it: nothing known stands in its way, and opening the app sends it.
    func testALateReservationIsToldWithWhatStandsInItsWay() {
        let theatre = row("サンプル劇場", 0x3101, at: 60)
        let first = Self.notYet("サンプル劇場", at: "21:00")
        let told = tell([Run(name: "another recorder", sending: .anotherAnswered, waiting: [theatre],
                             notYet: first + Self.another)])
        XCTAssertEqual(told, TVTold(stop: .another, rows: [theatre.id]))
        tell([Run(name: "silent at the read that opens the round",
                  sending: .sent(PendingQueue.Outcome(slot: .recorder, stopped: .silent(afterSending: false))),
                  waiting: [theatre], notYet: first + Self.notAnswering)])
        let held = row("サンプル寄席", 0x3110, at: 30, reason: Self.held)
        tell([Run(name: "silent at a create, one behind it",
                  sending: .sent(PendingQueue.Outcome(slot: .recorder, stopped: .silent(afterSending: true))),
                  waiting: [held, theatre], queue: Self.held, notYet: first + Self.notAnswering)])
        tell([Run(name: "passed over", sending: .sent(PendingQueue.Outcome(slot: .recorder, deferred: [theatre])),
                  waiting: [theatre], notYet: first + "アプリを開くと送ります")])
    }

    /// That another recorder answered is told once: by the run that first finds it, and not by the next. A run
    /// that reached nobody in between leaves it told. It is told again after a run with nothing waiting, which
    /// forgets it -- a stranger with nothing waiting is told of by nothing -- and after a round, which the
    /// recorder known answered. The reservation here starts after the next run, so no notice carries the stop.
    func testAnotherRecorderAnsweringIsToldOnceUntilSomethingHasChanged() {
        let morning = row("サンプル天気", 0x3103, at: 420)
        let stranger = Run(name: "another recorder", sending: .anotherAnswered, waiting: [morning],
                           queue: Self.another)
        let again = Run(name: "another recorder again", sending: .anotherAnswered, waiting: [morning])

        XCTAssertEqual(tell([stranger, again]), TVTold(stop: .another))
        XCTAssertEqual(tell([stranger, Run(name: "nobody reached", sending: .unreachable, waiting: [morning]), again]),
                       TVTold(stop: .another))
        let forgotten = tell([stranger, Run(name: "a stranger, nothing waiting", sending: .nothingWaiting)])
        XCTAssertEqual(forgotten, TVTold(), "the stop told was kept over a run with nothing waiting")
        tell([stranger], from: forgotten)
        let went = PendingQueue.Outcome(slot: .recorder, sent: [row("サンプル劇場", 0x3101, at: 60)])
        tell([stranger,
              Run(name: "a round", sending: .sent(went), waiting: [morning],
                  queue: "送信待ちだった「サンプル劇場」を登録しました"),
              stranger])
    }

    /// What is told of a round is what a round with no screen tells (`RecorderDriver.tells`), and not the
    /// television's rule: the device is named only where a word for it is handed in; a round that stopped at
    /// silence at a create says that the reservation is held, after what else it has to say and also beside a
    /// late notice; of one with news that passed over a reservation held before, whatever that function says
    /// of it, which is asked here and not written out; and one with no news tells nothing.
    func testWhatIsToldOfARoundIsWhatARoundWithNoScreenTells() {
        let theatre = row("サンプル劇場", 0x3101, at: 60)
        let held = row("サンプル寄席", 0x3110, at: 30, reason: Self.held)
        typealias Outcome = PendingQueue.Outcome
        let sent = Run(name: "sent", sending: .sent(Outcome(slot: .recorder, sent: [theatre])),
                       queue: "送信待ちだった「サンプル劇場」を登録しました")
        tell([sent])
        tell([Run(name: "sent, the recorder named", sending: sent.sending,
                  queue: "送信待ちだった「サンプル劇場」をレコーダーに登録しました")], naming: "レコーダー")
        tell([Run(name: "sent, then silent at a create",
                  sending: .sent(Outcome(slot: .recorder, sent: [theatre], stopped: .silent(afterSending: true))),
                  queue: "送信待ちだった「サンプル劇場」を登録しました。" + Self.held)])
        let passedOver = Outcome(slot: .recorder, sent: [theatre], held: [held])
        tell([Run(name: "sent, one held before passed over", sending: .sent(passedOver), waiting: [held],
                  queue: RecorderDriver.tells(passedOver, naming: nil))])
        tell([Run(name: "only one passed over", sending: .sent(Outcome(slot: .recorder, deferred: [theatre])),
                  waiting: [])])
    }

    /// A sending of the screens' own takes the recorder's late notice away once none of the reservations it
    /// told of waits to go -- gone, held with a reason, or over -- and they are told of no more; the stop told
    /// stays. While one of them still waits nothing changes. The reservations are the recorder's: a television's
    /// row that waits does not keep the notice.
    func testTheScreensSendingTakesTheRecordersLateNoticeAwayOnceNoneOfItsReservationsWaits() {
        let theatre = row("サンプル劇場", 0x3101, at: 60), journey = row("サンプル紀行", 0x3102, at: 210)
        let told = TVTold(stop: .another, rows: [theatre.id])
        let held = row("サンプル劇場", 0x3101, at: 60, reason: RecorderDriver.heldForAnotherRecorder)
        let over = row("サンプル劇場", 0x3101, at: -120)
        let televisions = row("サンプル劇場", 0x3101, at: 60, target: .tv)
        let cases: [(String, [PendingReservation], TVTold?)] = [
            ("still waiting", [theatre, journey], nil),
            ("sent", [journey, televisions], TVTold(stop: .another)),
            ("held with a reason", [held], TVTold(stop: .another)),
            ("over", [over], TVTold(stop: .another)),
        ]
        for (name, waiting, after) in cases {
            XCTAssertEqual(told.afterTheScreensSent(waiting: waiting, now: Self.now, words: .recorder), after, name)
        }
        XCTAssertNil(TVTold(stop: .another).afterTheScreensSent(waiting: [], now: Self.now, words: .recorder),
                     "none told of")
    }
}
