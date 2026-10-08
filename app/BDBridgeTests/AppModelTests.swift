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
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = SilentRecorder(holding: true)
        let model = bench.model(recorder: recorder)

        try await within(5, "start() waited for the connect") { await model.start() }
        try await until("the first connect never asked the recorder") { await recorder.asked > 0 }
        let results = try await within(5, "search() waited for the connect") { await model.search("サンプル") }
        XCTAssertFalse(results.hits.isEmpty, "the search found nothing in the cached guide")
        XCTAssertTrue(isConnecting(model), "the connect was over before the recorder had said anything")

        await recorder.letGo()
        try await untilTheConnectEnds(model)
        XCTAssertTrue(model.gaveUp)
    }

    /// The same launch with a recorder that answers, which is where the waiting on itself happened: the
    /// connect has to get as far as the reservations, and everything that waits on start() still return.
    func testStartReturnsAndTheFirstConnectFinishesWithARecorderThatAnswers() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: DemoRecorder())

        try await within(5, "start() did not return") { await model.start() }
        try await until("the first connect never finished") { model.connected && !isConnecting(model) }
        XCTAssertFalse(model.reservations.isEmpty, "the connect did not read the reservations")
        expectFalse(try await within(5, "search() did not return") { await model.search("サンプル") }.hits.isEmpty)
        try await within(5, "loadReservations() did not return") { await model.loadReservations() }
        XCTAssertNil(model.busy)
    }

    /// What the overnight run and the Shortcuts action go by: they have no model, and read from the defaults
    /// where the recorder is and the MAC to wake it with. A connect is what writes those down -- the address
    /// it was answered at, the MAC the recorder reported, and the address it reported it at, which is what a
    /// recorder the router has moved is recognised by. Left unwritten, nothing fails on any screen: the guide
    /// only grows stale, night after night.
    func testAConnectWritesDownWhereTheRecorderIsAndHowToWakeIt() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: DemoRecorder())
        // An address the model was given and that is not saved, as one from a launch argument is.
        bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)

        await model.start()
        try await untilConnected(model)

        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.recorderHost), Bench.host)
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.recorderMac), DemoData.mac)
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.recorderMacHost), Bench.host)
        XCTAssertEqual(model.mac, DemoData.mac)
    }

    /// Work overlaps -- a tab loading its list while another is still loading, 再接続 in the middle of both --
    /// and the recorder answers first come, first served. When each piece of work saved the line it found and
    /// put it back when it finished, the first to finish put back a line from before the second began, and the
    /// second then put back the first's, which stayed on screen for good: 予約一覧を取得中 under a spinner, and
    /// every button that waits for the app to be idle greyed out until the app was quit.
    func testBusyClearsOnceOverlappingWorkHasFinished() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        // The demo's own pace, for the moment in which two pieces of work overlap.
        let model = bench.model(recorder: DemoRecorder(delay: DemoData.answerDelay))
        await model.start()
        try await until("the first connect never finished") { model.connected && !isConnecting(model) }

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
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilGivenUp(model)
        XCTAssertTrue(model.offline)
        let askedBefore = await recorder.asked

        let program = try await aProgramme(model)
        let kept = await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none")

        XCTAssertTrue(kept, "the reservation was not kept: \(model.problem ?? "no reason given")")
        XCTAssertNotNil(model.pending(for: program), "the guide would not show the reservation as waiting")
        XCTAssertEqual(keptJustNow(model)?.request.eventID, program.eventID)
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
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilGivenUp(model)
        let asked = await recorder.asked
        XCTAssertGreaterThan(asked, 0)

        model.wentToBackground()
        await model.returnedToForeground()
        await lookAtTheNetwork(model)
        model.networkReported()
        // Long enough for the first look after the report, which reads the same decision as every look after it
        // (`LinkRules.onNetworkChange`); that a list asked for meanwhile asks nothing is SessionRuleTests'.
        try await Task.sleep(for: .milliseconds(100))
        expectEqual(await recorder.asked, asked, "the app asked again on the network it had given up on")
        XCTAssertTrue(model.gaveUp)

        bench.network = "away"
        model.wentToBackground()
        await model.returnedToForeground()
        let askedOnAnotherNetwork = await recorder.asked
        XCTAssertGreaterThan(askedOnAnotherNetwork, asked, "another network did not bring another try")
        XCTAssertTrue(model.gaveUp)
    }

    /// The phone leaves the Wi-Fi with the app open, the recorder falls silent and the app gives up, as it
    /// should. Then the Wi-Fi comes back -- and iOS says so before the phone has its address on it: the report
    /// of a new path arrives first, with IPv6 or with nothing yet, and the address a moment later, with no
    /// report of its own. Looked at only when the report came, the network had not changed, and the app stayed
    /// on 接続できません at home beside a recorder that was answering, until the reader pressed 再接続.
    func testComingBackToTheWiFiReconnectsWhenTheAddressArrivesAfterTheReport() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = RecorderAtHome()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await until("the first connect never finished") { model.connected && !isConnecting(model) }

        bench.network = ""
        await recorder.setReachable(false)
        model.networkReported()
        try await untilGivenUp(model, "the app never noticed the Wi-Fi had gone")

        await recorder.setReachable(true)
        model.networkReported()
        // The address arrives after the report, between its first look and its second.
        try await Task.sleep(for: .milliseconds(400))
        bench.network = "home"
        try await until("the app stayed given up at home", within: 15) { model.connected && !model.gaveUp }
    }

    /// The Wi-Fi goes and comes back while the app is in the middle of something, and the something is what
    /// meets the silence. By the time it gives up the phone is on the home Wi-Fi again, the one the app last
    /// connected on, so comparing where it is with where it last tried says nothing has changed -- but the
    /// silence was met on the way, not at home. The reports of the Wi-Fi going and coming, both of which
    /// arrived while the app was busy, are what say so.
    func testAWiFiThatWentAndCameBackDuringARequestIsTriedAgain() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = RecorderAtHome()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await until("the first connect never finished") { model.connected && !isConnecting(model) }

        bench.network = ""
        await recorder.setReachable(false, holding: true)
        let asked = await recorder.asked
        let loading = Task { await model.loadTitles(force: true) }
        try await until("the recordings were never asked for") { await recorder.asked > asked }
        model.networkReported()
        bench.network = "home"
        await recorder.setReachable(true)
        model.networkReported()
        await recorder.letGo()
        await loading.value
        XCTAssertTrue(model.gaveUp, "the request that met silence did not give up")

        try await until("the app stayed given up at home", within: 15) { model.connected && !model.gaveUp }
    }
}
