import XCTest
@testable import RecorderKit

/// The loop of a bulk delete or protect (`BulkRuns`), over stand-ins for both devices' drivers and lists. What a
/// driver does with a recording is its own tests'; the scan for duplicates, which asks the recorder's driver for
/// texts, is tested through the app's model (`RunGateTests`).
@MainActor
final class BulkRunsTests: XCTestCase {
    /// A driver that answers each recording as the test says, and puts down what it was asked.
    private final class Driver: RunDriver {
        var asked: [String] = []
        var refusesToBegin: RunStop?
        var answers: [String: ItemCame] = [:]
        /// Holds the answer to this recording until `release`.
        var holds: String?
        private var held: CheckedContinuation<Void, Never>?

        var isHolding: Bool { held != nil }
        func release() {
            held?.resume()
            held = nil
        }

        func beginRun(_ kind: RunKind) -> Result<Run, RunStop> {
            refusesToBegin.map { .failure($0) } ?? .success(Run(kind: kind, began: 0))
        }
        func mayGoOn(_ run: Run) async -> RunStop? {
            asked.append("may go on")
            return nil
        }
        func delete(_ title: RecordedTitle, in run: Run) async -> ItemCame {
            asked.append("delete \(title.id)")
            if holds == title.id { await withCheckedContinuation { held = $0 } }
            return answers[title.id] ?? .done
        }
        func protect(_ title: RecordedTitle, _ on: Bool, in run: Run) async -> ItemCame {
            asked.append("protect \(title.id) \(on)")
            return answers[title.id] ?? .done
        }
        func end(_ run: Run, deleted: Int, stopped: RunStop?) async {
            asked.append("end, \(deleted) deleted" + (stopped.map { ", stopped by \($0)" } ?? ""))
        }

        /// Holds the end of a read of the list said to be out, the first time it is waited for, until
        /// `releaseTheRead`.
        var holdsTheRead = false
        private var readHeld: CheckedContinuation<Void, Never>?
        var isHoldingTheRead: Bool { readHeld != nil }
        func releaseTheRead() {
            holdsTheRead = false
            readHeld?.resume()
            readHeld = nil
        }
        func afterTheListRead() async {
            if holdsTheRead { await withCheckedContinuation { readHeld = $0 } }
        }
    }

    /// What the recorder said, as far as a run reads and writes it.
    private final class Said: DuplicatesHeld {
        var titles: [RecordedTitle]
        var titlesLoaded = true
        var summaries: [String: String] = [:]
        var fixedBlurbs: Set<Duplicates.Blurb> = []
        var duplicates: [DuplicateSet] = []
        var lookedForDuplicates = false
        private(set) var recomputed = 0
        func recomputeDuplicates() { recomputed += 1 }
        init(_ ids: [String]) { titles = ids.map(recording) }
    }

    private final class TelevisionList: TitlesHeld {
        var titles: [RecordedTitle]
        init(_ ids: [String]) { titles = ids.map(recording) }
    }

    private var away = false
    private var holds = 0
    private var released = 0
    private var endings: [Bool] = []
    private var runs: BulkRuns!

    override func setUp() async throws {
        away = false
        holds = 0
        released = 0
        endings = []
        runs = BulkRuns(away: { [unowned self] in away },
                        hold: { [unowned self] in
                            holds += 1
                            return { [unowned self] in released += 1 }
                        },
                        inPlay: { nil },
                        ended: { [unowned self] walked in endings.append(walked) })
    }

    private func finished() async throws {
        let task = try XCTUnwrap(runs.task, "no run was started")
        await task.value
        XCTAssertTrue(try XCTUnwrap(runs.job).finished)
        XCTAssertFalse(runs.running)
    }

    func testEachRowIsAskedOfItsOwnDevicesDriverAndBothAreToldTheEnd() async throws {
        let recorder = Driver(), television = Driver()
        let said = Said(["r1", "r2"]), list = TelevisionList(["t1"])
        runs.startBulk(.delete, ids: ["r1", "t1", "r2"], onTV: ["t1"], recorder: (recorder, said),
                       television: (television, list))
        XCTAssertTrue(runs.isOnTheRecorder)
        XCTAssertTrue(runs.isOnTheTelevision)
        try await finished()
        XCTAssertEqual(recorder.asked, ["may go on", "delete r1", "may go on", "delete r2", "end, 2 deleted"])
        XCTAssertEqual(television.asked, ["may go on", "delete t1", "end, 1 deleted"])
        XCTAssertEqual(said.titles, [])
        XCTAssertEqual(list.titles, [])
        let job = try XCTUnwrap(runs.job)
        XCTAssertEqual(job.done, 3)
        XCTAssertEqual(job.changed, ["r1", "t1", "r2"])
        XCTAssertNil(job.stopped)
        XCTAssertEqual(endings, [true], "what follows the end is told the run walked the television's rows")
        XCTAssertEqual(holds, 5, "each recording and each end is held")
        XCTAssertEqual(released, holds)
    }

    func testTheFirstStopIsTheEndAndSilenceAfterSendingHasTheListReadAgain() async throws {
        let recorder = Driver()
        recorder.answers["r1"] = .stopped(.silent(afterSending: true))
        let said = Said(["r1", "r2"])
        runs.startBulk(.delete, ids: ["r1", "r2"], onTV: [], recorder: (recorder, said), television: nil)
        try await finished()
        XCTAssertEqual(recorder.asked, ["may go on", "delete r1",
                                        "end, 0 deleted, stopped by \(RunStop.silent(afterSending: true))"])
        let job = try XCTUnwrap(runs.job)
        XCTAssertEqual(job.stopped, .silent(afterSending: true))
        XCTAssertEqual(job.stoppedOn, .recorder)
        XCTAssertEqual(job.done, 0)
        XCTAssertFalse(said.titlesLoaded, "a delete that may have gone through is read again")
        XCTAssertEqual(said.titles.map(\.id), ["r1", "r2"])
        XCTAssertEqual(endings, [false])
    }

