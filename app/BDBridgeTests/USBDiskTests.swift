import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder's USB disk as far as it is read and shown: whether one is there, asked once at every attach and
/// not by the screens; the free space in the settings, a row to a disk once there are two; and the overnight
/// run's notices, the USB disk's with a mark of its own. The disk is the test's own answer to the slot, given
/// through the bench's recorder; the demo's recorder answers it with nothing, which is no disk.
@MainActor
final class USBDiskTests: XCTestCase {
    /// A disk in the slot in the recorder's own wrapping and order, its name, time and sizes made up: 123.5 GB free
    /// of 2000.4.
    static func slot(mount: String = "1", remain: Int = 123_456,
                     registered: String? = "2026-01-02T03:04:05+0900") -> String {
        "<?xml version=\"1.0\"?><xsrs xmlns=\"urn:schemas-xsrs-org:metadata-1-0/x_srs/\"><name>録画用ディスク</name>"
            + "<mount>\(mount)</mount><remain>\(remain)</remain><total>2000398</total>"
            + (registered.map { "<registeredTime>\($0)</registeredTime>" } ?? "")
            + "<recordableRemain>654321</recordableRemain></xsrs>"
    }

    /// The disk `slot()` describes, as the app reads it.
    static let disk = RecorderDisk(destination: "USBHDD", name: "録画用ディスク", mounted: true, freeMB: 123_456,
                                   totalMB: 2_000_398, registered: "2026-01-02T03:04:05+0900")

    /// The slot as it answered right after a waking, with a disk registered and connected: no name and no
    /// registration, not mounted and of no size.
    static let wakingSlot = "<?xml version=\"1.0\"?><xsrs xmlns=\"urn:schemas-xsrs-org:metadata-1-0/x_srs/\">"
        + "<name></name><mount>0</mount><remain>0</remain><total>0</total><registeredTime></registeredTime>"
        + "<recordableRemain>0</recordableRemain></xsrs>"

    /// A model started and connected to a recorder that answers the slot with `slot`, or as the demo's does when
    /// it is nil.
    private func connected(answering slot: String?) async throws -> (bench: Bench, recorder: NamedRecorder,
                                                                         model: AppModel) {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        if let slot { await recorder.answer("X_GetMediaInfo", with: .result(slot), times: 1000) }
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        return (bench, recorder, model)
    }

