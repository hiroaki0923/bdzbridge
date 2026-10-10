import Foundation
import RecorderKit
import UIKit
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

    /// A scan for duplicates as its screen starts one, and waited for until it is over.
    private func scan(_ model: AppModel) async throws {
        model.startDuplicateScan()
        try await untilTheRunEnds(model, "the scan never ended")
    }

    /// The two recordings a scan of the recorder with a copy asks about, in the order it asks: one a run can
    /// delete, and the demo's protected one.
    private func copies(_ model: AppModel) throws -> (first: String, second: String) {
        let found = Duplicates.candidates(model.titles).flatMap { $0 }
        guard found.count == 2, !found[0].protected, found[1].protected else {
            XCTFail("the recorder was meant to hold one broadcast twice, the second copy protected")
            throw StillWaiting()
        }
        return (found[0].id, found[1].id)
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

    // MARK: - silence

    /// Silence at a recording of a run stops the run there: the request is not sent again -- a write that met
    /// silence may have arrived all the same -- nothing after it is asked, the free space is not read, and the
    /// app is left given up on the recorder. The job says how far it got and that the recorder stopped
    /// answering. So it is at a delete, at the question a delete asks first, and at a protect.
    ///
    /// Two things are as they are today. The line of what went wrong is left as it was: a later change has
    /// the silence said there, as a single delete says it. And the recordings are marked unread in every row,
    /// the one where nothing had been sent for the recording among them: a later change marks them only after
    /// silence on something sent.
    func testSilenceAtARecordingStopsTheRunThereAndMarksTheRecordingsUnread() async throws {
        let (_, recorder, model, _) = try await settled()
        let lost = "したところで、レコーダーの応答がなくなったため中止しました"
        let rows: [(name: String, kind: AppModel.BulkJob.Kind, silent: String, heard: [String], outcome: String)] = [
            ("the second delete", .delete, Ask.deleteRecording,
             [Ask.details, Ask.deleteRecording, Ask.details, Ask.deleteRecording], "1 件を削除" + lost),
            ("the second recording asked about", .delete, Ask.details,
             [Ask.details, Ask.deleteRecording, Ask.details], "1 件を削除" + lost),
            ("the second protect", .protecting(true), Ask.changeRecording,
             [Ask.changeRecording, Ask.changeRecording], "1 件を保護" + lost),
        ]
        for row in rows {
            let three = model.titles.filter { !$0.recording && !$0.protected }.prefix(3).map(\.id)
            guard three.count == 3 else {
                return XCTFail("the demo was meant to hold three recordings to write to before \(row.name)")
            }
            XCTAssertTrue(model.titlesLoaded, row.name)
            leaveALine(on: model)
            await recorder.answer(row.silent, with: .silence, after: 1)
            let count = await recorder.heard.count
            try await run(model, row.kind, three)

            expectEqual(await recorder.heard(since: count), row.heard,
                        "silence at \(row.name): sent again, or something asked after it")
            XCTAssertTrue(model.gaveUp, "silence at \(row.name) did not leave the app given up")
            XCTAssertEqual(model.problem(for: .recorder), lineLeft,
                           "silence at \(row.name) is said on the line, today not")
            XCTAssertFalse(model.titlesLoaded, "silence at \(row.name) left the recordings as read")
            XCTAssertEqual(model.job?.changed, [three[0]], row.name)
            XCTAssertEqual(model.job?.done, 1, row.name)
            XCTAssertEqual(model.job?.outcome, row.outcome, row.name)
            await reconnect(model)
            await model.loadTitles()
        }
    }

    /// Silence at a recording whose request is out as the reader leaves the app ends the run there and then, as
    /// it does in front. The run does not go round to wait for the app to come back, its job still running and
    /// the recorder kept to it all the while: it is over in the turn of the silence, the app left given up on
    /// the recorder, with nothing asked after the request that met it.
    func testSilenceAtARecordingThatIsOutAsTheAppLeavesEndsTheRunAndDoesNotWaitForItsReturn() async throws {
        let (_, recorder, model, idle) = try await settled()
        await recorder.hold(only: Ask.details)
        let before = await recorder.asked
        let count = await recorder.heard.count
        model.startBulk(.delete, ids: [idle[0].id, idle[1].id])
        try await until("the run never asked about its first recording") {
            await recorder.asked(Ask.details, since: before) == 1
        }
        model.wentToBackground()
        await recorder.answer(Ask.deleteRecording, with: .silence)
        await recorder.letGo()
        try await until("the run neither ended nor waited for the app to come back") {
            !model.jobRunning || model.backInFront != nil
        }

        XCTAssertFalse(model.jobRunning, "a run that met silence while the app was away waits for its return")
        XCTAssertNil(model.backInFront, "a run that met silence while the app was away waits for its return")
        XCTAssertTrue(model.gaveUp, "silence at a delete while the app was away did not leave the app given up")
        expectEqual(await recorder.heard(since: count), [Ask.details, Ask.deleteRecording],
                    "something was asked after the silence")
        XCTAssertEqual(model.job?.outcome, "0 件を削除したところで、レコーダーの応答がなくなったため中止しました")
    }

    /// The free space read after a bulk delete is only shown, and cannot fail the run it follows. A recorder that
    /// will not say leaves it unknown and the app connected. Silence on it loses the recorder like any other,
    /// and the job still says what it deleted.
    ///
    /// That silence is said nowhere today: the line of what went wrong is left with nothing on it. A later
    /// change says it there, as the free space read after a single delete does.
    func testTheFreeSpaceAfterABulkDeleteIsOnlyShownAndItsSilenceIsSaidNowhere() async throws {
        let (_, recorder, model, idle) = try await settled()

        clearTheLine(on: model)
        await recorder.goQuiet(on: Ask.freeSpace)
        let count = await recorder.heard.count
        try await run(model, .delete, [idle[0].id])
        expectEqual(await recorder.heard(since: count), [Ask.details, Ask.deleteRecording, Ask.freeSpace])
        XCTAssertTrue(model.gaveUp, "silence on the free space did not leave the app given up")
        XCTAssertNil(model.problem(for: .recorder), "silence on the free space after a run is said, today not")
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")

        await reconnect(model)
        XCTAssertNotNil(model.storage, "the connect was meant to read the free space")
        await recorder.answer(Ask.freeSpace, with: .fault(402))
        try await run(model, .delete, [idle[1].id])
        XCTAssertNil(model.storage, "the free space the recorder would not say is still shown as it was")
        XCTAssertTrue(model.connected, "a recorder that would not say its free space was let go of")
        XCTAssertFalse(model.gaveUp)
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")
    }

    // MARK: - the check before a recording

    /// A run makes sure of the recorder before its first recording, as anything the reader asks for does, and
    /// one started while a check is out waits for that check's answer in place of a probe of its own.
    ///
    /// With the recorder known to be away nothing is asked, and with a check that meets silence nothing but the
    /// check's own ask: the run ends with nothing sent. After a check the recorder answered, the recordings go.
    ///
    /// Three things are as they are today. A run that could not begin says that the recorder stopped answering,
    /// whatever the reason was, and with the recorder known to be away the check writes on the line that the
    /// app is not connected: a later change has the job say the reason, and leaves the line at that door. And
    /// after a check that heard the recorder busy with somebody else as it was asked who it is -- which says
    /// nothing of which recorder answered -- the run's recordings are sent: a later change stops the run there.
    func testARunMakesSureOfTheRecorderBeforeItsFirstRecordingAndWaitsForACheckThatIsOut() async throws {
        let (_, recorder, model, idle) = try await settled()
        let notBegun = "0 件を削除したところで、レコーダーの応答がなくなったため中止しました"

        // The recorder known to be away.
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.gaveUp, "the recorder was meant to be known to be away")
        leaveALine(on: model)
        var count = await recorder.heard.count
        try await run(model, .delete, [idle[0].id])
        expectEqual(await recorder.heard(since: count), [], "a recorder known to be away was asked")
        XCTAssertEqual(model.problem(for: .recorder), Said.notConnected)
        XCTAssertEqual(model.job?.outcome, notBegun)
        await reconnect(model)

        // Beside a check that meets silence.
        leaveALine(on: model)
        count = await recorder.heard.count
        let silent = try await duringACheck(by: model, of: recorder, endingIn: .silence, "the run",
                                            waitingFor: { model.jobRunning }) {
            model.startBulk(.delete, ids: [idle[0].id])
        }
        try await untilTheRunEnds(model)
        XCTAssertFalse(silent.there)
        expectEqual(await recorder.heard(since: count), [Ask.description],
                    "a recording was sent, or a probe of the run's own, beside a check that met silence")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertEqual(model.job?.outcome, notBegun)
        await reconnect(model)

        // Beside a check that hears it busy with somebody else, through both tries after the first.
        count = await recorder.heard.count
        let busy = try await duringACheck(by: model, of: recorder, endingIn: .busy, "the run",
                                          waitingFor: { model.jobRunning }) {
            model.startBulk(.delete, ids: [idle[0].id])
        }
        try await untilTheRunEnds(model)
        await recorder.comeFree()
        XCTAssertTrue(busy.there, "a recorder that answered busy was taken for gone")
        expectEqual(await recorder.heard(since: count),
                    [Ask.description, Ask.description, Ask.description,
                     Ask.details, Ask.deleteRecording, Ask.freeSpace],
                    "the recording goes after a check that heard the recorder busy, today")
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")
    }

    /// A run started beside a check that woke the recorder and was then turned away -- silent to the check's own
    /// ask, answering the waking, and busy with somebody else as the waking's attach asks who it is -- sends none
    /// of its recordings: the recorder is there, and the app is not connected to it.
    ///
    /// Two things are as they are today. The job says that the recorder stopped answering, which it did not: a
    /// later change has it say the check's reason. And the free space is read once the run has stopped, of a
    /// recorder that has not said which it is: a later change reads it only after a run that deleted something
    /// and that the recorder did not stop.
    func testARunBesideACheckTurnedAwayAfterAWakingSendsNoRecording() async throws {
        let (_, recorder, model, idle) = try await settled(wakeable: true)
        let count = await recorder.heard.count
        _ = try await duringACheckTurnedAwayAfterAWaking(by: model, of: recorder, waitingFor: { model.jobRunning }) {
            model.startBulk(.delete, ids: [idle[0].id])
        }
        try await untilTheRunEnds(model)

        expectEqual(await recorder.heard(since: count).filter { $0 != Ask.description }, [Ask.freeSpace],
                    "a recording was sent to a recorder that turned the attach away; the free space is read, today")
        XCTAssertEqual(model.job?.changed, [])
        XCTAssertEqual(model.job?.outcome, "0 件を削除したところで、レコーダーの応答がなくなったため中止しました")
    }

    /// A run in front, between two recordings, hears out a check that is waking the recorder. The check's own ask
    /// came between the two requests of the first recording and met silence, and the first ask of the waking that
    /// follows is held: while the recorder is being woken the second recording is not asked about. Once the same
    /// recorder answers, the run goes on to it and comes to its end, and the line of what went wrong is as the
    /// waking left it, which is with nothing on it: a waking clears the line as it begins, and its attach again.
    ///
    /// Nothing is looked at of the first recording while the waking is out, and what became of it is held only
    /// once the run has ended: where its delete stands at that moment is not this test's to say.
    func testARunInFrontHearsOutACheckThatIsWakingTheRecorderBeforeItsNextRecording() async throws {
        let (_, recorder, model, idle) = try await settled(wakeable: true)
        let two = [idle[0].id, idle[1].id]
        leaveALine(on: model)
        await recorder.holdTheNext(Ask.details)
        await recorder.hold(only: Ask.description)
        let before = await recorder.asked
        model.startBulk(.delete, ids: two)
        try await until("the run never asked about its first recording") {
            await recorder.asked(Ask.details, since: before) == 1
        }
        // The check's ask waits its turn behind the question about the first recording, and is silent.
        let check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") { isMakingSure(model) }
        await recorder.letGo(only: Ask.details)
        try await until("the check never asked who answers") {
            await recorder.asked(Ask.description, since: before) == 1
        }
        await recorder.goQuiet(on: Ask.description)
        await recorder.letTheFirstGo(of: Ask.description)
        try await until("the recorder was never being woken") {
            await recorder.asked(Ask.description, since: before) == 2
        }

        XCTAssertTrue(model.waking, "the recorder was meant to be being woken")
        expectEqual(await recorder.asked(Ask.details, since: before), 1,
                    "the run asked about its next recording while the recorder was being woken")

        await recorder.letGo()
        expectTrue(await check.value, "the recorder was meant to answer once woken")
        try await untilTheRunEnds(model)
        XCTAssertEqual(model.job?.changed, two, "the run did not go on once the recorder had answered")
        XCTAssertEqual(model.job?.done, 2)
        XCTAssertEqual(model.job?.outcome, "2 件を削除しました")
        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 2)
        XCTAssertNil(model.problem(for: .recorder), "the line is not as the waking left it")
    }

    /// A run in front, the delete of its first recording out, when the network changes and the recorder is asked
    /// whether it is still there: the ask waits its turn behind that delete and meets silence. The run hears the
    /// check out before its next recording, and that one is not sent.
    func testARunInFrontSendsNoMoreAfterALookAtTheNetworkThatMetSilence() async throws {
        let (bench, recorder, model, idle) = try await settled()
        await recorder.hold(only: Ask.deleteRecording)
        let before = await recorder.asked
        model.startBulk(.delete, ids: [idle[0].id, idle[1].id])
        try await until("the run never came to its first delete") {
            await recorder.asked(Ask.deleteRecording, since: before) == 1
        }
        bench.network = "away"
        let check = Task { await lookAtTheNetwork(model) }
        try await until("the recorder was never made sure of") { isMakingSure(model) }
        await recorder.goQuiet(on: Ask.description)
        await recorder.letGo()
        _ = await check.value
        try await untilTheRunEnds(model)

        XCTAssertTrue(model.gaveUp, "the look at the network was meant to lose the recorder")
        expectEqual(await recorder.asked(Ask.details, since: before), 1,
                    "the run went on to its next recording after a check that met silence")
        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 1)
        XCTAssertEqual(model.job?.changed, [idle[0].id])
    }

    /// A connect under way has a client of its own that has not yet heard which recorder answers it, and a
    /// reconnect the recorder answered busy with somebody else leaves the app connected from the attach before,
    /// beside such a client. A single delete is turned away at its door in both moments. A run is not, today:
    /// started then, it takes that client and its recording is sent on it -- beside the connect, queued behind
    /// the connect's own ask. A later change starts no run on a client that has not heard which recorder
    /// answers.
    func testARunStartedOnAClientThatHasNotHeardWhichRecorderAnswersSendsItsRecording() async throws {
        let (bench, recorder, model, idle) = try await settled()

        // After a reconnect answered busy.
        await recorder.busyAtTheDoor()
        let made = bench.clientsMade
        await model.connect()
        XCTAssertEqual(bench.clientsMade, made + 1, "the reconnect was meant to make a client of its own")
        XCTAssertTrue(model.connected, "the attach before was meant to stand")
        await recorder.comeFree()
        var before = await recorder.asked
        try await run(model, .delete, [idle[0].id])
        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 1,
                    "the recording goes on a client that never heard which recorder answers, today")
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")
        await reconnect(model)

        // During a connect, with its ask of who answers held.
        await recorder.hold(only: Ask.description)
        before = await recorder.asked
        let connecting = Task { await model.connect() }
        try await until("the connect never asked who answers") {
            await recorder.asked(Ask.description, since: before) == 1
        }
        model.startBulk(.delete, ids: [idle[1].id])
        XCTAssertTrue(model.jobRunning, "no run was started beside a connect under way, where today one is")
        await recorder.letGo()
        await connecting.value
        try await untilTheRunEnds(model)
        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 1,
                    "the recording goes beside a connect under way, today")
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")
        XCTAssertTrue(model.connected)
    }

    // MARK: - 中止, and leaving the app

    /// 中止 stops a run before its next recording. Tapped while a recording's request is out, that recording is
    /// finished and counted, the next is not asked about, and the job says it was stopped and how far it got;
    /// the free space is still read, something having been deleted. Until the run has stopped its job cannot be
    /// taken off the screen, and afterwards it can.
    func testStoppingARunCountsTheRecordingThatIsOutAndSendsNoOther() async throws {
        let (_, recorder, model, idle) = try await settled()
        await recorder.hold(only: Ask.deleteRecording)
        let count = await recorder.heard.count
        model.startBulk(.delete, ids: [idle[0].id, idle[1].id])
        try await until("the run never came to its first delete") { await recorder.heard.count == count + 2 }

        model.cancelBulk()
        model.clearJob()
        XCTAssertNotNil(model.job, "a job still running was taken off the screen")
        XCTAssertTrue(model.jobRunning)
        await recorder.letGo()
        try await untilTheRunEnds(model)

        expectEqual(await recorder.heard(since: count), [Ask.details, Ask.deleteRecording, Ask.freeSpace],
                    "a recording after 中止 was asked about, or the free space was not read")
        XCTAssertEqual(model.job?.changed, [idle[0].id])
        XCTAssertEqual(model.job?.done, 1)
        XCTAssertEqual(model.job?.outcome, "1 件を削除したところで中止しました")
        model.clearJob()
        XCTAssertNil(model.job, "a job that has stopped could not be taken off the screen")
    }

    /// A run takes no new step while the app is away: iOS suspends it soon after, and a request frozen with it
    /// comes back as a failure. The step that is out as the reader leaves is finished, under a background task
    /// of its own, and counted; the run then waits between two recordings, under no background task, and goes on
    /// when the app is back. A bulk delete, and a scan for duplicates.
    func testARunFinishesTheStepThatIsOutAsTheAppLeavesAndWaitsForItsReturnBeforeTheNext() async throws {
        /// Leaves while the first question of a run is out, held, and comes back once the run is waiting.
        func leaveAndComeBack(_ model: AppModel, _ recorder: NamedRecorder, _ what: String,
                              since before: [String: Int]) async throws {
            try await until("\(what) never asked its first question") {
                await recorder.asked(Ask.details, since: before) == 1
            }
            XCTAssertNotEqual(model.stepTask, .invalid, "\(what): the step that is out is under no background task")
            model.wentToBackground()
            await recorder.letGo()
            try await until("\(what) never counted the recording that was out") { (model.job?.done ?? 0) > 0 }
            XCTAssertNotNil(model.backInFront, "\(what) did not wait for the app to come back")
            XCTAssertEqual(model.job?.done, 1, "\(what) counted more than the recording that was out")
            XCTAssertEqual(model.stepTask, .invalid, "\(what) kept a background task while it waited")
            expectEqual(await recorder.asked(Ask.details, since: before), 1,
                        "\(what) went on to its next recording while the app was away")
            await model.returnedToForeground()
            try await untilTheRunEnds(model, "\(what) never ended once the app was back")
            expectEqual(await recorder.asked(Ask.details, since: before), 2,
                        "\(what) did not go on to its next recording once the app was back")
        }

        let (_, recorder, model, idle) = try await settled()
        await recorder.hold(only: Ask.details)
        var before = await recorder.asked
        model.startBulk(.delete, ids: [idle[0].id, idle[1].id])
        try await leaveAndComeBack(model, recorder, "the bulk delete", since: before)
        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 2)
        XCTAssertEqual(model.job?.outcome, "2 件を削除しました")

        let (_, withACopy, scanning, _) = try await settled(withACopy: true)
        await withACopy.hold(only: Ask.details)
        before = await withACopy.asked
        scanning.startDuplicateScan()
        try await leaveAndComeBack(scanning, withACopy, "the scan", since: before)
        XCTAssertEqual(scanning.summaries.count, 2)
        XCTAssertEqual(scanning.job?.outcome, "2 件の確認が完了しました")
    }

    /// A run waiting for the app to come back makes sure of the recorder itself once it is, and sends nothing
    /// more to one that was lost meanwhile -- here by a look at the network, taken while the app was away, that
    /// met silence. The job says that the recorder stopped answering, today; a later change has it say why the
    /// check turned it away.
    func testARunWaitingForTheAppToComeBackSendsNothingToARecorderLostMeanwhile() async throws {
        let (bench, recorder, model, idle) = try await settled()
        model.wentToBackground()
        model.startBulk(.delete, ids: [idle[0].id, idle[1].id])
        try await until("the run never waited for the app to come back") { model.backInFront != nil }
        bench.network = "away"
        await recorder.goQuiet(for: 1)
        await lookAtTheNetwork(model)
        XCTAssertTrue(model.gaveUp, "the look at the network was meant to lose the recorder")
        let count = await recorder.heard.count

        await model.returnedToForeground()
        try await untilTheRunEnds(model)
        expectEqual(await recorder.heard(since: count), [], "a recorder lost while the run waited was asked")
        XCTAssertEqual(model.job?.outcome, "0 件を削除したところで、レコーダーの応答がなくなったため中止しました")
    }

    /// A run waiting for the app to come back, beside a check that is waking the recorder: back in front, it
    /// hears that check out before it makes sure of the recorder itself -- until the waking is over the app
    /// counts the recorder as not answering. The recorder answers after the return, the run's recording goes,
    /// and the line of what went wrong is as the waking left it, with nothing on it.
    func testARunWaitingForTheAppToComeBackHearsOutACheckThatIsWakingTheRecorder() async throws {
        let (_, recorder, model, idle) = try await settled(wakeable: true)
        model.wentToBackground()
        model.startBulk(.delete, ids: [idle[0].id])
        try await until("the run never waited for the app to come back") { model.backInFront != nil }
        // A check whose own ask meets silence, and the first ask of its waking held.
        leaveALine(on: model)
        await recorder.hold(only: Ask.description)
        let before = await recorder.asked
        let check = Task { await makeSure(model) }
        try await until("the check never asked who answers") {
            await recorder.asked(Ask.description, since: before) == 1
        }
        await recorder.goQuiet(on: Ask.description)
        await recorder.letTheFirstGo(of: Ask.description)
        try await until("the recorder was never being woken") {
            await recorder.asked(Ask.description, since: before) == 2
        }
        XCTAssertTrue(model.waking, "the recorder was meant to be being woken")

        await model.returnedToForeground()
        expectEqual(await recorder.asked(Ask.details, since: before), 0)
        await recorder.letGo()
        expectTrue(await check.value, "the recorder was meant to answer once woken")
        try await untilTheRunEnds(model)

        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 1,
                    "the run did not go on once the recorder being woken had answered")
        XCTAssertEqual(model.job?.outcome, "1 件を削除しました")
        XCTAssertNil(model.problem(for: .recorder), "the line is not as the waking left it")
    }

    // MARK: - the list under a run

    /// A run looks each recording up in the list as it is when the run comes to it, not as it was when the run
    /// began, and puts a change on the row of that number in the list as it is when the recorder has answered.
    ///
    /// A recording deleted from its own sheet, that delete out as the run begins and answered before the run
    /// comes to the recording, is passed over as not in the list, with nothing asked. One protected so is passed
    /// over with nothing asked: held here by its number among those passed over, not by the letters of why.
    /// And the list read again while a bulk protect's request waits behind the read -- a list that has lost a
    /// row above the recording, deleted on the recorder's own screen, so that every row below has moved up one --
    /// leaves the flag on the recording protected and on no other.
    func testARunLooksEachRecordingUpInTheListAsItIsWhenItComesToIt() async throws {
        let (_, recorder, model, idle) = try await settled()
        let guarded = Set(model.titles.filter(\.protected).map(\.id))

        // Deleted from its sheet meanwhile.
        var before = await recorder.asked
        await recorder.holdTheNext(Ask.deleteRecording)
        let deleting = Task { await deleteARecording(model, idle[1]) }
        try await until("the single delete never got to the recorder") {
            await recorder.asked(Ask.deleteRecording, since: before) == 1
        }
        model.startBulk(.delete, ids: [idle[0].id, idle[1].id])
        await recorder.letGo()
        expectTrue(await deleting.value, model.problem(for: .recorder) ?? "no reason given")
        try await untilTheRunEnds(model)
        XCTAssertEqual(model.job?.changed, [idle[0].id])
        XCTAssertEqual(model.job?.skipped, [skip(idle[1], "一覧に見つかりません")])
        expectEqual(await recorder.asked(Ask.details, since: before), 1,
                    "the run asked about a recording that had left the list")
        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 2,
                    "the single delete and the run's first, and no other")

        // Protected from its sheet meanwhile.
        before = await recorder.asked
        await recorder.holdTheNext(Ask.changeRecording)
        let protecting = Task { await protectARecording(model, idle[3], true) }
        try await until("the single protect never got to the recorder") {
            await recorder.asked(Ask.changeRecording, since: before) == 1
        }
        model.startBulk(.delete, ids: [idle[2].id, idle[3].id])
        await recorder.letGo()
        expectTrue(await protecting.value, model.problem(for: .recorder) ?? "no reason given")
        try await untilTheRunEnds(model)
        XCTAssertEqual(model.job?.changed, [idle[2].id])
        XCTAssertEqual(model.job?.skipped.map(\.id), [idle[3].id])
        expectEqual(await recorder.asked(Ask.details, since: before), 1,
                    "the run asked about a recording protected since it began")
        expectEqual(await recorder.asked(Ask.deleteRecording, since: before), 1)

        // The list read again under a protect, one row shorter above the recording.
        let (above, subject) = (idle[4], idle[5])
        XCTAssertNotEqual(model.titles.last?.id, subject.id, "the recording was meant to have a row below it")
        try await aClient(of: recorder).deleteTitle(id: above.id)
        before = await recorder.asked
        await recorder.holdTheNext(Ask.recordings)
        let reading = Task { await model.loadTitles(force: true) }
        try await until("the recordings were never asked for again") {
            await recorder.asked(Ask.recordings, since: before) == 1
        }
        model.startBulk(.protecting(true), ids: [subject.id])
        try await until("the run never began its step") { model.stepTask != .invalid }
        await recorder.letGo()
        await reading.value
        try await untilTheRunEnds(model)
        XCTAssertFalse(model.titles.contains { $0.id == above.id }, "the list read again was meant to be a row shorter")
        XCTAssertEqual(model.job?.changed, [subject.id])
        XCTAssertEqual(Set(model.titles.filter(\.protected).map(\.id)), guarded.union([idle[3].id, subject.id]),
                       "the flag is on another row than the recording protected")
    }

    /// The sets of copies on screen were worked out from recordings that a bulk delete may have taken away, so
    /// they are worked out again when one has ended: the copy ticked, deleted by a run, leaves its set with one
    /// recording, which is no set, and nothing is left ticked.
    func testTheSetsOfCopiesAreWorkedOutAgainOnceABulkDeleteHasEnded() async throws {
        let (_, _, model, _) = try await settled(withACopy: true)
        try await scan(model)
        XCTAssertEqual(model.duplicates.count, 1, "the two copies were not found as one set")
        let ticked = try XCTUnwrap(model.duplicatePicks.first, "neither copy came up ticked")

        try await run(model, .delete, [ticked])
        XCTAssertEqual(model.job?.changed, [ticked])
        XCTAssertTrue(model.duplicates.isEmpty, "a set of one copy is still shown")
        XCTAssertTrue(model.duplicatePicks.isEmpty)
    }

    // MARK: - the scan for duplicates

    /// A scan asks the recorder what each candidate is about, once, with nothing on the strip, and keeps what
    /// it said in memory and in the cache, where it stays for the next scan; the job says how many it looked at.
    /// A candidate the recorder says it no longer holds (820) leaves the list. One whose text the recorder would
    /// not give is listed as passed over in the recorder's words and nothing is kept of it, in memory or in the
    /// cache -- two failures kept as empty texts would agree with each other and come up as copies -- and the job
    /// says that it was not compared.
    func testAScanReadsEachCandidatesTextOnceAndKeepsOnlyWhatTheRecorderSaid() async throws {
        let (bench, recorder, model, _) = try await settled(withACopy: true)
        let (first, second) = try copies(model)
        await recorder.holdTheNext(Ask.details)
        var before = await recorder.asked
        model.startDuplicateScan()
        try await until("the scan never asked what its first candidate is about") {
            await recorder.asked(Ask.details, since: before) == 1
        }
        XCTAssertNil(model.busy, "a scan put a line on the strip")
        XCTAssertEqual(model.job?.total, 2)
        await recorder.letGo()
        try await untilTheRunEnds(model, "the scan never ended")

        expectEqual(await recorder.asked(Ask.details, since: before), 2, "each candidate is asked about once")
        XCTAssertEqual(Set(model.summaries.keys), [first, second])
        XCTAssertFalse(model.summaries.values.contains(""), "the demo was meant to say what each is about")
        expectEqual(try await GuideStore(path: bench.guidePath).titleSummaries([first, second]), model.summaries,
                    "what the recorder said is not in the cache as it is in memory")
        XCTAssertEqual(model.job?.done, 2)
        XCTAssertEqual(model.job?.skipped, [])
        XCTAssertEqual(model.job?.outcome, "2 件の確認が完了しました")
        XCTAssertEqual(model.duplicates.count, 1, "the two copies were not found as one set")
        XCTAssertNil(model.busy)

        // On another phone: the second candidate's text refused, and then that candidate gone.
        let (other, refusing, another, _) = try await settled(withACopy: true)
        let cache = try GuideStore(path: other.guidePath)
        await refusing.answer(Ask.details, with: .fault(402), after: 1)
        before = await refusing.asked
        try await scan(another)
        expectEqual(await refusing.asked(Ask.details, since: before), 2)
        XCTAssertEqual(Array(another.summaries.keys), [first])
        expectEqual(try await cache.titleSummaries([first, second]), another.summaries,
                    "something is kept in the cache of a text the recorder would not give")
        XCTAssertEqual(another.job?.skipped, [.init(id: second, reason: Said.fault(402, Ask.details))])
        XCTAssertEqual(another.job?.outcome, "2 件の確認が完了しました（1 件は番組内容を取得できず、比べていません）")

        await refusing.answer(Ask.details, with: .fault(820))
        before = await refusing.asked
        try await scan(another)
        expectEqual(await refusing.asked(Ask.details, since: before), 1, "a text already read was asked for again")
        XCTAssertFalse(another.titles.contains { $0.id == second },
                       "a recording the recorder no longer holds is listed")
        XCTAssertTrue(another.titles.contains { $0.id == first })
        XCTAssertEqual(Array(another.summaries.keys), [first])
        expectEqual(try await cache.titleSummaries([first, second]), another.summaries)
        XCTAssertEqual(another.job?.skipped, [])
        XCTAssertEqual(another.job?.outcome, "2 件の確認が完了しました")
    }

    /// What the cache holds of a recording is not asked for: a scan asks the recorder only about the candidates
    /// whose text was never read, and one that has every text asks nothing. Such a scan needs no recorder: with
    /// the recorder known to be away it still comes to its end, says so, and leaves the line of what went wrong
    /// as it was -- it is made sure of only for what the cache does not hold.
    func testAScanAsksTheRecorderForNoTextTheCacheHolds() async throws {
        let (bench, recorder, model, _) = try await settled(withACopy: true)
        let (first, second) = try copies(model)
        try await GuideStore(path: bench.guidePath).setTitleSummary(second, "前に読んだ番組内容")
        var count = await recorder.heard.count
        try await scan(model)
        expectEqual(await recorder.heard(since: count), [Ask.details], "a text the cache holds was asked for")
        XCTAssertEqual(model.summaries[second], "前に読んだ番組内容")
        XCTAssertNotNil(model.summaries[first])

        count = await recorder.heard.count
        try await scan(model)
        expectEqual(await recorder.heard(since: count), [], "a scan with every text read asked the recorder")
        XCTAssertEqual(model.job?.outcome, "2 件の確認が完了しました")

        // The recorder known to be away.
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.gaveUp, "the recorder was meant to be known to be away")
        leaveALine(on: model)
        count = await recorder.heard.count
        try await scan(model)
        expectEqual(await recorder.heard(since: count), [], "a recorder known to be away was asked")
        XCTAssertEqual(model.job?.done, 2)
        XCTAssertEqual(model.job?.outcome, "2 件の確認が完了しました")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a scan that needed no recorder wrote on the line")
    }

    /// Silence at a candidate of a scan stops the scan there: no candidate after it is asked about, the app is
    /// left given up on the recorder, and nothing is kept for that candidate -- silence says nothing of what it
    /// is about. What was read before it stays, and the job says how far it got and that the recorder stopped
    /// answering. The recordings stay as read: a scan changes nothing on the recorder.
    ///
    /// The line of what went wrong is left as it was, today: a later change has the silence said there, as any
    /// read's is.
    func testSilenceAtAScansCandidateStopsItAndKeepsNothingForThatRecording() async throws {
        let (bench, recorder, model, _) = try await settled(withACopy: true)
        let (first, second) = try copies(model)
        let cache = try GuideStore(path: bench.guidePath)
        let lost = "調べたところで、レコーダーの応答がなくなったため中止しました"

        // At the first of the two, and then, once the recorder is back, at the second.
        for (silent, read) in [(1, [String]()), (2, [first])] {
            leaveALine(on: model)
            await recorder.answer(Ask.details, with: .silence, after: silent - 1)
            let before = await recorder.asked
            try await scan(model)

            expectEqual(await recorder.asked(Ask.details, since: before), silent,
                        "silence at candidate \(silent): asked again, or the scan went on")
            XCTAssertTrue(model.gaveUp, "silence at candidate \(silent) did not leave the app given up")
            XCTAssertEqual(model.summaries.keys.sorted(), read, "candidate \(silent)")
            expectEqual(try await cache.titleSummaries([first, second]).keys.sorted(), read, "candidate \(silent)")
            XCTAssertEqual(model.job?.outcome, "\(silent - 1) 件まで" + lost)
            XCTAssertTrue(model.titlesLoaded, "silence in a scan marked the recordings unread")
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "silence in a scan is said on the line, today not")
            await reconnect(model)
        }
    }

    /// 中止 stops a scan before its next candidate, and what it has read stays read. Tapped while a text is out,
    /// that text is kept and counted, the next candidate is not asked about, and the job says how far the scan got
    /// and that it was stopped. Nor is a candidate counted after 中止 whose text the cache already holds: with the
    /// second candidate's text there beforehand, a scan stopped at the first says one, not two. And a scan
    /// stopped while it waits for the app to come back asks about nothing once it is back.
    func testStoppingAScanKeepsWhatWasReadAndLooksAtNoMore() async throws {
        let (bench, recorder, model, _) = try await settled(withACopy: true)
        let (first, second) = try copies(model)
        await recorder.hold(only: Ask.details)
        var before = await recorder.asked
        model.startDuplicateScan()
        try await until("the scan never asked what its first candidate is about") {
            await recorder.asked(Ask.details, since: before) == 1
        }
        model.cancelBulk()
        await recorder.letGo()
        try await untilTheRunEnds(model, "the scan never ended")
        expectEqual(await recorder.asked(Ask.details, since: before), 1, "a candidate after 中止 was asked about")
        XCTAssertEqual(Array(model.summaries.keys), [first], "the text that was out as 中止 was tapped is not kept")
        expectEqual(try await GuideStore(path: bench.guidePath).titleSummaries([first, second]), model.summaries)
        XCTAssertEqual(model.job?.outcome, "1 件まで調べて中止しました")

        // Waiting for the app to come back, before the candidate still unread.
        model.wentToBackground()
        before = await recorder.asked
        model.startDuplicateScan()
        try await until("the scan never waited for the app to come back") { model.backInFront != nil }
        model.cancelBulk()
        await model.returnedToForeground()
        try await untilTheRunEnds(model, "the scan never ended")
        expectEqual(await recorder.asked(Ask.details, since: before), 0,
                    "a scan stopped while the app was away asked about a candidate once it was back")
        XCTAssertEqual(model.job?.outcome, "1 件まで調べて中止しました")

        // On another phone, whose cache holds the second candidate's text already.
        let (other, holding, another, _) = try await settled(withACopy: true)
        try await GuideStore(path: other.guidePath).setTitleSummary(second, "前に読んだ番組内容")
        await holding.hold(only: Ask.details)
        before = await holding.asked
        another.startDuplicateScan()
        try await until("the scan never asked what its first candidate is about") {
            await holding.asked(Ask.details, since: before) == 1
        }
        another.cancelBulk()
        await holding.letGo()
        try await untilTheRunEnds(another, "the scan never ended")
        XCTAssertEqual(another.job?.done, 1, "a candidate was counted after 中止, its text being in the cache")
        XCTAssertEqual(another.job?.outcome, "1 件まで調べて中止しました")
    }

    /// Another recorder heard by the check before an operation while a scan is in front, a text out: the scan is
    /// stopped, as 中止 stops one, since it asks by the numbers it began with and those are the last recorder's.
    /// No further text is asked of the newcomer; what the scan read and what it came to go with the recorder it
    /// was about, the texts in memory and the job on the screen.
    ///
    /// The text that was out is in memory before the check hears who answers: the check's ask is held as well,
    /// and the text let go alone and waited for.
    func testAnotherRecorderHeardWhileAScanIsInFrontEndsItAndKeepsNothingOfIt() async throws {
        let (bench, recorder, model, _) = try await settled(withACopy: true)
        await recorder.hold(only: Ask.details)
        let before = await recorder.asked
        model.startDuplicateScan()
        try await until("the scan never asked what its first candidate is about") {
            await recorder.asked(Ask.details, since: before) == 1
        }
        await recorder.holdTheNext(Ask.description)
        bench.network = "away"
        let check = Task { await lookAtTheNetwork(model) }
        try await until("the recorder was never made sure of") { isMakingSure(model) }
        await recorder.letGo(only: Ask.details)
        try await until("the text that was out was never kept") { !model.summaries.isEmpty }
        await recorder.become(2)
        await recorder.letGo()
        _ = await check.value
        try await until("the newcomer was never taken up", within: 20) {
            model.info?.udn == NamedRecorder.udn(2) && !isConnecting(model) && model.busy == nil && !model.jobRunning
        }

        expectEqual(await recorder.asked(Ask.details, since: before), 1,
                    "the scan went on, on the newcomer, by the last recorder's numbers")
        XCTAssertTrue(model.summaries.isEmpty, "a text read for the last recorder is kept over the newcomer")
        XCTAssertNil(model.job, "what the scan came to is shown over a recorder it was not about")
    }
}

/// Whether what a test set going has come back, for a test that does not wait for it to.
@MainActor
private final class Back {
    var came = false
}
