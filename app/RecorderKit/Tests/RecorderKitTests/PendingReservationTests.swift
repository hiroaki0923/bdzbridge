import XCTest
@testable import RecorderKit

/// The queue of reservations made while the recorder could not be reached.
final class PendingReservationTests: XCTestCase {
    func testTheSameProgrammeQueuedTwiceIsOneReservation() async throws {
        let store = try temporaryStore()
        try await store.queue(pending("最初"))
        try await store.queue(pending("あとから"))

        let back = try await store.pendingReservations()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.request.title, "あとから", "the later one replaces the earlier")
    }

    /// A reservation waits for one device, and which is part of what it is: the same programme for two
    /// devices is two reservations, each kept, found and removed by itself. The recorder's goes by the name
    /// it always had, so that one queued by an earlier version is the same reservation still.
    func testTheSameProgrammeWaitsForTwoDevicesAsTwoReservations() async throws {
        let store = try temporaryStore()
        let recorders = pending()
        let televisions = pending(target: DeviceSlot(rawValue: "tv"))
        try await store.queue(recorders)
        try await store.queue(televisions)

        XCTAssertEqual(recorders.id, "2/1064/12575")
        XCTAssertNotEqual(televisions.id, recorders.id)
        let back = try await store.pendingReservations()
        XCTAssertEqual(back.sorted { $0.id < $1.id }, [recorders, televisions].sorted { $0.id < $1.id },
                       "each comes back as it went in, down to when it was queued and the device it waits for")

        try await store.removePending(televisions.id)
        expectEqual(try await store.pendingReservations(), [recorders])
    }

    func testAReservationWithoutAProgrammeIdIsKeptByItsTime() async throws {
        let store = try temporaryStore()
        let nine = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.queue(pending(eventID: nil, start: nine))
        try await store.queue(pending(eventID: nil, start: nine.addingTimeInterval(3600)))

        let back = try await store.pendingReservations()
        XCTAssertEqual(back.count, 2, "two times on one channel are two reservations")
        XCTAssertNil(back.first?.request.eventID, "and neither invented a programme id")
    }

    func testWhatTheRecorderRefusedIsRemembered() async throws {
        let store = try temporaryStore()
        let refused = pending()
        try await store.queue(refused)
        try await store.setPendingProblem(refused.id, "このチャンネルは受信できません")

        var back = try await store.pendingReservations()
        XCTAssertEqual(back.first?.problem, "このチャンネルは受信できません")

        try await store.setPendingProblem(refused.id, nil)
        back = try await store.pendingReservations()
        XCTAssertNil(back.first?.problem, "and can be cleared for a retry")
    }
}

/// The rules the flush follows, which the app and the overnight run share.
final class PendingQueueTests: XCTestCase {
    /// One that is over, one on air, one still to come: the first goes, the other two are sent.
    func testWhatIsSentAndWhatIsDropped() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let over = pending("終わった番組", eventID: 1, start: now.addingTimeInterval(-7200))
        let onAir = pending("放送中の番組", eventID: 2, start: now.addingTimeInterval(-600))
        let later = pending("これからの番組", eventID: 3, start: now.addingTimeInterval(3600))
        for one in [over, onAir, later] { try await store.queue(one) }

