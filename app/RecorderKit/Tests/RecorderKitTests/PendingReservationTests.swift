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
