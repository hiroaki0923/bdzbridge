import Foundation
import XCTest
@testable import RecorderKit

/// The waking loop, the queue and the guide refresh, run against a device that is not a recorder.
///
/// They take whatever can be probed, reserved on or asked for a guide, and they read its errors through
/// `DeviceFailure`. The recorder's own tests show nothing changed for a recorder; these show that the rules
/// hold for something that has no SOAP, no XML and no `RecorderError` in it.
final class DeviceSeamTests: XCTestCase {
    /// Refused keeps its reason and waits for the reader, busy waits as it was, and silence stops the flush
    /// with the rest untouched: the queue's rules, read off the failure and not off the kind of error.
    func testTheQueueReadsTheFailureAndNotTheKindOfError() async throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let titles = ["断られる番組", "混んでいる番組", "送られる番組", "応答のない番組", "残される番組"]
        for (index, title) in titles.enumerated() {
            try await store.queue(pending(title, eventID: index + 1,
                                          start: now.addingTimeInterval(Double(index + 1) * 3600)))
        }
        let device = OtherDevice(creating: { request in
            switch request.title {
            case "断られる番組": throw OtherError(failure: .refused(reason: "この局は録画できません"))
            case "混んでいる番組": throw OtherError(failure: .busy)
            case "応答のない番組": throw OtherError(failure: .silent)
            default: break
            }
        })

        let outcome = await PendingQueue.flush(client: device, store: store, now: now)

        XCTAssertEqual(outcome.refused.map(\.request.title), ["断られる番組"])
        XCTAssertEqual(outcome.refused.first?.problem, "この局は録画できません")
        XCTAssertEqual(outcome.deferred.map(\.request.title), ["混んでいる番組"])
        XCTAssertEqual(outcome.sent.map(\.request.title), ["送られる番組"])
        XCTAssertTrue(outcome.interrupted)
        let asked = await device.created.map(\.title)
        XCTAssertEqual(asked, ["断られる番組", "混んでいる番組", "送られる番組", "応答のない番組"],
                       "nothing is sent once the device has gone quiet")
        let left = try await store.pendingReservations()
        XCTAssertEqual(left.map(\.request.title),
                       ["断られる番組", "混んでいる番組", "応答のない番組", "残される番組"])
        XCTAssertEqual(left.first?.problem, "この局は録画できません")
        XCTAssertNil(left.last?.problem)
    }

    /// A type the device has nothing for is noted, one that fails is passed over with the device's own words,
    /// and silence ends the refresh there.
    func testTheRefreshReadsTheFailureAndNotTheKindOfError() async throws {
        let store = try temporaryStore()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let service = GuideService(serviceID: 0x400, name: "サンプル総合", programs: [
            GuideProgram(serviceID: 0x400, eventID: 1, start: start, end: start.addingTimeInterval(1800),
                         title: "サンプルニュース"),
        ])
        let device = OtherDevice(guides: ["td": .success([service]), "bs": .success(nil),
                                          "cs": .failure(OtherError(failure: .unexpected("まだ用意できていません"))),
                                          "bs4k": .failure(OtherError(failure: .silent))])

        let outcome = try await GuideRefresh.run(client: device, store: store, types: ["td", "bs", "cs"])

        XCTAssertEqual(outcome.stored, 1)
        XCTAssertEqual(outcome.answered, ["td", "bs"])
        XCTAssertEqual(outcome.failed, [GuideRefresh.Failure(broadcasting: "cs", reason: "まだ用意できていません")])

        do {
            _ = try await GuideRefresh.run(client: device, store: store, types: ["bs4k", "td"])
            XCTFail("silence should end the refresh")
        } catch let error as any DeviceError {
            XCTAssertEqual(error.failure, .silent)
        }
        let asked = await device.guidesAsked
        XCTAssertEqual(asked, ["td", "bs", "cs", "bs4k"], "the type after the silent one was not asked for")
    }

    /// A device that is slower to say who it is than a recorder is asked with its own timeout.
    func testTheProbeIsGivenTheTimeoutTheCallerNames() async throws {
        let device = OtherDevice()

        _ = await Waking.waitForAnswer(from: device, limit: 5, interval: .milliseconds(1), probeTimeout: 7,
                                       resend: {})
        _ = await Waking.waitForAnswer(from: device, limit: 5, interval: .milliseconds(1), resend: {})

        expectEqual(await device.probeTimeouts, [7, RecorderClient.wakeProbeTimeout])
    }
}

/// What a device that is not a recorder throws.
private struct OtherError: DeviceError, Equatable {
    var failure: DeviceFailure
    var explanation: String {
        switch failure {
        case .refused(let reason), .deviceCannot(let reason), .unexpected(let reason): reason
        default: "テレビが応答しませんでした"
        }
    }
}

/// A device with nothing of a recorder about it: it is probed, asked for guides and reserved on.
private actor OtherDevice: GuideSource, ReservationTarget {
    private(set) var probeTimeouts: [TimeInterval] = []
    private(set) var created: [ReservationRequest] = []
    private(set) var guidesAsked: [String] = []
    private let creating: @Sendable (ReservationRequest) throws -> Void
    private let guides: [String: Result<[GuideService]?, OtherError>]

    init(guides: [String: Result<[GuideService]?, OtherError>] = [:],
         creating: @escaping @Sendable (ReservationRequest) throws -> Void = { _ in }) {
        self.guides = guides
        self.creating = creating
    }

    func probe(timeout: TimeInterval) async throws {
        probeTimeouts.append(timeout)
    }

    func guide(_ broadcasting: String) async throws -> [GuideService]? {
        guidesAsked.append(broadcasting)
        return try guides[broadcasting]?.get()
    }

    func logos(_ broadcasting: String) async throws -> [StationLogo]? { nil }

    func create(_ request: ReservationRequest) async throws {
        created.append(request)
        try creating(request)
    }
}
