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
        await attaching(link, in: world, after: last)
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
        // The newcomer's connect asks who answers once the read out on the last client is back.
        let connecting = Task { await link.connect() }
        await attaching(link, in: world, after: last)
        await recorder.letGo()
        try await within(10, "the newcomer's connect never came back") { await connecting.value }
        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, world.problem ?? "no reason given")
        _ = try await within(10, "the held read never came back") { await reading.result }
        let cancelled = try await within(10, "the delete never came back") { await cancelling.value }

        expectEqual(await recorder.actions.filter { $0 == "X_DeleteRecordSchedule" }.count, 0,
                    "the delete went once another recorder had described itself")
        expectEqual(await newcomer.actions.filter { $0 == "X_DeleteRecordSchedule" }.count, 0)
        XCTAssertEqual(cancelled.deleted, .notDone(RecorderDriver.anotherAnswered))
    }

    /// A keyword condition's delete the recorder answers as holding no such condition (892) once it has been let
    /// go of -- forgotten while the delete was out -- reads nothing after it, the list to read being the
    /// newcomer's, and says why it was let go of (`whyLetGo`), not what the recorder let go of answered: that
    /// another recorder answered, with nothing written on the line.
    func testAConditionsDeleteAnsweredAsNotHeldAcrossALetGoSaysWhyItWasLetGoOf() async throws {
        let list = try Vectors.load("xsrs.json").dictionary("recorder_rules").string("list_result")
        var answers = Self.answers
        answers["X_GetPrefRecSettingList"] = [Stub.soap("X_GetPrefRecSettingList", result: list)]
        answers["X_DeletePrefRecSetting"] = [Stub.fault("892")]
        let (world, link, recorder) = try await connected(answers)
        let driver = try XCTUnwrap(link.driver as? RecorderDriver)
        let listed = await driver.recorderRules().list
        let rule = try XCTUnwrap(listed?.first, world.problem ?? "no list read")
        await recorder.forget()
        world.problem = nil
        await recorder.holdTheNext("X_DeletePrefRecSetting")
        let deleting = Task { await driver.removeRule(rule) { _ in } }
        try await recorder.whenHeld()

        link.forgetTheDevice()
        await recorder.letGo()
        let deleted = try await within(10, "the delete never came back") { await deleting.value }

        expectEqual(await recorder.actions, ["X_GetPrefRecSettingList", "X_DeletePrefRecSetting"],
                    "the list was read after a delete answered once the recorder was let go of")
        XCTAssertEqual(deleted, .notDone(RecorderDriver.anotherAnswered))
        XCTAssertNil(world.problem, "the delete wrote on the line")
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

    // MARK: - one request on the wire at an address

    /// A connect to the address while the last client has a write out there, the recorder that answers now
    /// another: the connect's ask of who answers is not sent until the write has come back, and then is, and the
    /// newcomer taken up.
    func testANewcomersDescribeWaitsForTheWriteOutOnTheLastClient() async throws {
        let (world, link, recorder) = try await connected()
        let newcomer = try PlayingRecorder(Self.answers, udn: Self.anotherUDN)
        try await askedOnlyOnceTheWriteIsBack(on: link, in: world, last: recorder, now: newcomer,
                                              answering: Self.anotherUDN)
    }

    /// The same for a connect to the same recorder, which lets go of nothing.
    func testAReconnectsDescribeWaitsForTheWriteOutOnTheLastClient() async throws {
        let (world, link, recorder) = try await connected()
        try await askedOnlyOnceTheWriteIsBack(on: link, in: world, last: recorder, now: recorder,
                                              answering: DeviceLinkTests.udn)
    }

    /// A connect to another address waits for nothing the last client has out where it was.
    func testAConnectToAnotherAddressWaitsForNothing() async throws {
        let (world, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_UpdateTitle")
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        try await recorder.whenHeld()

        let elsewhere = try PlayingRecorder(Self.answers, udn: Self.anotherUDN)
        world.devices["192.0.2.11"] = elsewhere
        link.forgetTheDevice()
        link.host = "192.0.2.11"
        try await within(10, "the connect to another address never came back") { await link.connect() }
        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, world.problem ?? "no reason given")
        expectEqual(await elsewhere.actions.first, "description.xml")
        expectTrue(await recorder.isHolding, "the write out where the recorder was came back meanwhile")

        await recorder.letGo()
        _ = try await within(10, "the held write never came back") { await protecting.result }
    }

    /// A request of a link's client that waits for the wire goes once its own timeout has gone by, as it would
    /// have gone before: it waits for nothing longer than it would wait for its own answer.
    func testARequestWaitsForTheWireNoLongerThanItsOwnTimeout() async throws {
        let (_, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_UpdateTitle")
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        try await recorder.whenHeld()

        let another = try XCTUnwrap(link.driver.makeClient(for: link) as? RecorderClient)
        let described = try await within(10, "the describe waited past its own timeout") {
            await Task { try await another.describe(timeout: 0.2) }.result
        }
        XCTAssertNoThrow(try described.get())
        expectTrue(await recorder.isHolding, "the write out came back meanwhile")

        await recorder.letGo()
        _ = try await within(10, "the held write never came back") { await protecting.result }
    }

    /// A read handed to the connect's client while its ask of who answers waits for the wire, and so queued
    /// behind it, keeps the wire from the other clients as the ask does: back before the attach has heard that
    /// another recorder answers -- the attach kept from its turn here -- it gives the wire to nobody, and a
    /// write queued on the last client goes only once the attach has heard, and so not at all.
    func testAReadBehindTheConnectsDescribeKeepsTheWireUntilTheAttachHasHeard() async throws {
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
        await attaching(link, in: world, after: last)
        let fresh = try XCTUnwrap(link.client as? RecorderClient)
        let readingFresh = Task { try await fresh.titles() }
        await yield()

        await recorder.letGo()
        // The attach goes on in a turn of the main actor's, which this keeps until the newcomer has answered the
        // read behind the ask, and a moment more for whatever the read's return would let go. (The last client
        // sends where the address led when it was made, to the recorder put there then.)
        var turns = 0
        while !newcomer.answered.contains("X_GetTitleList"), turns < 5_000 {
            turns += 1
            usleep(1_000)
        }
        XCTAssertTrue(newcomer.answered.contains("X_GetTitleList"), "the read behind the ask was never answered")
        for _ in 0..<200 where !recorder.answered.contains("X_UpdateTitle") { usleep(1_000) }

        try await within(10, "the newcomer's connect never came back") { await connecting.value }
        XCTAssertEqual(link.session.info?.udn, Self.anotherUDN, world.problem ?? "no reason given")
        _ = try await within(10, "the held read never came back") { await reading.result }
        _ = try await within(10, "the read behind the ask never came back") { await readingFresh.result }
        let protect = try await within(10, "the queued protect never came back") { await protecting.result }
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 0,
                    "the protect queued on the last client went before the attach had heard who answered")
        expectEqual(await newcomer.actions.filter { $0 == "X_UpdateTitle" }.count, 0)
        XCTAssertEqual(failure(of: protect), .letGoMeanwhile)
    }

    /// The same across a reconnect to the same recorder, which retires nothing: the attach lets go of what its
    /// description kept while the read behind it is still out, and a write queued on the last client waits for
    /// that read rather than go beside it.
    func testAReadBehindAReconnectsDescribeKeepsTheWireUntilItIsBack() async throws {
        let (world, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        await yield()
        let connecting = Task { await link.connect() }
        await attaching(link, in: world, after: last)
        let fresh = try XCTUnwrap(link.client as? RecorderClient)
        let readingFresh = Task { try await fresh.titles() }
        await yield()

        let reads = recorder.heard.count("X_GetTitleList")
        await recorder.holdTheNext("X_GetTitleList")
        await recorder.letGo()
        // The attach goes on in a turn of the main actor's, which this keeps until the read behind the ask has
        // reached the recorder, so that the attach lets go of what the description kept with the read out.
        var turns = 0
        while recorder.heard.count("X_GetTitleList") == reads, turns < 5_000 {
            turns += 1
            usleep(1_000)
        }
        XCTAssertEqual(recorder.heard.count("X_GetTitleList"), reads + 1, "the read behind the ask never came")
        try await recorder.whenHeld()
        // The attach has heard who answered once it keeps the address; a moment more for what that let go.
        for _ in 0..<100_000 where !world.events.contains("address \(Stub.host)") { await Task.yield() }
        XCTAssertTrue(world.events.contains("address \(Stub.host)"), "the attach never heard who answered")
        for _ in 0..<100_000 { await Task.yield() }
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 0,
                    "the protect went beside the read out on the connect's client")

        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        _ = try await within(10, "the read behind the ask never came back") { await readingFresh.result }
        let protect = try await within(10, "the queued protect never came back") { await protecting.result }
        XCTAssertNoThrow(try protect.get(), "the protect queued on the last client failed")
        try await within(10, "the reconnect never came back") { await connecting.value }
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
    }

    /// A connect's description keeps the wire only until the attach has heard it: the next connect at the
    /// address asks who answers at once, and does not wait out its ask's own timeout.
    func testTheWireADescriptionKeptIsTheOthersOnceTheAttachHasHeard() async throws {
        let (world, link, recorder) = try await connected()
        try await within(4, "the next connect waited for what the last one's description kept") {
            await link.connect()
        }
        expectEqual(await recorder.actions.first, "description.xml")
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
    }

    /// Requests that wait for the wire at an address go in the order their waits began.
    func testWaitsForTheWireEndInTheOrderTheyBegan() async throws {
        let (_, link, recorder) = try await connected()
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_GetTitleList")
        let reading = Task { try await last.titles() }
        try await recorder.whenHeld()
        let first = try XCTUnwrap(link.driver.makeClient(for: link) as? RecorderClient)
        let second = try XCTUnwrap(link.driver.makeClient(for: link) as? RecorderClient)
        let protecting = Task { try await first.updateTitle(id: "0x1", protected: true) }
        await yield()
        let deleting = Task { try await second.deleteTitle(id: "0x2") }
        await yield()

        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        _ = try await within(10, "the protect never came back") { await protecting.result }
        _ = try await within(10, "the delete never came back") { await deleting.result }
        expectEqual(await recorder.actions, ["X_GetTitleList", "X_UpdateTitle", "X_DeleteTitle"])
    }

    /// A request answered 503 waits for the wire again before its next try: a request of another client's that
    /// went in between is not sent beside.
    func testATryAfterABusyAnswerWaitsForTheWireAgain() async throws {
        var answers = Self.answers
        answers["X_UpdateTitle"] = [HTTPResponse(statusCode: 503), Stub.soap("X_UpdateTitle")]
        let (_, link, recorder) = try await connected(answers)
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_UpdateTitle")
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        try await recorder.whenHeld()
        let another = try XCTUnwrap(link.driver.makeClient(for: link) as? RecorderClient)
        let reading = Task { try await another.titles() }
        await yield()

        await recorder.holdTheNext("X_GetTitleList")
        await recorder.letGo()
        try await recorder.whenHeld()
        for _ in 0..<100_000 { await Task.yield() }
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 1,
                    "the protect's next try went beside the read of another client")

        await recorder.letGo()
        _ = try await within(10, "the held read never came back") { await reading.result }
        let protect = try await within(10, "the protect never came back") { await protecting.result }
        XCTAssertNoThrow(try protect.get())
        expectEqual(await recorder.actions.filter { $0 == "X_UpdateTitle" }.count, 2)
    }

    /// A write held on the last client, a connect begun at its address with `now` answering there as the
    /// recorder `answering`: nothing is asked of `now` while the write is out, and once it is back the connect
    /// asks who answers and takes it up.
    private func askedOnlyOnceTheWriteIsBack(on link: DeviceLink, in world: LinkWorld, last recorder: PlayingRecorder,
                                             now: PlayingRecorder, answering udn: String) async throws {
        let last = try XCTUnwrap(link.client as? RecorderClient)
        await recorder.holdTheNext("X_UpdateTitle")
        let protecting = Task { try await last.updateTitle(id: "0x1", protected: true) }
        try await recorder.whenHeld()
        await now.forget()

        world.devices[Stub.host] = now
        let connecting = Task { await link.connect() }
        for _ in 0..<100_000 { await Task.yield() }
        expectFalse(await now.actions.contains("description.xml"),
                    "who answers was asked while the last client had a write out at the address")

        await recorder.letGo()
        _ = try await within(10, "the held write never came back") { await protecting.result }
        try await within(10, "the connect never came back") { await connecting.value }
        expectTrue(await now.actions.contains("description.xml"), "who answers was never asked")
        XCTAssertEqual(link.session.info?.udn, udn, world.problem ?? "no reason given")
        XCTAssertTrue(link.clientIsAttached, world.problem ?? "no reason given")
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
    /// holds is let go as the test is torn down. A request waits for the wire as long as its own timeout, as in
    /// the app.
    private func connected(_ answers: [String: [HTTPResponse]] = ClientQueueTests.answers) async throws
        -> (LinkWorld, DeviceLink, PlayingRecorder) {
        let world = LinkWorld()
        world.wireWaitLimit = nil
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

    /// Returns once a connect begun on `link` has made a client in place of `last` and its attach is under way
    /// (接続中), and its ask of who answers has had the turns to get as far as its wait for the wire: waited
    /// for a bounded number of turns, and a failure when it has not come by then.
    private func attaching(_ link: DeviceLink, in world: LinkWorld, after last: RecorderClient) async {
        for _ in 0..<100_000 where link.client === last || world.line != "接続中" { await Task.yield() }
        XCTAssertFalse(link.client === last, "the connect made no client of its own")
        XCTAssertEqual(world.line, "接続中", "the connect's attach never began")
        await yield()
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