        let transport = StubTransport(always: Stub.soap("X_CreateRecordSchedule",
                                                        extra: "<RecordScheduleID>0x1</RecordScheduleID>"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertEqual(outcome.sent.map(\.request.title), ["放送中の番組", "これからの番組"])
        XCTAssertEqual(outcome.expired.map(\.request.title), ["終わった番組"])
        XCTAssertTrue(outcome.refused.isEmpty)
        let left = try await store.pendingReservations()
        XCTAssertTrue(left.isEmpty, "nothing waits after a flush that reached the recorder")
    }

    /// The recorder is sent what waits for the recorder. What waits for another device is not asked of it,
    /// and is as it was afterwards: still waiting, with no reason written on it. One whose programme is over
    /// is left as well: whether it is dropped is for whatever sends that device its own.
    func testWhatWaitsForAnotherDeviceIsNotSentToTheRecorder() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let television = DeviceSlot(rawValue: "tv")
        let recorders = pending("レコーダーに送る番組", eventID: 1, start: now.addingTimeInterval(3600))
        let televisions = pending("テレビに送る番組", eventID: 2, start: now.addingTimeInterval(7200), target: television)
        let over = pending("テレビ宛の終わった番組", eventID: 3, start: now.addingTimeInterval(-7200), target: television)
        for one in [recorders, televisions, over] { try await store.queue(one) }

        let transport = StubTransport(always: Stub.soap("X_CreateRecordSchedule",
                                                        extra: "<RecordScheduleID>0x1</RecordScheduleID>"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertEqual(outcome.sent.map(\.request.title), ["レコーダーに送る番組"])
        XCTAssertTrue(outcome.expired.isEmpty, "the recorder's flush dropped what waits for another device")
        let asked = await transport.requests.count
        XCTAssertEqual(asked, 1, "the recorder was asked for a reservation that waits for another device")
        let left = try await store.pendingReservations()
        XCTAssertEqual(left.map(\.id), [over.id, televisions.id])
        XCTAssertEqual(left.map(\.problem), [nil, nil])
    }

    /// A recorder that answers and refuses: the reservation stays, with the reason on it. Refused once is
    /// refused until the reader asks again: the recorder is not asked on every connect and every night, and
    /// the reader is not told about it every morning.
    func testARefusedReservationKeepsItsReasonAndIsNotSentAgain() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.queue(pending("受信できない局の番組", eventID: 1, start: now.addingTimeInterval(3600)))
        let transport = StubTransport(always: Stub.fault("831"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)

        let first = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertTrue(first.sent.isEmpty)
        XCTAssertEqual(first.refused.count, 1)
        XCTAssertFalse(first.interrupted)
        var left = try await store.pendingReservations()
        XCTAssertEqual(left.count, 1, "it is still waiting")
        XCTAssertTrue(left.first?.problem?.contains("831") ?? false, "with what the recorder said")
        let asked = await transport.requests.count

        let again = await PendingQueue.flush(client: client, store: store, now: now)

        expectEqual(await transport.requests.count, asked, "nothing is sent for it the second time")
        XCTAssertTrue(again.refused.isEmpty, "and it is not news the second time")
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.held.map(\.request.title), ["受信できない局の番組"])
        left = try await store.pendingReservations()
        XCTAssertNotNil(left.first?.problem, "it keeps its reason")
    }

    /// Clearing the reason is the reader asking for another try, and the next flush sends it.
    func testAClearedRefusalIsSentAgain() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let refused = pending("契約した局の番組", eventID: 1, start: now.addingTimeInterval(3600))
        try await store.queue(refused)
        try await store.setPendingProblem(refused.id, "このチャンネルは受信できません")
        try await store.setPendingProblem(refused.id, nil)

        let transport = StubTransport(always: Stub.soap("X_CreateRecordSchedule",
                                                        extra: "<RecordScheduleID>0x1</RecordScheduleID>"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertEqual(outcome.sent.map(\.request.title), ["契約した局の番組"])
        expectTrue(try await store.pendingReservations().isEmpty)
    }

    /// A refused one whose programme has finished goes like any other, and the reader is told.
    func testARefusedReservationStillExpires() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let over = pending("終わった番組", eventID: 1, start: now.addingTimeInterval(-7200))
        try await store.queue(over)
        try await store.setPendingProblem(over.id, "このチャンネルは受信できません")

        let transport = StubTransport(always: Stub.fault("831"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertEqual(outcome.expired.map(\.request.title), ["終わった番組"])
        XCTAssertTrue(outcome.held.isEmpty)
        expectTrue(try await store.pendingReservations().isEmpty)
    }

    /// A recorder busy with somebody else's request, or answering without a reason, has said nothing about
    /// the reservation: it waits as it was and goes next time, the ones after it are still tried, and
    /// nothing is said about it overnight.
    func testAFailureWithoutAReasonIsSentAgainNextTime() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for (i, title) in ["503 の番組", "理由のない 500 の番組", "通る番組"].enumerated() {
            try await store.queue(pending(title, eventID: i + 1, start: now.addingTimeInterval(3600 + Double(i))))
        }
        let noCode = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
            + "<s:Body><s:Fault><faultcode>s:Server</faultcode></s:Fault></s:Body></s:Envelope>"
        // The client sends a 503 again twice before it gives up on it, so the first reservation takes three.
        let transport = StubTransport { _, index in
            switch index {
            case 0...2: return HTTPResponse(statusCode: 503)
            case 3: return HTTPResponse(statusCode: 500, body: Data(noCode.utf8))
            default: return Stub.soap("X_CreateRecordSchedule", extra: "<RecordScheduleID>0x1</RecordScheduleID>")
            }
        }
        let client = RecorderClient(host: "192.0.2.1", transport: transport, busyRetryDelay: 0...0)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertEqual(outcome.deferred.map(\.request.title), ["503 の番組", "理由のない 500 の番組"])
        XCTAssertEqual(outcome.sent.map(\.request.title), ["通る番組"], "the ones after are still tried")
        XCTAssertTrue(outcome.refused.isEmpty)
        XCTAssertFalse(outcome.interrupted)
        var left = try await store.pendingReservations()
        XCTAssertEqual(left.count, 2)
        XCTAssertTrue(left.allSatisfy { $0.problem == nil }, "no reason written, so nothing holds them back")

        let next = await PendingQueue.flush(client: client, store: store, now: now)
        XCTAssertEqual(next.sent.count, 2, "and they go the next time")
        left = try await store.pendingReservations()
        XCTAssertTrue(left.isEmpty)
    }

    /// The screens and the overnight run each flush with a client and a connection of their own, and can
    /// be at it together in one process. The second waits for the first and reads the queue after it, so a
    /// reservation is sent once, not once each.
    func testTwoFlushesAtOnceSendAReservationOnce() async throws {
        let path = temporaryPath()
        let screens = try GuideStore(path: path)
        let overnight = try GuideStore(path: path)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await screens.queue(pending("一度だけ送る番組", eventID: 1, start: now.addingTimeInterval(3600)))

        let transport = StubTransport { _, _ in
            // long enough for both flushes to have read the queue, were they let in together
            try await Task.sleep(for: .milliseconds(100))
            return Stub.soap("X_CreateRecordSchedule", extra: "<RecordScheduleID>0x1</RecordScheduleID>")
        }
        let first = RecorderClient(host: "192.0.2.1", transport: transport)
        let second = RecorderClient(host: "192.0.2.1", transport: transport)
        async let one = PendingQueue.flush(client: first, store: screens, now: now)
        async let other = PendingQueue.flush(client: second, store: overnight, now: now)
        let outcomes = await [one, other]

        let sent = await transport.requests.count
        XCTAssertEqual(sent, 1, "sent once, not by each")
        XCTAssertEqual(outcomes.map(\.sent.count).sorted(), [0, 1])
        expectTrue(try await overnight.pendingReservations().isEmpty)
    }

    /// A recorder that goes away part way leaves the rest alone rather than marking them refused.
    func testTheRestStayQueuedWhenTheRecorderGoesAway() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for (i, title) in ["一番目", "二番目"].enumerated() {
            try await store.queue(pending(title, eventID: i + 1, start: now.addingTimeInterval(3600)))
        }
        let transport = StubTransport { _, index in
            if index == 0 {
                return Stub.soap("X_CreateRecordSchedule", extra: "<RecordScheduleID>0x1</RecordScheduleID>")
            }
            throw RecorderError.transport("the recorder went away")
        }
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertEqual(outcome.sent.count, 1)
        XCTAssertTrue(outcome.interrupted)
        let left = try await store.pendingReservations()
        XCTAssertEqual(left.count, 1)
        XCTAssertNil(left.first?.problem, "not refused: it was never asked")
    }
}

/// Whether there is anything in the queue worth reaching the recorder for, which the Shortcuts action asks
/// before it wakes one.
final class PendingQueueWorthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testOneStillToComeOrOnAirIsWorthSending() {
        XCTAssertTrue(PendingQueue.hasSomethingToSend([pending(start: now.addingTimeInterval(3600))], now: now))
        XCTAssertTrue(PendingQueue.hasSomethingToSend([pending(start: now.addingTimeInterval(-600))], now: now))
        // Ending this very second still counts, as it does for the flush.
        XCTAssertTrue(PendingQueue.hasSomethingToSend([pending(start: now.addingTimeInterval(-3600))], now: now))
    }