    func testWhatARecordingCameToIsKeptWithTheJob() async throws {
        let recorder = Driver()
        recorder.answers = ["r2": .gone, "r3": .passedOver("保護されています")]
        let said = Said(["r1", "r2", "r3"])
        runs.startBulk(.protecting(true), ids: ["r1", "r2", "r3", "r4"], onTV: [], recorder: (recorder, said),
                       television: nil)
        try await finished()
        let job = try XCTUnwrap(runs.job)
        XCTAssertEqual(job.changed, ["r1"])
        XCTAssertEqual(job.skipped, [.init(id: "r2", reason: ItemCame.alreadyGone),
                                     .init(id: "r3", reason: "保護されています"),
                                     .init(id: "r4", reason: RecorderDriver.notInTheList)])
        XCTAssertEqual(job.done, 4)
        XCTAssertEqual(said.titles.map(\.protected), [true, false, false])
        XCTAssertFalse(recorder.asked.contains("protect r4 true"), "a row no longer listed is not sent")
    }

    func testARunADriverWillNotBeginIsAJobThatEndedWithWhy() throws {
        let recorder = Driver()
        recorder.refusesToBegin = .said("接続していません")
        runs.startBulk(.delete, ids: ["r1"], onTV: [], recorder: (recorder, Said(["r1"])), television: nil)
        let job = try XCTUnwrap(runs.job)
        XCTAssertTrue(job.finished)
        XCTAssertEqual(job.stopped, .said("接続していません"))
        XCTAssertNil(runs.task)
        XCTAssertEqual(recorder.asked, [])
        runs.clear()
        XCTAssertNil(runs.job)
    }

    func testNoStepIsStartedWhileTheAppIsAway() async throws {
        let recorder = Driver()
        recorder.holds = "r1"
        runs.startBulk(.delete, ids: ["r1", "r2"], onTV: [], recorder: (recorder, Said(["r1", "r2"])), television: nil)
        let holding = await eventually { recorder.isHolding }
        XCTAssertTrue(holding)
        XCTAssertEqual(holds - released, 1, "the step under way is held")
        away = true
        recorder.release()
        let waits = await eventually { self.runs.waitsForTheApp }
        XCTAssertTrue(waits, "the run did not wait for the app to come back")
        XCTAssertEqual(holds, released, "nothing is held while the run waits")
        XCTAssertEqual(recorder.asked, ["may go on", "delete r1"])
        away = false
        runs.appIsBack()
        try await finished()
        XCTAssertFalse(runs.waitsForTheApp)
        XCTAssertEqual(recorder.asked, ["may go on", "delete r1", "may go on", "delete r2", "end, 2 deleted"])
    }

    /// A run looks a recording up in the list a read out brings, once that read has handed it over, and not in the
    /// list the read is about to replace (`RunDriver.afterTheListRead`): a recording that list no longer has is
    /// passed over with nothing asked, and the next is asked as that list has it.
    func testARunLooksARecordingUpOnlyOnceTheListReadOutHasComeIn() async throws {
        let recorder = Driver()
        recorder.holdsTheRead = true
        let said = Said(["r1", "r2"])
        runs.startBulk(.protecting(true), ids: ["r1", "r2"], onTV: [], recorder: (recorder, said), television: nil)
        let holding = await eventually { recorder.isHoldingTheRead }
        XCTAssertTrue(holding, "the run did not wait for the read of the list that was out")
        XCTAssertEqual(recorder.asked, ["may go on"], "something was asked before the list came in")
        said.titles = [recording("r2")]
        recorder.releaseTheRead()
        try await finished()
        XCTAssertEqual(recorder.asked, ["may go on", "may go on", "protect r2 true", "end, 0 deleted"])
        let job = try XCTUnwrap(runs.job)
        XCTAssertEqual(job.skipped, [.init(id: "r1", reason: RecorderDriver.notInTheList)])
        XCTAssertEqual(job.changed, ["r2"])
    }

    func testAStoppedRunGoesNoFurtherThanTheRecordingItIsOn() async throws {
        let recorder = Driver()
        recorder.holds = "r1"
        runs.startBulk(.delete, ids: ["r1", "r2"], onTV: [], recorder: (recorder, Said(["r1", "r2"])), television: nil)
        let holding = await eventually { recorder.isHolding }
        XCTAssertTrue(holding)
        runs.cancel()
        recorder.release()
        try await finished()
        let job = try XCTUnwrap(runs.job)
        XCTAssertTrue(job.cancelled)
        XCTAssertNil(job.stopped)
        XCTAssertEqual(job.done, 1, "what has been done stays done")
        XCTAssertEqual(recorder.asked, ["may go on", "delete r1", "end, 1 deleted"])
    }
}

private func recording(_ id: String) -> RecordedTitle {
    RecordedTitle(id: id, title: "", start: Date(timeIntervalSince1970: 1_800_000_000), durationSec: 60,
                  broadcastingType: 0, serviceID: 0, qualityCode: 0, protected: false, isNew: false,
                  recording: false, destination: RecorderDisk.internalID, sizeMB: nil)
}
