import XCTest
@testable import RecorderKit

/// The queue of reservations made while the recorder could not be reached.
final class PendingReservationTests: XCTestCase {
    private func store() throws -> GuideStore {
        try GuideStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString).sqlite3").path)
    }

    private func request(title: String = "サンプル番組", eventID: Int? = 0x311f,
                         start: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> ReservationRequest {
        ReservationRequest(title: title, start: start, durationSec: 3600, repeatCode: "1",
                           broadcastingType: 2, serviceID: 0x428, qualityCode: 240, eventID: eventID)
    }

    func testAQueuedReservationComesBackAsItWentIn() async throws {
        let store = try store()
        let pending = PendingReservation(request: request(), serviceName: "サンプルテレビ",
                                         queuedAt: Date(timeIntervalSince1970: 1_789_000_000))
        try await store.queue(pending)

        let back = try await store.pendingReservations()
        XCTAssertEqual(back, [pending], "what was queued is what waits, down to the moment it was queued")
    }

    func testTheSameProgrammeQueuedTwiceIsOneReservation() async throws {
        let store = try store()
        try await store.queue(PendingReservation(request: request(title: "最初"), serviceName: "サンプルテレビ"))
        try await store.queue(PendingReservation(request: request(title: "あとから"), serviceName: "サンプルテレビ"))

        let back = try await store.pendingReservations()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.request.title, "あとから", "the later one replaces the earlier")
    }

    func testAReservationWithoutAProgrammeIdIsKeptByItsTime() async throws {
        let store = try store()
        let nine = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.queue(PendingReservation(request: request(eventID: nil, start: nine),
                                                 serviceName: "サンプルテレビ"))
        try await store.queue(PendingReservation(request: request(eventID: nil, start: nine.addingTimeInterval(3600)),
                                                 serviceName: "サンプルテレビ"))

        let back = try await store.pendingReservations()
        XCTAssertEqual(back.count, 2, "two times on one channel are two reservations")
        XCTAssertNil(back.first?.request.eventID, "and neither invented a programme id")
    }

    func testWhatTheRecorderRefusedIsRemembered() async throws {
        let store = try store()
        let pending = PendingReservation(request: request(), serviceName: "サンプルテレビ")
        try await store.queue(pending)
        try await store.setPendingProblem(pending.id, "このチャンネルは受信できません")

        var back = try await store.pendingReservations()
        XCTAssertEqual(back.first?.problem, "このチャンネルは受信できません")

        try await store.setPendingProblem(pending.id, nil)
        back = try await store.pendingReservations()
        XCTAssertNil(back.first?.problem, "and can be cleared for a retry")
    }

    /// What the flush uses to decide whether a queued reservation is still worth sending.
    func testAReservationIsWorthSendingUntilTheProgrammeEnds() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let request = request(start: start)
        XCTAssertEqual(request.end, start.addingTimeInterval(3600))
        XCTAssertGreaterThan(request.end, start, "a programme on air has not finished")
    }

    func testRemovingOneLeavesTheOthers() async throws {
        let store = try store()
        let first = PendingReservation(request: request(eventID: 1), serviceName: "サンプルテレビ")
        let second = PendingReservation(request: request(eventID: 2), serviceName: "サンプルテレビ")
        try await store.queue(first)
        try await store.queue(second)

        try await store.removePending(first.id)
        let left = try await store.pendingReservations()
        XCTAssertEqual(left.map(\.id), [second.id])
    }

    /// The guide is a cache and is thrown away when the schema moves on; a reservation the reader made is not.
    func testTheQueueSurvivesTheGuideBeingRebuilt() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString).sqlite3").path
        let pending = PendingReservation(request: request(), serviceName: "サンプルテレビ")
        let before = try GuideStore(path: path, schemaVersion: "1")
        try await before.queue(pending)

        let after = try GuideStore(path: path, schemaVersion: "2")
        let kept = try await after.pendingReservations()
        XCTAssertEqual(kept.map(\.id), [pending.id])
    }
}

