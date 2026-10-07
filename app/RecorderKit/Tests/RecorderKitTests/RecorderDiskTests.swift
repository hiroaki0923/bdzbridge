import Foundation
import XCTest
@testable import RecorderKit

/// The disks a recorder records to: the slot read as the recorder answers it, what counts as a USB disk being
/// there, how one disk is told from another and named, what the low-space notice says, the recordings of one
/// disk, and the attach that reads the slot.
@MainActor
final class RecorderDiskTests: XCTestCase {
    /// The slot as `X_GetMediaInfo` describes a disk: the root, the elements and their order as a BDZ-FBT4100
    /// gives them, with the name, the time and the sizes made up. An element given as nil is left out.
    static func slot(name: String = "録画用ディスク", mount: String? = "1", remain: String = "123456",
                     total: String = "2000398", registered: String? = "2026-01-02T03:04:05+0900") -> String {
        var xml = "<?xml version=\"1.0\"?><xsrs xmlns=\"urn:schemas-xsrs-org:metadata-1-0/x_srs/\"><name>\(name)</name>"
        if let mount { xml += "<mount>\(mount)</mount>" }
        xml += "<remain>\(remain)</remain><total>\(total)</total>"
        if let registered { xml += "<registeredTime>\(registered)</registeredTime>" }
        return xml + "<recordableRemain>654321</recordableRemain></xsrs>"
    }

    static func disk(name: String = "録画用ディスク", mounted: Bool = true, total: Int? = 2_000_398,
                     registered: String = "2026-01-02T03:04:05+0900") -> RecorderDisk {
        RecorderDisk(destination: RecorderDisk.usbID, name: name, mounted: mounted, freeMB: 123_456, totalMB: total,
                     registered: registered)
    }

    private func client(answering response: HTTPResponse) -> (RecorderClient, StubTransport) {
        let transport = StubTransport(always: response)
        return (RecorderClient(host: Stub.host, transport: transport), transport)
    }

    // MARK: - the slot

