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
