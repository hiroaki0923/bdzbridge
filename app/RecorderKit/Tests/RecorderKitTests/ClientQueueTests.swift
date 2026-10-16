import Foundation
import XCTest
import RecorderKit

/// What a link's clients send of what was handed to them, whatever has become of the device meanwhile: each
/// client sends one request at a time, in the order they were handed over (`SerialQueue`), and a link makes a
/// client anew for every attempt. Through a link of the test's own to a recorder that can hold a request
/// (`PlayingRecorder`), with requests handed to the client the link holds, as a driver hands them.
@MainActor
final class ClientQueueTests: XCTestCase {
    /// The links a test made, held for as long as the tests run: a driver holds its link weakly.
    private static var links: [DeviceLink] = []

    private static let answers = [
        "X_GetTitleList": [Stub.soap("X_GetTitleList", result: "<xsrs></xsrs>", totalMatches: 0)],
        "X_UpdateTitle": [Stub.soap("X_UpdateTitle")],
        "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
    ]

    // MARK: - what still goes

    /// A connect to the same recorder makes a client of its own and lets go of nothing: a request held on the
    /// last client, and one queued behind it there, both go once the held one is let go, and the reconnect
    /// goes through.
    func testWhatIsQueuedOnTheLastClientGoesAcrossAReconnectToTheSameRecorder() async throws {
        let (world, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        await yield()

        let connecting = Task { await link.connect() }
        await yield()
        await recorder.letGo()
        try await within(10, "the reconnect never came back") { await connecting.value }

        let read = try await within(10, "the held read never came back") { await reading.result }
        XCTAssertNotNil(try? read.get(), "the held read failed")
        let protect = try await within(10, "the queued protect never came back") { await protecting.result }
        XCTAssertNoThrow(try protect.get(), "the protect queued on the last client failed")
        XCTAssertTrue(link.session.connected && link.clientIsAttached, world.problem ?? "no reason given")
        XCTAssertFalse(link.client === last, "the reconnect was meant to make a client of its own")
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 1,
                    "the protect queued on the last client was not sent")
    }

    /// A client made outside any link, at the link's address, is the link's in nothing: the link letting go of
    /// its device (`forgetTheDevice`) leaves what is queued on that client to go.
    func testWhatIsQueuedOnAClientOutsideTheLinkGoesWhenTheLinkLetsGo() async throws {
        let (_, link, recorder) = try await connected()
        let outside = RecorderClient(host: link.host, transport: recorder, busyRetryDelay: 0...0)
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await outside.titles() }
        try await recorder.whenHeld()
        let protecting = Task { try await outside.updateTitle(id: "0x1", protected: true) }
        await yield()

        link.forgetTheDevice()
        await recorder.letGo()

        let read = try await within(10, "the held read never came back") { await reading.result }
        XCTAssertNotNil(try? read.get(), "the held read failed")
        let protect = try await within(10, "the queued protect never came back") { await protecting.result }
        XCTAssertNoThrow(try protect.get(), "the protect queued on a client outside the link failed")
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 1,
                    "the protect queued on a client outside the link was not sent")
    }

    // MARK: - what the tests start from

    /// A link of the test's own to a recorder at the bench's address that answers as `answers` says and can hold
    /// a request (`PlayingRecorder`), connected a moment ago; the recorder has put down nothing yet. Whatever it
    /// holds is let go as the test is torn down.
    private func connected(_ answers: [String: [HTTPResponse]] = ClientQueueTests.answers) async throws
        -> (LinkWorld, DeviceLink, PlayingRecorder) {
        let world = LinkWorld()
        let recorder = try PlayingRecorder(answers, udn: DeviceLinkTests.udn)
        world.devices[Stub.host] = recorder
        addTeardownBlock { await recorder.letGo() }
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: nil), driver: driver,
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        await recorder.forget()
        world.events = []
        Self.links.append(link)
        return (world, link, recorder)
    }

    /// A bounded number of turns, for what was set going to get as far as its first wait.
    private func yield() async {
        for _ in 0..<1_000 { await Task.yield() }
    }

    /// Runs `work` and hands back what it returns, failing the test if it has not returned within `seconds`:
    /// what is tested here is a request that waits, and a test of it has to fail rather than wait with it.
    private func within<T: Sendable>(_ seconds: TimeInterval, _ what: String,
                                     _ work: @escaping @MainActor () async -> T) async throws -> T {
        let returned = expectation(description: what)
        let task = Task { @MainActor in
            let value = await work()
            returned.fulfill()
            return value
        }
        guard await XCTWaiter().fulfillment(of: [returned], timeout: seconds) == .completed else {
            XCTFail("\(what): still waiting after \(Int(seconds)) seconds")
            throw StillWaiting()
        }
        return await task.value
    }
}

/// Thrown to end a test whose wait was given up on, once the failure is recorded.
private struct StillWaiting: Error {}
