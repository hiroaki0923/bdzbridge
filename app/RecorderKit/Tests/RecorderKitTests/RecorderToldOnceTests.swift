import Foundation
import RecorderKit
import XCTest

/// What the recorder's runs with no screen tell once, through the two runs themselves
/// (`RecorderDriver.refreshWithNoScreen`, `sendWithNoScreen`): that another recorder answered, and a
/// reservation that starts before the next overnight run and has not reached the recorder. The rule is the
/// television's, handed the recorder's words, and is held across runs in `NoScreenReachTests`; here, that each
/// run settles what its sending came to before the rule is asked, hands over what it tells where it should, and
/// keeps it back once the time is up or the cache is another recorder's. Every value is invented.
///
/// On the main actor, as the app's tests are: a failure recorded off it by the last assertion of an async test
/// has been seen to go unrecorded, the test ending with one failure fewer than it had.
@MainActor
final class RecorderToldOnceTests: XCTestCase {
    private static let notAnswering = "レコーダーが応答しないため送っていません。次にレコーダーが答えたときに送ります"
    private static let another = "これまでとは別のレコーダーが応答したため、送信待ちの予約はそのまま残しています。"
        + "アプリを開いて確かめてください。"
    private static let heldAfterSilence = "予約の登録中にレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "自動では送り直しません。予約一覧で確かめ、届いていなければ「もう一度送る」を選んでください。"

    /// The notice's first sentence for one reservation and so many more.
    private static func notYet(_ title: String, at start: String, andOthers others: Int = 0) -> String {
        "レコーダーにまだ届いていない予約があります（「\(title)」\(start) から\(others > 0 ? "、ほか \(others) 件" : "")）。"
    }

    /// A second recorder's name, beside the first's, which the vectors' recorder carries, and a third's.
    private static let stranger = "uuid:00000000-0000-0000-0000-f84e17000002"
    private static let third = "uuid:00000000-0000-0000-0000-f84e17000003"