    func testNothingRefusedOnlyAndFinishedOnlyAreNot() {
        XCTAssertFalse(PendingQueue.hasSomethingToSend([], now: now))
        XCTAssertFalse(PendingQueue.hasSomethingToSend(
            [pending(start: now.addingTimeInterval(3600), problem: "断られました")], now: now))
        XCTAssertFalse(PendingQueue.hasSomethingToSend([pending(start: now.addingTimeInterval(-7200))], now: now))
        // Nor one that ended a second ago: a programme ends its length after it starts, and no later.
        XCTAssertFalse(PendingQueue.hasSomethingToSend([pending(start: now.addingTimeInterval(-3601))], now: now))
    }

    func testOneWorthSendingAmongOthersIsEnough() {
        XCTAssertTrue(PendingQueue.hasSomethingToSend(
            [pending(start: now.addingTimeInterval(-7200)),
             pending(start: now.addingTimeInterval(3600), problem: "断られました"),
             pending(start: now.addingTimeInterval(7200))], now: now))
    }

    /// What waits for another device is nothing the recorder would be sent, so it is not woken for it.
    func testWhatWaitsForAnotherDeviceIsNotWorthReachingTheRecorderFor() {
        let elsewhere = pending(start: now.addingTimeInterval(3600), target: DeviceSlot(rawValue: "tv"))
        XCTAssertFalse(PendingQueue.hasSomethingToSend([elsewhere], now: now))
        XCTAssertTrue(PendingQueue.hasSomethingToSend([elsewhere, pending(start: now.addingTimeInterval(3600))],
                                                      now: now))
    }

