import Foundation
import XCTest
@testable import RecorderKit

/// The recordings of a USB disk beside the internal disk's: one list read from both, the free space of both read
/// after it, and what is not written to a row of that disk -- one whose disk has left the slot, and one whose id
/// will change as its recording ends. On a recorder of the test's own, which answers the two disks' lists apart.
@MainActor
final class RecorderUSBTitlesTests: XCTestCase {
    private static let disk = RecorderDiskTests.disk()
    private static let another = RecorderDiskTests.disk(registered: "2026-02-03T04:05:06+0900")
    private static let slot = Stub.soap("X_GetMediaInfo", result: RecorderDiskTests.slot())
    private static let anotherSlot = Stub.soap("X_GetMediaInfo",
                                               result: RecorderDiskTests.slot(registered: "2026-02-03T04:05:06+0900"))
    private nonisolated static let finished = "0x0002010000034f5d"
    private nonisolated static let inProgress = "0x0002010000034f5e"

    /// A recording as a recorder lists it, on the disk named.
    private nonisolated static func item(_ id: String, on destination: String, recording: Bool = false,
                                         protected: Bool = false) -> String {
        "<item id=\"\(id)\"><title>サンプル \(id)</title>"
            + "<scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
            + "<scheduledDuration>1800</scheduledDuration>"
            + "<titleProtectFlag>\(protected ? 1 : 0)</titleProtectFlag>"
            + "<recordingFlag>\(recording ? 1 : 0)</recordingFlag>"
            + "<recordDestinationID>\(destination)</recordDestinationID></item>"
    }

    private nonisolated static func list(_ items: String...) -> HTTPResponse {
        Stub.soap("X_GetTitleList", result: "<xsrs>" + items.joined() + "</xsrs>", totalMatches: items.count)
    }

    private nonisolated static let ownList = list(item("0x1", on: "HDD"), item("0x2", on: "HDD"))
    private nonisolated static let usbList = list(item(finished, on: "USBHDD"),
                                                  item(inProgress, on: "USBHDD", recording: true))