    func testTheSlotIsReadAsTheRecorderAnswersIt() async throws {
        let (client, transport) = client(answering: Stub.soap("X_GetMediaInfo", result: Self.slot()))

        let read = try await client.disk(RecorderDisk.usbID)
        let disk = try XCTUnwrap(read)

        XCTAssertEqual(disk.destination, "USBHDD")
        XCTAssertEqual(disk.name, "録画用ディスク")
        XCTAssertTrue(disk.mounted)
        XCTAssertEqual(disk.freeMB, 123_456, "the free space is <remain>")
        XCTAssertEqual(disk.totalMB, 2_000_398)
        XCTAssertEqual(disk.registered, "2026-01-02T03:04:05+0900", "kept as written, never read as a time")
        XCTAssertEqual(disk.freeBytes, 123_456_000_000, "the recorder's MB is a million bytes")
        XCTAssertEqual(disk.totalBytes, 2_000_398_000_000)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.path, "/X_PvrControl")
        XCTAssertEqual(request.headers["SOAPACTION"], "\"\(Upnp.pvrService)#X_GetMediaInfo\"")
        let bodies = await transport.bodies
        let body = try XCTUnwrap(bodies.first)
        XCTAssertTrue(body.contains("<recordDestinationID>USBHDD</recordDestinationID>"), body)
    }

    /// Only a disk the recorder has registered counts. What the slot answers with no disk -- in a home that never
    /// had one, or with the disk unplugged -- has not been seen, so every answer that is not a registered disk is
    /// no disk: an empty result or none, a refusal, an answer that is not XML or names no mount, and a disk with
    /// no registration. Then nothing is drawn of a USB disk anywhere.
    func testASlotThatAnswersNoRegisteredDiskIsNoDisk() async throws {
        let answers: [(String, HTTPResponse)] = [
            ("an empty result", Stub.soap("X_GetMediaInfo", result: "")),
            ("no result", Stub.soap("X_GetMediaInfo")),
            ("refused", Stub.fault("803")),
            ("not XML", Stub.soap("X_GetMediaInfo", result: "no disk")),
            ("no mount", Stub.soap("X_GetMediaInfo", result: Self.slot(mount: nil))),
            ("unmounted and unregistered", Stub.soap("X_GetMediaInfo",
                                                     result: Self.slot(mount: "0", registered: nil))),
            ("an empty registration", Stub.soap("X_GetMediaInfo", result: Self.slot(registered: ""))),
        ]
        for (what, response) in answers {
            let (client, _) = client(answering: response)
            let disk = try await RecorderDriver.usbDisk(of: client)
            XCTAssertNil(disk, what)
        }

        // A registered disk the recorder says is not mounted is kept, as the disk it is, and offered nowhere.
        let (client, _) = client(answering: Stub.soap("X_GetMediaInfo", result: Self.slot(mount: "0")))
        let kept = try await RecorderDriver.usbDisk(of: client)
        let unplugged = try XCTUnwrap(kept)
        XCTAssertFalse(unplugged.mounted)
        XCTAssertFalse(unplugged.takesRecordings)
    }

    /// The slot is read at every attach and in every overnight run, and only silence says the recorder is gone.
    func testOnlySilenceGetsOutOfTheSlotsRead() async throws {
        let silent = RecorderClient(host: Stub.host, transport: StubTransport { _, _ in
            throw RecorderError.transport("timed out")
        })
        do {
            let disk = try await RecorderDriver.usbDisk(of: silent)
            XCTFail("silence was taken for an answer: \(String(describing: disk))")
        } catch let error as RecorderError {
            XCTAssertEqual(error.failure, .silent)
        }

        let (refusing, _) = client(answering: Stub.fault("401"))
        let refused = try await RecorderDriver.usbDisk(of: refusing)
        XCTAssertNil(refused, "a model without the call")
    }

    // MARK: - one disk and another

    func testADiskTakesRecordingsWhenItIsThereAndHasASize() {
        XCTAssertTrue(Self.disk().takesRecordings)
        XCTAssertFalse(Self.disk(mounted: false).takesRecordings)
        XCTAssertFalse(Self.disk(total: 0).takesRecordings)
        XCTAssertFalse(Self.disk(total: nil).takesRecordings)
        // A disk of no size has not said how full it is, and is not shown as full.
        XCTAssertNil(Self.disk(total: 0).freeBytes)
        XCTAssertNil(Self.disk(total: 0).totalBytes)
    }

    /// The slot is one id, and the disk behind it is taken to change. A disk is the one read before when the slot,
    /// its registration and its name are all the same, so a renamed disk counts as another.
    func testTheSameDiskIsTheSameSlotRegistrationAndName() {
        let disk = Self.disk()
        XCTAssertTrue(disk.isSameDisk(as: Self.disk()))
        XCTAssertTrue(disk.isSameDisk(as: Self.disk(mounted: false, total: nil)), "sizes and the mount are not who")
        XCTAssertFalse(disk.isSameDisk(as: Self.disk(name: "別のディスク")), "renamed")
        XCTAssertFalse(disk.isSameDisk(as: Self.disk(registered: "2026-02-03T04:05:06+0900")), "another disk")
        var elsewhere = Self.disk()
        elsewhere.destination = RecorderDisk.internalID
        XCTAssertFalse(disk.isSameDisk(as: elsewhere), "another slot")
        XCTAssertFalse(disk.isSameDisk(as: nil))
    }

    /// The recorder's name for a disk, or its own id where it gives none: never a name of the app's.
    func testADiskIsCalledWhatTheRecorderCallsIt() {
        XCTAssertEqual(RecorderDisk.label("HDD", named: ""), "HDD")
        XCTAssertEqual(RecorderDisk.label("USBHDD", named: nil), "USBHDD")
        XCTAssertEqual(RecorderDisk.label("USBHDD", named: "録画用ディスク"), "録画用ディスク")
    }

    /// Without a disk to name, the sentence a recorder with its own disk alone has always had, character for
    /// character; with one, the disk's label in front.
    func testTheLowSpaceNoticeNamesADiskOnlyWhenToldTo() {
        XCTAssertEqual(RecorderDisk.lowSpaceBody(freeGB: 42.4, naming: nil),
                       "残り 42 GB です。古い録画を整理するか、録画モードを見直してください。")
        XCTAssertEqual(RecorderDisk.lowSpaceBody(freeGB: 42.4, naming: "HDD"),
                       "HDDの残りが 42 GB です。古い録画を整理するか、録画モードを見直してください。")
        XCTAssertEqual(RecorderDisk.lowSpaceBody(freeGB: 7, naming: "100%ディスク"),
                       "100%ディスクの残りが 7 GB です。古い録画を整理するか、録画モードを見直してください。")
    }

    // MARK: - the recordings of one disk

    private static func titleItem(_ id: String, on destination: String?) -> String {
        "<item id=\"\(id)\"><title>t</title><scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
            + "<scheduledDuration>60</scheduledDuration>"
            + (destination.map { "<recordDestinationID>\($0)</recordDestinationID>" } ?? "") + "</item>"
    }

    /// A recorder that answers every criteria with every disk's rows, as one does with a criteria it does not
    /// know: two pages of two, the first all the internal disk's, the second one of each. Stops answering after
    /// a few requests, so that paging that never moves on fails rather than waits.
    private static func mixedPages() -> StubTransport {
        let first = "<xsrs>" + titleItem("0x1", on: "HDD") + titleItem("0x2", on: nil) + "</xsrs>"
        let second = "<xsrs>" + titleItem("0x3", on: "USBHDD") + titleItem("0x4", on: "HDD") + "</xsrs>"
        return StubTransport { request, index in
            guard index < 4 else { throw RecorderError.transport("asked too often") }
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            let page = body.contains("<StartingIndex>0</StartingIndex>") ? first : second
            return Stub.soap("X_GetTitleList", result: page, totalMatches: 4)
        }
    }

    /// A disk's list keeps the rows that say they are on it, read through every page by the page's own count; a
    /// row that names no disk is the internal disk's. With no disk named every row is kept, as it always was,
    /// whatever disk the rows say they are on.
    func testTheSlotsListKeepsOnlyTheSlotsRows() async throws {
        let usb = try await RecorderClient(host: Stub.host, transport: Self.mixedPages())
            .allTitles(pageSize: 2, on: RecorderDisk.usbID)
        XCTAssertEqual(usb.map(\.id), ["0x3"])

        let own = try await RecorderClient(host: Stub.host, transport: Self.mixedPages())
            .allTitles(pageSize: 2, on: RecorderDisk.internalID)
        XCTAssertEqual(own.map(\.id), ["0x1", "0x2", "0x4"])

        let every = try await RecorderClient(host: Stub.host, transport: Self.mixedPages()).allTitles(pageSize: 2)
        XCTAssertEqual(every.map(\.id), ["0x1", "0x2", "0x3", "0x4"], "a list with no disk named was narrowed")
    }

    /// The USB disk's recordings are asked for by its id, quoted with no spaces as the official client asks;
    /// the internal disk's with no criteria, as before.
    func testTheUSBDisksRecordingsAreAskedForByItsID() async throws {
        let transport = Self.mixedPages()
        let client = RecorderClient(host: Stub.host, transport: transport)
        _ = try await client.titles(count: 2, startingAt: 2, on: RecorderDisk.usbID)
        _ = try await client.titles(count: 2)

        let bodies = await transport.bodies
        XCTAssertTrue(bodies[0].contains("<SearchCriteria>recordDestinationID=&quot;USBHDD&quot;</SearchCriteria>"),
                      bodies[0])
        XCTAssertTrue(bodies[0].contains("<StartingIndex>2</StartingIndex>"), bodies[0])
        XCTAssertTrue(bodies[1].contains("<SearchCriteria></SearchCriteria>"), bodies[1])
    }

    // MARK: - the attach

    /// A recorder that describes itself as the recorder of the vectors does, under that one's UDN or the one it is
    /// given, answers the slot as it is told, and refuses everything else an attach reads, which the attach does
    /// without. What it answers the slot, and which recorder it says it is, can be changed between two attaches, as
    /// a disk put in or taken out, or another recorder at the address, would change them. It counts the slot's
    /// reads, and can hold them, once it has let a number through, until the test lets them go: a read held is
    /// counted as it arrives, and answered as the slot is by the time it goes.
    private actor SlotRecorder: HTTPTransport {
        enum Slot { case answer(HTTPResponse), silence }
        private var slot: Slot
        private var description = ""
        private(set) var slotReads = 0
        private var throughBeforeHolding: Int?
        private var held: [CheckedContinuation<Void, Never>] = []

        init(_ slot: Slot, udn: String = RecorderDiskTests.vectorUDN) {
            self.slot = slot
            description = Self.describing(udn)
        }

        private static func describing(_ udn: String) -> String {
            ((try? Vectors.load("description.json"))?.string("description_xml") ?? "")
                .replacingOccurrences(of: RecorderDiskTests.vectorUDN, with: udn)
        }

        func answer(_ slot: Slot) { self.slot = slot }
        func become(udn: String) { description = Self.describing(udn) }
        func holdSlotReads(after count: Int) { throughBeforeHolding = count }

        func letGo() {
            throughBeforeHolding = nil
            for read in held { read.resume() }
            held = []
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            if request.url.lastPathComponent == "description.xml" {
                return HTTPResponse(statusCode: 200, body: Data(description.utf8))
            }
            guard request.headers["SOAPACTION"]?.contains("#X_GetMediaInfo") == true else {
                return HTTPResponse(statusCode: 500)
            }
            slotReads += 1
            if let through = throughBeforeHolding {
                if through > 0 {
                    throughBeforeHolding = through - 1
                } else {
                    await withCheckedContinuation { held.append($0) }
                }
            }
            switch slot {
            case .answer(let response): return response
            case .silence: throw RecorderError.transport("The request timed out.")
            }
        }
    }

    /// The UDN of the recorder of the vectors, all zeroes, and another recorder's: Sony's OUI and the rest zeroed,
    /// as everywhere in this repository, with a last digit of its own.
    nonisolated static let vectorUDN = "uuid:00000000-0000-0000-0000-000000000000"
    nonisolated static let anotherUDN = "uuid:00000000-0000-0000-0000-f84e17000002"

    private func connected(to slot: SlotRecorder.Slot) async -> (DeviceLink, LinkWorld) {
        await connected(to: SlotRecorder(slot))
    }

    private func connected(to recorder: SlotRecorder,
                           in world: LinkWorld = LinkWorld()) async -> (DeviceLink, LinkWorld) {
        world.devices[Stub.host] = recorder
        let link = DeviceLink(host: Stub.host, session: SessionState(),
                              driver: RecorderDriver(holdingTheQueueWith: "held", wakingLimit: 0.05,
                                                     wakingInterval: .milliseconds(10), busyRetryDelay: 0...0),
                              environment: world.environment)
        link.owner = world
        await link.connect()
        return (link, world)
    }

    /// The attach reads the slot and keeps what it found. A refusal is no disk and does not fail the attach;
    /// silence does, as it does anywhere.
    func testTheAttachReadsTheSlotAndOnlySilenceFailsIt() async {
        let (link, world) = await connected(to: .answer(Stub.soap("X_GetMediaInfo", result: Self.slot())))
        XCTAssertTrue(link.session.connected)
        XCTAssertEqual(link.session.usbDisk, Self.disk())
        XCTAssertEqual(link.session.timesAttached, 1)

        let (refused, refusedWorld) = await connected(to: .answer(Stub.fault("803")))
        XCTAssertTrue(refused.session.connected)
        XCTAssertNil(refused.session.usbDisk)
        XCTAssertEqual(refused.session.timesAttached, 1, "a slot refused failed the attach")
        XCTAssertNil(refusedWorld.problem)
        XCTAssertNil(world.problem)

        let (silent, _) = await connected(to: .silence)
        XCTAssertFalse(silent.session.connected)
        XCTAssertTrue(silent.session.unreachable)
        XCTAssertEqual(silent.session.timesAttached, 0)
    }

    /// What waits is sent before the slot is read, so that a slot slow to answer, or silent, does not hold back a
    /// reservation: with a disk in the slot and with silence there alike.
    func testWhatWaitsIsSentBeforeTheSlotIsRead() async {
        let slots: [(String, SlotRecorder.Slot)] = [
            ("a disk", .answer(Stub.soap("X_GetMediaInfo", result: Self.slot()))),
            ("silence", .silence),
        ]
        for (what, slot) in slots {
            let recorder = SlotRecorder(slot)
            let world = LinkWorld()
            var slotReadsWhenSent: [Int] = []
            world.onSendWhatWaits = { slotReadsWhenSent.append(await recorder.slotReads) }

            _ = await connected(to: recorder, in: world)

            XCTAssertEqual(slotReadsWhenSent, [0], "what waits was not sent first, or not at all: \(what)")
            let reads = await recorder.slotReads
            XCTAssertEqual(reads, 1, what)
        }
    }

    /// Each attach reads the slot afresh: another disk put in it is the one known after the next attach, and so is
    /// the first disk put back, a disk answered being taken at once. What one answer of none leaves is below.
    func testEveryAttachReadsTheSlotAfresh() async {
        let first = Stub.soap("X_GetMediaInfo", result: Self.slot())
        let recorder = SlotRecorder(.answer(first))
        let (link, _) = await connected(to: recorder)
        XCTAssertEqual(link.session.usbDisk, Self.disk())

        await recorder.answer(.answer(Stub.soap("X_GetMediaInfo",
                                                result: Self.slot(registered: "2026-02-03T04:05:06+0900"))))
        await link.connect()
        XCTAssertEqual(link.session.usbDisk, Self.disk(registered: "2026-02-03T04:05:06+0900"),
                       "the disk read before was kept")

        await recorder.answer(.answer(first))
        await link.connect()
        XCTAssertEqual(link.session.usbDisk, Self.disk())
        XCTAssertTrue(link.session.connected)
    }

    // MARK: - the slot right after a waking

    /// What the slot answered right after a waking, with a disk registered and connected: a disk with no name and
    /// no registration, not mounted and of no size, which is to say none.
    static let wakingAnswer = Stub.soap("X_GetMediaInfo",
                                        result: slot(name: "", mount: "0", remain: "0", total: "0", registered: ""))

    /// Waits for a read left for later to be over, a few seconds at most.
    private func untilOver(_ read: Task<Void, Never>, within seconds: TimeInterval = 3) async {
        let over = expectation(description: "the read left for later is over")
        Task {
            await read.value
            over.fulfill()
        }
        await fulfillment(of: [over], timeout: seconds)
    }

    /// A link whose recorder answered the slot with a disk at one attach and with `none` at the next, so that the
    /// slot is left to be read again after `delay`; with the recorder and the world, which the link's owner is.
    /// `holding` has the recorder hold that read when it comes, until the test lets it go.
    private func waitingToReadAgain(after delay: Duration, cache: GuideStore? = nil,
                                    none: HTTPResponse = wakingAnswer, holding: Bool = false) async
        -> (link: DeviceLink, recorder: SlotRecorder, world: LinkWorld) {
        let recorder = SlotRecorder(.answer(Stub.soap("X_GetMediaInfo", result: Self.slot())))
        let world = LinkWorld()
        world.slotReadAgainAfter = delay
        world.cache = cache
        let (link, _) = await connected(to: recorder, in: world)
        await recorder.answer(.answer(none))
        if holding { await recorder.holdSlotReads(after: 1) }
        await link.connect()
        return (link, recorder, world)
    }

    /// A disk known outlasts one answer of none -- as the slot answers right after a waking, and a refusal too --
    /// and is kept, in the session as it was read and with the cache, while the slot is left to be read again.
    /// Read again and answering none once more, the disk goes, from the session and from the cache, and the
    /// recorder is still connected.
    func testAKnownDiskOutlastsOneAnswerOfNoneAndGoesWhenReadAgainFindsNone() async throws {
        let nones: [(String, HTTPResponse)] = [("as right after a waking", Self.wakingAnswer),
                                               ("refused", Stub.fault("803"))]
        for (what, none) in nones {
            let cache = try temporaryStore()
            let (link, recorder, world) = await waitingToReadAgain(after: .milliseconds(1), cache: cache, none: none,
                                                                   holding: true)
            XCTAssertEqual(link.session.usbDisk, Self.disk(), "let go of on one answer of none: \(what)")
            expectEqual(try await cache.knownUSBDisk(), Self.disk(), what)
            let later = try XCTUnwrap(link.readLeftForLater, "the slot was not left to be read again: \(what)")

            await recorder.letGo()
            await untilOver(later)
            XCTAssertNil(link.session.usbDisk, "kept after the slot answered none twice: \(what)")
            expectNil(try await cache.knownUSBDisk(), what)
            expectEqual(await recorder.slotReads, 3, what)
            XCTAssertTrue(link.session.connected, what)
            XCTAssertNil(world.problem, what)
        }
    }

    /// Read again and answering the disk, the disk is taken as it answers now, in the session and in the cache.
    func testAKnownDiskIsTakenAsItAnswersWhenReadAgainFindsIt() async throws {
        let cache = try temporaryStore()
        let (link, recorder, _) = await waitingToReadAgain(after: .milliseconds(1), cache: cache, holding: true)
        let later = try XCTUnwrap(link.readLeftForLater)

        await recorder.answer(.answer(Stub.soap("X_GetMediaInfo", result: Self.slot(remain: "100000"))))
        await recorder.letGo()
        await untilOver(later)

        var fuller = Self.disk()
        fuller.freeMB = 100_000
        XCTAssertEqual(link.session.usbDisk, fuller, "the read again was not taken")
        expectEqual(try await cache.knownUSBDisk(), fuller)
    }

    /// Silence on the read again changes nothing: the disk known stays, in the session and in the cache, and the
    /// recorder is neither lost nor said to be.
    func testSilenceOnTheReadAgainChangesNothing() async throws {
        let cache = try temporaryStore()
        let (link, recorder, world) = await waitingToReadAgain(after: .milliseconds(1), cache: cache,
                                                               holding: true)
        let later = try XCTUnwrap(link.readLeftForLater)

        await recorder.answer(.silence)
        await recorder.letGo()
        await untilOver(later)

        XCTAssertEqual(link.session.usbDisk, Self.disk(), "silence was taken for no disk")
        expectEqual(try await cache.knownUSBDisk(), Self.disk())
        XCTAssertTrue(link.session.connected)
        XCTAssertFalse(link.session.unreachable)
        XCTAssertNil(world.problem)
    }

    /// The read left for later goes with the device: when the device is let go of, and when another recorder
    /// describes itself at the address, though that attach gets no further than the description. Nor is a
    /// recorder given up on since asked: that stands until the network changes or the reader asks.
    func testTheReadLeftForLaterGoesWithTheDevice() async throws {
        let (forgotten, forgottenRecorder, _) = await waitingToReadAgain(after: .seconds(60))
        let forgottenRead = try XCTUnwrap(forgotten.readLeftForLater)
        forgotten.forgetTheDevice()
        XCTAssertTrue(forgottenRead.isCancelled, "the device let go of")
        await untilOver(forgottenRead)
        expectEqual(await forgottenRecorder.slotReads, 2)

        let (replaced, replacing, _) = await waitingToReadAgain(after: .seconds(60))
        let replacedRead = try XCTUnwrap(replaced.readLeftForLater)
        await replacing.become(udn: Self.anotherUDN)
        await replacing.answer(.silence)
        await replaced.connect()
        XCTAssertTrue(replacedRead.isCancelled, "another recorder")
        await untilOver(replacedRead)

        // Long enough for the test to give the recorder up first.
        let (lost, lostRecorder, _) = await waitingToReadAgain(after: .milliseconds(300))
        let lostRead = try XCTUnwrap(lost.readLeftForLater)
        lost.lost()
        await untilOver(lostRead)
        expectEqual(await lostRecorder.slotReads, 2, "a recorder given up on was asked")
    }

    /// With no disk known, an answer of none is all there is: nothing is left for later, and the slot is asked
    /// once an attach and no more.
    func testNothingIsLeftForLaterWithNoDiskKnown() async throws {
        let world = LinkWorld()
        world.slotReadAgainAfter = .seconds(60)
        world.cache = try temporaryStore()
        let recorder = SlotRecorder(.answer(Self.wakingAnswer))
        let (link, _) = await connected(to: recorder, in: world)
        await link.connect()

        XCTAssertNil(link.session.usbDisk)
        XCTAssertNil(link.readLeftForLater, "the slot was left to be read again with no disk known")
        expectEqual(await recorder.slotReads, 2)
    }

    /// The disk known is kept with the cache for the next launch, whose first attach -- usually a waking one --
    /// then has a disk to keep through the slot's answer of none, as it was read. Another recorder taking the cache
    /// over takes it out of the cache and out of the session, and nothing is left for later.
    func testADiskKnownAtAnEarlierLaunchOutlastsTheFirstAnswerOfNoneAndGoesWithTheCache() async throws {
        let cache = try temporaryStore()
        let earlier = LinkWorld()
        earlier.cache = cache
        let (_, earlierWorld) = await connected(to: SlotRecorder(.answer(Stub.soap("X_GetMediaInfo",
                                                                                   result: Self.slot()))),
                                                in: earlier)
        expectEqual(try await cache.knownUSBDisk(), Self.disk())
        _ = earlierWorld

        let world = LinkWorld()
        world.slotReadAgainAfter = .seconds(60)
        world.cache = cache
        let recorder = SlotRecorder(.answer(Self.wakingAnswer))
        let (link, _) = await connected(to: recorder, in: world)
        XCTAssertEqual(link.session.usbDisk, Self.disk(), "the disk kept with the cache was not taken up")
        let later = try XCTUnwrap(link.readLeftForLater)

        await recorder.become(udn: Self.anotherUDN)
        await link.connect()
        XCTAssertTrue(later.isCancelled)
        XCTAssertNil(link.session.usbDisk)
        expectNil(try await cache.knownUSBDisk(), "the last recorder's disk was kept for another")
        XCTAssertNil(link.readLeftForLater)
    }

    /// A disk known in memory goes when the cache is made over to another recorder, though the session did not
    /// know the last one for another: it had not said which recorder it was, and the cache took it for its own.
    func testADiskKnownGoesWhenTheCacheIsMadeOver() async throws {
        let cache = try temporaryStore()
        let owner = LinkWorld()
        owner.cache = cache
        let (_, ownerWorld) = await connected(to: SlotRecorder(.answer(Self.wakingAnswer)), in: owner)
        expectEqual(try await cache.owner(), Self.vectorUDN)
        _ = ownerWorld

        let world = LinkWorld()
        world.slotReadAgainAfter = .seconds(60)
        world.cache = cache
        let recorder = SlotRecorder(.answer(Stub.soap("X_GetMediaInfo", result: Self.slot())), udn: "")
        let (link, _) = await connected(to: recorder, in: world)
        XCTAssertEqual(link.session.usbDisk, Self.disk())

        await recorder.become(udn: Self.anotherUDN)
        await recorder.answer(.answer(Self.wakingAnswer))
        await link.connect()
        XCTAssertEqual(world.count("another device"), 0, "the session knew the last recorder for another")
        XCTAssertNil(link.session.usbDisk, "the disk known stayed through the cache made over")
        XCTAssertNil(link.readLeftForLater)
    }
}
