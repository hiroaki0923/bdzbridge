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
    /// Their hosts, which a link holds weakly too.
    private static var hosts: [AnyObject] = []
    private static let anotherUDN = "uuid:00000000-0000-0000-0000-f84e17000002"

    private static let answers = [
        "X_GetTitleList": [Stub.soap("X_GetTitleList", result: "<xsrs></xsrs>", totalMatches: 0)],
        "X_UpdateTitle": [Stub.soap("X_UpdateTitle")],
        "X_DeleteTitle": [Stub.soap("X_DeleteTitle")],
        "X_GetRecordScheduleList": [Stub.soap("X_GetRecordScheduleList", result: listing(waiting.request),
                                              totalMatches: 1)],
        "X_DeleteRecordSchedule": [Stub.soap("X_DeleteRecordSchedule")],
        "X_CreateRecordSchedule": [Stub.soap("X_CreateRecordSchedule")],
    ]
    /// A reservation waiting on the phone, whose programme is a day off when the queue is sent (`before`).
    private static let waiting = pending("サンプル番組", eventID: 0x4001)
    private static let before = waiting.request.start.addingTimeInterval(-86_400)
    /// What an earlier operation left on the line.
    private static let left = "left by the request before"

    /// The recorder's list holding one reservation of `request`, under the id 0x9001.
    private static func listing(_ request: ReservationRequest) -> String {
        let open = "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\">"
        return open + XsrsElements.update(id: "0x9001", request).replacingOccurrences(of: open, with: "")
    }

    // MARK: - what no longer goes

    /// What is queued on the link's client behind a request still out when the link lets go of its device
    /// (`forgetTheDevice`) is not sent, and is thrown as one let go of meanwhile; the request that was out comes
    /// back as it would.
    func testWhatIsQueuedWhenTheDeviceIsLetGoOfIsNotSent() async throws {
        let (_, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        await yield()

        link.forgetTheDevice()
        await recorder.letGo()

        let read = try await within(10, "the held read never came back") { await reading.result }
        XCTAssertNotNil(try? read.get(), "the request that was out failed")
        let protect = try await within(10, "the queued protect never came back") { await protecting.result }
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 0,
                    "the protect queued behind it went once the device was let go of")
        XCTAssertEqual(failure(of: protect), .letGoMeanwhile)
    }

    /// The same across another recorder describing itself on a connect at the address, whose client is its own:
    /// what was queued on the last one is not sent, and the newcomer is taken up.
    func testWhatIsQueuedWhenAnotherRecorderDescribesItselfIsNotSent() async throws {
        let (world, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        await yield()

        let newcomer = try PlayingRecorder(Self.answers, udn: Self.anotherUDN)
        world.devices[Stub.host] = newcomer
        let connecting = Task { await link.connect() }
        await yield()
        await recorder.letGo()
        try await within(10, "the newcomer's connect never came back") { await connecting.value }

        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, world.problem ?? "no reason given")
        XCTAssertTrue(link.clientIsAttached, "the newcomer was not attached on its own client")
        _ = try await within(10, "the held read never came back") { await reading.result }
        let protect = try await within(10, "the queued protect never came back") { await protecting.result }
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 0,
                    "the protect queued on the last client went once the newcomer had described itself")
        expectEqual(await newcomer.actions.filter { $0 == "X_UpdateTitle" }.count, 0)
        XCTAssertEqual(failure(of: protect), .letGoMeanwhile)
    }

    /// A request the recorder answers 503 is not sent again once the device has been let go of while it was
    /// out: let go of before the first 503 comes back, the client's retries send nothing.
    func testABusyAnswerIsNotTriedAgainOnceTheDeviceIsLetGoOf() async throws {
        var answers = Self.answers
        answers["X_UpdateTitle"] = [HTTPResponse(statusCode: 503), HTTPResponse(statusCode: 503),
                                    Stub.soap("X_UpdateTitle")]
        let (_, link, recorder) = try await connected(answers)
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_UpdateTitle")
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        try await recorder.whenHeld()

        link.forgetTheDevice()
        await recorder.letGo()

        let protect = try await within(10, "the protect never came back") { await protecting.result }
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 1,
                    "the protect answered 503 was sent again once the device was let go of")
        XCTAssertEqual(failure(of: protect), .letGoMeanwhile)
    }

    /// A client kept past the let-go, as a driver keeps one for a step that comes later, sends nothing handed to
    /// it afterwards either.
    func testWhatIsHandedToAClientAfterItsDeviceWasLetGoOfIsNotSent() async throws {
        let (_, link, recorder) = try await connected()
        let kept = try XCTUnwrap(link.client as? RecorderClient)
        link.forgetTheDevice()

        let protect = await Task { try await kept.updateTitle(id: "0x1", protected: true) }.result
        expectEqual(await recorder.actions, [], "something was sent on a client kept past the let-go")
        XCTAssertEqual(failure(of: protect), .letGoMeanwhile)
    }

    /// A round of what waits on the phone, its first read queued on the link's client behind a request out when
    /// the link lets go of its device, sends nothing: it stops, every row waiting as it was with no reason on it,
    /// and nothing to tell. The next round, on the client of a connect made since, goes through.
    func testARoundQueuedWhenTheDeviceIsLetGoOfLeavesItsRows() async throws {
        var answers = Self.answers
        answers["X_GetRecordScheduleList"] = [Stub.soap("X_GetRecordScheduleList", result: "<xsrs></xsrs>",
                                                        totalMatches: 0)]
        let (world, link, recorder) = try await connected(answers)
        let store = try temporaryStore()
        try await store.queue(Self.waiting)
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let flushing = Task { await PendingQueue.flush(client: last, store: store, now: Self.before) }
        await yield()

        link.forgetTheDevice()
        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        let round = try await within(10, "the round never came back") { await flushing.value }

        expectEqual(await recorder.actions.filter { $0 != "X_GetTitleList" }, [], "the round sent something")
        XCTAssertEqual(round.stopped, .letGo)
        XCTAssertTrue(round.isEmpty, "a round that sent nothing had something to tell")
        expectEqual(try await store.pendingReservations(), [Self.waiting], "the row was not left as it waited")

        try await within(10, "the connect after the round never came back") { await link.connect() }
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        let fresh = try XCTUnwrap(link.client as? RecorderClient)
        let next = try await within(10, "the next round never came back") {
            await PendingQueue.flush(client: fresh, store: store, now: Self.before)
        }
        XCTAssertEqual(next.sent.map(\.id), [Self.waiting.id], "the next round did not send the row")
    }

    /// A round whose opening read was out when the link let go of its device sends no create on what came back:
    /// the read answered, and the create, on a client retired since, stops the round with the row as it waited.
    func testARoundWhoseReadWasOutWhenTheDeviceWasLetGoOfSendsNoCreate() async throws {
        var answers = Self.answers
        answers["X_GetRecordScheduleList"] = [Stub.soap("X_GetRecordScheduleList", result: "<xsrs></xsrs>",
                                                        totalMatches: 0)]
        let (_, link, recorder) = try await connected(answers)
        let store = try temporaryStore()
        try await store.queue(Self.waiting)
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_GetRecordScheduleList")
        let flushing = Task { await PendingQueue.flush(client: last, store: store, now: Self.before) }
        try await recorder.whenHeld()

        link.forgetTheDevice()
        await recorder.letGo()
        let round = try await within(10, "the round never came back") { await flushing.value }

        expectEqual(await recorder.actions, ["X_GetRecordScheduleList"], "the round sent its create")
        XCTAssertEqual(round.stopped, .letGo)
        XCTAssertEqual(round.deferred, [], "the row was passed over, to be told as one")
        XCTAssertTrue(round.isEmpty, "a round that made nothing had something to tell")
        expectEqual(try await store.pendingReservations(), [Self.waiting], "the row was not left as it waited")
    }

    /// The recorder's own sending of what waits, its round's first read queued behind a request out when the
    /// link lets go of its device, stops as let go of: nothing is sent, the row waits as it was, nothing is said
    /// on the line and the recorder is not lost.
    func testTheDriversSendingQueuedAcrossALetGoSaysNothing() async throws {
        var answers = Self.answers
        answers["X_GetRecordScheduleList"] = [Stub.soap("X_GetRecordScheduleList", result: "<xsrs></xsrs>",
                                                        totalMatches: 0)]
        let (world, link, recorder) = try await connected(answers)
        let store = try temporaryStore()
        world.cache = store
        // Its programme still to come, whenever the row is sent: a row over is dropped, and asks nothing.
        let ahead = pending("サンプル番組", eventID: 0x4002, start: Date(timeIntervalSince1970: 1_900_000_000))
        try await store.queue(ahead)
        let driver = try XCTUnwrap(link.driver as? RecorderDriver)
        let last = try XCTUnwrap(link.client as? RecorderClient)
        world.problem = Self.left
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let sending = Task { await driver.sendWhatWaits() }
        await yield()

        link.forgetTheDevice()
        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        let sent = try await within(10, "the sending never came back") { await sending.value }

        XCTAssertEqual(sent.round?.stopped, .letGo, "the round did not stop as let go of")
        expectEqual(await recorder.actions.filter { $0 != "X_GetTitleList" }, [], "the round sent something")
        XCTAssertEqual(world.problem, Self.left, "the sending wrote on the line")
        XCTAssertFalse(link.session.unreachable, "the recorder let go of was lost")
        expectEqual(try await store.pendingReservations(), [ahead], "the row was not left as it waited")
    }

    /// An attach whose client is retired part way -- the device let go of while one of its reads is out -- asks
    /// nothing after that read and ends as one let go of, writing nothing on the line: what let go of the
    /// device is the one to say why.
    func testAnAttachWhoseClientIsRetiredPartWayWritesNothing() async throws {
        let (world, link, recorder) = try await connected()
        world.problem = Self.left
        await recorder.holdTheNext("X_GetFirmwareVersion")
        let connecting = Task { await link.connect() }
        try await recorder.whenHeld()

        link.forgetTheDevice()
        await recorder.letGo()
        try await within(10, "the connect never came back") { await connecting.value }

        expectEqual(await recorder.actions, ["description.xml", "X_GetFirmwareVersion"],
                    "the attach asked on after its client was retired")
        XCTAssertEqual(world.problem, Self.left, "the attach wrote on the line")
        XCTAssertFalse(link.session.connected)
    }

    /// A check whose ask of who answers waited behind a request out when the link let go of its device asks
    /// nothing, and comes to the let-go: nothing written on the line, nobody lost.
    func testACheckQueuedAcrossALetGoComesToTheLetGo() async throws {
        let (world, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        world.problem = Self.left
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let checking = Task { await link.check(evenIfRecent: true) }
        await yield()

        link.forgetTheDevice()
        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        let checked = try await within(10, "the check never came back") { await checking.value }

        guard case .notUp(.letGo) = checked else { return XCTFail("the check came to \(checked)") }
        expectEqual(await recorder.actions, ["X_GetTitleList"], "the check asked who answers on a retired client")
        XCTAssertEqual(world.problem, Self.left, "the check wrote on the line")
        XCTAssertFalse(link.session.unreachable, "the recorder let go of was lost")
    }

    /// A reservation's change, queued on the link's client behind a request out when the link lets go of its
    /// device, is not sent, and says what a let-go says, as a delete does.
    func testARecordersChangeQueuedAcrossALetGoIsNotSent() async throws {
        let (world, link, recorder) = try await connected()
        let driver = try XCTUnwrap(link.driver as? RecorderDriver)
        let listed = await driver.reservations()
        let target = try XCTUnwrap(listed?.first, world.problem ?? "no list read")
        await recorder.forget()
        world.problem = nil
        let last = try XCTUnwrap(link.client as? RecorderClient)
        // The change's own read of the list held, a read handed in behind it and held in its turn: the change
        // follows the list and waits behind that read.
        await recorder.holdTheNext("X_GetRecordScheduleList")
        let changing = Task {
            await driver.update(target, quality: "SR", repeating: "none", disk: nil, now: Self.before)
        }
        try await recorder.whenHeld()
        let reading = Task { try await last.titles() }
        await yield()
        await recorder.holdTheNext("X_GetTitleList")
        await recorder.letGo()
        try await recorder.whenHeld()
        await yield()

        link.forgetTheDevice()
        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        let changed = try await within(10, "the change never came back") { await changing.value }

        expectEqual(await recorder.actions.filter { $0 == "X_UpdateRecordSchedule" }.count, 0,
                    "the change went once the recorder was let go of")
        XCTAssertEqual(changed.altered, .notDone(RecorderDriver.anotherAnswered))
        XCTAssertNil(world.problem, "the change wrote on the line")
    }

    /// A reservation's delete, queued on the link's client behind a request out when another recorder describes
    /// itself, is not sent, and says that another recorder answered, as one let go of before it is sent.
    func testARecordersDeleteQueuedAcrossALetGoSaysAnotherAnswered() async throws {
        let (world, link, recorder) = try await connected()
        let driver = try XCTUnwrap(link.driver as? RecorderDriver)
        let listed = await driver.reservations()
        let target = try XCTUnwrap(listed?.first, world.problem ?? "no list read")
        await recorder.forget()
        world.problem = nil
        let last = try XCTUnwrap(link.client as? RecorderClient)
        // The delete's own read of the list held, a read handed in behind it and held in its turn: the delete
        // follows the list and waits behind that read.
        await recorder.holdTheNext("X_GetRecordScheduleList")
        let cancelling = Task { await driver.cancel(target) }
        try await recorder.whenHeld()
        let reading = Task { try await last.titles() }
        await yield()
        await recorder.holdTheNext("X_GetTitleList")
        await recorder.letGo()
        try await recorder.whenHeld()
        await yield()

        let newcomer = try PlayingRecorder(Self.answers, udn: Self.anotherUDN)
        world.devices[Stub.host] = newcomer
        await link.connect()
        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, world.problem ?? "no reason given")
        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        let cancelled = try await within(10, "the delete never came back") { await cancelling.value }

        expectEqual(await recorder.actions.filter { $0 == "X_DeleteRecordSchedule" }.count, 0,
                    "the delete went once another recorder had described itself")
        expectEqual(await newcomer.actions.filter { $0 == "X_DeleteRecordSchedule" }.count, 0)
        XCTAssertEqual(cancelled.deleted, .notDone(RecorderDriver.anotherAnswered))
    }

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

    // MARK: - a television's

    /// A television's client sends nothing either of what was queued on it when its link lets go of the device:
    /// the request out comes back, the one behind it is not sent and is thrown as one let go of meanwhile.
    func testWhatIsQueuedOnATelevisionsClientWhenItIsLetGoOfIsNotSent() async throws {
        let bench = await television()
        let last = try XCTUnwrap(bench.link.client as? ScalarClient)
        let asked = await bench.gate.asked.count
        let latch = Latch()
        addTeardownBlock { await latch.open() }
        await bench.gate.before("getPowerStatus") { await latch.wait() }
        let asking = Task { try await last.powerStatus() }
        try await within(10, "the request never came to be held") { await latch.whenWaiting() }
        let reading = Task { try await last.interface() }
        await yield()

        bench.link.forgetTheDevice()
        await latch.open()

        _ = try await within(10, "the held request never came back") { await asking.result }
        let read = try await within(10, "the queued request never came back") { await reading.result }
        expectEqual(await bench.gate.asked.dropFirst(asked).filter { $0 == "getInterfaceInformation" }.count, 0,
                    "the request queued behind it went once the television was let go of")
        XCTAssertEqual(failure(of: read), .letGoMeanwhile)
    }

    /// A television's delete, queued on its link's client behind a request out when the link lets go of the
    /// device, is not sent, and says the app is not connected to the television: the host that would show the
    /// line has gone with the link.
    func testATelevisionsDeleteQueuedAcrossALetGoSaysNotConnected() async throws {
        let bench = await television()
        let listed = await bench.driver.reservations()
        let target = try XCTUnwrap(listed?.first, bench.world.problem ?? "no list read")
        bench.world.problem = nil
        let last = try XCTUnwrap(bench.link.client as? ScalarClient)
        let list = Latch(), read = Latch()
        addTeardownBlock {
            await list.open()
            await read.open()
        }
        await bench.gate.before("getScheduleList") { await list.wait() }
        await bench.gate.before("getInterfaceInformation") { await read.wait() }
        let cancelling = Task { await bench.driver.cancel(target) }
        try await within(10, "the delete's read never came to be held") { await list.whenWaiting() }
        let reading = Task { try await last.interface() }
        await yield()
        await list.open()
        try await within(10, "the request behind it never came to be held") { await read.whenWaiting() }
        await yield()

        bench.link.forgetTheDevice()
        await read.open()
        _ = try await within(10, "the held request never came back") { await reading.result }
        let cancelled = try await within(10, "the delete never came back") { await cancelling.value }

        expectEqual(await bench.gate.asked.filter { $0 == "deleteSchedule" }.count, 0,
                    "the delete went once the television was let go of")
        XCTAssertEqual(cancelled.deleted, .notDone(TVDriver.notConnected))
    }

    /// The same of a change, on a television's row still to come.
    func testATelevisionsChangeQueuedAcrossALetGoSaysNotConnected() async throws {
        let bench = await television(startingAt: Date(timeIntervalSince1970: 1_900_000_000))
        let listed = await bench.driver.reservations()
        let target = try XCTUnwrap(listed?.first, bench.world.problem ?? "no list read")
        bench.world.problem = nil
        let last = try XCTUnwrap(bench.link.client as? ScalarClient)
        let list = Latch(), read = Latch()
        addTeardownBlock {
            await list.open()
            await read.open()
        }
        await bench.gate.before("getScheduleList") { await list.wait() }
        await bench.gate.before("getInterfaceInformation") { await read.wait() }
        let changing = Task { await bench.driver.update(target, repeating: "daily") }
        try await within(10, "the change's read never came to be held") { await list.whenWaiting() }
        let reading = Task { try await last.interface() }
        await yield()
        await list.open()
        try await within(10, "the request behind it never came to be held") { await read.whenWaiting() }
        await yield()
        let asked = await bench.gate.asked.count

        bench.link.forgetTheDevice()
        await read.open()
        _ = try await within(10, "the held request never came back") { await reading.result }
        let changed = try await within(10, "the change never came back") { await changing.value }

        expectEqual(Array(await bench.gate.asked.dropFirst(asked)), [],
                    "the change went once the television was let go of")
        XCTAssertEqual(changed.altered, .notDone(TVDriver.notConnected))
    }

    /// A television's sending of what waits, its round's first read queued behind a request out when the link
    /// lets go of the television, stops as let go of: nothing is sent, the row waits as it was, and nothing is
    /// said on the line.
    func testATelevisionsSendingQueuedAcrossALetGoSaysNothing() async throws {
        let bench = await television()
        let store = try temporaryStore()
        bench.world.cache = store
        let ahead = pending("サンプル番組", eventID: 0x4003, start: Date(timeIntervalSince1970: 1_900_000_000),
                            target: .tv)
        try await store.queue(ahead)
        let last = try XCTUnwrap(bench.link.client as? ScalarClient)
        bench.world.problem = Self.left
        let latch = Latch()
        addTeardownBlock { await latch.open() }
        await bench.gate.before("getPowerStatus") { await latch.wait() }
        let asking = Task { try await last.powerStatus() }
        try await within(10, "the request never came to be held") { await latch.whenWaiting() }
        let sending = Task { await bench.driver.sendWhatWaits() }
        await yield()
        let asked = await bench.gate.asked.count

        bench.link.forgetTheDevice()
        await latch.open()
        _ = try await within(10, "the held request never came back") { await asking.result }
        let sent = try await within(10, "the sending never came back") { await sending.value }

        XCTAssertEqual(sent?.stopped, .letGo, "the round did not stop as let go of")
        expectEqual(Array(await bench.gate.asked.dropFirst(asked)), [], "the round sent something")
        XCTAssertEqual(bench.world.problem, Self.left, "the sending wrote on the line")
        expectEqual(try await store.pendingReservations(), [ahead], "the row was not left as it waited")
    }

    /// A television's attach whose client is retired part way asks nothing after the read that was out, and
    /// writes nothing on the line, as a recorder's does.
    func testATelevisionsAttachWhoseClientIsRetiredPartWayWritesNothing() async throws {
        let bench = await television()
        let latch = Latch()
        addTeardownBlock { await latch.open() }
        await bench.gate.before("getInterfaceInformation") { await latch.wait() }
        bench.world.problem = Self.left
        let connecting = Task { await bench.link.connect() }
        try await within(10, "the attach's read never came to be held") { await latch.whenWaiting() }
        let asked = await bench.gate.asked.count

        bench.link.forgetTheDevice()
        await latch.open()
        try await within(10, "the connect never came back") { await connecting.value }

        expectEqual(Array(await bench.gate.asked.dropFirst(asked)), [],
                    "the attach asked on after its client was retired")
        XCTAssertEqual(bench.world.problem, Self.left, "the attach wrote on the line")
    }

    /// A check of a television whose ask waited behind a request out when the link let go of it asks nothing
    /// and comes to the let-go: nothing written on the line, and nothing kept on the link as heard in the
    /// television's place.
    func testATelevisionsCheckQueuedAcrossALetGoComesToTheLetGo() async throws {
        let bench = await television()
        let last = try XCTUnwrap(bench.link.client as? ScalarClient)
        let latch = Latch()
        addTeardownBlock { await latch.open() }
        await bench.gate.before("getPowerStatus") { await latch.wait() }
        let asking = Task { try await last.powerStatus() }
        try await within(10, "the request never came to be held") { await latch.whenWaiting() }
        let checking = Task { await bench.link.check(evenIfRecent: true) }
        await yield()
        let asked = await bench.gate.asked.count

        bench.link.forgetTheDevice()
        await latch.open()
        _ = try await within(10, "the held request never came back") { await asking.result }
        let checked = try await within(10, "the check never came back") { await checking.value }

        guard case .notUp(.letGo) = checked else { return XCTFail("the check came to \(checked)") }
        expectEqual(Array(await bench.gate.asked.dropFirst(asked)), [], "the check asked on a retired client")
        XCTAssertNil(bench.world.problem, "the check wrote on the line")
        XCTAssertFalse(bench.link.checksAgain, "the check kept something heard in the television's place")
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

    /// A link of the test's own to an invented television that holds one reservation, starting at `start`,
    /// registered with it, the television behind a gate a test can hold a request at (`TVGate`), connected a
    /// moment ago.
    private func television(startingAt start: Date = ClientQueueTests.waiting.request.start) async
        -> (world: LinkWorld, link: DeviceLink, driver: TVDriver, gate: TVGate) {
        let television = DemoTV()
        await television.put([DemoTV.Schedule(id: "recording.41", title: "サンプル劇場",
                                              start: start, eventId: 12345)])
        await television.knows("BDBridge:test", cookie: "kept")
        // The app out of the way (`inFront`), so that no renewal is asked whatever the cookie's age.
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept"))
        let gate = TVGate(television)
        let world = LinkWorld()
        world.devices[Stub.host] = gate
        let driver = TVDriver(credentials: credentials, nickname: "BD Bridge", inFront: { false })
        let link = DeviceLink(host: Stub.host, session: SessionState(), driver: driver,
                              environment: world.environment)
        let host = NoRecorder(world)
        link.owner = host
        Self.hosts.append(host)
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        world.problem = nil
        Self.links.append(link)
        return (world, link, driver, gate)
    }

    /// How what came back from a request failed, as an operation reads it, or nil when it went through.
    private func failure<T>(of result: Result<T, any Error>) -> OperationFailure? {
        guard case .failure(let error) = result else { return nil }
        return OperationFailure(error, sending: nil)
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

/// Holds whoever waits on it until it is opened, for a gate to hold a request at (`TVGate.before`).
private actor Latch {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Lets every waiter go, and whoever comes afterwards through at once.
    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    /// Returns once somebody waits on it.
    func whenWaiting() async {
        while waiting.isEmpty, !opened { await Task.yield() }
    }
}

/// A host for a television's link: the world's, with nothing of what only a recorder's link asks of its host.
@MainActor
private final class NoRecorder: LinkHost {
    let world: LinkWorld

    init(_ world: LinkWorld) {
        self.world = world
    }

    var problem: String? {
        get { world.problem }
        set { world.problem = newValue }
    }
    func beginActivity(_ text: String) -> Activities.Token { world.beginActivity(text) }
    func updateActivity(_ token: Activities.Token, to text: String) { world.updateActivity(token, to: text) }
    func endActivity(_ token: Activities.Token) { world.endActivity(token) }
    var isBusy: Bool { world.isBusy }
    var holdsOffConnect: Bool { world.holdsOffConnect }
    var isDemo: Bool { world.isDemo }
    var cache: GuideStore? { world.cache }
    func cacheForAttempt() async { await world.cacheForAttempt() }
    func keepAddress(_ host: String) { world.keepAddress(host) }
    func keepMAC(_ text: String) { world.keepMAC(text) }
    func sendWhatWaits() async { await world.sendWhatWaits() }
    func queueWritten() async { await world.queueWritten() }
    func reached() async { await world.reached() }
    func anotherAnsweredTheCheck() { world.anotherAnsweredTheCheck() }
    func waitForPermission(at host: String) { world.waitForPermission(at: host) }
    func stopWaitingForPermission() { world.stopWaitingForPermission() }
}