    /// Asked for a device by name, it is that device's rows that count and no other's, by the same rule: one
    /// that has not been refused and whose programme is not over.
    func testWhatWaitsForADeviceIsWorthReachingThatDeviceFor() {
        let televisions = pending(start: now.addingTimeInterval(3600), target: .tv)
        XCTAssertTrue(PendingQueue.hasSomethingToSend([televisions], for: .tv, now: now))
        XCTAssertFalse(PendingQueue.hasSomethingToSend([televisions], for: .recorder, now: now))
        XCTAssertFalse(PendingQueue.hasSomethingToSend([pending(start: now.addingTimeInterval(3600))], for: .tv,
                                                       now: now), "the recorder's is not the television's")
        XCTAssertFalse(PendingQueue.hasSomethingToSend(
            [pending(start: now.addingTimeInterval(3600), problem: "断られました", target: .tv),
             pending(start: now.addingTimeInterval(-7200), target: .tv)], for: .tv, now: now))
    }
}

/// What the queue's loop does with a device's answers, whichever device it is: asked of a device of the tests'
/// own (`FakeTarget`), which takes what waits for the television and answers as each test says.
final class QueueTargetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let refusal = "この局は録画できません"

    /// The rows are dealt with in the order they start, each as the queue comes to it. One whose programme is
    /// over is dropped. One with a reason on it is held. The device is read for the round at the first row
    /// that is to go: once, and handed every row that is not over, the held ones among them. By then what was
    /// over before that row has gone from the queue, and what is over after it has not. Each row that is to go
    /// is then sent, in the round as the row before it left it.
    func testTheRowsGoInTheirOrderAndTheRoundIsOpenedAtTheFirstThatIsToGo() async throws {
        let store = try await store(with: [
            row("終わった番組", 1, startingIn: -3),
            row("断られていた長い番組", 2, startingIn: -2.5, lasting: 4, reason: refusal),
            row("その間に終わった番組", 3, startingIn: -2.25, lasting: 0.25),
            row("放送中の長い番組", 4, startingIn: -2, lasting: 4),
            row("あとから始まって終わった番組", 5, startingIn: -1.5, lasting: 0.25),
            row("断られていた番組", 6, startingIn: 1, reason: refusal),
            row("これからの番組", 7, startingIn: 2),
        ])
        let device = FakeTarget(store)

        let outcome = await PendingQueue.flush(client: device, store: store, now: now)

        expectEqual(await device.asked, [
            .open(["断られていた長い番組", "放送中の長い番組", "断られていた番組", "これからの番組"]),
            .send("放送中の長い番組", after: 0),
            .send("これからの番組", after: 1),
        ])
        expectEqual(await device.queuedAtOpening,
                    ["断られていた長い番組", "放送中の長い番組", "あとから始まって終わった番組", "断られていた番組",
                     "これからの番組"])
        expectEqual(try await came(outcome, store),
                    Came(sent: ["放送中の長い番組", "これからの番組"],
                         expired: ["終わった番組", "その間に終わった番組", "あとから始まって終わった番組"],
                         held: ["断られていた長い番組", "断られていた番組"],
                         left: ["断られていた長い番組", "断られていた番組"], written: [refusal, refusal]))
    }

    /// With nothing to send -- no rows, only rows whose programmes are over, only rows with a reason on them --
    /// nothing is asked of the device: no round is opened. What is over is dropped all the same.
    func testWithNothingToSendNothingIsAskedOfTheDevice() async throws {
        let over = row("終わった番組", 1, startingIn: -3)
        let held = row("断られていた番組", 2, startingIn: 1, reason: refusal)
        let queues: [(name: String, rows: [PendingReservation], comes: Came)] = [
            ("nothing waiting", [], Came()),
            ("only what is over", [over], Came(expired: ["終わった番組"])),
            ("only what was refused", [held], Came(held: ["断られていた番組"], left: ["断られていた番組"],
                                                   written: [refusal])),
            ("both", [over, held], Came(expired: ["終わった番組"], held: ["断られていた番組"],
                                        left: ["断られていた番組"], written: [refusal])),
        ]
        for queue in queues {
            let store = try await store(with: queue.rows)
            let device = FakeTarget(store)

            let outcome = await PendingQueue.flush(client: device, store: store, now: now)

            expectEqual(await device.asked, [], queue.name)
            expectEqual(try await came(outcome, store), queue.comes, queue.name)
        }
    }

    /// A row the opening found on the device leaves the queue and is not sent: one with a reason on it as
    /// well, whether the queue passed it before the round was opened or comes to it afterwards. It is told as
    /// found there, not as sent, and it is news.
    func testARowTheOpeningFoundOnTheDeviceLeavesTheQueueUnsent() async throws {
        let foundThere = [
            row("断られていたがテレビにある番組", 1, startingIn: 1, reason: refusal),
            row("テレビにある番組", 2, startingIn: 2),
            row("あとの断られていたがテレビにある番組", 3, startingIn: 3, reason: refusal),
            row("あとのテレビにある番組", 4, startingIn: 4),
        ]
        let others = [row("テレビにない番組", 5, startingIn: 5),
                      row("断られていた番組", 6, startingIn: 6, reason: refusal)]
        let store = try await store(with: foundThere + others)
        let device = FakeTarget(store, finding: foundThere)

        let outcome = await PendingQueue.flush(client: device, store: store, now: now)

        expectEqual(await device.asked,
                    [.open((foundThere + others).map(\.request.title)), .send("テレビにない番組", after: 0)])
        expectEqual(try await came(outcome, store),
                    Came(sent: ["テレビにない番組"], alreadyThere: foundThere.map(\.request.title),
                         held: ["断られていた番組"], left: ["断られていた番組"], written: [refusal]))
        XCTAssertFalse(PendingQueue.Outcome(slot: .tv, alreadyThere: [foundThere[1]]).isEmpty,
                       "a reservation found there is no longer waiting, which the reader has not been told")
    }

    /// A row with a reason on it is not sent, unless the reader consented to it: then it is sent though the
    /// reason is on it, and the device is told of the consent. Consent is by id and for that row alone: the
    /// row beside it stays held, and a row with no reason is sent as one not consented to. A consented row is
    /// a row to go, so the round is opened for it though nothing else waits.
    func testARowWithAReasonIsHeldUnlessTheReaderConsentedToIt() async throws {
        let held = row("断られたままの番組", 1, startingIn: 1, reason: refusal)
        let consented = row("それでも予約する番組", 2, startingIn: 2, reason: refusal)
        let plain = row("これからの番組", 3, startingIn: 3)
        let store = try await store(with: [held, consented, plain])
        let device = FakeTarget(store)

        let outcome = await PendingQueue.flush(client: device, store: store, consenting: [consented.id], now: now)

        expectEqual(await device.asked, [
            .open(["断られたままの番組", "それでも予約する番組", "これからの番組"]),
            .send("それでも予約する番組", consented: true, after: 0),
            .send("これからの番組", after: 1),
        ])
        expectEqual(try await came(outcome, store),
                    Came(sent: ["それでも予約する番組", "これからの番組"], held: ["断られたままの番組"],
                         left: ["断られたままの番組"], written: [refusal]))

        let alone = try await self.store(with: [consented])
        let asked = FakeTarget(alone)
        _ = await PendingQueue.flush(client: asked, store: alone, consenting: [consented.id], now: now)
        expectEqual(await asked.asked,
                    [.open(["それでも予約する番組"]), .send("それでも予約する番組", consented: true, after: 0)])

        // A consented row the device passes over keeps its reason: the consent was for this flush, and the row
        // waits for the reader again.
        let passed = try await self.store(with: [consented])
        let passing = FakeTarget(passed, answering: ["それでも予約する番組": .passedOver])
        let over = await PendingQueue.flush(client: passing, store: passed, consenting: [consented.id], now: now)
        expectEqual(try await came(over, passed),
                    Came(deferred: ["それでも予約する番組"], left: ["それでも予約する番組"], written: [refusal]))
    }

    /// What a row came to settles the row. Made, or held by the device already: it leaves the queue, told as
    /// sent or as found there. Refused: the reason is written on it. Passed over: it stays as it was. After
    /// each of those the next row is sent, in the round as this row left it. A stop ends the round there, the
    /// row as it was -- counted with the rows passed over when the device says so, and in no list when not --
    /// and the next row is not sent.
    func testWhatARowCameToSettlesTheRowAndWhetherTheRoundGoesOn() async throws {
        let first = "最初の番組", second = "次の番組"
        let goesOn: [FakeTarget.Asked] = [.open([first, second]), .send(first, after: 0), .send(second, after: 1)]
        let ends: [FakeTarget.Asked] = [.open([first, second]), .send(first, after: 0)]
        let answers: [(answer: RowSent, asked: [FakeTarget.Asked], comes: Came)] = [
            (.made, goesOn, Came(sent: [first, second])),
            (.alreadyThere, goesOn, Came(sent: [second], alreadyThere: [first])),
            (.refused(reason: refusal), goesOn,
             Came(sent: [second], refused: [first], reasons: [refusal], left: [first], written: [refusal])),
            (.passedOver, goesOn, Came(sent: [second], deferred: [first], left: [first], written: [nil])),
            (.stopped(.saysNothing, passedOver: true), ends,
             Came(deferred: [first], stopped: .saysNothing, left: [first, second], written: [nil, nil])),
            (.stopped(.silent(afterSending: true), passedOver: false), ends,
             Came(stopped: .silent(afterSending: true), left: [first, second], written: [nil, nil])),
        ]
        for (answer, asked, comes) in answers {
            let store = try await store(with: [row(first, 1, startingIn: 1), row(second, 2, startingIn: 2)])
            let device = FakeTarget(store, answering: [first: answer])

            let outcome = await PendingQueue.flush(client: device, store: store, now: now)

            expectEqual(await device.asked, asked, "\(answer)")
            expectEqual(try await came(outcome, store), comes, "\(answer)")
        }
    }

    /// Whatever stops a round, it is said why, nothing is sent after it, and the rows not yet sent stay as
    /// they were: in the queue, with nothing written on them, and in none of the outcome's lists. A round
    /// that cannot be opened sends nothing at all. Only silence is the device having gone away part way.
    func testWhateverStopsARoundLeavesTheRowsNotYetSentAsTheyWere() async throws {
        let stops: [SendingStop] = [.silent(afterSending: false), .silent(afterSending: true), .needsPairing,
                                    .cannotRecord(reason: "録画用のディスクが見つかりません"), .saysNothing]
        let rows = [row("断られていた番組", 1, startingIn: 1, reason: refusal), row("最初の番組", 2, startingIn: 2),
                    row("次の番組", 3, startingIn: 3), row("その次の番組", 4, startingIn: 4)]
        let waiting = rows.map(\.request.title)
        // One whose programme is over, in front of a round that cannot be opened, is dropped all the same:
        // that needs no device.
        let over = row("終わった番組", 5, startingIn: -3)
        for stop in stops {
            let silence = stop == .silent(afterSending: false) || stop == .silent(afterSending: true)

            let unopened = try await store(with: [over] + rows)
            let closed = FakeTarget(unopened, stoppingTheOpeningWith: stop)
            var outcome = await PendingQueue.flush(client: closed, store: unopened, now: now)

            expectEqual(await closed.asked, [.open(waiting)], "\(stop), at the opening")
            expectEqual(try await came(outcome, unopened),
                        Came(expired: ["終わった番組"], held: ["断られていた番組"], stopped: stop, left: waiting,
                             written: [refusal, nil, nil, nil]), "\(stop), at the opening")
            XCTAssertEqual(outcome.interrupted, silence, "\(stop), at the opening")

            let opened = try await store(with: rows)
            let device = FakeTarget(opened, answering: ["次の番組": .stopped(stop, passedOver: false)])
            outcome = await PendingQueue.flush(client: device, store: opened, now: now)

            expectEqual(await device.asked,
                        [.open(waiting), .send("最初の番組", after: 0), .send("次の番組", after: 1)], "\(stop)")
            expectEqual(try await came(outcome, opened),
                        Came(sent: ["最初の番組"], held: ["断られていた番組"], stopped: stop,
                             left: ["断られていた番組", "次の番組", "その次の番組"], written: [refusal, nil, nil]),
                        "\(stop)")
            XCTAssertEqual(outcome.interrupted, silence, "\(stop)")
        }
    }

    /// A device is sent what waits for it and nothing else, whichever device it is, and the outcome says
    /// whose round it was. What waits for another device is never handed to this one, at the opening or
    /// after, and is as it was: one whose programme is over is not dropped, and nothing is written on any.
    /// The recorder's client then takes the recorder's and leaves the rest.
    func testWhatWaitsForAnotherDeviceIsNeverHandedToTheTarget() async throws {
        let projector = DeviceSlot(rawValue: "projector")
        let store = try await store(with: [
            row("レコーダー宛の終わった番組", 1, startingIn: -3, target: .recorder),
            row("レコーダーに送る番組", 2, startingIn: 1, target: .recorder),
            row("テレビに送る番組", 3, startingIn: 2),
            row("ほかの機器に送る番組", 4, startingIn: 3, target: projector),
        ])
        let device = FakeTarget(store)

        let televisions = await PendingQueue.flush(client: device, store: store, now: now)

        XCTAssertEqual(televisions.slot, .tv)
        expectEqual(await device.asked, [.open(["テレビに送る番組"]), .send("テレビに送る番組", after: 0)])
        expectEqual(try await came(televisions, store),
                    Came(sent: ["テレビに送る番組"],
                         left: ["レコーダー宛の終わった番組", "レコーダーに送る番組", "ほかの機器に送る番組"],
                         written: [nil, nil, nil]))

        let transport = StubTransport(always: Stub.soap("X_CreateRecordSchedule",
                                                        extra: "<RecordScheduleID>0x1</RecordScheduleID>"))
        let recorders = await PendingQueue.flush(client: RecorderClient(host: "192.0.2.1", transport: transport),
                                                 store: store, now: now)

        XCTAssertEqual(recorders.slot, .recorder)
        expectEqual(try await came(recorders, store),
                    Came(sent: ["レコーダーに送る番組"], expired: ["レコーダー宛の終わった番組"],
                         left: ["ほかの機器に送る番組"], written: [nil]))
        expectEqual(await device.asked.count, 2, "the television was asked nothing by the recorder's flush")
    }

    // MARK: - what the tests put in the queue, and read back

    /// A row waiting for the television unless said, for the programme numbered `number`, which starts
    /// `hours` from now and lasts `lasting` of them.
    private func row(_ title: String, _ number: Int, startingIn hours: Double, lasting: Double = 1,
                     reason: String? = nil, target: DeviceSlot = .tv) -> PendingReservation {
        var row = pending(title, eventID: number, start: now.addingTimeInterval(hours * 3600), problem: reason,
                          target: target)
        row.request.durationSec = Int(lasting * 3600)
        return row
    }

    /// A cache of the test's own with `rows` waiting in it.
    private func store(with rows: [PendingReservation]) async throws -> GuideStore {
        let store = try temporaryStore()
        for row in rows { try await store.queue(row) }
        return store
    }

    /// What a flush came to and what it left in the queue, by title.
    private func came(_ outcome: PendingQueue.Outcome, _ store: GuideStore) async throws -> Came {
        let left = try await store.pendingReservations()
        return Came(sent: outcome.sent.map(\.request.title), alreadyThere: outcome.alreadyThere.map(\.request.title),
                    expired: outcome.expired.map(\.request.title), refused: outcome.refused.map(\.request.title),
                    reasons: outcome.refused.map(\.problem), deferred: outcome.deferred.map(\.request.title),
                    held: outcome.held.map(\.request.title), stopped: outcome.stopped,
                    left: left.map(\.request.title), written: left.map(\.problem))
    }
}

