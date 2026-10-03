import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder the phone knows: it keeps everything the phone holds of it, wherever and however it answers.
extension WhichRecorderTests {
    /// The first answer after this was written down: a phone that has used one recorder all along, with its
    /// guide, a recording's text and a reservation waiting, and nothing saying whose they are. The recorder
    /// that answers is the one: it is written down as the owner and everything is as it was -- above all the
    /// queue, which goes to it as it always did. Nothing is guessed from the MAC kept for waking, whatever it
    /// is and wherever it was read: a model's UDN need not end in it, and the reader may have typed it.
    func testTheFirstAnswerAfterTheOwnerIsKeptTakesTheCacheAsItIs() async throws {
        // A MAC the recorder's UDN does not carry, read at this address; read at another, as after the
        // recorder's new address was typed in; with no note of where it was read, as the first versions left
        // it; and no MAC at all.
        let installations: [(mac: String?, readAt: String?)] = [
            ("f8:4e:17:00:00:09", Bench.host), ("f8:4e:17:00:00:09", Bench.otherHost),
            ("f8:4e:17:00:00:09", nil), (nil, nil),
        ]
        for installation in installations {
            let bench = try aBench()
            let recorder = NamedRecorder(1)
            try await bench.cacheAGuide()
            recording = "0x0000010000000001"
            try await store(bench).setTitleSummary(recording, "あらすじ")
            if let mac = installation.mac { bench.keep(mac: mac, readAt: installation.readAt) }
            leaveMarks(in: bench)
            let model = bench.model(recorders: [Bench.host: recorder])
            // Held until the reservation is in the queue, so that the first connect finds it waiting.
            await recorder.hold()
            await model.start()
            try await queueAReservation(bench, model)
            expectNil(try await kept(bench).owner)
            await recorder.letGo()
            try await untilConnected(model)

            let what = "MAC \(installation.mac ?? "none"), read at \(installation.readAt ?? "nowhere noted")"
            try await expect(bench, keeps: .all(of: 1), what)
            expectEqual(await recorder.asked("X_CreateRecordSchedule"), 1,
                        "the queue did not go to the recorder it was made for: \(what)")
            XCTAssertTrue(model.pending.isEmpty, what)
            expectEqual(await recorder.asked("EPG_TRDEPG_FILE.dat"), 0,
                        "a guide already in the cache was fetched again: \(what)")
            XCTAssertEqual(model.mac, installation.mac, what)
            XCTAssertNil(model.flushReport?.range(of: "別のレコーダー"), what)
            XCTAssertFalse(model.anotherTookOver, what)
        }
    }

    /// A later launch, and 再接続 after it: the recorder the phone knows answers, and nothing is asked of it
    /// that was not asked before. Its recordings are read once, by the screen that shows them.
    func testALaterLaunchAndAReconnectReadNothingAgain() async throws {
        let (bench, recorder, _) = try await atHome()
        let atFirst = await recorder.asked

        let later = bench.model(recorders: [Bench.host: recorder])
        await later.start()
        try await untilConnected(later, "the later launch never connected")
        await later.loadTitles()
        let before = await recorder.asked
        await later.connect()

        XCTAssertTrue(later.connected, "the connect failed: \(later.problem ?? "no reason given")")
        XCTAssertTrue(later.titlesLoaded)
        expectEqual(await recorder.asked("X_GetTitleList", since: before), 0,
                    "the recordings were read again from the recorder they were read from")
        expectEqual(await recorder.asked("EPG_TRDEPG_FILE.dat", since: atFirst), 0)
        try await expect(bench, keeps: .all(of: 1))
        XCTAssertNil(later.flushReport)
    }

    /// Silence, and the same recorder back: it is the one the lists were read from, however long it said
    /// nothing, and they stand.
    func testTheSameRecorderBackAfterSilenceKeepsItsLists() async throws {
        let (bench, recorder, model) = try await atHome()
        await recorder.goQuiet(for: 1)
        await model.loadTitles(force: true)
        XCTAssertTrue(model.gaveUp)
        let before = await recorder.asked

        await model.connect()

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertTrue(model.titlesLoaded)
        XCTAssertFalse(model.titles.isEmpty)
        expectEqual(await recorder.asked("X_GetTitleList", since: before), 0,
                    "the recordings were read again from the recorder they were read from")
        try await expect(bench, keeps: .all(of: 1))
    }

