import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The television's recordings beside the recorder's, in the one list: what the filter and the title bar offer,
/// each row sent to the device that holds it and to no other, the two read side by side and
/// neither harmed by the other, the list that does not add up, and what goes with the television. How a television's
/// list is read and a row written to, step by step and sentence by sentence, is RecorderKit's to hold
/// (`TVDriverRecordingsTests`). And that a home with no television is shown, and asks, what it always did.
@MainActor
final class TVTitlesTests: XCTestCase {
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_534_400)

    private nonisolated static func recording(_ number: Int, sizeMB: Int = 3000, title: String? = nil,
                                              protected: Bool = false, recording: Bool = false) -> DemoTV.Recording {
        DemoTV.Recording(contentID: number, title: title ?? "テレビの録画\(number)", station: "サンプル放送", start: start,
                         sizeMB: sizeMB, protected: protected, recording: recording, summary: "あらすじ\(number)")
    }

    private struct Home {
        let bench: Bench
        let recorder: NamedRecorder
        let television: DemoTV
        let door: HeldTelevision
        let model: AppModel
    }

    /// A home with both devices connected, the recorder's recordings read and, unless `read` is false, the
    /// television's. `slot` is what the recorder's USB slot answers: no disk unless a test gives one.
    private func atHome(_ recordings: [DemoTV.Recording] = [TVTitlesTests.recording(1), TVTitlesTests.recording(2)],
                        diskMB: Int = 100_000, slot: String? = nil, read: Bool = true) async throws -> Home {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        if let slot { await recorder.answer("X_GetMediaInfo", with: .result(slot), times: 1000) }
        let television = DemoTV(recordings: recordings, diskMB: diskMB)
        let door = HeldTelevision(television, holding: false)
        let credentials = await registered(with: television)
        let model = bench.model(recorder: recorder, television: door, credentials: credentials)
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        await model.loadTitles()
        if read { await model.loadTVTitles() }
        return Home(bench: bench, recorder: recorder, television: television, door: door, model: model)
    }

    /// A home with a television and no recorder, its recordings read.
    private func atHomeWithNoRecorder(_ recordings: [DemoTV.Recording]) async throws -> (DemoTV, AppModel) {
        let bench = try aBench()
        let television = DemoTV(recordings: recordings, diskMB: 100_000)
        let credentials = await registered(with: television)
        let model = bench.modelWithNoRecorder(television: television, credentials: credentials)
        await model.start()
        try await untilTheTelevisionIsConnected(model)
        await model.loadTVTitles()
        return (television, model)
    }

    private func tvRow(_ model: AppModel, _ number: Int = 1) throws -> RecordedTitle {
        try XCTUnwrap(model.tvHost?.titles.first { $0.id == Self.recording(number).uri })
    }

    // MARK: - one list

    /// The two devices' rows are one list, sorted as the list sorts: a television's order is not by date. Each
    /// is found by what tells the rows apart, and says its station and its place: テレビ on a television's, and
    /// nothing on the internal disk's. A television's row says its own text, with nothing asked.
    func testTheTwoDevicesAreOneList() async throws {
        let early = DemoTV.Recording(contentID: 1, title: "テレビの録画", start: Self.start)
        let late = DemoTV.Recording(contentID: 2, title: "テレビの録画", start: Self.start.addingTimeInterval(86_400))
        let home = try await atHome([early, late])
        let model = home.model

        let recorders = model.titles.count
        XCTAssertGreaterThan(recorders, 0)
        XCTAssertEqual(model.allTitles.count, recorders + 2)
        XCTAssertEqual(model.titlesOnTheShownDisk.count, recorders + 2)
        let sorted = model.shownTitles.map(\.start)
        XCTAssertEqual(sorted, sorted.sorted(by: >), "the list is not newest first")
        XCTAssertEqual(Set(model.shownTitles.map(\.listKey)).count, recorders + 2)

        let row = try XCTUnwrap(model.allTitles.first { $0.device == .tv })
        XCTAssertEqual(model.diskShown(row), "テレビ")
        XCTAssertEqual(model.row(like: row)?.listKey, "tv|\(row.id)")
        XCTAssertEqual(model.channelName(for: row), "サンプルテレビ")
        XCTAssertNil(model.logo(for: row))
        let recorderRow = try XCTUnwrap(model.titles.first)
        XCTAssertNil(model.diskShown(recorderRow))
        XCTAssertEqual(model.titleGroups.reduce(0) { $0 + $1.count }, recorders + 2)
        XCTAssertEqual(model.members(of: try XCTUnwrap(model.titleGroups.first { $0.name == "テレビの録画" })).count, 2)
    }

    /// The sheet's details are the row's own.
    func testASheetsDetailsAreTheRowsOwn() async throws {
        let home = try await atHome()
        let before = await home.television.calls.count
        let detail = await home.model.detail(of: try tvRow(home.model))
        XCTAssertEqual(detail?.summary, "あらすじ1")
        XCTAssertEqual(detail?.details, [])
        expectEqual(await home.television.calls.count, before)
    }

    /// The filter offers テレビ beside the internal disk, there being two places to tell apart though the recorder
    /// has no USB disk. Narrowed to it the list and the title bar's 残り follow, and すべて puts both back.
    func testTheFilterOffersTheTelevision() async throws {
        let home = try await atHome(diskMB: 20_000)
        let model = home.model
        XCTAssertEqual(model.titleDestinations.map(\.label), ["HDD", "テレビ"])
        let internalFree = model.shownFreeBytes
        XCTAssertNotNil(internalFree)

        model.titleDestination = TVDriver.recordsTo
        XCTAssertEqual(model.shownDestination, TVDriver.recordsTo)
        XCTAssertEqual(model.titlesOnTheShownDisk.map(\.device), [.tv, .tv])
        XCTAssertEqual(model.shownFreeBytes, 13_400 * 1_000_000)
        XCTAssertEqual(model.titleDestinationLabel(TVDriver.recordsTo), "テレビ")

        model.titleDestination = RecorderDisk.internalID
        XCTAssertFalse(model.shownTitles.contains { $0.device == .tv })
        XCTAssertEqual(model.shownFreeBytes, internalFree)

        model.titleDestination = nil
        XCTAssertEqual(model.shownFreeBytes, internalFree, "すべて stays the internal disk's")
    }

    /// With a USB disk the filter has the three, the television last.
    func testTheFilterHasTheThree() async throws {
        let home = try await atHome(slot: USBDiskTests.slot())
        XCTAssertEqual(home.model.titleDestinations.map(\.destination), ["HDD", "USBHDD", TVDriver.recordsTo])
    }

    /// A television with no disk is no place to choose: the filter does not offer it, and in a home with no other
    /// choice there is none. A filter on it let go of goes with the choice.
    func testATelevisionWithNoDiskIsNotOffered() async throws {
        let home = try await atHome()
        let model = home.model
        model.titleDestination = TVDriver.recordsTo

        await home.television.unmount()
        await model.loadTVTitles()

        XCTAssertEqual(model.titleDestinations, [])
        XCTAssertNil(model.shownDestination)
        XCTAssertFalse(model.allTitles.contains { $0.device == .tv }, "a disk that is away has no rows")
        XCTAssertTrue(model.titlesOutOfStep)
        await model.loadOutdatedTitles()
        XCTAssertNil(model.titleDestination)
    }

    /// With a television and no recorder its rows are there, with no filter, there being one place: and no
    /// recorder is asked for anything to protect, delete or run over them.
    func testATelevisionWithNoRecorderHasItsRows() async throws {
        let (television, model) = try await atHomeWithNoRecorder([Self.recording(1), Self.recording(2),
                                                                  Self.recording(3)])
        XCTAssertFalse(model.connected)
        XCTAssertEqual(model.allTitles.count, 3)
        XCTAssertTrue(model.tvHasSomethingToShow, "the tab would say that no recorder was added")
        XCTAssertEqual(model.titleDestinations, [])
        XCTAssertNil(model.shownFreeBytes)

        expectTrue(await protectARecording(model, try tvRow(model), true), model.problem(for: .tv) ?? "no reason given")
        XCTAssertEqual(model.tvHost?.titles.first?.protected, true)
        expectTrue(await deleteARecording(model, try tvRow(model, 2)), model.problem(for: .tv) ?? "no reason given")
        expectEqual(await television.recordings.map(\.contentID), [1, 3])
    }

    // MARK: - each row to its own device

    /// A protect and a delete of a television's row go to the television and to no recorder, and show in the list;
    /// a recorder's go to the recorder and to no television.
    func testEachRowIsWrittenToItsOwnDevice() async throws {
        let home = try await atHome(diskMB: 20_000)
        let model = home.model
        let row = try tvRow(model)
        let before = await home.recorder.asked

        expectTrue(await protectARecording(model, row, true), model.problem(for: .tv) ?? "no reason given")
        XCTAssertEqual(try tvRow(model).protected, true)
        expectTrue(await protectARecording(model, try tvRow(model), false), model.problem(for: .tv) ?? "no reason given")
        expectTrue(await deleteARecording(model, try tvRow(model)), model.problem(for: .tv) ?? "no reason given")

        XCTAssertNil(model.row(like: row))
        expectEqual(await home.television.recordings.map(\.contentID), [2])
        XCTAssertEqual(model.tvDriver?.facts.storage?.freeMB, 16_400, "the free space was not read again")
        expectEqual(await home.recorder.asked("X_UpdateTitle", since: before), 0, "the recorder was told")
        expectEqual(await home.recorder.asked("X_DeleteTitle", since: before), 0, "the recorder was told")

        let calls = await home.television.calls.count
        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        expectTrue(await deleteARecording(model, title), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await home.television.calls.count, calls, "the television was told")
    }

    /// The rules the screens hold their buttons by are the row's device's. Nothing is written to a row being
    /// recorded, and it has no length to say.
    func testTheScreensAskTheRowsDevice() async throws {
        let home = try await atHome([Self.recording(1), Self.recording(2, protected: true),
                                     Self.recording(3, recording: true)])
        let model = home.model

        XCTAssertNil(model.whyNot(altering: try tvRow(model)))
        XCTAssertEqual(model.whyNot(deleting: try tvRow(model, 2)), RecorderDriver.protectedCannotBeDeleted)
        let being = try tvRow(model, 3)
        XCTAssertTrue(being.recording)
        XCTAssertFalse(being.lengthKnown)
        XCTAssertNil(being.sizeMB)
        XCTAssertEqual(model.whyNot(altering: being), TVDriver.stillRecording)
        XCTAssertEqual(model.whyNot(deleting: being), TVDriver.stillRecording)
    }

    /// A television's work holds its rows' buttons and not the recorder's, and the reverse; a run holds them all.
    func testEachDevicesWorkHoldsItsOwnRows() async throws {
        let home = try await atHome()
        let model = home.model
        let tv = try tvRow(model), recorders = try XCTUnwrap(model.titles.first)
        XCTAssertTrue(model.canAlter(tv))
        XCTAssertTrue(model.canAlter(recorders))

        await home.door.hold(only: "getContentList")
        let reading = Task { await model.loadTVTitles() }
        try await until("the read's line never went up") { model.isBusy(for: .tv) }
        XCTAssertFalse(model.canAlter(tv), "held by nothing of its own")
        XCTAssertTrue(model.canAlter(recorders), "held by the television's work")
        await home.door.letGo()
        await reading.value
        XCTAssertTrue(model.canAlter(tv))
    }

    /// What is said before a delete names the devices it takes from, as the recorder alone, the television alone or
    /// both. In a list of the recorder's alone it reads as it always did.
    func testTheQuestionBeforeADeleteNamesTheDevices() async throws {
        let home = try await atHome()
        let model = home.model
        let tv = try tvRow(model), recorders = try XCTUnwrap(model.titles.first)

        XCTAssertEqual([recorders].deletedForGood.asABody, "レコーダーから削除され、元に戻せません。")
        XCTAssertEqual([tv].deletedForGood.asABody, "テレビから削除され、元に戻せません。")
        XCTAssertEqual([tv, recorders].deletedForGood.asABody, "レコーダーとテレビから削除され、元に戻せません。")
        XCTAssertTrue(RecordingsScreen.deleteMessage(recorders).hasSuffix("\nレコーダーから削除され、元に戻せません。"))
        XCTAssertTrue(RecordingsScreen.deleteMessage(tv).hasSuffix("\nテレビから削除され、元に戻せません。"))
    }

    // MARK: - side by side

    /// Pulling down reads both, neither waiting on the other: a television held does not hold the recorder's list.
    func testPullingDownReadsBothAndNeitherWaitsOnTheOther() async throws {
        let home = try await atHome()
        let model = home.model
        await home.television.records([Self.recording(1)])
        await home.door.hold(only: "getContentList")
        let before = await home.recorder.asked("X_GetTitleList")

        let pulling = Task { await model.pullDownTitles() }
        try await until("the recorder's list was held up by the television") {
            await home.recorder.asked("X_GetTitleList") > before && !model.isBusy
        }
        await home.door.letGo()
        await pulling.value

        XCTAssertEqual(model.tvHost?.titles.count, 1)
    }

    /// A television that stops answering keeps its rows, with its usual line, and the recorder's stay as they are;
    /// back, it is read again as it is attached. A recorder that does not answer leaves the television's alone.
    func testAFailedReadHarmsOnlyItsOwnDevice() async throws {
        let home = try await atHome()
        let model = home.model
        let recorders = model.titles

        await home.television.goSilent()
        await model.loadTVTitles()

        XCTAssertEqual(model.tvHost?.titles.count, 2, "a television that does not answer lost its rows")
        XCTAssertEqual(model.strip(), .tvGaveUp)
        XCTAssertEqual(model.titles, recorders)
        XCTAssertNil(model.problem(for: .recorder))

        let bench = try aBench()
        try await bench.cacheAGuide()
        let silent = NamedRecorder(1)
        let television = DemoTV(recordings: [Self.recording(1)], diskMB: 100_000)
        let credentials = await registered(with: television)
        let other = bench.model(recorder: silent, television: television, credentials: credentials)
        await other.start()
        try await untilConnected(other)
        try await untilTheTelevisionIsConnected(other)
        await silent.goQuiet(for: 100)
        await other.pullDownTitles()
        XCTAssertEqual(other.tvHost?.titles.count, 1, "the recorder's silence kept the television's list out")
    }

    /// When the television is let go of its rows go, and a filter on it with them. The recorder's stay.
    func testItsRowsGoWithTheTelevision() async throws {
        let home = try await atHome()
        let model = home.model
        let recorders = model.titles
        model.titleDestination = TVDriver.recordsTo
        let forgotten = model.tvTimesForgotten

        model.removeTV()

        XCTAssertEqual(model.allTitles, recorders)
        XCTAssertEqual(model.titleDestinations, [])
        XCTAssertNil(model.shownDestination)
        XCTAssertTrue(model.titlesOutOfStep)
        XCTAssertEqual(model.tvTimesForgotten, forgotten + 1)
        XCTAssertNotEqual(model.tvTitlesToRead, "\(forgotten)-1", "the tab would not read the next television's")
    }

    // MARK: - a list that does not add up

    /// After a restart: no rows, the disk full. The line says so for as long as it is read again, holding none of
    /// the television's buttons, rows that come are shown as they come, and once they are all there nothing is
    /// said.
    func testAListThatMayStillBeComingIsWaitedFor() async throws {
        let rows = [Self.recording(1), Self.recording(2)]
        let home = try await atHome(rows, read: false)
        let model = home.model
        await home.television.leavesOutOfItsList(Set(rows.map(\.uri)))
        let idle = model.tvTitlesToWaitFor

        await model.loadTVTitles()
        XCTAssertNotEqual(model.tvTitlesToWaitFor, idle, "the tab would not begin the wait")
        XCTAssertEqual(model.tvHost?.titlesAccount, .mayStillBeComing)
        XCTAssertNil(model.tvTitlesNote)

        await home.door.hold(only: "getContentList")
        let waiting = Task { await model.waitForTVTitles() }
        try await until("the wait never began") { await home.door.isHolding }
        XCTAssertEqual(model.strip(), .busy(TVDriver.titlesComingLine))
        XCTAssertFalse(model.isBusy(for: .tv), "the wait held the television's buttons")
        await home.television.leavesOutOfItsList([rows[1].uri])
        await home.door.letGo()
        try await until("the rows that came were not shown") { model.tvHost?.titles.count == 1 }
        XCTAssertNil(model.tvTitlesNote, "a list some of whose rows came is still being waited for")
        await home.television.leavesOutOfItsList([])
        await waiting.value

        XCTAssertFalse(model.waitingForTVTitles)
        XCTAssertNil(model.strip())
        XCTAssertEqual(model.tvHost?.titles.count, 2)
        XCTAssertEqual(model.tvHost?.titlesAccount, .addsUp)
        XCTAssertNil(model.tvTitlesNote)
    }

    /// Still short once the wait is over, the note is said, under the list: of the television's rows, so not of a
    /// list narrowed to the recorder's disk. Not an error: nothing is on the strip or on either device's line.
    func testAListThatNeverComesHasItsNote() async throws {
        let home = try await atHome(read: false)
        let model = home.model
        await home.television.leavesOutOfItsList(Set([Self.recording(1).uri, Self.recording(2).uri]))
        await model.loadTVTitles()

        await model.waitForTVTitles()

        XCTAssertEqual(model.tvTitlesNote, TVDriver.titlesMissing)
        XCTAssertEqual(TVDriver.titlesMissing.asABody,
                       "テレビには、ここに出ていない録画があります。テレビで一度再生すると出ることがあります。")
        XCTAssertNil(model.strip())
        XCTAssertNil(model.problem(for: .tv))
        model.titleDestination = RecorderDisk.internalID
        XCTAssertNil(model.tvTitlesNote)
        model.titleDestination = TVDriver.recordsTo
        XCTAssertEqual(model.tvTitlesNote, TVDriver.titlesMissing)
    }

    /// Rows, and their sum short by more than the margin: the note at once, with no waiting.
    func testRowsShortOfTheDiskHaveTheNoteAtOnce() async throws {
        let home = try await atHome(read: false)
        await home.television.leavesOutOfItsList([Self.recording(2).uri])
        await home.model.loadTVTitles()
        XCTAssertEqual(home.model.tvHost?.titlesAccount, .someAreMissing)
        XCTAssertEqual(home.model.tvTitlesNote, TVDriver.titlesMissing)
    }

    /// A list that adds up, and an empty disk, say nothing, a row being recorded with no comparison made.
    func testNothingIsSaidOfAListThatAddsUp() async throws {
        let home = try await atHome([], read: true)
        XCTAssertNil(home.model.tvTitlesNote)
        XCTAssertEqual(home.model.tvHost?.titlesAccount, .addsUp)

        let recording = try await atHome([Self.recording(1, recording: true)], read: true)
        XCTAssertEqual(recording.model.tvHost?.titlesAccount, .addsUp)
    }

    // MARK: - a home with no television

    /// Nothing changes where there is none: the list, the filter, the title bar and the sentences are the
    /// recorder's, nothing is said of a television, and pulling down asks the recorder what it always did.
    func testAHomeWithNoTelevisionIsAsItWas() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilConnected(model)
        await model.loadTitles()

        XCTAssertNil(model.tv)
        XCTAssertEqual(model.allTitles, model.titles)
        XCTAssertEqual(model.titleDestinations, [], "a filter of one place")
        XCTAssertNil(model.shownDestination)
        XCTAssertEqual(model.shownFreeBytes, model.storage?.free)
        XCTAssertNil(model.tvTitlesNote)
        XCTAssertFalse(model.waitingForTVTitles)
        XCTAssertFalse(model.tvHasSomethingToShow, "rows held of a recorder that is away would be shown")
        XCTAssertEqual(model.tvTitlesToRead, "0-0")
        let row = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        XCTAssertNil(model.diskShown(row))
        XCTAssertEqual(model.channelName(for: row), model.channelNames["\(row.broadcastingType)-\(row.serviceID)"] ?? "")
        XCTAssertTrue(RecordingsScreen.deleteMessage(row).hasSuffix("\nレコーダーから削除され、元に戻せません。"))
        XCTAssertEqual(model.canAlter(row), model.canAlterARecording)

        let before = await recorder.heard.count
        await model.pullDownTitles()
        let pulled = await recorder.heard(since: before)
        await model.refreshTitles()
        let alone = await recorder.heard(since: before + pulled.count)
        XCTAssertEqual(pulled, alone, "a pull-down asks what a read of the recorder's list asks")

        XCTAssertTrue(model.startBulk(.delete, ids: [row.id]))
        try await until("the job never ended") { model.job?.finished == true }
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")
    }

    /// With a USB disk and no television the filter is the two disks, as it was.
    func testAHomeWithAUSBDiskAndNoTelevisionHasItsTwoDisks() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot()), times: 1000)
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilConnected(model)

        XCTAssertEqual(model.titleDestinations.map(\.destination), model.diskChoices.map(\.destination))
        XCTAssertEqual(model.titleDestinations.map(\.label),
                       model.diskChoices.map { RecorderDisk.label($0.destination, named: $0.name) })
        XCTAssertEqual(model.titleDestinationLabel(RecorderDisk.usbID), model.diskLabel(RecorderDisk.usbID))
    }
}