/// What became of the queue, in words: the sentences a home with one device has always read, and the same
/// with the device named, for a home with two.
final class QueueSentenceTests: XCTestCase {
    private let one = [pending("朝の番組", eventID: 1)]
    private let three = [pending("昼の番組", eventID: 2), pending("夕方の番組", eventID: 3),
                         pending("夜の番組", eventID: 4)]

    /// Each way a row can go has its sentence, about the first row by its title and the others by their
    /// number. With no device named it is the sentence as it has always read, and `summary` is that form;
    /// named, the device's word is in every one of them. The device going silent is said only after another
    /// sentence, and no other stop is said at all. What was held before, and nothing at all, say nothing.
    func testEachSentenceWithNoDeviceNamedAndWithOne() {
        let silent = SendingStop.silent(afterSending: true)
        let sentences: [(name: String, outcome: PendingQueue.Outcome, unnamed: String?, named: String?)] = [
            ("sent", PendingQueue.Outcome(slot: .tv, sent: one),
             "送信待ちだった「朝の番組」を登録しました", "送信待ちだった「朝の番組」をテレビに登録しました"),
            ("three sent", PendingQueue.Outcome(slot: .tv, sent: three),
             "送信待ちだった「昼の番組」ほか 2 件を登録しました",
             "送信待ちだった「昼の番組」ほか 2 件をテレビに登録しました"),
            ("found there already", PendingQueue.Outcome(slot: .tv, alreadyThere: one),
             "「朝の番組」はすでに予約されていました", "「朝の番組」はテレビにすでに予約がありました"),
            ("over", PendingQueue.Outcome(slot: .tv, expired: one),
             "「朝の番組」は放送が終わっていたため、送らずに削除しました",
             "テレビ宛の「朝の番組」は放送が終わっていたため、送らずに削除しました"),
            ("refused now", PendingQueue.Outcome(slot: .tv, refused: one),
             "「朝の番組」はレコーダーが受け付けませんでした。理由は予約タブにあります",
             "「朝の番組」はテレビに登録できませんでした。理由は予約タブにあります"),
            ("passed over", PendingQueue.Outcome(slot: .tv, deferred: one),
             "「朝の番組」は送れなかったため、次の機会にもう一度送ります",
             "「朝の番組」はテレビに送れなかったため、次の機会にもう一度送ります"),
            ("sent, then silence", PendingQueue.Outcome(slot: .tv, sent: one, stopped: silent),
             "送信待ちだった「朝の番組」を登録しました。"
                + "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります",
             "送信待ちだった「朝の番組」をテレビに登録しました。"
                + "途中でテレビの応答がなくなったため、残りは次につながったときに送ります"),
            ("silence alone", PendingQueue.Outcome(slot: .tv, stopped: silent), nil, nil),
            ("sent, then the registration wanted", PendingQueue.Outcome(slot: .tv, sent: one, stopped: .needsPairing),
             "送信待ちだった「朝の番組」を登録しました", "送信待ちだった「朝の番組」をテレビに登録しました"),
            ("sent, then nothing said of two rows", PendingQueue.Outcome(slot: .tv, sent: one, stopped: .saysNothing),
             "送信待ちだった「朝の番組」を登録しました", "送信待ちだった「朝の番組」をテレビに登録しました"),
            ("nowhere to record to",
             PendingQueue.Outcome(slot: .tv, stopped: .cannotRecord(reason: "録画先がありません")), nil, nil),
            ("only what was held before", PendingQueue.Outcome(slot: .tv, held: one), nil, nil),
            ("nothing", PendingQueue.Outcome(slot: .tv), nil, nil),
        ]
        for sentence in sentences {
            XCTAssertEqual(sentence.outcome.says(naming: nil), sentence.unnamed, sentence.name)
            XCTAssertEqual(sentence.outcome.summary, sentence.unnamed, sentence.name)
            XCTAssertEqual(sentence.outcome.says(naming: "テレビ"), sentence.named, sentence.name)
        }
    }