    /// A recorder that answers the internal disk's list and the slot's apart, by the criteria each is asked with.
    /// The slot is answered as it is told, with answers ahead of that one given in turn; everything an attach
    /// reads besides is refused but the description, and the free space, which is answered. It puts down what it
    /// was asked, the slot's list as `usbList`, and can hold the next of the slot's list or of the free space until
    /// the test lets it go.
    private actor TwoDisks: HTTPTransport {
        static let usbList = "X_GetTitleList USBHDD"
        enum Reply { case answer(HTTPResponse), silence }
        private var slot: Reply
        private var slotAhead: [Reply] = []
        private let own: HTTPResponse
        private var usb: Reply
        private var details = Stub.soap("X_GetTitleDetail", result: "<detail><summary>サンプルの番組内容です</summary></detail>")
        private let description: String
        private(set) var asked: [String] = []
        private var holdsTheNext: String?
        private var held: CheckedContinuation<Void, Never>?

        init(slot: Reply, own: HTTPResponse = RecorderUSBTitlesTests.ownList,
             usb: Reply = .answer(RecorderUSBTitlesTests.usbList)) throws {
            self.slot = slot
            self.own = own
            self.usb = usb
            description = try Vectors.descriptionXML()
        }

        func answer(slot: Reply) { self.slot = slot }
        func answer(usb: Reply) { self.usb = usb }
        func answer(details: HTTPResponse) { self.details = details }
        func answerNext(slot: [Reply]) { slotAhead = slot }
        func forget() { asked = [] }
        func holdTheNext(_ what: String) { holdsTheNext = what }
        var isHolding: Bool { held != nil }

        func letGo() {
            held?.resume()
            held = nil
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            guard request.url.lastPathComponent != "description.xml" else {
                return HTTPResponse(statusCode: 200, body: Data(description.utf8))
            }
            let action = String((request.headers["SOAPACTION"] ?? "").split(separator: "#").last ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            switch action {
            case "X_GetTitleList" where body.contains("recordDestinationID=&quot;USBHDD&quot;"):
                asked.append(Self.usbList)
                await holdIfTold(Self.usbList)
                return try Self.answered(usb)
            case "X_GetTitleList":
                asked.append(action)
                return own
            case "X_GetMediaInfo":
                asked.append(action)
                return try Self.answered(slotAhead.isEmpty ? slot : slotAhead.removeFirst())
            case "X_HDLnkGetRecordDestinationInfo":
                asked.append(action)
                await holdIfTold(action)
                return Stub.soap(action, extra: "<RecordDestinationInfo>"
                    + Soap.escape("<info totalCapacity=\"100\" availableCapacity=\"30\" />")
                    + "</RecordDestinationInfo>")
            case "X_UpdateTitle", "X_PlayControlTitle", "X_PowerControl":
                asked.append(action)
                return Stub.soap(action)
            case "X_GetTitleDetail":
                asked.append(action)
                return details
            case "X_DeleteTitle":
                asked.append(action)
                return Stub.soap(action)
            default:
                return HTTPResponse(statusCode: 500)
            }
        }

        private func holdIfTold(_ what: String) async {
            guard holdsTheNext == what else { return }
            holdsTheNext = nil
            await withCheckedContinuation { held = $0 }
        }

        private static func answered(_ reply: Reply) throws -> HTTPResponse {
            switch reply {
            case .answer(let response): return response
            case .silence: throw RecorderError.transport("The request timed out.")
            }
        }
    }

    /// Held by the driver weakly: kept here for as long as the test runs.
    private var links: [DeviceLink] = []

    private func connected(to recorder: TwoDisks) async throws -> (RecorderDriver, DeviceLink, LinkWorld) {
        let world = LinkWorld()
        world.slotReadAgainAfter = .seconds(60)
        world.devices[Stub.host] = recorder
        let driver = RecorderDriver(wakingLimit: 0.05, wakingInterval: .milliseconds(10), busyRetryDelay: 0...0)
        let link = DeviceLink(host: Stub.host, session: SessionState(), driver: driver, environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        await recorder.forget()
        links.append(link)
        return (driver, link, world)
    }

    /// What one read of the list handed over, and how many times it was handed over.
    private struct Kept {
        var list: [RecordedTitle] = []
        var disk: RecorderDisk?
        var times = 0
    }

    private func read(through driver: RecorderDriver) async -> (read: Bool, kept: Kept) {
        var kept = Kept()
        let read = await driver.titles {
            kept.list = $0
            kept.disk = $1
            kept.times += 1
        }
        return (read, kept)
    }

    /// The rows of a recorder with both disks, as a read of the list handed them over, the recorder having put
    /// nothing down since.
    private func rows(of recorder: TwoDisks) async throws
        -> (driver: RecorderDriver, link: DeviceLink, world: LinkWorld, own: RecordedTitle, usb: RecordedTitle,
            recording: RecordedTitle) {
        let (driver, link, world) = try await connected(to: recorder)
        let list = await read(through: driver).kept.list
        await recorder.forget()
        return (driver, link, world, try XCTUnwrap(list.first { $0.id == "0x1" }),
                try XCTUnwrap(list.first { $0.id == Self.finished }),
                try XCTUnwrap(list.first { $0.id == Self.inProgress }))
    }

    // MARK: - the list

    /// With a disk in the slot the list is both disks' rows, handed over once, the USB rows saying which disk they
    /// were read from and the internal ones saying none. The USB disk is read after the internal disk's list, and
    /// the free space after that.
    func testTheListIsBothDisksHandedOverOnce() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, _, world) = try await connected(to: recorder)

        let (read, kept) = await read(through: driver)

        XCTAssertTrue(read)
        XCTAssertEqual(kept.times, 1, "the list was handed over more than once")
        XCTAssertEqual(kept.list.map(\.id), ["0x1", "0x2", Self.finished, Self.inProgress])
        XCTAssertEqual(kept.list.map(\.readFrom), [nil, nil, Self.disk, Self.disk])
        XCTAssertEqual(kept.disk, Self.disk)
        expectEqual(await recorder.asked, ["X_GetTitleList", TwoDisks.usbList, "X_HDLnkGetRecordDestinationInfo",
                                           "X_GetMediaInfo"])
        XCTAssertNil(world.problem)
    }

    /// A home with no USB disk is asked what it always was: nothing of the slot, by a read of the list or by the
    /// free space after it, and a row that says it is on the slot stays as the recorder gave it.
    func testAHomeWithNoUSBDiskIsAskedWhatItAlwaysWas() async throws {
        let recorder = try TwoDisks(slot: .answer(Stub.fault("803")),
                                    own: Self.list(Self.item("0x1", on: "HDD"), Self.item("0x2", on: "USBHDD")))
        let (driver, link, _) = try await connected(to: recorder)
        XCTAssertNil(link.session.usbDisk)

        let (read, kept) = await read(through: driver)

        XCTAssertTrue(read)
        XCTAssertEqual(kept.list.map(\.id), ["0x1", "0x2"])
        XCTAssertEqual(kept.list.map(\.readFrom), [nil, nil])
        XCTAssertNil(kept.disk)
        expectEqual(await recorder.asked, ["X_GetTitleList", "X_HDLnkGetRecordDestinationInfo"])
    }

    /// A registered disk that takes no recordings -- not mounted, or of no size -- is not read.
    func testADiskThatTakesNoRecordingsIsNotRead() async throws {
        let answers = [RecorderDiskTests.slot(mount: "0"), RecorderDiskTests.slot(total: "0")]
        for answer in answers {
            let recorder = try TwoDisks(slot: .answer(Stub.soap("X_GetMediaInfo", result: answer)))
            let (driver, link, _) = try await connected(to: recorder)
            XCTAssertNotNil(link.session.usbDisk)

            let (_, kept) = await read(through: driver)

            XCTAssertEqual(kept.list.map(\.id), ["0x1", "0x2"], answer)
            XCTAssertNil(kept.disk, answer)
            expectFalse(await recorder.asked.contains(TwoDisks.usbList), answer)
        }
    }

