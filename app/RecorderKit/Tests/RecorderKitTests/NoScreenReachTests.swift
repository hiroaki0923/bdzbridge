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
}