    /// The sentences come in one order whatever the rows' own -- sent, found there already, over, refused
    /// now, passed over, and the silence last -- and are joined with a full stop. The word is whatever is
    /// handed in: a recorder's round is named as a television's is.
    func testTheSentencesComeInOneOrderJoinedWithAFullStop() {
        let outcome = PendingQueue.Outcome(slot: .recorder, sent: one, expired: [pending("終わった番組", eventID: 5)],
                                           refused: [pending("断られた番組", eventID: 6)],
                                           deferred: [pending("見送った番組", eventID: 7)], held: three,
                                           alreadyThere: [pending("すでにある番組", eventID: 8)],
                                           stopped: .silent(afterSending: false))

        XCTAssertEqual(outcome.summary, [
            "送信待ちだった「朝の番組」を登録しました",
            "「すでにある番組」はすでに予約されていました",
            "「終わった番組」は放送が終わっていたため、送らずに削除しました",
            "「断られた番組」はレコーダーが受け付けませんでした。理由は予約タブにあります",
            "「見送った番組」は送れなかったため、次の機会にもう一度送ります",
            "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります",
        ].joined(separator: "。"))
        XCTAssertEqual(outcome.says(naming: "レコーダー"), [
            "送信待ちだった「朝の番組」をレコーダーに登録しました",
            "「すでにある番組」はレコーダーにすでに予約がありました",
            "レコーダー宛の「終わった番組」は放送が終わっていたため、送らずに削除しました",
            "「断られた番組」はレコーダーに登録できませんでした。理由は予約タブにあります",
            "「見送った番組」はレコーダーに送れなかったため、次の機会にもう一度送ります",
            "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります",
        ].joined(separator: "。"))
    }
}