    /// The check before an operation, answered by the recorder the phone knows, goes on as it always did:
    /// at once when it is up, and after a waking when it was asleep -- attached once more, and not turned
    /// away from, nor connected to a second time.
    func testTheCheckAnsweredByTheSameRecorderGoesOn() async throws {
        let (bench, recorder, model) = try await atHome(wakeable: true)
        let attached = model.timesAttached
        let before = await recorder.asked

        expectTrue(await makeSure(model), model.problem ?? "no reason given")
        XCTAssertEqual(model.timesAttached, attached)

        await recorder.goQuiet(for: 1)
        expectTrue(await makeSure(model), model.problem ?? "no reason given")
        XCTAssertEqual(model.timesAttached, attached + 1)
        XCTAssertTrue(model.titlesLoaded)
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.mac, Self.firstsMAC)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.timesAttached, attached + 1, "a connect was set going after the check")
        expectEqual(await recorder.asked("X_GetTitleList", since: before), 0)
    }

    /// The recorder the phone knows, answering without saying which it is -- its description gives no UDN
    /// from here on. It cannot be told from any other, and is taken for the one known: its lists stand, the
    /// cache stays its own and what waits goes to it. Read the other way, it would be a stranger each time it
    /// answered.
    func testTheRecorderKnownIsStillTheOneWhenItStopsSayingWhichItIs() async throws {
        let (bench, recorder, model) = try await atHome(waiting: true)
        let before = await recorder.asked

        await recorder.stopSayingWhich()
        await model.connect()
        try await untilIdle(model)

        XCTAssertEqual(model.info?.udn, "", model.problem ?? "no reason given")
        XCTAssertTrue(model.titlesLoaded, "its lists were forgotten as a stranger's")
        expectEqual(await recorder.asked("X_GetTitleList", since: before), 0)
        try await expect(bench, keeps: .all(of: 1))
        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 1, "the queue did not go to the recorder")
        XCTAssertFalse(model.anotherTookOver)
    }

    /// One that never says which it is, from the first answer on: the queue goes to it, nothing is written
    /// down as its name, and a check that has to wake it goes on.
    func testARecorderThatNeverSaysWhichItIsIsWrittenDownAsNobody() async throws {
        let bench = try aBench()
        bench.keep(mac: Self.firstsMAC)
        let recorder = NamedRecorder.nameless()
        try await bench.cacheAGuide()
        let model = bench.model(recorders: [Bench.host: recorder])
        await recorder.hold()
        await model.start()
        try await queueAReservation(bench, model)
        await recorder.letGo()
        try await untilConnected(model)

        XCTAssertEqual(model.info?.udn, "")
        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 1, "the queue did not go to the recorder")
        let owner = try await kept(bench).owner
        XCTAssertNil(owner, "a recorder with no name of its own was written down as the cache's owner")

        await model.loadTitles()
        let attached = model.timesAttached
        await recorder.goQuiet(for: 1)
        expectTrue(await makeSure(model), model.problem ?? "no reason given")
        XCTAssertTrue(model.titlesLoaded, "its lists were forgotten as a stranger's")
        XCTAssertEqual(model.timesAttached, attached + 1)
    }

    /// The same recorder at another address, typed in. Its lists are read again, since an address that has
    /// changed is not gone by; everything on the phone is as it was, and the queue goes to it as before.
    func testTheSameRecorderAtAnotherAddressKeepsWhatThePhoneHoldsOfIt() async throws {
        let bench = try aBench()
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder, Bench.otherHost: recorder])
        try await queueAReservation(bench, model)
        let before = await recorder.asked

        await model.adopt(host: Bench.otherHost)
        try await untilIdle(model)

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertEqual(model.info?.host, Bench.otherHost)
        try await expect(bench, keeps: .all(of: 1))
        expectEqual(await recorder.asked("EPG_TRDEPG_FILE.dat", since: before), 0,
                    "a guide already fetched from this recorder was fetched again")
        expectEqual(await recorder.asked("X_CreateRecordSchedule"), 1,
                    "the queue did not go to the recorder it was made for")
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.flushReport?.range(of: "別のレコーダー"), "the strip says another recorder answered")
        XCTAssertFalse(model.anotherTookOver, "the strip says another recorder answered")
    }

    /// Something answers at the address chosen that is not a recorder. Nobody has said who is there, so what
    /// the phone keeps is not touched, and putting the address right brings the recorder back with
    /// everything as it was.
    func testAnAddressAnsweredBySomethingElseLeavesWhatThePhoneKeepsAlone() async throws {
        let bench = try aBench()
        let model = try await connected(bench, at: [Bench.host: NamedRecorder(1), Bench.otherHost: NotARecorder()])

        await model.adopt(host: Bench.otherHost)

        XCTAssertFalse(model.connected)
        try await expect(bench, keeps: .all(of: 1), "the cache is still the first recorder's")

        await model.adopt(host: Bench.host)
        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertFalse(model.reservations.isEmpty)
        try await expect(bench, keeps: .all(of: 1))
    }

    // MARK: - the demo

    /// The demo has a cache of its own, and the real recorder's is as it was when the demo is over: its
    /// owner, its texts, what the defaults keep about its disk. So is the MAC for waking it, which the demo
    /// puts its own in the place of while it lasts, and where that MAC was read.
    func testTheDemoLeavesTheRealRecordersCacheAsItWas() async throws {
        let (bench, recorder, model) = try await atHome(wakeable: true)
        let before = await recorder.asked

        // Out by ending it, and then out by choosing the real recorder from inside it.
        for leaving in ["ending", "choosing"] {
            await model.enterDemo()
            XCTAssertTrue(model.connected, "the demo did not start: \(model.problem ?? "no reason given")")
            let demos = try await GuideStore(path: Storage.guidePath(demo: true, in: bench.folder)).owner()
            XCTAssertNil(demos, "the demo's cache was written down as somebody's")
            XCTAssertEqual(model.mac, DemoData.mac, "the demo went on under the real recorder's MAC")
            if leaving == "ending" { await model.leaveDemo() } else { await model.adopt(host: Bench.host) }
            try await untilIdle(model)

            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(1), leaving)
            try await expect(bench, keeps: .all(of: 1), leaving)
            expectEqual(await recorder.asked("EPG_TRDEPG_FILE.dat", since: before), 0,
                        "the guide was fetched again after \(leaving)")
            XCTAssertEqual(model.mac, Self.firstsMAC, "the real recorder's MAC did not come back after \(leaving)")
            XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.recorderMac), Self.firstsMAC, leaving)
            XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.recorderMacHost), Bench.host, leaving)
        }
    }
}