    /// A home with no USB disk sees what it always has, and pays one request for it at an attach: the slot,
    /// asked in its place among what an attach reads, and by nothing a screen does after. The recorder that
    /// never registered a disk is not seen yet, so neither answer it might give is read as one: nothing at all,
    /// as the demo's recorder answers, and a disk neither mounted nor registered.
    func testAHomeWithNoUSBDiskIsShownNothingAndAskedOnceAnAttach() async throws {
        for slot in [nil, Self.slot(mount: "0", registered: nil)] {
            let what = slot ?? "nothing"
            let (_, recorder, model) = try await connected(answering: slot)
            XCTAssertNil(model.usbDisk, what)
            let storage = try XCTUnwrap(model.storage, what)
            XCTAssertEqual(SettingsScreen.storageRows(storage: model.storage, usb: model.usbDisk),
                           [.init(label: "残り容量",
                                  value: "\(Format.gigabytes(storage.free)) / \(Format.gigabytes(storage.total))")],
                           what)
            expectEqual(await recorder.heard, ["description.xml", "X_GetFirmwareVersion", "X_GetPrivateIp",
                                               "X_HDLnkGetRecordDestinationInfo", "X_GetMediaInfo",
                                               "X_GetRecordScheduleList"], what)

            let before = await recorder.asked
            await model.loadTitles(force: true)
            let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected }, what)
            expectTrue(await deleteARecording(model, title), model.problem ?? "no reason given")
            expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 0,
                        "the slot was read again by a list or a delete: \(what)")
        }
    }

    /// With a USB disk the one row of free space becomes a row to a disk: the internal one under the recorder's
    /// own word for it, the USB one under the name the recorder gives it, each in the words the television's
    /// USB disk is described in. A registered disk the recorder says is not mounted -- what an unplugged one
    /// answers has not been seen -- is said to be away.
    func testTheSettingsShowARowPerDisk() async throws {
        let (_, _, model) = try await connected(answering: Self.slot())
        XCTAssertEqual(model.usbDisk, RecorderDisk(destination: "USBHDD", name: "録画用ディスク", mounted: true,
                                                   freeMB: 123_456, totalMB: 2_000_398,
                                                   registered: "2026-01-02T03:04:05+0900"))
        let storage = try XCTUnwrap(model.storage)
        XCTAssertEqual(SettingsScreen.storageRows(storage: model.storage, usb: model.usbDisk), [
            .init(label: "HDD", value: "残り \(Format.gigabytes(storage.free)) / \(Format.gigabytes(storage.total))"),
            .init(label: "録画用ディスク", value: "残り 123.5 GB / 2000.4 GB"),
        ])

        let (_, _, away) = try await connected(answering: Self.slot(mount: "0"))
        XCTAssertEqual(SettingsScreen.storageRows(storage: away.storage, usb: away.usbDisk).last,
                       .init(label: "録画用ディスク", value: "つながっていません"))
        XCTAssertEqual(Format.storage(mounted: true, freeBytes: nil, totalBytes: nil), "つながっています")
    }

    /// What an overnight run told, in order.
    private actor Told {
        private(set) var said: [String] = []
        func say(_ what: String) { said.append(what) }
    }

    /// What an overnight run tells, as text.
    private func telling(_ told: Told) -> BackgroundWork.Telling {
        BackgroundWork.Telling(
            heldBack: {}, flushed: { _ in },
            freeSpace: { _, _, naming in await told.say("free space" + (naming.map { " of \($0)" } ?? "")) },
            usbSpace: { await told.say("USB space of \($0.name)") },
            fetched: { _ in })
    }

    /// The overnight run reads the slot once, before the internal disk's space, through the rule the screens use:
    /// in a home with no USB disk too, which pays that one request a night and no more. A USB disk that takes
    /// recordings has its space told, and the internal disk's notice then names its disk; with no such disk the
    /// internal disk's is told as it always was, naming none.
    func testTheNightRunTellsTheUSBDisksSpaceOnlyForADiskThatTakesRecordings() async throws {
        let cases: [(String?, [String])] = [
            (Self.slot(), ["free space of HDD", "USB space of 録画用ディスク"]),
            (nil, ["free space"]),
            (Self.slot(mount: "0"), ["free space"]),
            (Self.slot(registered: nil), ["free space"]),
        ]
        for (slot, expected) in cases {
            let (bench, recorder, _) = try await connected(answering: slot)
            let told = Told()
            let before = await recorder.asked

            // No MAC: the run sends its packet itself, and would send it on the network this is run on.
            _ = await BackgroundWork.refresh(client: RecorderClient(host: Bench.host, transport: recorder),
                                             store: try GuideStore(path: bench.guidePath), mac: nil,
                                             telling: telling(told))

            expectEqual(await told.said, expected, slot ?? "nothing")
            expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 1,
                        "the slot was not read once in the night: \(slot ?? "nothing")")
        }
    }

    /// A slot that says nothing ends the overnight run there: the free space and the guide are not asked for,
    /// each of which would only wait out the same silence, and nothing is told.
    func testTheNightRunStopsAtASilentSlot() async throws {
        let (bench, recorder, _) = try await connected(answering: nil)
        let told = Told()
        await recorder.goQuiet(on: "X_GetMediaInfo")
        let before = await recorder.heard.count

        // No MAC, as above.
        let fetched = await BackgroundWork.refresh(client: RecorderClient(host: Bench.host, transport: recorder),
                                                   store: try GuideStore(path: bench.guidePath), mac: nil,
                                                   telling: telling(told))

        XCTAssertFalse(fetched)
        expectEqual(await recorder.heard(since: before).last, "X_GetMediaInfo", "the run went on past the slot")
        expectEqual(await told.said, [])
    }

    /// The overnight run never lets a disk known go: a slot it reads as none -- as it is right after a waking,
    /// which the run often is -- and reads as none again after the guide means no USB notice that night, and the
    /// disk kept with the cache stays for the screens to settle. There are still two disks, so the internal disk's
    /// notice names its disk.
    func testTheNightRunKeepsTheDiskKnown() async throws {
        let (bench, recorder, _) = try await connected(answering: Self.slot())
        expectEqual(try await GuideStore(path: bench.guidePath).knownUSBDisk(), Self.disk)
        await recorder.answer("X_GetMediaInfo", with: .result(Self.wakingSlot), times: 1000)
        let told = Told()
        let before = await recorder.asked

        // No MAC, as above.
        _ = await BackgroundWork.refresh(client: RecorderClient(host: Bench.host, transport: recorder),
                                         store: try GuideStore(path: bench.guidePath), mac: nil,
                                         telling: telling(told))

        expectEqual(await told.said, ["free space of HDD"])
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 2)
        expectEqual(try await GuideStore(path: bench.guidePath).knownUSBDisk(), Self.disk,
                    "the night let the disk known go")
    }

    /// A night whose slot answers none while the disk known takes recordings reads the slot once more after the
    /// guide, by which time the disk has had a while to come up, and tells the USB disk's space if it answers
    /// then. Nothing is kept of that read: the screens' attach says what the slot holds.
    func testANightThatReadsNoneReadsTheSlotAgainAfterTheGuideForTheUSBDisksNotice() async throws {
        let (bench, recorder, _) = try await connected(answering: Self.slot())
        // The night's first read is the demo's answer, which is none, and the read after it the disk, lower.
        await recorder.answer("X_GetMediaInfo", with: .result(Self.slot(remain: 12_345)), times: 1000, after: 1)
        let told = Told()
        let before = await recorder.heard.count

        // No MAC, as above.
        _ = await BackgroundWork.refresh(client: RecorderClient(host: Bench.host, transport: recorder),
                                         store: try GuideStore(path: bench.guidePath), mac: nil,
                                         telling: telling(told))

        expectEqual(await told.said, ["free space of HDD", "USB space of 録画用ディスク"])
        let heard = await recorder.heard(since: before)
        XCTAssertEqual(heard.filter { $0 == "X_GetMediaInfo" }.count, 2)
        XCTAssertEqual(heard.last, "X_GetMediaInfo", "the slot was not read again after the guide")
        expectEqual(try await GuideStore(path: bench.guidePath).knownUSBDisk(), Self.disk,
                    "the night kept what it read again")
    }

    /// A disk known at an earlier launch is kept with the cache, and the first attach of the next -- usually a
    /// waking one, when the slot answers as if no disk were registered -- shows it as it was read, not as away,
    /// with the slot left to be read again. The app leaving ends that read before it is made, and the disk stays.
    /// Another recorder answering takes the disk away, from the screens and from the cache.
    func testADiskKnownAtAnEarlierLaunchIsShownThroughTheFirstWakingAndGoesWithTheCache() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        do {
            let earlier = NamedRecorder(1)
            await earlier.answer("X_GetMediaInfo", with: .result(Self.slot()), times: 1000)
            let before = bench.model(recorders: [Bench.host: earlier])
            await before.start()
            try await untilConnected(before)
            expectEqual(try await GuideStore(path: bench.guidePath).knownUSBDisk(), Self.disk)
        }

        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(Self.wakingSlot), times: 1000)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        XCTAssertEqual(model.usbDisk, Self.disk, "the disk known at the earlier launch was not taken up")
        XCTAssertEqual(SettingsScreen.storageRows(storage: model.storage, usb: model.usbDisk).last,
                       .init(label: "録画用ディスク", value: "残り 123.5 GB / 2000.4 GB"))
        let later = try XCTUnwrap(model.recorder.readLeftForLater, "the slot was not left to be read again")

        model.wentToBackground()
        XCTAssertTrue(later.isCancelled, "the read again outlived the app's leaving")
        try await within(5, "the read again never ended") { await later.value }
        expectEqual(await recorder.asked("X_GetMediaInfo"), 1)
        XCTAssertEqual(model.usbDisk, Self.disk)

        await recorder.become(2)
        await model.returnedToForeground()
        await reconnect(model)
        XCTAssertNil(model.usbDisk, "the last recorder's disk was shown for another")
        expectNil(try await GuideStore(path: bench.guidePath).knownUSBDisk())
    }

    /// The app leaving ends the slot's read again, and coming back inside the minute after the last answer, which
    /// makes no attach, leaves it for later again: made then and answered none, it lets the disk go, rather than
    /// the disk being kept for as long as the reader comes and goes.
    func testAReturnWithNoAttachLeavesTheSlotsReadAgainForLater() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        // Long enough for the leaving to come first, which the hold below makes sure of.
        bench.slotReadAgainAfter = .seconds(1)
        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(Self.slot()), times: 1)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        // The demo's answer from here on, which is none; and the read again held, should it go before the leaving.
        await reconnect(model)
        await recorder.hold(only: "X_GetMediaInfo")
        let left = try XCTUnwrap(model.recorder.readLeftForLater, "the slot was not left to be read again")

        model.wentToBackground()
        XCTAssertTrue(left.isCancelled, "the read again outlived the app's leaving")
        await model.returnedToForeground()
        XCTAssertEqual(model.usbDisk, Self.disk)
        let again = try XCTUnwrap(model.recorder.readLeftForLater, "the return left nothing for later")
        XCTAssertFalse(again.isCancelled)

        await recorder.letGo()
        try await until("the read left for later again did not let the disk go", within: 5) { model.usbDisk == nil }
        expectNil(try await GuideStore(path: bench.guidePath).knownUSBDisk())
    }

    /// The slot is read again once the surroundings' time has gone by -- the app's minute, a moment here -- and a
    /// second answer of none lets the disk go, from the screens and from the cache.
    func testTheSlotIsReadAgainOnceTheSurroundingsTimeHasGoneBy() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        bench.slotReadAgainAfter = .milliseconds(50)
        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(Self.slot()), times: 1)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        XCTAssertEqual(model.usbDisk, Self.disk)

        // The demo's answer from here on, which is none.
        await reconnect(model)
        try await until("the slot was not read again", within: 5) { model.usbDisk == nil }
        expectEqual(await recorder.asked("X_GetMediaInfo"), 3)
        expectNil(try await GuideStore(path: bench.guidePath).knownUSBDisk())
    }

    /// The USB disk's warning is given once per fall below the line, for the disk in the slot: a disk that was
    /// warned about is not warned about again until it has had room, and another disk -- or the same one renamed,
    /// which is not to be told from another -- has not been warned about yet. A warning leaves the disk's
    /// identity as the mark, and goes under an identifier of its own.
    func testTheUSBDisksLowSpaceMarkIsTheDisksOwn() {
        func disk(freeGB: Int, name: String = "録画用ディスク", registered: String = "2026-01-02T03:04:05+0900",
                  mounted: Bool = true) -> RecorderDisk {
            RecorderDisk(destination: RecorderDisk.usbID, name: name, mounted: mounted, freeMB: freeGB * 1000,
                         totalMB: 2_000_398, registered: registered)
        }
        let low = disk(freeGB: 10), roomy = disk(freeGB: 100)
        let another = disk(freeGB: 10, registered: "2026-02-03T04:05:06+0900")
        let renamed = disk(freeGB: 10, name: "別のディスク")

        XCTAssertEqual(Notify.usbSpace(low, marked: nil, warnBelowGB: 50), .warn(freeGB: 10, mark: low.identity),
                       "the warning does not leave the disk's identity as its mark")
        XCTAssertEqual(Notify.usbSpace(low, marked: low.identity, warnBelowGB: 50), .nothing, "warned twice")
        XCTAssertEqual(Notify.usbSpace(another, marked: low.identity, warnBelowGB: 50),
                       .warn(freeGB: 10, mark: another.identity), "another disk taken for the one warned about")
        XCTAssertEqual(Notify.usbSpace(renamed, marked: low.identity, warnBelowGB: 50),
                       .warn(freeGB: 10, mark: renamed.identity))
        XCTAssertEqual(Notify.usbSpace(roomy, marked: roomy.identity, warnBelowGB: 50), .roomAgain)
        XCTAssertEqual(Notify.usbSpace(roomy, marked: another.identity, warnBelowGB: 50), .nothing)
        XCTAssertEqual(Notify.usbSpace(roomy, marked: nil, warnBelowGB: 50), .nothing)
        XCTAssertEqual(Notify.usbSpace(disk(freeGB: 10, mounted: false), marked: nil, warnBelowGB: 50), .nothing,
                       "a disk that is not there was warned about")

        // Pinned as written: a notice still shown from an earlier version is replaced by the next under it.
        XCTAssertEqual(Notify.usbLowSpaceID, "low-space-usb")
    }
}