/// What a flush came to, by title: the list of the outcome each row is in, the reasons on the ones refused,
/// why the round stopped, and what is left in the queue -- every device's -- with what is written on each.
private struct Came: Equatable {
    var sent: [String] = []
    var alreadyThere: [String] = []
    var expired: [String] = []
    var refused: [String] = []
    var reasons: [String?] = []
    var deferred: [String] = []
    var held: [String] = []
    var stopped: SendingStop?
    var left: [String] = []
    var written: [String?] = []
}

/// A device of the tests' own behind the queue's protocol, which takes what waits for the television. It
/// answers the opening and each row as the test says -- a row it is told nothing of is made -- and writes down
/// what it was asked. Its round counts the rows it has been sent: what a device carries from one row to the
/// next, so that the queue is seen to hand each row the round the row before it left.
private actor FakeTarget: QueueTarget {
    static let slot = DeviceSlot.tv

    struct Round: Sendable {
        var sent = 0
    }

    enum Asked: Equatable {
        /// The round opened, for the rows with these titles.
        case open([String])
        /// A row sent, by its title, in a round that had been sent `after` rows before it.
        case send(String, consented: Bool = false, after: Int)
    }

    private(set) var asked: [Asked] = []
    /// The titles in the queue, every device's, at the moment the round was opened.
    private(set) var queuedAtOpening: [String]?
    private let store: GuideStore
    private let stop: SendingStop?
    private let found: Set<String>
    private let answers: [String: RowSent]

    /// `stop` is what the opening comes to in place of a round; `found` the rows the opening finds on the
    /// device; `answers` what sending a row comes to, by its title.
    init(_ store: GuideStore, stoppingTheOpeningWith stop: SendingStop? = nil,
         finding found: [PendingReservation] = [], answering answers: [String: RowSent] = [:]) {
        self.store = store
        self.stop = stop
        self.found = Set(found.map(\.id))
        self.answers = answers
    }

    func probe(timeout: TimeInterval) async throws {}

    func openRound(for waiting: [PendingReservation]) async -> RoundOpened<Round> {
        asked.append(.open(waiting.map(\.request.title)))
        queuedAtOpening = ((try? await store.pendingReservations()) ?? []).map(\.request.title)
        if let stop { return .stopped(stop) }
        return .open(Round(), alreadyThere: found)
    }

    func send(_ waiting: PendingReservation, consented: Bool,
              in round: Round) async -> (sent: RowSent, round: Round) {
        asked.append(.send(waiting.request.title, consented: consented, after: round.sent))
        return (answers[waiting.request.title] ?? .made, Round(sent: round.sent + 1))
    }
}