    /// Half past noon in Japan on 18 May 2033, when the reservation of these runs starts, and the overnight run
    /// asked for next, which is put an hour after it or an hour before it: no run here is told the time, and at
    /// any hour it is run the reservation is not over.
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)
    private static let afterIt = start + 3600, beforeIt = start - 3600

    /// What the runs' notice says of the one reservation.
    private static let late = notYet("サンプル劇場", at: "12:33")

    /// What a night handed over, in order.
    private enum Handed: Equatable {
        case heldBack, queue, told(notYet: String?, withdraws: Bool, kept: ToldOnce), somethingElse
    }

    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Handed] = []
        func put(_ what: Handed) { lock.withLock { list.append(what) } }
        var all: [Handed] { lock.withLock { list } }
    }

    /// A recorder of the vectors under `udn`, or its own name: it says who it is, gives an empty list of
    /// reservations, takes every reservation, and refuses everything else, as a night's slot, free space and
    /// guide are refused here. `silent`: nothing answers. `atACreate` is run as each create arrives, and
    /// `whenAsked` as anything is asked of it, before it answers or does not.
    private func recorder(_ udn: String? = nil, silent: Bool = false,
                          whenAsked: @escaping @Sendable () async -> Void = {},
                          atACreate: @escaping @Sendable () async -> Void = {}) throws -> StubTransport {
        let description = try Vectors.descriptionXML(udn: udn)
        let made = Stub.soap("X_CreateRecordSchedule", extra: "<RecordScheduleID>0x1</RecordScheduleID>")
        return StubTransport { request, _ in
            await whenAsked()
            if silent { throw RecorderError.transport("The request timed out.") }
            if request.url.lastPathComponent == "description.xml" {
                return HTTPResponse(statusCode: 200, body: Data(description.utf8))
            }
            let action = request.headers["SOAPACTION"] ?? ""
            if action.contains("X_CreateRecordSchedule") {
                await atACreate()
                return made
            }
            return action.contains("X_GetRecordScheduleList") ? made : HTTPResponse(statusCode: 500, body: Data())
        }
    }

    /// A cache the first recorder has claimed, with `rows` waiting in it.
    private func cache(_ rows: [PendingReservation] = []) async throws -> GuideStore {
        let store = try temporaryStore()
        try await store.claim(for: RecorderClient(host: Stub.host, transport: recorder()).describe())
        for row in rows { try await store.queue(row) }
        return store
    }

    /// A night from `told` with the next run at `nextRun`, no packet out: what it handed over. `packet` is run
    /// where its packet would go, and `each` as each thing is handed over, both in the night's own task.
    private static func night(_ transport: StubTransport, _ store: GuideStore,
                              from told: ToldOnce = ToldOnce(),
                              before nextRun: Date? = RecorderToldOnceTests.afterIt,
                              packet: @escaping @Sendable () -> Void = {},
                              each: @escaping @Sendable (Handed) async -> Void = { _ in }) async -> [Handed] {
        let record = Record()
        _ = await RecorderDriver.refreshWithNoScreen(
            RecorderClient(host: Stub.host, transport: transport), store: store, told: { told }, nextRun: nextRun,
            sendPacket: {
                packet()
                return false
            }, found: { found in
                let handed: Handed = switch found {
                case .heldBack: .heldBack
                case .queue: .queue
                case .told(let notYet, let withdraws, let kept): .told(notYet: notYet, withdraws: withdraws, kept: kept)
                default: .somethingElse
                }
                record.put(handed)
                await each(handed)
            })
        return record.all
    }

    /// The Shortcuts action's sending from `told`, no packet out, at the moment the reservation starts.
    private static func action(_ transport: StubTransport, _ store: GuideStore,
                               from told: ToldOnce = ToldOnce(),
                               before nextRun: Date? = RecorderToldOnceTests.afterIt,
                               packet: @escaping @Sendable () -> Void = {}) async
        -> (sending: NoScreenSending, told: NoScreenTold) {
        await RecorderDriver.sendWithNoScreen(
            RecorderClient(host: Stub.host, transport: transport), store: store, told: { told }, nextRun: nextRun,
            now: Self.start, sendPacket: {
                packet()
                return false
            }, tell: { _, _ in })
    }

    /// A night that reaches nobody, with a reservation waiting that starts before the next: it hands over what
    /// is told once -- the notice, that the recorder is not answering, and the reservation as told of -- and
    /// nothing else. The next such night, handed what the first kept, hands over no notice. And the night after
    /// the reservation has gone from the queue takes the notice away. So the Shortcuts action, whose sending
    /// comes to nobody reached, and to nothing waiting once the reservation has gone.
    ///
    /// With no next run handed in neither tells any of it.
    func testARunThatReachesNobodyTellsOnceOfAReservationDueBeforeTheNextNight() async throws {
        let theatre = pending("サンプル劇場", eventID: 0x3101, start: Self.start)
        let store = try await cache([theatre])
        let nobody = try recorder(silent: true)
        let kept = ToldOnce(rows: [theatre.id])
        let notice = Self.late + Self.notAnswering

        var handed = await Self.night(nobody, store)
        XCTAssertEqual(handed, [.told(notYet: notice, withdraws: false, kept: kept)])
        handed = await Self.night(nobody, store, from: kept)
        XCTAssertEqual(handed, [.told(notYet: nil, withdraws: false, kept: kept)], "told a second time")
        handed = await Self.night(nobody, store, before: nil)
        XCTAssertEqual(handed, [], "with no next run")

        var acted = await Self.action(nobody, store)
        XCTAssertEqual(acted.sending, .unreachable)
        XCTAssertEqual(acted.told, NoScreenTold(notYet: notice, kept: kept))
        acted = await Self.action(nobody, store, from: kept)
        XCTAssertEqual(acted.told, NoScreenTold(kept: kept), "told a second time")
        acted = await Self.action(nobody, store, before: nil)
        XCTAssertEqual(acted.told, NoScreenTold(), "with no next run")
        acted = await Self.action(nobody, store, before: Self.beforeIt)
        XCTAssertEqual(acted.told, NoScreenTold(kept: ToldOnce()), "a reservation that starts after the next run")

        try await store.removePending(theatre.id)
        handed = await Self.night(nobody, store, from: kept)
        XCTAssertEqual(handed, [.told(notYet: nil, withdraws: true, kept: ToldOnce())])
        let asked = await nobody.requests.count
        acted = await Self.action(nobody, store, from: kept)
        XCTAssertEqual(acted.sending, .nothingWaiting)
        XCTAssertEqual(acted.told, NoScreenTold(withdrawsNotYet: true, kept: ToldOnce()))
        expectEqual(await nobody.requests.count, asked, "the recorder was asked with nothing waiting")
    }

    /// A run answered by another recorder than the cache's, a reservation waiting that starts after the next
    /// run: that the queue was held back is handed over, and then what is told once, which keeps that it was
    /// said. The next such run, handed that, hands over nothing of the queue. With a reservation that starts
    /// before the next run, the notice carries the sentence and the queue's telling is not handed over beside
    /// it. And a night answered by a stranger with nothing waiting that would go tells nothing, and forgets
    /// what was told: a stranger is told of only when something waits.
    ///
    /// With no next run handed in, that the queue was held back is handed over each time, as it has been.
    func testAnotherRecorderAnsweringIsHandedOverOnceAndNotWithNothingWaiting() async throws {
        let theatre = pending("サンプル劇場", eventID: 0x3101, start: Self.start)
        let store = try await cache([theatre])
        let stranger = try recorder(Self.stranger)
        let said = ToldOnce(stop: .another)

        var handed = await Self.night(stranger, store, before: Self.beforeIt)
        XCTAssertEqual(handed, [.heldBack, .told(notYet: nil, withdraws: false, kept: said)])
        handed = await Self.night(stranger, store, from: said, before: Self.beforeIt)
        XCTAssertEqual(handed, [.told(notYet: nil, withdraws: false, kept: said)], "told a second time")
        handed = await Self.night(stranger, store, from: said, before: nil)
        XCTAssertEqual(handed, [.heldBack], "with no next run")

        var acted = await Self.action(stranger, store, before: Self.beforeIt)
        XCTAssertEqual(acted.sending, .anotherAnswered)
        XCTAssertEqual(acted.told, NoScreenTold(heldBackIsNews: true, kept: said))
        acted = await Self.action(stranger, store, from: said, before: Self.beforeIt)
        XCTAssertEqual(acted.told, NoScreenTold(kept: said), "told a second time")
        acted = await Self.action(stranger, store, from: said, before: nil)
        XCTAssertEqual(acted.told, NoScreenTold(heldBackIsNews: true), "with no next run")

        let late = ToldOnce(stop: .another, rows: [theatre.id])
        handed = await Self.night(stranger, store)
        XCTAssertEqual(handed, [.told(notYet: Self.late + Self.another, withdraws: false, kept: late)])
        acted = await Self.action(stranger, store)
        XCTAssertEqual(acted.told, NoScreenTold(notYet: Self.late + Self.another, kept: late))

        // Held for the reader now: nothing waits that would go.
        try await store.setPendingProblem(theatre.id, "前に断られた理由")
        handed = await Self.night(stranger, store, from: late)
        XCTAssertEqual(handed, [.told(notYet: nil, withdraws: true, kept: ToldOnce())],
                       "a stranger with nothing waiting")
        handed = await Self.night(stranger, store, from: late, before: nil)
        XCTAssertEqual(handed, [], "a stranger with nothing waiting, and no next run")
        expectEqual(try await store.pendingReservations().map(\.problem), ["前に断られた理由"])
    }

    /// A night whose round ran hands over what became of the queue and then what is told once, ahead of
    /// whatever it finds next. Of two reservations the first's create meets silence here, by the test's own
    /// doing: that one is held with its reason, and the one behind it, which starts before the next run, is
    /// told as not having reached a recorder that is not answering. So the action hands it back.
    func testARoundThatMetSilenceIsToldAndThenTheReservationBehindItThatIsDue() async throws {
        let first = pending("サンプル寄席", eventID: 0x3110, start: Self.start - 1800)
        let theatre = pending("サンプル劇場", eventID: 0x3101, start: Self.start)
        let kept = ToldOnce(rows: [theatre.id])
        for run in ["the night", "the action"] {
            let store = try await cache([first, theatre])
            let description = try Vectors.descriptionXML()
            let transport = StubTransport { request, _ in
                if request.url.lastPathComponent == "description.xml" {
                    return HTTPResponse(statusCode: 200, body: Data(description.utf8))
                }
                guard (request.headers["SOAPACTION"] ?? "").contains("X_GetRecordScheduleList") else {
                    throw RecorderError.transport("The request timed out.")
                }
                return Stub.soap("X_GetRecordScheduleList")
            }
            if run == "the night" {
                let handed = await Self.night(transport, store)
                XCTAssertEqual(handed, [.queue, .told(notYet: Self.late + Self.notAnswering, withdraws: false,
                                                      kept: kept)])
            } else {
                let acted = await Self.action(transport, store)
                XCTAssertEqual(acted.told, NoScreenTold(notYet: Self.late + Self.notAnswering, kept: kept))
            }
            expectEqual(try await store.pendingReservations().map(\.problem), [Self.heldAfterSilence, nil], run)
        }
    }

    /// A night whose round went through hands over what became of the queue and then what is told once, and
    /// goes on: here the reservation is made, nothing is late, the stop told before is forgotten -- the
    /// recorder known has answered -- and the night asks for the slot, the free space and the guide, each
    /// refused, so that nothing more is handed over.
    func testWhatIsToldOnceIsHandedOverRightAfterWhatBecameOfTheQueue() async throws {
        let store = try await cache([pending("サンプル劇場", eventID: 0x3101, start: Self.start)])
        let transport = try recorder()
        let handed = await Self.night(transport, store, from: ToldOnce(stop: .another))
        XCTAssertEqual(handed, [.queue, .told(notYet: nil, withdraws: false, kept: ToldOnce())])
        expectTrue(await transport.requests.count > 3, "the night ended at what it told once")
    }

    /// Nothing of what is told once is handed over, and so nothing kept, by a run whose time is up, nor by one
    /// that finds the cache another recorder's after its round.
    ///
    /// The time up as the packet would go, nobody answering: nothing. So with another recorder answering. The
    /// time up as what became of the queue is told: nothing after that, and so with the cache made over to
    /// another recorder just then, as the screens make it over. The cache made over while the reservation is
    /// being made: it goes, its request being out, and the night hands over nothing at all. The
    /// Shortcuts action, cancelled the same way or over a cache made over the same way, hands back its sending
    /// with no notice and nothing to keep; that another recorder answered it still says, as it says what its
    /// sending came to whatever its task says -- unless that was what was told last -- and says again the next
    /// time, nothing having been kept.
    ///
    /// Another recorder answering a night, with a reservation that starts after the next run, so that the queue
    /// held back is news and is handed over first: nothing of what is told once after it, the time up as that
    /// is handed over, or the cache made over to another recorder just then.
    ///
    /// And a cache that no recorder had claimed as the run began, claimed for another recorder than the one
    /// that answers while what became of the queue is told, or while the reservation is being made: nothing
    /// of what is told once either. Whose cache it was as the run began cannot be said there, and it is what
    /// the recorder that answered says it is, held against the cache, that keeps the telling back.
    func testNothingIsToldOnceOrKeptOnceTheTimeIsUpOrTheCacheIsAnotherRecorders() async throws {
        let theatre = pending("サンプル劇場", eventID: 0x3101, start: Self.start)
        let cancel: @Sendable () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }

        var store = try await cache([theatre])
        let nobody = try recorder(silent: true)
        var handed = await Task { [store] in await Self.night(nobody, store, packet: cancel) }.value
        XCTAssertEqual(handed, [], "nobody reached, the time up")
        let cancelled = await Task { [store] in await Self.action(nobody, store, packet: cancel) }.value
        XCTAssertEqual(cancelled.sending, .unreachable)
        XCTAssertEqual(cancelled.told, NoScreenTold(), "the action cancelled, nobody reached")

        let stranger = try recorder(Self.stranger)
        handed = await Task { [store] in await Self.night(stranger, store, packet: cancel) }.value
        XCTAssertEqual(handed, [], "another recorder, the time up")
        let heldBack = await Task { [store] in await Self.action(stranger, store, packet: cancel) }.value
        XCTAssertEqual(heldBack.sending, .anotherAnswered)
        XCTAssertEqual(heldBack.told, NoScreenTold(heldBackIsNews: true), "the action cancelled, another recorder")
        let saidBefore = await Task { [store] in
            await Self.action(stranger, store, from: ToldOnce(stop: .another), packet: cancel)
        }.value
        XCTAssertEqual(saidBefore.told, NoScreenTold(), "the action cancelled, another recorder told of before")
        handed = await Task { [store] in
            await Self.night(stranger, store, before: Self.beforeIt, each: { if $0 == .heldBack { cancel() } })
        }.value
        XCTAssertEqual(handed, [.heldBack], "another recorder, the time up as the queue held back was told")

        let answers = try recorder()
        handed = await Task { [store] in
            await Self.night(answers, store, each: { if $0 == .queue { cancel() } })
        }.value
        XCTAssertEqual(handed, [.queue], "the time up as what became of the queue was told")

        let other = try await RecorderClient(host: Stub.host, transport: recorder(Self.stranger)).describe()
        store = try await cache([theatre])
        handed = await Self.night(try recorder(), store, each: { [store] handed in
            guard handed == .queue else { return }
            _ = try? await store.claim(for: other, holdingTheQueueWith: RecorderDriver.heldForAnotherRecorder)
        })
        XCTAssertEqual(handed, [.queue], "the cache another recorder's as what became of the queue was told")
        store = try await cache([theatre])
        handed = await Self.night(stranger, store, before: Self.beforeIt, each: { [store] handed in
            guard handed == .heldBack else { return }
            _ = try? await store.claim(for: other, holdingTheQueueWith: RecorderDriver.heldForAnotherRecorder)
        })
        XCTAssertEqual(handed, [.heldBack], "another recorder, the cache made over as the queue held back was told")
        expectEqual(try await store.owner(), Self.stranger, "the cache was meant to be made over")
        for (run, claimed) in [("the night", true), ("the action", true), ("the night", false), ("the action", false)] {
            let name = "\(run), \(claimed ? "the first recorder's cache" : "a cache nobody had claimed")"
            store = claimed ? try await cache([theatre]) : try temporaryStore()
            if !claimed { try await store.queue(theatre) }
            let made = store
            let transport = try recorder(atACreate: {
                _ = try? await made.claim(for: other, holdingTheQueueWith: RecorderDriver.heldForAnotherRecorder)
            })
            if run == "the night" {
                handed = await Self.night(transport, store)
                XCTAssertEqual(handed, [], "the cache another recorder's after the round: \(name)")
            } else {
                let acted = await Self.action(transport, store)
                guard case .sent(let outcome) = acted.sending else { return XCTFail("no round ran: \(acted.sending)") }
                XCTAssertEqual(outcome.sent.map(\.id), [theatre.id], name)
                XCTAssertEqual(acted.told, NoScreenTold(),
                               "the cache another recorder's after the action's round: \(name)")
            }
            expectEqual(try await store.owner(), Self.stranger, "the cache was meant to be another's: \(name)")
        }

        store = try temporaryStore()
        try await store.queue(theatre)
        handed = await Self.night(try recorder(), store, each: { [store] handed in
            guard handed == .queue else { return }
            _ = try? await store.claim(for: other, holdingTheQueueWith: RecorderDriver.heldForAnotherRecorder)
        })
        XCTAssertEqual(handed, [.queue], "a cache nobody had claimed, another recorder's as the queue was told")
    }

    /// Nor is anything of it handed over, or kept, once the cache is another recorder's than it was as the run
    /// began, by a run that has heard nothing to hold against the cache: whose cache it is is noted as each
    /// run begins. Made over here by the test's own recorder, from inside the request that asks it who it is,
    /// as the screens make a cache over when they take a recorder up while a run with no screen is out.
    ///
    /// Nobody reached, the request then meeting silence: the night hands over nothing, where it handed over
    /// what to keep of the recorder before, and the action hands back that nobody was reached with nothing to
    /// tell or to keep. The recorder the cache was made over to answering: the round is run, for the recorder
    /// the cache is of now -- nothing goes, the make-over having held what waited -- what became of the queue
    /// is handed over, and nothing of what is told once: what was told was told of the recorder before, and
    /// the night ends there. And another recorder answering than the one the cache was made over to: neither
    /// that the queue was held back nor anything else.
    ///
    /// A cache that no recorder had claimed as the run began keeps nothing back when the first one claims it
    /// meanwhile: whose it was cannot be said, and no other recorder is known to have taken it.
    func testNothingIsToldOnceOrKeptOnceTheCacheIsAnothersThanItWasAsTheRunBegan() async throws {
        let theatre = pending("サンプル劇場", eventID: 0x3101, start: Self.start)
        let told = ToldOnce(stop: .another, rows: [theatre.id])
        func describing(_ udn: String?) async throws -> RecorderDescription {
            try await RecorderClient(host: Stub.host, transport: recorder(udn)).describe()
        }
        let (second, third) = (try await describing(Self.stranger), try await describing(Self.third))
        /// A recorder that, as it is first asked anything, has the cache made over to `newcomer`.
        func madeOver(_ store: GuideStore, to newcomer: RecorderDescription, holding: Bool = true,
                      answering udn: String? = nil, silent: Bool = false) throws -> StubTransport {
            try recorder(udn, silent: silent, whenAsked: {
                let reason = holding ? RecorderDriver.heldForAnotherRecorder : nil
                _ = try? await store.claim(for: newcomer, holdingTheQueueWith: reason)
            })
        }

        var store = try await cache([theatre])
        var handed = await Self.night(try madeOver(store, to: second, silent: true), store, from: told)
        XCTAssertEqual(handed, [], "nobody reached, the cache made over meanwhile")
        expectEqual(try await store.owner(), Self.stranger, "the cache was meant to be made over")
        store = try await cache([theatre])
        var acted = await Self.action(try madeOver(store, to: second, silent: true), store, from: told)
        XCTAssertEqual(acted.sending, .unreachable)
        XCTAssertEqual(acted.told, NoScreenTold(), "the action, nobody reached, the cache made over meanwhile")

        store = try await cache([theatre])
        var transport = try madeOver(store, to: second, answering: Self.stranger)
        handed = await Self.night(transport, store, from: told)
        XCTAssertEqual(handed, [.queue], "the recorder the cache was made over to answering")
        expectEqual(await transport.requests.count, 1, "the night went on over a cache made over since it began")
        store = try await cache([theatre])
        acted = await Self.action(try madeOver(store, to: second, answering: Self.stranger), store, from: told)
        guard case .sent(let round) = acted.sending else { return XCTFail("no round ran: \(acted.sending)") }
        XCTAssertTrue(round.isEmpty, "something went, or was dropped, of what the make-over had held")
        XCTAssertEqual(acted.told, NoScreenTold(), "the action, the recorder the cache was made over to answering")

        store = try await cache([theatre])
        transport = try madeOver(store, to: third, holding: false, answering: Self.stranger)
        handed = await Self.night(transport, store, before: Self.beforeIt)
        XCTAssertEqual(handed, [], "another recorder answering than the one the cache was made over to")
        store = try await cache([theatre])
        transport = try madeOver(store, to: third, holding: false, answering: Self.stranger)
        acted = await Self.action(transport, store, before: Self.beforeIt)
        XCTAssertEqual(acted.sending, .anotherAnswered)
        XCTAssertEqual(acted.told, NoScreenTold(), "the action, another recorder answering than the one made over to")

        let first = try await describing(nil)
        let notice = Self.late + Self.notAnswering
        store = try temporaryStore()
        try await store.queue(theatre)
        handed = await Self.night(try madeOver(store, to: first, silent: true), store)
        XCTAssertEqual(handed, [.told(notYet: notice, withdraws: false, kept: ToldOnce(rows: [theatre.id]))],
                       "a cache nobody had claimed, claimed by the first meanwhile")
        expectEqual(try await store.owner(), first.udn, "the cache was meant to be claimed")
        store = try temporaryStore()
        try await store.queue(theatre)
        acted = await Self.action(try madeOver(store, to: first, silent: true), store)
        XCTAssertEqual(acted.told, NoScreenTold(notYet: notice, kept: ToldOnce(rows: [theatre.id])),
                       "the action, a cache nobody had claimed, claimed by the first meanwhile")
    }
}
