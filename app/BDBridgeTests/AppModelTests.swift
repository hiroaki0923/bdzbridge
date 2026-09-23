import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The model the screens share, made the way the app makes it at launch with a recorder saved, but with
/// surroundings of its own (see `Bench`): a recorder that is either the demo's, which answers with the XML a
/// BDZ-FBT4100 sends and remembers what is done to it, or one that says nothing. Nothing here reaches the
/// network the tests run on, and nothing waits for a real timeout.
///
/// What is tested is what went wrong once and was only ever seen on a phone: a launch that waited on itself,
/// a line on screen that never cleared, a reservation made away from home, and an app that kept knocking on a
/// recorder it had given up on.
@MainActor
final class AppModelTests: XCTestCase {
    /// The tests make models of their own, and the app they run inside must not be starting one of its own
    /// beside them, connected to whatever recorder this simulator last saved.
    func testTheAppLeavesItsOwnStartOutWhileHostingTheTests() {
        XCTAssertTrue(BDBridgeApp.hostingUnitTests)
    }

    /// Launching with a recorder saved once connected inside the task every screen waits on, and connecting
    /// reads the reservations, which waited on that task: with a recorder that answered, the app waited on
    /// itself for good. Away from home, where the recorder says nothing, a search waited out the half minute of
    /// the connect before it could answer from the cache.
    func testStartAndSearchDoNotWaitForARecorderThatSaysNothing() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let recorder = SilentRecorder(holding: true)
        let model = bench.model(recorder: recorder)

        try await within(5, "start() waited for the connect") { await model.start() }
        try await until("the first connect never asked the recorder") { await recorder.asked > 0 }
        let results = try await within(5, "search() waited for the connect") { await model.search("サンプル") }
        XCTAssertFalse(results.hits.isEmpty, "the search found nothing in the cached guide")
        XCTAssertTrue(model.connecting, "the connect was over before the recorder had said anything")

        await recorder.letGo()
        try await until("the connect never ended") { !model.connecting }
        XCTAssertTrue(model.gaveUp)
    }

    /// The same launch with a recorder that answers, which is where the waiting on itself happened: the
    /// connect has to get as far as the reservations, and everything that waits on start() still return.
    func testStartReturnsAndTheFirstConnectFinishesWithARecorderThatAnswers() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let model = bench.model(recorder: DemoRecorder())

        try await within(5, "start() did not return") { await model.start() }
        try await until("the first connect never finished") { model.connected && !model.connecting }
        XCTAssertFalse(model.reservations.isEmpty, "the connect did not read the reservations")
        let results = try await within(5, "search() did not return") { await model.search("サンプル") }
        XCTAssertFalse(results.hits.isEmpty)
        try await within(5, "loadReservations() did not return") { await model.loadReservations() }
        XCTAssertNil(model.busy)
    }

    /// Work overlaps -- a tab loading its list while another is still loading, 再接続 in the middle of both --
    /// and the recorder answers first come, first served. When each piece of work saved the line it found and
    /// put it back when it finished, the first to finish put back a line from before the second began, and the
    /// second then put back the first's, which stayed on screen for good: 予約一覧を取得中 under a spinner, and
    /// every button that waits for the app to be idle greyed out until the app was quit.
    func testBusyClearsOnceOverlappingWorkHasFinished() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let model = bench.model(recorder: DemoRecorder())
        await model.start()
        try await until("the first connect never finished") { model.connected && !model.connecting }

        // The reservations tab loading when the recordings tab is opened for the first time, in that order: the
        // recordings begin while the reservations are still on their way, and the reservations, asked for
        // first, are answered first.
        let reservationsTab = Task { await model.loadReservations() }
        try await until("the reservations never began loading") { model.busy == "予約一覧を取得中" }
        let recordingsTab = Task { await model.loadTitles(force: true) }
        try await until("the recordings never began loading") { model.busy == "録画一覧を取得中" }
        await reservationsTab.value
        await recordingsTab.value
        XCTAssertNil(model.busy, "the line of the work that finished first stayed on screen")

        // Anything else at once, 再接続 among it, in whatever order it comes.
        async let reconnect: Void = model.connect()
        async let reservations: Void = model.loadReservations()
        async let recordings: Void = model.loadTitles(force: true)
        async let rules: Void = model.loadRecorderRules()
        async let reservationsAgain: Void = model.loadReservations()
        _ = await (reconnect, reservations, recordings, rules, reservationsAgain)

        XCTAssertNil(model.busy, "a line stayed on screen after everything had finished")
        XCTAssertFalse(model.working)
        XCTAssertTrue(model.canChangeRecorder)
        XCTAssertTrue(model.titlesLoaded)
        XCTAssertTrue(model.recorderRulesLoaded)
    }

    /// Away from home the recorder is not there to write to, and the programme is still worth keeping: the
    /// reservation goes to the queue, at once rather than after a timeout spent finding out again, and on disk,
    /// where the next connect and the overnight run send it from.
    func testAReservationMadeWhileOfflineIsQueued() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await until("the first connect never gave up") { model.gaveUp && !model.connecting }
        XCTAssertTrue(model.offline)
        let askedBefore = await recorder.asked

        let later = Date().addingTimeInterval(3600)
        let found = await model.search("サンプル").hits.first { $0.program.start > later }
        let program = try XCTUnwrap(found?.program, "the cached guide had nothing an hour or more ahead")
        let kept = await model.reserve(program, quality: "DR", repeating: "none")

        XCTAssertTrue(kept, "the reservation was not kept: \(model.problem ?? "no reason given")")
        XCTAssertNotNil(model.pending(for: program), "the guide would not show the reservation as waiting")
        XCTAssertEqual(model.queued?.request.eventID, program.eventID)
        let askedAfter = await recorder.asked
        XCTAssertEqual(askedAfter, askedBefore, "the recorder was asked although the app knew it was not there")
        let onDisk = try await GuideStore(path: bench.guidePath).pendingReservations()
        XCTAssertEqual(onDisk.map(\.request.eventID), [program.eventID])
    }

    /// Once the recorder has been given every chance on this network and said nothing, asking again costs
    /// another half minute of waking something that is not there, and the answer will be the same. So nothing
    /// asks by itself -- not coming back to the app, not the network watcher, not the screens loading their
    /// lists -- until the network changes or the reader asks. A new network does ask.
    func testAfterGivingUpTheAppAsksAgainOnlyOnAnotherNetwork() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await until("the first connect never gave up") { model.gaveUp && !model.connecting }
        let asked = await recorder.asked
        XCTAssertGreaterThan(asked, 0)

        model.wentToBackground()
        await model.returnedToForeground()
        await model.networkChangedWhileOpen()
        await model.loadReservations()
        await model.loadTitles()
        await model.loadRecorderRules()
        let askedOnTheSameNetwork = await recorder.asked
        XCTAssertEqual(askedOnTheSameNetwork, asked, "the app asked again on the network it had given up on")
        XCTAssertTrue(model.gaveUp)

        bench.network = "away"
        model.wentToBackground()
        await model.returnedToForeground()
        let askedOnAnotherNetwork = await recorder.asked
        XCTAssertGreaterThan(askedOnAnotherNetwork, asked, "another network did not bring another try")
        XCTAssertTrue(model.gaveUp)
    }
}