/// The rules the flush follows, which the app and the overnight run share.
final class PendingQueueTests: XCTestCase {
    private func store() throws -> GuideStore {
        try GuideStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("flush-\(UUID().uuidString).sqlite3").path)
    }

    private func pending(_ title: String, eventID: Int, start: Date) -> PendingReservation {
        PendingReservation(request: ReservationRequest(title: title, start: start, durationSec: 3600,
                                                       repeatCode: "1", broadcastingType: 2, serviceID: 0x428,
                                                       qualityCode: 240, eventID: eventID),
                           serviceName: "サンプルテレビ")
    }

    /// One that is over, one on air, one still to come: the first goes, the other two are sent.
    func testWhatIsSentAndWhatIsDropped() async throws {
        let store = try store()
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

    /// A recorder that answers and refuses: the reservation stays, with the reason on it.
    func testARefusedReservationKeepsItsReason() async throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.queue(pending("受信できない局の番組", eventID: 1, start: now.addingTimeInterval(3600)))

        let transport = StubTransport(always: Stub.fault("831"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertTrue(outcome.sent.isEmpty)
        XCTAssertEqual(outcome.refused.count, 1)
        XCTAssertFalse(outcome.interrupted)
        let left = try await store.pendingReservations()
        XCTAssertEqual(left.count, 1, "it is still waiting")
        XCTAssertTrue(left.first?.problem?.contains("831") ?? false, "with what the recorder said")
    }

    /// Refused once is refused until the reader asks again: the recorder is not asked on every connect and
    /// every night, and the reader is not told about it every morning.
    func testARefusedReservationIsNotSentAgain() async throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.queue(pending("受信できない局の番組", eventID: 1, start: now.addingTimeInterval(3600)))
        let transport = StubTransport(always: Stub.fault("831"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        _ = await PendingQueue.flush(client: client, store: store, now: now)
        let asked = await transport.requests.count

        let again = await PendingQueue.flush(client: client, store: store, now: now)

        let askedAgain = await transport.requests.count
        XCTAssertEqual(askedAgain, asked, "nothing is sent for it the second time")
        XCTAssertTrue(again.refused.isEmpty, "and it is not news the second time")
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.held.map(\.request.title), ["受信できない局の番組"])
        let left = try await store.pendingReservations()
        XCTAssertNotNil(left.first?.problem, "it keeps its reason")
    }

    /// Clearing the reason is the reader asking for another try, and the next flush sends it.
    func testAClearedRefusalIsSentAgain() async throws {
        let store = try store()
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
        let left = try await store.pendingReservations()
        XCTAssertTrue(left.isEmpty)
    }

    /// A refused one whose programme has finished goes like any other, and the reader is told.
    func testARefusedReservationStillExpires() async throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let over = pending("終わった番組", eventID: 1, start: now.addingTimeInterval(-7200))
        try await store.queue(over)
        try await store.setPendingProblem(over.id, "このチャンネルは受信できません")

        let transport = StubTransport(always: Stub.fault("831"))
        let client = RecorderClient(host: "192.0.2.1", transport: transport)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now)

        XCTAssertEqual(outcome.expired.map(\.request.title), ["終わった番組"])
        XCTAssertTrue(outcome.held.isEmpty)
        let left = try await store.pendingReservations()
        XCTAssertTrue(left.isEmpty)
    }

    /// A recorder busy with somebody else's request, or answering without a reason, has said nothing about
    /// the reservation: it waits as it was and goes next time, the ones after it are still tried, and
    /// nothing is said about it overnight.
    func testAFailureWithoutAReasonIsSentAgainNextTime() async throws {
        let store = try store()
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

    /// What counts as the recorder turning a request down for good.
    func testWhatCountsAsARefusal() {
        let action = "X_CreateRecordSchedule"
        XCTAssertTrue(RecorderError.soap(action: action, status: 500, code: "831", body: "").refusal)
        XCTAssertTrue(RecorderError.soap(action: action, status: 500, code: "402", body: "").refusal)
        XCTAssertFalse(RecorderError.soap(action: action, status: 500, code: nil, body: "").refusal,
                       "no code, no reason")
        XCTAssertFalse(RecorderError.soap(action: action, status: 503, code: "501", body: "").refusal,
                       "busy is busy, whatever else it says")
        XCTAssertFalse(RecorderError.soap(action: action, status: 500, code: "880", body: "").refusal,
                       "standby is about the recorder, not the request")
        XCTAssertFalse(RecorderError.badResponse(status: 503).refusal)
        XCTAssertFalse(RecorderError.transport("gone").refusal)
    }

    /// The screens and the overnight run each flush with a client and a connection of their own, and can
    /// be at it together in one process. The second waits for the first and reads the queue after it, so a
    /// reservation is sent once, not once each.
    func testTwoFlushesAtOnceSendAReservationOnce() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("flush-\(UUID().uuidString).sqlite3")
            .path
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
        let left = try await overnight.pendingReservations()
        XCTAssertTrue(left.isEmpty)
    }

    /// A recorder that goes away part way leaves the rest alone rather than marking them refused.
    func testTheRestStayQueuedWhenTheRecorderGoesAway() async throws {
        let store = try store()
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
