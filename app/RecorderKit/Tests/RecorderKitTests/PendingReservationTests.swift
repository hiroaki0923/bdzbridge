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
}
