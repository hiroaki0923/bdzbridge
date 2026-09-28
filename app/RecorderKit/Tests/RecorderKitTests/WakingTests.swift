import Foundation
import XCTest
@testable import RecorderKit

/// Waiting for a recorder to come back from a magic packet, which the screens, the overnight run and the
/// Shortcuts action all do through `Waking`. Nothing here waits in real time: the limits and the pauses are
/// milliseconds, and the packet is a closure that counts.
final class WakingTests: XCTestCase {
    private static let vectors = "description.json"

    /// Silence for the first asks, then the recorder's description: what a recorder coming up looks like.
    private func recorder(silentFor asks: Int) throws -> StubTransport {
        let xml = try Vectors.load(Self.vectors).string("description_xml")
        return StubTransport { _, index in
            guard index >= asks else { throw RecorderError.transport("silence") }
            return HTTPResponse(statusCode: 200, body: Data(xml.utf8))
        }
    }

    func testARecorderThatAnswersOnTheThirdAskHasAnswered() async throws {
        let transport = try recorder(silentFor: 2)
        let client = RecorderClient(host: Stub.host, transport: transport)
        let told = Collected()

        let outcome = await Waking.waitForAnswer(from: client, limit: 5, interval: .milliseconds(1),
                                                 resend: {}, waited: { await told.add($0) })

        XCTAssertEqual(outcome, .answered)
        let asked = await transport.requests.count
        XCTAssertEqual(asked, 3)
        let seconds = await told.values
        XCTAssertEqual(seconds.count, 3, "the wait is said once before each ask")
        XCTAssertEqual(seconds, seconds.sorted(), "the seconds said went backwards")
    }

    func testARecorderThatNeverAnswersIsSilentOnceTheLimitHasPassed() async throws {
        let transport = StubTransport { _, _ in throw RecorderError.transport("silence") }
        let client = RecorderClient(host: Stub.host, transport: transport)
        let started = Date()

        let outcome = await Waking.waitForAnswer(from: client, limit: 0.2, interval: .milliseconds(10),
                                                 resend: {})

        XCTAssertEqual(outcome, .silent)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2, "gave up before the limit")
        let asked = await transport.requests.count
        XCTAssertGreaterThan(asked, 1, "asked once and gave up")
    }

    /// Nothing acknowledges a magic packet, and one lost on the way was a recorder left asleep for the whole
    /// wait. So it goes again as often as `resendEvery` allows -- here after every pause -- and not once the
    /// recorder has answered.
    func testThePacketGoesAgainBetweenAsksAndNotAfterTheAnswer() async throws {
        let transport = try recorder(silentFor: 3)
        let client = RecorderClient(host: Stub.host, transport: transport)
        let packets = Collected()

        let outcome = await Waking.waitForAnswer(from: client, limit: 5, interval: .milliseconds(1),
                                                 resendEvery: 0, resend: { await packets.add(1) })

        XCTAssertEqual(outcome, .answered)
        let sent = await packets.values.count
        XCTAssertEqual(sent, 3, "one packet after each of the three asks that met silence")
    }

    /// The overnight run and the Shortcuts action send the first packet before a five-second probe, and the
    /// next one is due counting from that packet, not from when the waiting began.
    func testThePacketIsDueCountingFromWhenTheFirstWent() async throws {
        let transport = try recorder(silentFor: 1)
        let client = RecorderClient(host: Stub.host, transport: transport)
        let packets = Collected()

        let outcome = await Waking.waitForAnswer(from: client, limit: 5, interval: .milliseconds(1),
                                                 resendEvery: 60, packetSentAt: Date().addingTimeInterval(-61),
                                                 resend: { await packets.add(1) })

        XCTAssertEqual(outcome, .answered)
        let sent = await packets.values.count
        XCTAssertEqual(sent, 1, "the packet overdue since before the wait was not sent at the first chance")
    }

    func testThePacketIsNotSentAgainBeforeItsTime() async throws {
        let transport = try recorder(silentFor: 3)
        let client = RecorderClient(host: Stub.host, transport: transport)
        let packets = Collected()

        _ = await Waking.waitForAnswer(from: client, limit: 5, interval: .milliseconds(1),
                                       resendEvery: 60, resend: { await packets.add(1) })

        let sent = await packets.values.count
        XCTAssertEqual(sent, 0)
    }

    /// The overnight run is stopped when its time is up, and must not go on asking with the task completed.
    func testACancelledWaitEndsAtOnce() async throws {
        let transport = StubTransport { _, _ in throw RecorderError.transport("silence") }
        let client = RecorderClient(host: Stub.host, transport: transport)
        let waiting = Task {
            await Waking.waitForAnswer(from: client, limit: 60, interval: .milliseconds(10), resend: {})
        }
        try await Task.sleep(for: .milliseconds(50))

        let cancelledAt = Date()
        waiting.cancel()
        let outcome = await waiting.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1, "the wait went on after it was cancelled")
    }

    /// An answer that is an error -- a 503 from a recorder busy with somebody else, a 500 from one still
    /// starting up -- is not the recorder describing itself, and the wait goes on, as both of the loops this
    /// replaced did.
    func testAnErrorIsNotAnAnswer() async throws {
        let xml = try Vectors.load(Self.vectors).string("description_xml")
        // A 503 is sent again twice by the client before it is thrown, so the first ask is three requests.
        let transport = StubTransport { _, index in
            switch index {
            case 0...2: HTTPResponse(statusCode: 503)
            case 3: HTTPResponse(statusCode: 500)
            default: HTTPResponse(statusCode: 200, body: Data(xml.utf8))
            }
        }
        let client = RecorderClient(host: Stub.host, transport: transport, busyRetryDelay: 0...0)
        let told = Collected()

        let outcome = await Waking.waitForAnswer(from: client, limit: 5, interval: .milliseconds(1),
                                                 resend: {}, waited: { await told.add($0) })

        XCTAssertEqual(outcome, .answered)
        let asks = await told.values.count
        XCTAssertEqual(asks, 3, "a 503 and a 500 were taken for the recorder answering")
    }
}

/// What the closures were given, collected across the actor boundary.
private actor Collected {
    private(set) var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}