    /// A row the internal disk's list gives of the slot, which a BDZ-FBT4100 does not do and another model may, is
    /// not listed twice once the slot's own list has been read.
    func testARowBothListsGiveIsListedOnce() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot),
                                    own: Self.list(Self.item("0x1", on: "HDD"), Self.item(Self.finished, on: "USBHDD")))
        let (driver, _, _) = try await connected(to: recorder)

        let (_, kept) = await read(through: driver)

        XCTAssertEqual(kept.list.map(\.id), ["0x1", Self.finished, Self.inProgress])
    }

    /// The USB disk's list turned down -- busy, refused, an answer that cannot be read -- loses nothing of the
    /// internal list, is said nowhere and fails nothing: the disk read from is none, for the next read to try.
    func testAUSBListTurnedDownLeavesTheInternalList() async throws {
        let answers = [HTTPResponse(statusCode: 503), Stub.fault("803"), Stub.soap("X_GetTitleList", result: "<nope")]
        for answer in answers {
            let recorder = try TwoDisks(slot: .answer(Self.slot), usb: .answer(answer))
            let (driver, link, world) = try await connected(to: recorder)

            let (read, kept) = await read(through: driver)

            XCTAssertTrue(read, "the read as a whole failed")
            XCTAssertEqual(kept.list.map(\.id), ["0x1", "0x2"])
            XCTAssertNil(kept.disk)
            XCTAssertNil(world.problem, "a failure of the USB disk's list was said")
            XCTAssertTrue(link.session.connected)
        }
    }

    /// Silence on the USB disk's list keeps the internal list, as the free space's silence does, and is said as a
    /// read's: the recorder lost, and the line saying so, where nothing clears it after.
    func testSilenceOnTheUSBListKeepsTheInternalListAndIsSaid() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot), usb: .silence)
        let (driver, link, world) = try await connected(to: recorder)

        let (read, kept) = await read(through: driver)

        XCTAssertTrue(read, "the list read was failed by the silence after it")
        XCTAssertEqual(kept.list.map(\.id), ["0x1", "0x2"])
        XCTAssertNil(kept.disk)
        XCTAssertEqual(world.problem, driver.noAnswerLine)
        XCTAssertTrue(link.session.gaveUp, "silence did not lose the recorder")
        expectFalse(await recorder.asked.contains("X_HDLnkGetRecordDestinationInfo"))
    }

    /// With the disk known and the slot not yet answering it, as right after a waking, the slot is waited for
    /// before its list is read: the disk it answers is the one the rows say they were read from.
    func testTheSlotIsWaitedForBeforeItsListIsRead() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, world) = try await connected(to: recorder)
        link.session.learned(usbDisk: Self.another)
        await recorder.answerNext(slot: [.answer(RecorderDiskTests.wakingAnswer)])

        let (_, kept) = await read(through: driver)

        XCTAssertEqual(kept.disk, Self.disk)
        XCTAssertEqual(kept.list.last?.readFrom, Self.disk)
        expectEqual(await recorder.asked.prefix(4), ["X_GetTitleList", "X_GetMediaInfo", "X_GetMediaInfo",
                                                     TwoDisks.usbList])
        XCTAssertTrue(world.begun.contains(RecorderDriver.settlingLine), "the wait was not said on the line")
    }

    /// No disk answered through the whole wait leaves the internal list, with nothing read of the slot's and
    /// nothing said, the disk known staying as it was until the slot is read again.
    func testTheInternalListStandsWhenTheSlotAnswersNoDiskThroughout() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, world) = try await connected(to: recorder)
        link.session.learned(usbDisk: Self.disk)
        await recorder.answer(slot: .answer(RecorderDiskTests.wakingAnswer))

        let (read, kept) = await read(through: driver)

        XCTAssertTrue(read)
        XCTAssertEqual(kept.list.map(\.id), ["0x1", "0x2"])
        XCTAssertNil(kept.disk)
        XCTAssertEqual(link.session.usbDisk, Self.disk)
        expectFalse(await recorder.asked.contains(TwoDisks.usbList))
        XCTAssertNil(world.problem)
    }

    /// The recorder let go of while the USB disk's list is out: nothing is handed over, nor is the free space read
    /// after it.
    func testTheListIsNotHandedOverOnceTheRecorderHasBeenLetGoOf() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _) = try await connected(to: recorder)
        await recorder.holdTheNext(TwoDisks.usbList)
        var kept = false
        let reading = Task { await driver.titles { _, _ in kept = true } }
        try await untilHeld(recorder)

        link.session.forgotTheDevice()
        await recorder.letGo()
        let read = await reading.value

        XCTAssertFalse(read)
        XCTAssertFalse(kept, "a list was handed over for a recorder let go of")
        expectFalse(await recorder.asked.contains("X_HDLnkGetRecordDestinationInfo"))
    }

    private func untilHeld(_ recorder: TwoDisks) async throws {
        for _ in 0..<100_000 { if await recorder.isHolding { break } else { await Task.yield() } }
        expectTrue(await recorder.isHolding, "the request that was to be held never came")
    }

    /// A read asked for afresh is not folded into the read out, whose answer whoever asked has already seen and
    /// wants put right: the list is handed over and the read goes on to the free space, in which time the screens
    /// have asked again. It waits for that read to end, and reads. Any other read is folded in, as ever.
    func testAReadAskedAfreshWaitsForTheOneOutAndReads() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot), usb: .answer(Stub.fault("803")))
        let (driver, _, _) = try await connected(to: recorder)
        await recorder.holdTheNext("X_HDLnkGetRecordDestinationInfo")
        var kept: [RecorderDisk?] = []
        let first = Task { await driver.titles { _, disk in kept.append(disk) } }
        try await untilHeld(recorder)
        XCTAssertEqual(kept, [nil], "the list was meant to be handed over with no disk read")

        await recorder.answer(usb: .answer(Self.usbList))
        let folded = Task { await driver.titles { _, disk in kept.append(disk) } }
        let afresh = Task { await driver.titles(afresh: true) { _, disk in kept.append(disk) } }
        for _ in 0..<1_000 { await Task.yield() }
        await recorder.letGo()
        let reads = await [first.value, folded.value, afresh.value]

        XCTAssertEqual(reads, [true, true, true])
        XCTAssertEqual(kept, [nil, Self.disk], "the read asked for afresh was folded into the one out")
        expectEqual(await recorder.asked.filter { $0 == TwoDisks.usbList }.count, 2)
    }

    // MARK: - the free space

    /// A delete and the end of a run read the slot after the internal disk's free space, once, so that what the
    /// title bar says of the USB disk follows them: a disk answered afresh is taken.
    func testTheFreeSpaceIsReadWithTheSlotAfterADeleteAndARun() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, _, usb, _) = try await rows(of: recorder)
        let fuller = Stub.soap("X_GetMediaInfo", result: RecorderDiskTests.slot(remain: "100000"))
        await recorder.answer(slot: .answer(fuller))

        _ = await driver.delete(usb) {}

        expectEqual(await recorder.asked, ["X_GetMediaInfo", "X_GetTitleDetail", "X_DeleteTitle",
                                           "X_HDLnkGetRecordDestinationInfo", "X_GetMediaInfo"])
        XCTAssertEqual(link.session.usbDisk?.freeMB, 100_000)

        await recorder.forget()
        await recorder.answer(slot: .answer(Stub.soap("X_GetMediaInfo", result: RecorderDiskTests.slot(remain: "9"))))
        let run = try driver.beginRun(.delete).get()
        await driver.end(run, deleted: 1, stopped: nil)

        expectEqual(await recorder.asked, ["X_HDLnkGetRecordDestinationInfo", "X_GetMediaInfo"])
        XCTAssertEqual(link.session.usbDisk?.freeMB, 9)
    }

    /// An answer of none there does not let the disk known go, as at an attach: it is read again later.
    func testAnAnswerOfNoneWithTheFreeSpaceKeepsTheDisk() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, own, _, _) = try await rows(of: recorder)
        await recorder.answer(slot: .answer(RecorderDiskTests.wakingAnswer))

        _ = await driver.delete(own) {}

        XCTAssertEqual(link.session.usbDisk, Self.disk)
        XCTAssertTrue(link.session.usbDiskUnanswered)
        XCTAssertNotNil(link.readLeftForLater, "the slot was not left to be read again")
    }

    // MARK: - what is not written

    /// A row read from a disk no longer in the slot -- another disk, none, or the same one not taking recordings
    /// -- is not written to; nor is a row whose id will change as its recording ends. A row of the internal disk
    /// is asked nothing of the slot, whatever it is.
    func testWhatIsNotWrittenToARow() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (_, _, _, own, usb, recording) = try await rows(of: recorder)
        let changed = RecorderDriver.diskChanged
        var unmounted = Self.disk
        unmounted.mounted = false

        XCTAssertNil(RecorderDriver.whyNot(altering: usb, usb: Self.disk))
        XCTAssertNil(RecorderDriver.whyNot(deleting: usb, usb: Self.disk))
        for other: RecorderDisk? in [Self.another, nil, unmounted] {
            XCTAssertEqual(RecorderDriver.whyNot(altering: usb, usb: other), changed)
            XCTAssertEqual(RecorderDriver.whyNot(deleting: usb, usb: other), changed)
            XCTAssertEqual(RecorderDriver.whyNot(altering: recording, usb: other), changed,
                           "a disk gone comes before what is held of the row")
            XCTAssertNil(RecorderDriver.whyNot(altering: own, usb: other))
            XCTAssertNil(RecorderDriver.whyNot(deleting: own, usb: other))
        }
        XCTAssertEqual(RecorderDriver.whyNot(altering: recording, usb: Self.disk), RecorderDriver.recordingOnTheUSBDisk)
        XCTAssertEqual(RecorderDriver.whyNot(deleting: recording, usb: Self.disk), RecorderDriver.recordingOnTheUSBDisk)
    }

    /// The internal disk's recording in progress stays as it was: it can be protected, and its delete is refused
    /// in its own sentence.
    func testARecordingInProgressOnTheInternalDiskStaysAsItWas() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot),
                                    own: Self.list(Self.item("0x1", on: "HDD", recording: true)))
        let (driver, _, _) = try await connected(to: recorder)
        let list = await read(through: driver).kept.list
        let row = try XCTUnwrap(list.first)

        XCTAssertFalse(row.idChangesWhenItEnds)
        XCTAssertNil(RecorderDriver.whyNot(altering: row, usb: Self.disk))
        XCTAssertNil(RecorderDriver.whyNot(protecting: row, true))
        XCTAssertEqual(RecorderDriver.whyNot(deleting: row, usb: Self.disk), RecorderDriver.stillRecording)
    }

    /// A protect and a delete of a row of the USB disk go while its disk is in the slot, the slot being read
    /// once before each: what the session remembers of it is only as old as the last read.
    func testAProtectAndADeleteGoWhileTheDiskIsInTheSlot() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, _, usb, _) = try await rows(of: recorder)

        let protected = await driver.protect(usb, true) {}
        let deleted = await driver.delete(usb) {}

        XCTAssertEqual(protected.altered, .done(saying: nil))
        XCTAssertEqual(deleted.altered, .done(saying: nil))
        expectEqual(await recorder.asked.prefix(4), ["X_GetMediaInfo", "X_UpdateTitle", "X_GetMediaInfo",
                                                     "X_GetTitleDetail"])
        XCTAssertFalse(link.session.usbDiskUnanswered, "the slot's answer left the disk waited for")
    }

    /// The disk swapped in the slot with nothing having told the session: no attach, no read left for later. A
    /// protect and a delete find that out from the slot, keep what it answered and send nothing.
    func testAWriteFindsADiskSwappedWithNothingTelling() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, _, usb, _) = try await rows(of: recorder)
        await recorder.answer(slot: .answer(Self.anotherSlot))

        let protected = await driver.protect(usb, true) {}

        XCTAssertEqual(protected.altered, .notDone(RecorderDriver.diskChanged))
        XCTAssertEqual(link.session.usbDisk, Self.another, "what the slot answered was not kept")
        expectEqual(await recorder.asked, ["X_GetMediaInfo"])

        let again = try TwoDisks(slot: .answer(Self.slot))
        let (second, secondLink, _, _, row, _) = try await rows(of: again)
        await again.answer(slot: .answer(Self.anotherSlot))

        let deleted = await second.delete(row) {}

        XCTAssertEqual(deleted.altered, .notDone(RecorderDriver.diskChanged))
        XCTAssertEqual(secondLink.session.usbDisk, Self.another)
        expectEqual(await again.asked, ["X_GetMediaInfo"])
    }

    /// A row of the internal disk asks the slot nothing, whatever it is written, and a home with no USB disk has
    /// nothing added.
    func testARowOfTheInternalDiskAsksTheSlotNothing() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, _, _, own, _, _) = try await rows(of: recorder)

        _ = await driver.protect(own, true) {}
        let run = try driver.beginRun(.protecting(true)).get()
        _ = await driver.protect(own, true, in: run)
        _ = await driver.text(of: own, in: run)

        expectEqual(await recorder.asked, ["X_UpdateTitle", "X_UpdateTitle", "X_GetTitleDetail"])
    }

    /// A protect and a delete of a row whose disk has left the slot send nothing, and say so in the result alone.
    func testAProtectAndADeleteOfARowOfAnotherDiskSendNothing() async throws {
        for other: RecorderDisk? in [Self.another, nil] {
            let recorder = try TwoDisks(slot: .answer(Self.slot))
            let (driver, link, world, _, usb, _) = try await rows(of: recorder)
            link.session.slotAnswered(other)
            var kept = 0

            let protected = await driver.protect(usb, true) { kept += 1 }
            let deleted = await driver.delete(usb) { kept += 1 }

            XCTAssertEqual(protected.altered, .notDone(RecorderDriver.diskChanged))
            XCTAssertEqual(deleted.altered, .notDone(RecorderDriver.diskChanged))
            XCTAssertFalse(protected.readAgain)
            XCTAssertFalse(deleted.readAgain)
            XCTAssertEqual(kept, 0)
            XCTAssertNil(world.problem, "what the result says was said on the line too")
            expectEqual(await recorder.asked, [])

            // At the door, ahead of whether the recorder is there: no check goes for what would be turned away.
            link.session.lost()
            let away = await driver.protect(usb, true) { kept += 1 }
            XCTAssertEqual(away.altered, .notDone(RecorderDriver.diskChanged))
        }
    }

    /// A row of the USB disk still being recorded is neither protected nor deleted: its id goes as it ends.
    func testARecordingInProgressOnTheUSBDiskIsNotWrittenTo() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, _, _, _, _, recording) = try await rows(of: recorder)

        let protected = await driver.protect(recording, true) {}
        let deleted = await driver.delete(recording) {}

        XCTAssertEqual(protected.altered, .notDone(RecorderDriver.recordingOnTheUSBDisk))
        XCTAssertEqual(deleted.altered, .notDone(RecorderDriver.recordingOnTheUSBDisk))
        expectEqual(await recorder.asked, [])
    }

    /// With the disk known and the slot not yet answering it, a write waits for the slot, once the recorder has
    /// been made sure of: the disk answered lets it go.
    func testAWriteWaitsForTheSlot() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, _, usb, _) = try await rows(of: recorder)
        link.session.learned(usbDisk: Self.disk)
        await recorder.answerNext(slot: [.answer(RecorderDiskTests.wakingAnswer)])

        let protected = await driver.protect(usb, true) {}

        XCTAssertEqual(protected.altered, .done(saying: nil))
        expectEqual(await recorder.asked, ["X_GetMediaInfo", "X_GetMediaInfo", "X_UpdateTitle"])
    }

    /// The wait ending on another disk, or on none, sends nothing, and says why.
    func testAWriteIsNotSentWhenTheWaitDoesNotFindItsDisk() async throws {
        let answers: [(String, HTTPResponse)] = [
            ("another disk", Stub.soap("X_GetMediaInfo",
                                       result: RecorderDiskTests.slot(registered: "2026-02-03T04:05:06+0900"))),
            ("none", RecorderDiskTests.wakingAnswer),
        ]
        for (what, answer) in answers {
            let recorder = try TwoDisks(slot: .answer(Self.slot))
            let (driver, link, _, _, usb, _) = try await rows(of: recorder)
            link.session.learned(usbDisk: Self.disk)
            await recorder.answer(slot: .answer(answer))

            let protected = await driver.protect(usb, true) {}
            let deleted = await driver.delete(usb) {}

            XCTAssertEqual(protected.altered, .notDone(RecorderDriver.diskChanged), what)
            XCTAssertEqual(deleted.altered, .notDone(RecorderDriver.diskChanged), what)
            expectFalse(await recorder.asked.contains("X_UpdateTitle"), what)
            expectFalse(await recorder.asked.contains("X_DeleteTitle"), what)
            expectFalse(await recorder.asked.contains("X_GetTitleDetail"), what)
        }
    }

    /// Silence while the slot is waited for loses the recorder and says so; nothing is sent.
    func testSilenceOnTheWaitSendsNothing() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, world, _, usb, _) = try await rows(of: recorder)
        link.session.learned(usbDisk: Self.disk)
        await recorder.answer(slot: .silence)

        let protected = await driver.protect(usb, true) {}

        XCTAssertEqual(protected.altered, .notDone(driver.noAnswerLine))
        XCTAssertEqual(world.problem, driver.noAnswerLine)
        expectFalse(await recorder.asked.contains("X_UpdateTitle"))
    }

    // MARK: - playing

    /// A play of a row of a disk gone sends nothing: whatever holds that number on the next disk would play, its
    /// new mark and its resume point moving, and from standby the recorder and the television would be turned on
    /// for it first. A pause and a stop are about what is on the television, whatever list the sheet was opened
    /// from, and stay open.
    func testAPlayOfARowOfADiskGoneSendsNothing() async throws {
        for other: RecorderDisk? in [Self.another, nil] {
            let recorder = try TwoDisks(slot: .answer(Self.slot))
            let (driver, link, world, _, usb, _) = try await rows(of: recorder)
            link.session.slotAnswered(other)
            link.session.powerNeeded(true)

            let played = await driver.play(usb, "play")

            XCTAssertEqual(played, .notDone(RecorderDriver.diskChanged))
            XCTAssertEqual(RecorderDriver.whyNot(playing: usb, usb: other), RecorderDriver.diskChanged)
            XCTAssertTrue(link.session.needsPower, "the offer of the power went with a play turned away at its door")
            XCTAssertNil(world.problem, "what the result says was said on the line too")
            expectEqual(await recorder.asked, [])

            for operation in ["pause", "stop"] {
                let sent = await driver.play(usb, operation)
                XCTAssertEqual(sent, .done(saying: nil), operation)
            }
            expectEqual(await recorder.asked, ["X_PlayControlTitle", "X_PlayControlTitle"])
        }
    }

    /// A play reads the slot first, as a write does: a disk swapped with nothing having told the session is found
    /// there, and the disk in the slot plays.
    func testAPlayReadsTheSlotFirst() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, _, _, _, usb, _) = try await rows(of: recorder)

        let played = await driver.play(usb, "play")

        XCTAssertEqual(played, .done(saying: nil))
        expectEqual(await recorder.asked, ["X_GetMediaInfo", "X_PlayControlTitle"])

        await recorder.forget()
        await recorder.answer(slot: .answer(Self.anotherSlot))
        let swapped = await driver.play(usb, "play")

        XCTAssertEqual(swapped, .notDone(RecorderDriver.diskChanged))
        expectEqual(await recorder.asked, ["X_GetMediaInfo"])
    }

    /// A row still being recorded to the USB disk is not played: that has not been tried, and its id goes as it
    /// ends. It says so in a sentence of its own, and a pause and a stop stay open.
    func testARecordingInProgressOnTheUSBDiskIsNotPlayed() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, _, _, _, _, recording) = try await rows(of: recorder)

        let played = await driver.play(recording, "play")
        let stopped = await driver.play(recording, "stop")

        XCTAssertEqual(played, .notDone(RecorderDriver.notPlayedWhileRecording))
        XCTAssertEqual(stopped, .done(saying: nil))
        expectEqual(await recorder.asked, ["X_PlayControlTitle"])
    }

    /// A row of the internal disk plays as it always has, one being recorded among them, and asks the slot nothing.
    func testARowOfTheInternalDiskPlaysAsItAlwaysHas() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot),
                                    own: Self.list(Self.item("0x1", on: "HDD", recording: true)))
        let (driver, link, _) = try await connected(to: recorder)
        let list = await read(through: driver).kept.list
        let row = try XCTUnwrap(list.first)
        await recorder.forget()
        link.session.slotAnswered(nil)

        let played = await driver.play(row, "play")

        XCTAssertNil(RecorderDriver.whyNot(playing: row, usb: nil))
        XCTAssertEqual(played, .done(saying: nil))
        expectEqual(await recorder.asked, ["X_PlayControlTitle"])
    }

    // MARK: - a run

    /// What one recording of a run came to, as what stopped the run there; nil when the run went on.
    private func stop(at title: RecordedTitle, in run: Run, _ kind: RunKind,
                      through driver: RecorderDriver) async -> RunStop? {
        switch kind {
        case .delete:
            if case .stopped(let why) = await driver.delete(title, in: run) { return why }
        case .protecting:
            if case .stopped(let why) = await driver.protect(title, true, in: run) { return why }
        case .scanning:
            if case .stopped(let why) = await driver.text(of: title, in: run) { return why }
        }
        return nil
    }

    /// A run stops at a row whose disk has left the slot, with why and nothing sent for it: the rows after it are
    /// of the same disk, and the list they came from is out of date. The session has not been told: the slot is
    /// read for that row, as the swap may have come at any moment of a run the app was away for.
    func testARunStopsAtARowOfAnotherDisk() async throws {
        for kind: RunKind in [.delete, .protecting(true), .scanning] {
            let recorder = try TwoDisks(slot: .answer(Self.slot))
            let (driver, link, _, _, usb, _) = try await rows(of: recorder)
            let run = try driver.beginRun(kind).get()
            await recorder.answer(slot: .answer(Self.anotherSlot))

            let stopped = await stop(at: usb, in: run, kind, through: driver)

            XCTAssertEqual(stopped, .said(RecorderDriver.diskChanged), "\(kind)")
            expectEqual(await recorder.asked, ["X_GetMediaInfo"], "\(kind)")
            XCTAssertEqual(link.session.usbDisk, Self.another, "\(kind)")
        }
    }

    /// The disk unplugged under a run, the session not told: the slot answers none, and a recording's details,
    /// asked all the same, would answer 820, which reads as a recording deleted on the recorder. The run stops
    /// there with the row left alone, and the slot is left to be read again, so that the disk does not stay waited
    /// for with nothing to end the wait.
    func testAnUnpluggedDiskStopsARunRatherThanGivingItsRowsUp() async throws {
        for kind: RunKind in [.delete, .protecting(true), .scanning] {
            let recorder = try TwoDisks(slot: .answer(Self.slot))
            let (driver, link, _, _, usb, _) = try await rows(of: recorder)
            let run = try driver.beginRun(kind).get()
            await recorder.answer(slot: .answer(RecorderDiskTests.wakingAnswer))
            await recorder.answer(details: Stub.fault("820"))

            let stopped = await stop(at: usb, in: run, kind, through: driver)

            XCTAssertEqual(stopped, .said(RecorderDriver.diskChanged), "\(kind)")
            expectFalse(await recorder.asked.contains("X_GetTitleDetail"), "\(kind)")
            expectFalse(await recorder.asked.contains("X_UpdateTitle"), "\(kind)")
            XCTAssertEqual(link.session.usbDisk, Self.disk, "one wait's none let the disk known go")
            XCTAssertNotNil(link.readLeftForLater, "nothing is left to end the wait: \(kind)")
        }
    }

    /// The single write's half of the same: nothing sent, the row left, the slot left to be read again.
    func testAnUnpluggedDiskStopsASingleWrite() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, _, usb, _) = try await rows(of: recorder)
        await recorder.answer(slot: .answer(RecorderDiskTests.wakingAnswer))
        await recorder.answer(details: Stub.fault("820"))
        var kept = 0

        let deleted = await driver.delete(usb) { kept += 1 }

        XCTAssertEqual(deleted.altered, .notDone(RecorderDriver.diskChanged))
        XCTAssertEqual(kept, 0, "a row taken out of the list for a disk that was only unplugged")
        expectFalse(await recorder.asked.contains("X_GetTitleDetail"))
        XCTAssertNotNil(link.readLeftForLater)
    }

    /// With the disk let go of already there is nothing to read the slot for: the row stops the run at once.
    func testARunStopsAtOnceWithNoDiskKnown() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, _, usb, _) = try await rows(of: recorder)
        let run = try driver.beginRun(.delete).get()
        link.session.slotAnswered(nil)

        let came = await driver.delete(usb, in: run)

        XCTAssertEqual(came, .stopped(.said(RecorderDriver.diskChanged)))
        expectEqual(await recorder.asked, [])
        XCTAssertFalse(link.session.usbDiskUnanswered, "no disk known was left waited for")
    }

    /// The internal disk's rows of a run go on whatever has become of the USB disk.
    func testARunGoesOnOverTheInternalDiskWhateverBecomesOfTheSlot() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, link, _, own, _, _) = try await rows(of: recorder)
        let run = try driver.beginRun(.delete).get()
        link.session.slotAnswered(nil)

        let came = await driver.delete(own, in: run)

        XCTAssertEqual(came, .done)
    }

    /// A row still being recorded on the USB disk is passed over by a run, in the sentence of its sheet, and the
    /// run goes on.
    func testARunPassesOverARecordingInProgressOnTheUSBDisk() async throws {
        let recorder = try TwoDisks(slot: .answer(Self.slot))
        let (driver, _, _, _, _, recording) = try await rows(of: recorder)
        let run = try driver.beginRun(.delete).get()

        let deleted = await driver.delete(recording, in: run)
        let protected = await driver.protect(recording, true, in: run)

        XCTAssertEqual(deleted, .passedOver(RecorderDriver.recordingOnTheUSBDisk))
        XCTAssertEqual(protected, .passedOver(RecorderDriver.recordingOnTheUSBDisk))
        expectEqual(await recorder.asked, [])
    }

    // MARK: - the duplicates

    /// A row still being recorded on the USB disk is no candidate: its text would be asked of an id that is
    /// about to go, and kept under it for good. One on the internal disk is, as it always was.
    func testARecordingInProgressOnTheUSBDiskIsNoCandidate() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func row(_ id: String, recording: Bool = false, readFrom disk: RecorderDisk? = nil) -> RecordedTitle {
            RecordedTitle(id: id, title: "サンプルドラマ　第１話", start: start, durationSec: 1800, broadcastingType: 2,
                          serviceID: 0x400, qualityCode: 230, protected: false, isNew: false, recording: recording,
                          destination: disk == nil ? "HDD" : "USBHDD", sizeMB: 1000, genreCode: nil, lastPlayed: nil,
                          resumeSec: nil, readFrom: disk)
        }

        XCTAssertEqual(Duplicates.candidates([row("a"), row("b", recording: true, readFrom: Self.disk)]).count, 0)
        XCTAssertEqual(Duplicates.candidates([row("a"), row("b", readFrom: Self.disk)]).first?.map(\.id), ["a", "b"],
                       "copies across the two disks are copies")
        XCTAssertEqual(Duplicates.candidates([row("a"), row("b", recording: true)]).first?.map(\.id), ["a", "b"])
        XCTAssertTrue(Duplicates.deletable(row("b", readFrom: Self.disk)), "a row is taken as it was read")
    }

    /// A row made up for what is kept of it by key: one number, on the disk named or on the internal disk.
    private func numbered(_ id: String, readFrom disk: RecorderDisk? = nil) -> RecordedTitle {
        RecordedTitle(id: id, title: "サンプルドラマ　第１話", start: Date(timeIntervalSince1970: 1_790_000_000), durationSec: 1800,
                      broadcastingType: 2, serviceID: 0x400, qualityCode: 230, protected: false, isNew: false,
                      recording: false, destination: disk == nil ? "HDD" : "USBHDD", sizeMB: 1000, genreCode: nil,
                      lastPlayed: nil, resumeSec: nil, readFrom: disk)
    }

    /// A row of the internal disk keeps the key it always had, which is what the texts kept on phones are under,
    /// and the same number on two USB disks is two keys, whether or not a disk ever gives one out twice.
    func testARowsKeyIsItsIdWithTheDiskItWasReadFrom() {
        XCTAssertEqual(numbered("0x1").listKey, "0x1")
        XCTAssertEqual(numbered("0x1", readFrom: Self.disk).listKey, "2026-01-02T03:04:05+0900|0x1")
        XCTAssertNotEqual(numbered("0x1", readFrom: Self.disk).listKey, numbered("0x1", readFrom: Self.another).listKey)
    }

    /// A text read of one disk's row says nothing of the same number on another disk: that row counts as unread and
    /// is in no set, where taken for read it would come up as a sure copy, ticked for deletion.
    func testATextIsNotTakenForTheSameNumberOnAnotherDisk() {
        let story = "架空の町で起きた出来事を追う連続ドラマの第１話。主人公が町に着くところから始まる。"
        let own = numbered("0x2")
        let read = numbered("0x1", readFrom: Self.disk)
        let summaries = [own.listKey: story, read.listKey: story]

        let found = Duplicates.readSets([own, read], summaries: summaries)
        XCTAssertEqual(found.sets.map(\.confidence), [.high], "the two were meant to be a sure set")

        let swapped = Duplicates.readSets([own, numbered("0x1", readFrom: Self.another)], summaries: summaries)
        XCTAssertEqual(swapped.sets.count, 0, "another disk's row took a text it never gave")
        XCTAssertEqual(swapped.unread, 1)
    }
}
