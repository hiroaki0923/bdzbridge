import Foundation
import XCTest
@testable import RecorderKit

/// The recordings of a USB disk beside the internal disk's: one list read from both, and the free space of both
/// read after it. On a recorder of the test's own, which answers the two disks' lists apart.
@MainActor
final class RecorderUSBTitlesTests: XCTestCase {
    private static let disk = RecorderDiskTests.disk()
    private static let another = RecorderDiskTests.disk(registered: "2026-02-03T04:05:06+0900")
    private static let slot = Stub.soap("X_GetMediaInfo", result: RecorderDiskTests.slot())
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
    /// was asked, the slot's list as `usbList`, and can hold the slot's list until the test lets it go.
    private actor TwoDisks: HTTPTransport {
        static let usbList = "X_GetTitleList USBHDD"
        enum Reply { case answer(HTTPResponse), silence }
        private var slot: Reply
        private var slotAhead: [Reply] = []
        private let own: HTTPResponse
        private var usb: Reply
        private let description: String
        private(set) var asked: [String] = []
        private var holdsTheUSBList = false
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
        func answerNext(slot: [Reply]) { slotAhead = slot }
        func forget() { asked = [] }
        func holdTheUSBList() { holdsTheUSBList = true }
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
                if holdsTheUSBList {
                    holdsTheUSBList = false
                    await withCheckedContinuation { held = $0 }
                }
                return try Self.answered(usb)
            case "X_GetTitleList":
                asked.append(action)
                return own
            case "X_GetMediaInfo":
                asked.append(action)
                return try Self.answered(slotAhead.isEmpty ? slot : slotAhead.removeFirst())
            case "X_HDLnkGetRecordDestinationInfo":
                asked.append(action)
                return Stub.soap(action, extra: "<RecordDestinationInfo>"
                    + Soap.escape("<info totalCapacity=\"100\" availableCapacity=\"30\" />")
                    + "</RecordDestinationInfo>")
            case "X_DeleteTitle", "X_GetTitleDetail":
                asked.append(action)
                return Stub.soap(action, result: "<detail><summary>サンプルの番組内容です</summary></detail>")
            default:
                return HTTPResponse(statusCode: 500)
            }
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
        await recorder.holdTheUSBList()
        var kept = false
        let reading = Task { await driver.titles { _, _ in kept = true } }
        for _ in 0..<100_000 { if await recorder.isHolding { break } else { await Task.yield() } }
        expectTrue(await recorder.isHolding, "the slot's list was never asked for")

        link.session.forgotTheDevice()
        await recorder.letGo()
        let read = await reading.value

        XCTAssertFalse(read)
        XCTAssertFalse(kept, "a list was handed over for a recorder let go of")
        expectFalse(await recorder.asked.contains("X_HDLnkGetRecordDestinationInfo"))
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

        expectEqual(await recorder.asked, ["X_GetTitleDetail", "X_DeleteTitle", "X_HDLnkGetRecordDestinationInfo",
                                           "X_GetMediaInfo"])
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
}
