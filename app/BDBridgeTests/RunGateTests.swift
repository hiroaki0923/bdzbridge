import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder's work over many recordings, each run asked for as a screen asks for it -- the bulk delete, the
/// bulk protect and the scan for duplicates: what a run asks of the recorder for each recording and in which
/// order, what its job says while it runs and once it has ended, and what silence, 中止, leaving the app, a check
/// beside it and another recorder's arrival each do to it.
///
/// Gates, as `FunnelGateTests` is and for the same kind of move: each pins what the app does today, so that a
/// run's steps can move out of the model and into RecorderKit with the test's body unchanged, and where a test
/// holds something that is still to be changed on purpose it says so, and that change rewrites it. A test asks
/// only what a screen asks and reads only what a screen reads, with the bench's own words for the rest (`Said`,
/// `Ask`, `makeSure`).
///
/// The recorder is the bench's (`NamedRecorder`), told what to answer a request at a time.
@MainActor
final class RunGateTests: XCTestCase {
    // MARK: - what the tests start from

    /// At home with the first recorder (`connectedHome`), nothing in the cache, and its recordings read as their
    /// screen reads them. `idle` are the recordings a run can write to, neither being recorded nor protected, in
    /// the list's order. `withACopy` puts one broadcast on the recorder's disk twice before the list is read
    /// (`NamedRecorder.haveACopy`), for a scan to find; `wakeable` saves the MAC the recorder's UDN carries, so
    /// that a check which meets silence wakes it.
    private func settled(wakeable: Bool = false, withACopy: Bool = false) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel, idle: [RecordedTitle]) {
        let (bench, recorder, model) = try await connectedHome(guide: false, wakeable: wakeable)
        if withACopy { await recorder.haveACopy() }
        await model.loadTitles()
        let idle = model.titles.filter { !$0.recording && !$0.protected }
        let six = try XCTUnwrap(idle.count >= 6 ? idle : nil, "the demo was meant to hold six recordings to write to")
        return (bench, recorder, model, six)
    }

    /// Waits for the run under way to be over, however it ended. One that was never started is over already, and
    /// what the test looks at next says so.
    private func untilTheRunEnds(_ model: AppModel, _ what: String = "the run never ended") async throws {
        try await until(what) { !model.jobRunning }
    }

    /// A bulk delete or protect as its screen starts one, and waited for until it is over.
    private func run(_ model: AppModel, _ kind: AppModel.BulkJob.Kind, _ ids: [String]) async throws {
        model.startBulk(kind, ids: ids)
        try await untilTheRunEnds(model)
    }

    /// A recording a run passed over, and why, as its job lists it.
    private func skip(_ title: RecordedTitle, _ reason: String) -> AppModel.BulkJob.Skip {
        AppModel.BulkJob.Skip(id: title.id, reason: reason)
    }

    // MARK: - a bulk delete and a bulk protect to their ends

    /// A bulk delete asks the recorder about each recording and then deletes it, one request at a time and each
    /// once, with nothing on the strip, and reads the free space once when it has ended. What it does not delete
    /// it lists with why: a recording still being recorded and a protected one, neither of which the recorder
    /// is asked about; one the recorder says it no longer holds as it is asked about it (820), which leaves the
    /// list and is not sent for; one whose delete the recorder refuses, in the recorder's words, which stays.
    /// Every recording counts as done, deleted or not, and the job says how many went and how many did not.
    ///
    /// Three things are as they are today. The two it does not ask about are listed as 「録画中です」 and
    /// 「保護されています」, where a single delete's door has a sentence for each; a later change says the door's.
    /// A recording the recorder is too busy to be asked about is deleted all the same: a later change passes it
    /// over. And the free space is read after a run that deleted nothing: a later change reads it only after one
    /// that deleted something.
    func testABulkDeleteAsksAboutEachRecordingDeletesItAndListsWhatItPassedOver() async throws {
        let (_, recorder, model, idle) = try await settled()
        let writing = try XCTUnwrap(model.titles.first { $0.recording }, "the demo was meant to be recording")
        let guarded = try XCTUnwrap(model.titles.first { $0.protected }, "the demo was meant to protect a recording")
        let room = try XCTUnwrap(model.storage?.free, "the recorder never said how much room it has")
        let (deleted, gone, refused, lateAsked) = (idle[0], idle[1], idle[2], idle[3])

        // The second recording it is asked about has left it, and the second delete it turns down.
        await recorder.answer(Ask.details, with: .fault(820), after: 1)
        await recorder.answer(Ask.deleteRecording, with: .fault(402), after: 1)
        await recorder.holdTheNext(Ask.details)
        var count = await recorder.heard.count
        model.startBulk(.delete, ids: [writing.id, guarded.id, deleted.id, gone.id, refused.id])
        try await until("the run never asked about a recording") { await recorder.heard.count == count + 1 }
        XCTAssertNil(model.busy, "a run put a line on the strip")
        XCTAssertEqual(model.job?.total, 5)
        await recorder.letGo()
        try await untilTheRunEnds(model)

        expectEqual(await recorder.heard(since: count),
                    [Ask.details, Ask.deleteRecording, Ask.details, Ask.details, Ask.deleteRecording, Ask.freeSpace],
                    "each recording asked about and then deleted, once, and the free space once after")
        XCTAssertEqual(model.job?.changed, [deleted.id])
        XCTAssertEqual(model.job?.skipped, [skip(writing, "録画中です"), skip(guarded, "保護されています"),
                                            skip(gone, "すでに削除されています"),
                                            skip(refused, Said.fault(402, Ask.deleteRecording))])
        XCTAssertEqual(model.job?.done, 5)
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました（4 件はスキップ）")
        let listed = Set(model.titles.map(\.id))
        XCTAssertFalse(listed.contains(deleted.id), "the recording deleted is still listed")
        XCTAssertFalse(listed.contains(gone.id), "a recording the recorder no longer holds is still listed")
        XCTAssertTrue(listed.isSuperset(of: [writing.id, guarded.id, refused.id]),
                      "a recording passed over left the list")
        XCTAssertGreaterThan(model.storage?.free ?? 0, room, "the room the deleted recording took is not shown")
        XCTAssertNil(model.busy)

        // Busy with somebody else as it is asked about a recording, through both tries after the first.
        await recorder.beBusy(with: Ask.details)
        count = await recorder.heard.count
        try await run(model, .delete, [lateAsked.id])
        expectEqual(await recorder.heard(since: count),
                    [Ask.details, Ask.details, Ask.details, Ask.deleteRecording, Ask.freeSpace],
                    "a recording the recorder was too busy to be asked about is deleted all the same, today")
        XCTAssertEqual(model.job?.changed, [lateAsked.id])
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")

        // Nothing to delete.
        count = await recorder.heard.count
        try await run(model, .delete, [guarded.id])
        expectEqual(await recorder.heard(since: count), [Ask.freeSpace],
                    "the free space is read after a run that deleted nothing, today")
        XCTAssertEqual(model.job?.outcome, "0 件を削除しました（1 件はスキップ）")
    }

    /// A bulk protect, and one that takes the protection off, change each recording with one request and nothing
    /// asked first, and put the flag on the row of that number in the list. A recording already the way it is to
    /// be is listed as passed over with nothing sent, and one the recorder refuses in the recorder's words. The
    /// free space is not read after either: nothing was deleted.
    func testABulkProtectChangesEachRecordingByItsNumberAndReadsNoFreeSpace() async throws {
        let (_, recorder, model, idle) = try await settled()
        let guarded = try XCTUnwrap(model.titles.first { $0.protected }, "the demo was meant to protect a recording")
        let (first, second, open) = (idle[0], idle[1], idle[2])
        func protected() -> Set<String> { Set(model.titles.filter(\.protected).map(\.id)) }

        var count = await recorder.heard.count
        try await run(model, .protecting(true), [guarded.id, first.id, second.id])
        expectEqual(await recorder.heard(since: count), [Ask.changeRecording, Ask.changeRecording])
        XCTAssertEqual(model.job?.changed, [first.id, second.id])
        XCTAssertEqual(model.job?.skipped, [skip(guarded, "すでに保護されています")])
        XCTAssertEqual(model.job?.done, 3)
        XCTAssertEqual(model.job?.outcome, "2 件を保護しました（1 件はスキップ）")
        XCTAssertEqual(protected(), [guarded.id, first.id, second.id], "the flag is not on the rows protected")

        // Taken off again, the second of them refused.
        await recorder.answer(Ask.changeRecording, with: .fault(402), after: 1)
        count = await recorder.heard.count
        try await run(model, .protecting(false), [first.id, second.id, open.id])
        expectEqual(await recorder.heard(since: count), [Ask.changeRecording, Ask.changeRecording])
        XCTAssertEqual(model.job?.changed, [first.id])
        XCTAssertEqual(model.job?.skipped, [skip(second, Said.fault(402, Ask.changeRecording)),
                                            skip(open, "保護されていません")])
        XCTAssertEqual(model.job?.outcome, "1 件を保護解除しました（2 件はスキップ）")
        XCTAssertEqual(protected(), [guarded.id, second.id], "the flag came off a row the recorder kept protected")
    }

    /// What a job says once it has stopped, letter for letter: how many recordings it changed, or a scan how many
    /// it looked at, whether it came to its end, was stopped by 中止 or lost the recorder, and how many it passed
    /// over. One that lost the recorder says so whether or not 中止 was tapped as well.
    ///
    /// The sentences of a run that lost the recorder are today's, and so is the one field of the job this test
    /// sets to have them said: a later change gives a run its reason for stopping, and these rows go with it.
    func testWhatAJobSaysOnceItHasStoppedLetterForLetter() {
        typealias Job = AppModel.BulkJob
        func said(_ kind: Job.Kind, cancelled: Bool = false, lost: Bool = false, skipped: Int = 0) -> String {
            var job = Job(kind: kind, total: 5)
            job.done = 3
            job.changed = ["a", "b"]
            job.skipped = (0..<skipped).map { Job.Skip(id: "\($0)", reason: "") }
            job.cancelled = cancelled
            job.lostRecorder = lost
            job.finished = true
            return job.outcome
        }

        for (kind, verb) in [(Job.Kind.delete, "削除"), (.protecting(true), "保護"), (.protecting(false), "保護解除")] {
            XCTAssertEqual(said(kind), "2 件を\(verb)しました")
            XCTAssertEqual(said(kind, skipped: 1), "2 件を\(verb)しました（1 件はスキップ）")
            XCTAssertEqual(said(kind, cancelled: true), "2 件を\(verb)したところで中止しました")
            XCTAssertEqual(said(kind, cancelled: true, skipped: 2), "2 件を\(verb)したところで中止しました（2 件はスキップ）")
            XCTAssertEqual(said(kind, lost: true), "2 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました")
            XCTAssertEqual(said(kind, lost: true, skipped: 1),
                           "2 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました（1 件はスキップ）")
            XCTAssertEqual(said(kind, cancelled: true, lost: true),
                           "2 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました")
        }
        XCTAssertEqual(said(.scanning), "3 件の確認が完了しました")
        XCTAssertEqual(said(.scanning, skipped: 1), "3 件の確認が完了しました（1 件は番組内容を取得できず、比べていません）")
        XCTAssertEqual(said(.scanning, cancelled: true), "3 件まで調べて中止しました")
        XCTAssertEqual(said(.scanning, cancelled: true, skipped: 2),
                       "3 件まで調べて中止しました（2 件は番組内容を取得できず、比べていません）")
        XCTAssertEqual(said(.scanning, lost: true), "3 件まで調べたところで、レコーダーの応答がなくなったため中止しました")
        XCTAssertEqual(said(.scanning, lost: true, skipped: 1),
                       "3 件まで調べたところで、レコーダーの応答がなくなったため中止しました（1 件は番組内容を取得できず、比べていません）")
        XCTAssertEqual(said(.scanning, cancelled: true, lost: true),
                       "3 件まで調べたところで、レコーダーの応答がなくなったため中止しました")
    }

    // MARK: - a job from the turn it is asked for

    /// A job stands from the turn it is asked for, before its task has had a turn of its own: the screens say a
    /// run is under way, the recorder in play cannot be changed -- for another address or for the demo -- and a
    /// connect asked for in that very turn asks nothing, since a second client would be a second conversation
    /// with the recorder beside the run's. Pulling the recordings down while it runs reads nothing either: the
    /// run is walking that list. A run of no recordings is not started at all.
    func testAJobStandsInTheTurnItIsAskedForAndKeepsTheRecorderToItself() async throws {
        let (_, recorder, model, idle) = try await settled()
        model.startBulk(.delete, ids: [])
        XCTAssertNil(model.job, "a run of no recordings was started")
        XCTAssertFalse(model.jobRunning)

        await recorder.hold(only: Ask.details)
        let before = await recorder.asked
        model.startBulk(.delete, ids: [idle[0].id])
        XCTAssertTrue(model.jobRunning, "the job does not stand in the turn it was asked for")
        XCTAssertEqual(model.job?.total, 1)
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen in the turn a job was asked for")
        await model.connect()
        expectEqual(await recorder.asked(Ask.description, since: before), 0,
                    "a connect asked for in the turn a job was started asked the recorder who it is")
        // Only once that is so: where it is not, either of these would go through and take the recorder away
        // from under everything below.
        if !model.canChangeRecorder {
            await model.adopt(host: Bench.otherHost)
            XCTAssertEqual(model.host, Bench.host, "another address was taken with a job running")
            await model.enterDemo()
            XCTAssertFalse(model.demo, "the demo was entered with a job running")
        }

        // Pulled down beside the run, the recordings are not read: one that went on would put its line up and
        // wait there behind the run's request.
        let back = Back()
        let pulling = Task {
            await model.refreshTitles()
            back.came = true
        }
        try await until("the pull-down neither came back nor went on to read") { back.came || model.busy != nil }
        XCTAssertNil(model.busy, "the recordings were being read again beside a job")
        await recorder.letGo()
        await pulling.value
        try await untilTheRunEnds(model)
        expectEqual(await recorder.asked(Ask.recordings, since: before), 0, "the recordings were read beside a job")
        expectEqual(await recorder.asked(Ask.description, since: before), 0)
        XCTAssertEqual(model.job?.changed, [idle[0].id])
    }
}

/// Whether what a test set going has come back, for a test that does not wait for it to.
@MainActor
private final class Back {
    var came = false
}
