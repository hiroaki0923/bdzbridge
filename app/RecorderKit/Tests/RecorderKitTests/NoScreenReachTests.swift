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
}
