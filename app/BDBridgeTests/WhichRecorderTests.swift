import Foundation
import RecorderKit
import SQLite3
import XCTest
@testable import BDBridge

/// Which recorder the app is talking to, and what the phone keeps of one when another answers.
///
/// The address is only where to knock: a recorder is known by what it says it is (its UDN). The same one
/// keeps everything the phone holds of it wherever it answers. Another one -- chosen by the reader, or found
/// at the address the first had -- gets nothing that was the first's: not its lists, which name recordings
/// by numbers each recorder gives out for itself, and not what the phone kept of it. What the reader chose
/// and what is on screen meanwhile is `SessionRuleTests`' ("another recorder"); this is what happens once
/// somebody has answered.
///
/// Two recorders here hold the same recordings under the same numbers, which is the case that matters: a row
/// or a text left from the first would stand for another recording on the second.
@MainActor
final class WhichRecorderTests: XCTestCase {
    /// The recording whose text `connected` puts in the cache.
    private var recording = ""

    /// When the overnight run is on record as having last fetched, in `connected`.
    private static let lastNight = "2026-09-30T02:00:00+09:00"

    /// A model connected to the recorder at `Bench.host`, with its recordings and keyword conditions read,
    /// one recording's text in the cache, and on record a low-space warning and an overnight fetch.
    private func connected(_ bench: Bench, at places: [String: any HTTPTransport]) async throws -> AppModel {
        try await bench.cacheAGuide()
        bench.defaults.set(true, forKey: DefaultsKey.warnedLowSpace)
        bench.defaults.set(Self.lastNight, forKey: DefaultsKey.lastBackgroundRefresh)
        let model = bench.model(recorders: places)
        await model.start()
        try await until("the first connect never finished", within: 20) {
            model.connected && !model.connecting && model.busy == nil
        }
        await model.loadTitles()
        await model.loadRecorderRules()
        XCTAssertFalse(model.titles.isEmpty)
        XCTAssertFalse(model.reservations.isEmpty)
        XCTAssertFalse(model.recorderRules.isEmpty)
        recording = try XCTUnwrap(model.titles.first).id
        try await store(bench).setTitleSummary(recording, "あらすじ")
        return model
    }

    private func store(_ bench: Bench) throws -> GuideStore {
        try GuideStore(path: bench.guidePath)
    }

    private func textsKept(_ bench: Bench) async throws -> Int {
        try await store(bench).titleSummaries([recording]).count
    }

    /// Whether what the defaults keep about one recorder's disk and guide is still as `connected` left it.
    private func marksKept(_ bench: Bench) -> [Bool] {
        [bench.defaults.bool(forKey: DefaultsKey.warnedLowSpace),
         bench.defaults.string(forKey: DefaultsKey.lastBackgroundRefresh) == Self.lastNight]
    }

    /// A programme from the cached guide that starts an hour or more from now: the first, or the one after
    /// as many as `skipping`.
    private func aProgramme(_ model: AppModel, skipping: Int = 0) async throws -> GuideProgramRow {
        let later = Date().addingTimeInterval(3600)
        let found = await model.search("サンプル").hits.filter { $0.program.start > later }.dropFirst(skipping).first
        return try XCTUnwrap(found?.program, "the cached guide had nothing more an hour or more ahead")
    }

    /// A reservation for it, as the app queues one away from home.
    private func aReservationToQueue(_ model: AppModel) async throws -> PendingReservation {
        let program = try await aProgramme(model)
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        return PendingReservation(request: request, serviceName: program.serviceName)
    }

    // MARK: - the recorder the phone knows

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
            let bench = try Bench()
            defer { bench.throwAway() }
            let recorder = NamedRecorder(1)
            try await bench.cacheAGuide()
            let cache = try store(bench)
            try await cache.setTitleSummary("0x0000010000000001", "あらすじ")
            bench.defaults.set(installation.mac, forKey: DefaultsKey.recorderMac)
            bench.defaults.set(installation.readAt, forKey: DefaultsKey.recorderMacHost)
            bench.defaults.set(true, forKey: DefaultsKey.warnedLowSpace)
            bench.defaults.set(Self.lastNight, forKey: DefaultsKey.lastBackgroundRefresh)
            let model = bench.model(recorders: [Bench.host: recorder])
            // Held until the reservation is in the queue, so that the first connect finds it waiting.
            await recorder.hold()
            await model.start()
            try await cache.queue(try await aReservationToQueue(model))
            let unowned = try await cache.owner()
            XCTAssertNil(unowned)
            await recorder.letGo()

            try await until("the first connect never finished", within: 20) {
                model.connected && !model.connecting && model.busy == nil
            }

            let what = "MAC \(installation.mac ?? "none"), read at \(installation.readAt ?? "nowhere noted")"
            let owner = try await cache.owner()
            XCTAssertEqual(owner, NamedRecorder.udn(1), what)
            let texts = try await cache.titleSummaries(["0x0000010000000001"]).count
            XCTAssertEqual(texts, 1, "the texts take one request a recording to gather again: \(what)")
            let made = await recorder.asked("X_CreateRecordSchedule")
            XCTAssertEqual(made, 1, "the queue did not go to the recorder it was made for: \(what)")
            XCTAssertTrue(model.pending.isEmpty, what)
            let guideAsked = await recorder.asked("EPG_TRDEPG_FILE.dat")
            XCTAssertEqual(guideAsked, 0, "a guide already in the cache was fetched again: \(what)")
            XCTAssertEqual(marksKept(bench), [true, true], what)
            XCTAssertEqual(model.mac, installation.mac, what)
            XCTAssertNil(model.flushReport?.range(of: "別のレコーダー"), what)
            XCTAssertFalse(model.anotherTookOver, what)
        }
    }

    /// A later launch, and 再接続 after it: the recorder the phone knows answers, and nothing is asked of it
    /// that was not asked before. Its recordings are read once, by the screen that shows them.
    func testALaterLaunchAndAReconnectReadNothingAgain() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        _ = try await connected(bench, at: [Bench.host: recorder])
        let guideAsked = await recorder.asked("EPG_TRDEPG_FILE.dat")

        let later = bench.model(recorders: [Bench.host: recorder])
        await later.start()
        try await until("the later launch never connected", within: 20) {
            later.connected && !later.connecting && later.busy == nil
        }
        await later.loadTitles()
        let read = await recorder.asked("X_GetTitleList")
        await later.connect()

        XCTAssertTrue(later.connected, "the connect failed: \(later.problem ?? "no reason given")")
        XCTAssertTrue(later.titlesLoaded)
        let readAfter = await recorder.asked("X_GetTitleList")
        XCTAssertEqual(readAfter, read, "the recordings were read again from the recorder they were read from")
        let guideAskedAfter = await recorder.asked("EPG_TRDEPG_FILE.dat")
        XCTAssertEqual(guideAskedAfter, guideAsked)
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 1)
        let owner = try await store(bench).owner()
        XCTAssertEqual(owner, NamedRecorder.udn(1))
        XCTAssertNil(later.flushReport)
    }

    /// Silence, and the same recorder back: it is the one the lists were read from, however long it said
    /// nothing, and they stand.
    func testTheSameRecorderBackAfterSilenceKeepsItsLists() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        await recorder.goQuiet(for: 1)
        await model.loadTitles(force: true)
        XCTAssertTrue(model.gaveUp)
        let read = await recorder.asked("X_GetTitleList")

        await model.connect()

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertTrue(model.titlesLoaded)
        XCTAssertFalse(model.titles.isEmpty)
        let readAfter = await recorder.asked("X_GetTitleList")
        XCTAssertEqual(readAfter, read, "the recordings were read again from the recorder they were read from")
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 1)
    }

    /// The check before an operation, answered by the recorder the phone knows, goes on as it always did:
    /// at once when it is up, and after a waking when it was asleep -- attached once more, and not turned
    /// away from, nor connected to a second time.
    func testTheCheckAnsweredByTheSameRecorderGoesOn() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        bench.defaults.set("f8:4e:17:00:00:01", forKey: DefaultsKey.recorderMac)
        bench.defaults.set(Bench.host, forKey: DefaultsKey.recorderMacHost)
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        let attached = model.timesAttached
        let read = await recorder.asked("X_GetTitleList")

        let up = await model.wakeIfDozing(evenIfRecent: true)
        XCTAssertTrue(up, model.problem ?? "no reason given")
        XCTAssertEqual(model.timesAttached, attached)

        await recorder.goQuiet(for: 1)
        let woken = await model.wakeIfDozing(evenIfRecent: true)
        XCTAssertTrue(woken, model.problem ?? "no reason given")
        XCTAssertEqual(model.timesAttached, attached + 1)
        XCTAssertTrue(model.titlesLoaded)
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.mac, "f8:4e:17:00:00:01")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.timesAttached, attached + 1, "a connect was set going after the check")
        let readAfter = await recorder.asked("X_GetTitleList")
        XCTAssertEqual(readAfter, read)
    }

    /// The recorder the phone knows, answering without saying which it is -- its description gives no UDN
    /// from here on. It cannot be told from any other, and is taken for the one known: its lists stand, the
    /// cache stays its own and what waits goes to it. Read the other way, it would be a stranger each time it
    /// answered.
    func testTheRecorderKnownIsStillTheOneWhenItStopsSayingWhichItIs() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        try await store(bench).queue(try await aReservationToQueue(model))
        let read = await recorder.asked("X_GetTitleList")

        await recorder.stopSayingWhich()
        await model.connect()
        try await until("the connect never finished") { !model.connecting && model.busy == nil }

        XCTAssertEqual(model.info?.udn, "", model.problem ?? "no reason given")
        XCTAssertTrue(model.titlesLoaded, "its lists were forgotten as a stranger's")
        let readAfter = await recorder.asked("X_GetTitleList")
        XCTAssertEqual(readAfter, read)
        let owner = try await store(bench).owner()
        XCTAssertEqual(owner, NamedRecorder.udn(1))
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 1)
        let made = await recorder.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 1, "the queue did not go to the recorder")
        XCTAssertFalse(model.anotherTookOver)
    }

    /// One that never says which it is, from the first answer on: the queue goes to it, nothing is written
    /// down as its name, and a check that has to wake it goes on.
    func testARecorderThatNeverSaysWhichItIsIsWrittenDownAsNobody() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        bench.defaults.set("f8:4e:17:00:00:01", forKey: DefaultsKey.recorderMac)
        bench.defaults.set(Bench.host, forKey: DefaultsKey.recorderMacHost)
        let recorder = NamedRecorder.nameless()
        try await bench.cacheAGuide()
        let cache = try store(bench)
        let model = bench.model(recorders: [Bench.host: recorder])
        await recorder.hold()
        await model.start()
        try await cache.queue(try await aReservationToQueue(model))
        await recorder.letGo()
        try await until("the first connect never finished", within: 20) {
            model.connected && !model.connecting && model.busy == nil
        }

        XCTAssertEqual(model.info?.udn, "")
        let made = await recorder.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 1, "the queue did not go to the recorder")
        let owner = try await cache.owner()
        XCTAssertNil(owner, "a recorder with no name of its own was written down as the cache's owner")

        await model.loadTitles()
        let attached = model.timesAttached
        await recorder.goQuiet(for: 1)
        let woken = await model.wakeIfDozing(evenIfRecent: true)
        XCTAssertTrue(woken, model.problem ?? "no reason given")
        XCTAssertTrue(model.titlesLoaded, "its lists were forgotten as a stranger's")
        XCTAssertEqual(model.timesAttached, attached + 1)
    }

    /// The same recorder at another address, typed in. Its lists are read again, since an address that has
    /// changed is not gone by; everything on the phone is as it was, and the queue goes to it as before.
    func testTheSameRecorderAtAnotherAddressKeepsWhatThePhoneHoldsOfIt() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder, Bench.otherHost: recorder])
        try await store(bench).queue(try await aReservationToQueue(model))
        let guideAsked = await recorder.asked("EPG_TRDEPG_FILE.dat")

        await model.adopt(host: Bench.otherHost)
        try await until("the connect never finished") { !model.connecting && model.busy == nil }

        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertEqual(model.info?.host, Bench.otherHost)
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 1)
        XCTAssertEqual(marksKept(bench), [true, true])
        let guideAskedAfter = await recorder.asked("EPG_TRDEPG_FILE.dat")
        XCTAssertEqual(guideAskedAfter, guideAsked, "a guide already fetched from this recorder was fetched again")
        let made = await recorder.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 1, "the queue did not go to the recorder it was made for")
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.flushReport?.range(of: "別のレコーダー"), "the strip says another recorder answered")
        XCTAssertFalse(model.anotherTookOver, "the strip says another recorder answered")
    }

    /// Something answers at the address chosen that is not a recorder. Nobody has said who is there, so what
    /// the phone keeps is not touched, and putting the address right brings the recorder back with
    /// everything as it was.
    func testAnAddressAnsweredBySomethingElseLeavesWhatThePhoneKeepsAlone() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let model = try await connected(bench, at: [Bench.host: NamedRecorder(1), Bench.otherHost: NotARecorder()])

        await model.adopt(host: Bench.otherHost)

        XCTAssertFalse(model.connected)
        let owner = try await store(bench).owner()
        XCTAssertEqual(owner, NamedRecorder.udn(1), "the cache is still the first recorder's")
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 1)
        XCTAssertEqual(marksKept(bench), [true, true])

        await model.adopt(host: Bench.host)
        XCTAssertTrue(model.connected, "the connect failed: \(model.problem ?? "no reason given")")
        XCTAssertFalse(model.reservations.isEmpty)
        let still = try await textsKept(bench)
        XCTAssertEqual(still, 1)
    }

    // MARK: - another recorder

    /// Another recorder answering takes the app over whole. Its own lists are read; the other's programme
    /// texts go, and so do the marks that said the guide need not be fetched, and that a low-space warning
    /// had been given; a reservation that was waiting is held with a reason, not sent to a recorder it was
    /// not made for, until the reader asks.
    func testAnotherRecorderGetsNothingThatWasTheFirsts() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let first = NamedRecorder(1), second = NamedRecorder(2)
        let model = try await connected(bench, at: [Bench.host: first, Bench.otherHost: second])
        try await store(bench).queue(try await aReservationToQueue(model))

        await model.adopt(host: Bench.otherHost)
        try await until("the connect never finished") { !model.connecting && model.busy == nil }

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        XCTAssertFalse(model.reservations.isEmpty, "the new recorder's reservations were not read")
        let owner = try await store(bench).owner()
        XCTAssertEqual(owner, NamedRecorder.udn(2))
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 0, "the first recorder's text would confirm a duplicate on the second")
        let asked = await second.asked("EPG_TRDEPG_FILE.dat")
        XCTAssertGreaterThan(asked, 0, "the marks left by the first kept the second from being asked for its guide")
        XCTAssertEqual(marksKept(bench), [false, false],
                       "the warning given of the first one's disk, and when the first one's guide was last fetched")

        let made = await second.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0, "what was waiting for the first recorder was made on the second")
        XCTAssertEqual(model.pending.map(\.problem), [AppModel.heldForAnotherRecorder],
                       "the reservation waits with nothing to say why")
        XCTAssertNotNil(model.flushReport, "nothing on screen says the reservation was held back")
        XCTAssertFalse(model.anotherTookOver, "the strip tells the reader of a recorder they chose themselves")

        // The reader asks: it goes to the recorder in play now.
        await model.resend(try XCTUnwrap(model.pending.first))
        let sent = await second.asked("X_CreateRecordSchedule")
        XCTAssertEqual(sent, 1)
        XCTAssertTrue(model.pending.isEmpty)
    }

    /// Nobody chose anything: the address the recorder had is answered by another, as after the router has
    /// handed it on. The app finds out at the next connect, by what answers, and reads the lists again from
    /// the one that did -- with the app connected throughout, so that no screen is waiting to ask.
    func testAnotherRecorderAtTheSameAddressIsNotTakenForTheFirst() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        let read = await recorder.asked("X_GetTitleList")

        await recorder.become(2)
        await model.connect()
        try await until("the connect never finished") { !model.connecting && model.busy == nil }

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2))
        XCTAssertTrue(model.titlesLoaded, "the recordings tab was left saying there are none")
        let readAfter = await recorder.asked("X_GetTitleList")
        XCTAssertEqual(readAfter, read + 1, "the first recorder's recordings stood for the second's")
        XCTAssertTrue(model.recorderRulesLoaded)
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 0)
        XCTAssertTrue(model.anotherTookOver, "nothing says why the lists under the reader are other ones")
    }

    /// The check before an operation hears who is there as well. Another recorder answering it gets nothing
    /// the reader asked of the first: the lists go, the check says no, and the newcomer is taken up by a
    /// connect of its own.
    func testAnotherRecorderAnsweringTheCheckIsSentNothing() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])

        await recorder.become(2)
        let answering = await model.wakeIfDozing(evenIfRecent: true)

        XCTAssertFalse(answering, "what the reader asked of the first recorder would have gone to the second")
        XCTAssertTrue(model.titles.isEmpty)
        XCTAssertEqual(model.problem, AppModel.anotherAnswered, "nothing says why what was asked for was not sent")
        try await until("the newcomer was never taken up") {
            model.info?.udn == NamedRecorder.udn(2) && !model.connecting && model.busy == nil
        }
        // The connect has taken the failure line away, and a sheet the reader asked from was closed with
        // its alert: the strip is what still says it.
        XCTAssertNil(model.problem)
        XCTAssertTrue(model.anotherTookOver, "nothing is left saying why what was asked for was not done")
    }

    /// The same when the check has to wake what is there first. The waking's attach turns the app to whoever
    /// answers, which reads neither its reservations nor its guide; the check still says no, and the connect
    /// that follows reads them. The MAC that woke it was the first recorder's, and is not kept for the second.
    func testAnotherRecorderAnsweringAfterAWakingIsSentNothingEither() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        bench.defaults.set("f8:4e:17:00:00:01", forKey: DefaultsKey.recorderMac)
        bench.defaults.set(Bench.host, forKey: DefaultsKey.recorderMacHost)
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        XCTAssertTrue(model.canWake)
        try await store(bench).queue(try await aReservationToQueue(model))

        // Silent to the check's probe, and another recorder by the time the waking asks again.
        await recorder.become(2)
        await recorder.goQuiet(for: 1)
        let answering = await model.wakeIfDozing(evenIfRecent: true)

        XCTAssertFalse(answering, "what the reader asked of the first recorder would have gone to the second")
        XCTAssertTrue(model.titles.isEmpty)
        XCTAssertEqual(model.problem, AppModel.anotherAnswered, "nothing says why what was asked for was not sent")
        try await until("the newcomer was never taken up") {
            model.info?.udn == NamedRecorder.udn(2) && !model.connecting && model.busy == nil
        }
        XCTAssertTrue(model.anotherTookOver, "nothing is left saying why what was asked for was not done")
        XCTAssertFalse(model.reservations.isEmpty, "the newcomer's reservations were never read")
        // Not the first one's, here or where the overnight run reads it. (None at all, as it happens: this
        // newcomer keeps its own to itself.)
        XCTAssertNotEqual(model.mac, "f8:4e:17:00:00:01", "the packet would go on waking the first recorder")
        XCTAssertNotEqual(bench.defaults.string(forKey: DefaultsKey.recorderMac), "f8:4e:17:00:00:01")
        XCTAssertNil(bench.defaults.string(forKey: DefaultsKey.recorderMacHost))
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 0)
        // Held by the waking's attach, and said by the connect after it: the line is read from the rows.
        let made = await recorder.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0, "what was waiting for the first recorder was made on the second")
        XCTAssertEqual(model.pending.map(\.problem), [AppModel.heldForAnotherRecorder])
        XCTAssertTrue(model.flushReport?.contains("送らずに残しています") ?? false,
                      "nothing on the strip says the reservation was held back: \(model.flushReport ?? "nothing")")
    }

    /// Something asked of a recording while the check is out, which then hears another recorder -- answering
    /// its probe, or answering after a waking. The recording's number is the first recorder's, and the
    /// second, which numbers its own from the same start, has one under it: nothing is sent, and the reader is
    /// told why.
    func testADeleteAskedOfWhatTurnsOutToBeAnotherRecorderIsNotSent() async throws {
        for exit in ["on the probe", "after a waking"] {
            let bench = try Bench()
            defer { bench.throwAway() }
            bench.defaults.set("f8:4e:17:00:00:01", forKey: DefaultsKey.recorderMac)
            bench.defaults.set(Bench.host, forKey: DefaultsKey.recorderMacHost)
            let recorder = NamedRecorder(1)
            let model = try await connected(bench, at: [Bench.host: recorder])
            let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })

            // The network changes, the recorder is asked whether it is still there, and the ask is held.
            bench.network = "away"
            await recorder.hold()
            let asked = await recorder.asked("description.xml")
            let check = Task { await model.networkChangedWhileOpen() }
            try await until("the recorder was never made sure of") { await recorder.asked("description.xml") > asked }
            let deleting = Task { await model.delete(title) }
            try await until("the delete was never begun") { model.busy != nil }
            await recorder.become(2)
            if exit == "after a waking" { await recorder.goQuiet(for: 1) }
            await recorder.letGo()
            _ = await check.value
            let deleted = await deleting.value

            XCTAssertFalse(deleted, exit)
            XCTAssertEqual(model.problem, AppModel.anotherAnswered, "nothing says why it was not deleted, \(exit)")
            try await until("the newcomer was never taken up, \(exit)") {
                model.info?.udn == NamedRecorder.udn(2) && !model.connecting && model.busy == nil
            }
            let sent = await recorder.asked("X_DeleteTitle")
            XCTAssertEqual(sent, 0, "the second recorder was asked to delete its recording of that number, \(exit)")
        }
    }

    /// A reservation asked for while the check is out, which then hears another recorder -- answering its
    /// probe, or answering after a waking: it is not sent, and not queued either. Queued after the probe, it
    /// was held as one made for the recorder before the moment the newcomer was taken up, under a sheet that
    /// had just said it would go at the next connect. Queued after the waking, which had held the queue
    /// already, it was the one row not held, and the connect that followed sent it to the newcomer.
    func testAReservationAskedOfWhatTurnsOutToBeAnotherRecorderIsNeitherSentNorQueued() async throws {
        for exit in ["on the probe", "after a waking"] {
            let bench = try Bench()
            defer { bench.throwAway() }
            bench.defaults.set("f8:4e:17:00:00:01", forKey: DefaultsKey.recorderMac)
            bench.defaults.set(Bench.host, forKey: DefaultsKey.recorderMacHost)
            let recorder = NamedRecorder(1)
            let model = try await connected(bench, at: [Bench.host: recorder])
            let program = try await aProgramme(model)

            // The network changes, the recorder is asked whether it is still there, and the ask is held.
            bench.network = "away"
            await recorder.hold()
            let asked = await recorder.asked("description.xml")
            let check = Task { await model.networkChangedWhileOpen() }
            try await until("the recorder was never made sure of") { await recorder.asked("description.xml") > asked }
            let reserving = Task { await model.reserve(program, quality: "DR", repeating: "none") }
            try await until("the reservation was never begun") { model.busy != nil }
            await recorder.become(2)
            // Let go, the held ask is answered by the newcomer, or meets silence and the waking finds it.
            if exit == "after a waking" { await recorder.goQuiet(for: 1) }
            await recorder.letGo()
            _ = await check.value
            let reserved = await reserving.value

            XCTAssertFalse(reserved, "the sheet would close as though the programme were reserved, \(exit)")
            try await until("the newcomer was never taken up, \(exit)") {
                model.info?.udn == NamedRecorder.udn(2) && !model.connecting && model.busy == nil
            }
            XCTAssertNil(model.pending(for: program), "queued for a recorder that had turned out another, \(exit)")
            let onDisk = try await store(bench).pendingReservations()
            XCTAssertTrue(onDisk.isEmpty, exit)
            let made = await recorder.asked("X_CreateRecordSchedule")
            XCTAssertEqual(made, 0, "the reservation went to the newcomer, \(exit)")
        }
    }

    /// Another recorder heard by the check while a bulk job is under way -- parked, here, with the app in the
    /// background, which is when an address has the time to change hands. The job is stopped and nothing of
    /// it is sent; the connect that takes the newcomer up waits for it to end, since a connect does not start
    /// beside a job, and set going at once it left the app connected to nothing under a line saying the lists
    /// would be read again. What the job came to goes with the recorder it was about.
    func testAnotherRecorderHeardWhileAJobIsUnderWayIsTakenUpOnceItHasEnded() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        let id = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected }).id

        model.wentToBackground()
        model.startBulk(.delete, ids: [id])
        try await until("the job never waited for the app to come back") { model.backInFront != nil }
        await recorder.become(2)
        bench.network = "another"
        await model.networkChangedWhileOpen()
        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.titles.isEmpty)
        // Stopped by the check, as 中止 stops one: a scan under way in front goes by this alone, since it
        // asks by the numbers it began with and not from the list that has just gone.
        XCTAssertEqual(model.job?.cancelled, true)

        await model.returnedToForeground()
        try await until("the newcomer was never taken up", within: 20) {
            model.info?.udn == NamedRecorder.udn(2) && !model.connecting && !model.jobRunning
        }

        let deleted = await recorder.asked("X_DeleteTitle")
        XCTAssertEqual(deleted, 0, "the job went on, on the newcomer, by the last recorder's numbers")
        XCTAssertNil(model.job, "what the job came to is shown over a recorder it was not about")
        XCTAssertFalse(model.titlesLoaded)
        await model.loadTitles()
        XCTAssertFalse(model.titles.isEmpty)
    }

    /// A job under way in front, the last request of one step out, when the network changes and the recorder
    /// is asked whether it is still there: the ask waits its turn behind that request, whose answer comes
    /// back first. The job hears the check out before its next step. Going straight on, that step reached
    /// the recorder ahead of the check's verdict -- another recorder, here, with a recording of its own under
    /// the same number.
    func testAJobInFrontHearsTheCheckOutBeforeItsNextStep() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        let ids = model.titles.filter { !$0.recording && !$0.protected }.prefix(2).map(\.id)
        XCTAssertEqual(ids.count, 2, "the recorder was meant to have two recordings that can be deleted")

        await recorder.hold(only: "X_DeleteTitle")
        model.startBulk(.delete, ids: Array(ids))
        try await until("the job never came to its first delete") { await recorder.asked("X_DeleteTitle") == 1 }
        bench.network = "away"
        let check = Task { await model.networkChangedWhileOpen() }
        try await until("the recorder was never made sure of") { model.wakeCheck != nil }
        await recorder.become(2)
        await recorder.letGo()
        _ = await check.value
        try await until("the job never ended") { !model.jobRunning }

        // The step that was out when the ask was made is not called back; the next one is not sent.
        let deleted = await recorder.asked("X_DeleteTitle")
        XCTAssertEqual(deleted, 1, "the job went on to its next step on the recorder that had just answered")
        try await until("the newcomer was never taken up") {
            model.info?.udn == NamedRecorder.udn(2) && !model.connecting && model.busy == nil
        }
        XCTAssertNil(model.job)
    }

    /// What was held back is said even when the attach that held it got no further: the newcomer described
    /// itself, the cache was made over and the queue held, and then it said nothing more. The line is read
    /// from the rows by whichever attach does get through.
    func testWhatWasHeldIsSaidByALaterAttachWhenTheOneThatHeldItFailed() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        try await store(bench).queue(try await aReservationToQueue(model))

        await recorder.become(2)
        await recorder.goQuiet(for: 1, after: 1)
        await model.connect()
        XCTAssertTrue(model.gaveUp, "the attach was meant to meet silence after the description")
        let held = try await store(bench).pendingReservations()
        XCTAssertEqual(held.map(\.problem), [AppModel.heldForAnotherRecorder])
        XCTAssertEqual(model.pending.map(\.problem), [AppModel.heldForAnotherRecorder],
                       "the row on screen still says it goes at the next connect")

        await model.connect()

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        XCTAssertEqual(model.pending.map(\.problem), [AppModel.heldForAnotherRecorder])
        XCTAssertTrue(model.flushReport?.contains("送らずに残しています") ?? false,
                      "nothing on the strip says the reservation was held back: \(model.flushReport ?? "nothing")")
        let made = await recorder.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0)
    }

    /// A sheet open on a recording or a reservation holds a value, and stays up over an emptied list: when the
    /// lists go because another recorder has answered, its buttons would send that value's number to the
    /// newcomer. The screens close what they hold when the model says its lists were let go of, which it
    /// says whenever they are and not when the same recorder answers again.
    func testTheScreensAreToldWhenWhatTheyHoldIsTheLastRecorders() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder, Bench.otherHost: NamedRecorder(3)])
        var told = model.timesForgotten

        await model.connect()
        _ = await model.wakeIfDozing(evenIfRecent: true)
        await model.adopt(host: Bench.host)
        XCTAssertEqual(model.timesForgotten, told, "the screens were told to close what is still the recorder's")
        XCTAssertFalse(model.anotherTookOver, "the strip says another recorder answered, of the same one")

        await recorder.become(2)
        await model.connect()
        XCTAssertGreaterThan(model.timesForgotten, told, "another recorder answered the connect")
        told = model.timesForgotten

        try await until("the connect never finished") { !model.connecting && model.busy == nil }
        await recorder.become(1)
        _ = await model.wakeIfDozing(evenIfRecent: true)
        XCTAssertGreaterThan(model.timesForgotten, told, "another recorder answered the check")
        try await until("the newcomer was never taken up") {
            model.info?.udn == NamedRecorder.udn(1) && !model.connecting && model.busy == nil
        }
        told = model.timesForgotten

        await model.adopt(host: Bench.otherHost)
        XCTAssertGreaterThan(model.timesForgotten, told, "another address was chosen")
    }

    /// That another recorder answered, which nobody chose, is said for as long as the reader is looking: it
    /// goes when they leave the app, as the line about the queue does, and when they choose a recorder
    /// themselves, which is news of its own.
    func testThatAnotherRecorderAnsweredIsSaidUntilTheReaderLeavesOrChooses() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder, Bench.otherHost: NamedRecorder(3)])
        XCTAssertFalse(model.anotherTookOver)

        await recorder.become(2)
        await model.connect()
        XCTAssertTrue(model.anotherTookOver)
        // Answering again, it is the recorder the app has by now: said still, and not said a second time.
        await model.connect()
        XCTAssertTrue(model.anotherTookOver, "taken back by the next connect to the same recorder")
        model.wentToBackground()
        XCTAssertFalse(model.anotherTookOver, "still said on coming back to the app")

        await recorder.become(1)
        await model.connect()
        XCTAssertTrue(model.anotherTookOver)
        await model.adopt(host: Bench.otherHost)
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(3), model.problem ?? "no reason given")
        XCTAssertFalse(model.anotherTookOver, "said of a recorder the reader chose")
    }

    /// The cache is another recorder's and cannot be made over to the one that answers: another writer has
    /// held it for longer than the app waits. The app is not connected to that recorder -- it would go on
    /// over the other's guide and the texts of the other's recordings -- and says why; nothing waiting is
    /// sent, and the next connect, with the cache free, takes it over.
    func testACacheThatCannotBeMadeOverIsNotConnectedOver() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let second = NamedRecorder(2)
        let model = try await connected(bench, at: [Bench.host: NamedRecorder(1), Bench.otherHost: second])
        try await store(bench).queue(try await aReservationToQueue(model))

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(bench.guidePath, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        await model.adopt(host: Bench.otherHost)

        XCTAssertFalse(model.connected, "connected over a cache that is still the first recorder's")
        XCTAssertEqual(model.problem, AppModel.cacheNotMadeOver)
        XCTAssertFalse(model.gaveUp, "it answered: this is not silence")
        var made = await second.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0)
        var owner = try await store(bench).owner()
        XCTAssertEqual(owner, NamedRecorder.udn(1))
        var kept = try await textsKept(bench)
        XCTAssertEqual(kept, 1)

        // The guide on screen is still the first recorder's, and a programme reserved from it is not sent to
        // the one the app has just turned away from: there is nobody to ask, and it waits with the rest.
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(model.offline, "the recorder turned away from is still there to be asked")
        let program = try await aProgramme(model, skipping: 1)
        let waits = await model.reserve(program, quality: "DR", repeating: "none")
        XCTAssertTrue(waits, model.problem ?? "no reason given")
        made = await second.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0, "reserved on the recorder the app would not connect to")

        await model.connect()
        try await until("the connect never finished") { !model.connecting && model.busy == nil }

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        owner = try await store(bench).owner()
        XCTAssertEqual(owner, NamedRecorder.udn(2))
        kept = try await textsKept(bench)
        XCTAssertEqual(kept, 0)
        made = await second.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0)
        XCTAssertEqual(model.pending.map(\.problem),
                       [AppModel.heldForAnotherRecorder, AppModel.heldForAnotherRecorder])
    }

    /// The first recorder's name could not be put down -- the cache was being written to when it first
    /// answered -- and it is another one that answers next. The app knows that much without the cache: its
    /// lists were read from the first. So the cache is made over all the same, and what waited for the first
    /// is held, not sent to the second as the first answerer of a cache that is nobody's.
    func testAnotherRecorderTakesACacheWhoseOwnerCouldNotBeWrittenDown() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(bench.guidePath, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await until("the first connect never finished", within: 20) {
            model.connected && !model.connecting && model.busy == nil
        }
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        let cache = try store(bench)
        let unowned = try await cache.owner()
        XCTAssertNil(unowned, "the owner was meant not to have been written")
        await model.loadTitles()
        recording = try XCTUnwrap(model.titles.first).id
        try await cache.setTitleSummary(recording, "あらすじ")
        try await cache.queue(try await aReservationToQueue(model))

        await recorder.become(2)
        await model.connect()
        try await until("the connect never finished") { !model.connecting && model.busy == nil }

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
        let owner = try await cache.owner()
        XCTAssertEqual(owner, NamedRecorder.udn(2))
        let kept = try await textsKept(bench)
        XCTAssertEqual(kept, 0, "the first recorder's text was kept under the second one's numbers")
        let made = await recorder.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0, "what was waiting for the first recorder was made on the second")
        XCTAssertEqual(model.pending.map(\.problem), [AppModel.heldForAnotherRecorder])
    }

    // MARK: - the demo

    /// The demo has a cache of its own, and the real recorder's is as it was when the demo is over: its
    /// owner, its texts, what the defaults keep about its disk.
    func testTheDemoLeavesTheRealRecordersCacheAsItWas() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        let guideAsked = await recorder.asked("EPG_TRDEPG_FILE.dat")

        // Out by ending it, and then out by choosing the real recorder from inside it.
        for leaving in ["ending", "choosing"] {
            await model.enterDemo()
            XCTAssertTrue(model.connected, "the demo did not start: \(model.problem ?? "no reason given")")
            let demos = try await GuideStore(path: Storage.guidePath(demo: true, in: bench.folder)).owner()
            XCTAssertNil(demos, "the demo's cache was written down as somebody's")
            if leaving == "ending" { await model.leaveDemo() } else { await model.adopt(host: Bench.host) }
            try await until("the connect never finished") { !model.connecting && model.busy == nil }

            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(1), leaving)
            let owner = try await store(bench).owner()
            XCTAssertEqual(owner, NamedRecorder.udn(1), leaving)
            let kept = try await textsKept(bench)
            XCTAssertEqual(kept, 1, leaving)
            XCTAssertEqual(marksKept(bench), [true, true], leaving)
            let guideAskedAfter = await recorder.asked("EPG_TRDEPG_FILE.dat")
            XCTAssertEqual(guideAskedAfter, guideAsked, "the guide was fetched again after \(leaving)")
        }
    }

    // MARK: - with no screen

    /// With no screen the recorder the phone knows is sent the queue as before: when the cache has no owner
    /// written yet -- the app not opened since this was kept -- and when it has.
    ///
    /// No MAC is handed to these, here or below. The paths with no screen send their packet themselves, not
    /// through the model, and a MAC would put one on the network this is run on.
    func testWithNoScreenTheRecorderThePhoneKnowsIsSentTheQueue() async throws {
        for ownerWritten in [false, true] {
            let bench = try Bench()
            defer { bench.throwAway() }
            let recorder = NamedRecorder(1)
            let model: AppModel
            if ownerWritten {
                model = try await connected(bench, at: [Bench.host: recorder])
            } else {
                // A cache nobody has answered for since the owner was kept: the app's own connect met silence.
                try await bench.cacheAGuide()
                model = bench.model(recorders: [:])
                await model.start()
                try await until("the first connect never gave up") { model.gaveUp && !model.connecting }
            }
            let cache = try store(bench)
            let owner = try await cache.owner()
            XCTAssertEqual(owner, ownerWritten ? NamedRecorder.udn(1) : nil)
            try await cache.queue(try await aReservationToQueue(model))

            let sending = await BackgroundWork.sendWaiting(
                client: RecorderClient(host: Bench.host, transport: recorder), store: cache, mac: nil)

            guard case .sent(let outcome) = sending else {
                XCTFail("not sent, with the owner \(ownerWritten ? "written" : "not written"): \(sending)")
                continue
            }
            XCTAssertEqual(outcome.sent.count, 1)
            let left = try await cache.pendingReservations()
            XCTAssertTrue(left.isEmpty)
        }
    }

    /// The Shortcuts action knocks at the saved address with no screen to say who answered. A recorder the
    /// cache is not of is left alone: the queue was made for the other one.
    func testWithNoScreenARecorderTheCacheIsNotOfIsSentNothing() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let model = try await connected(bench, at: [Bench.host: NamedRecorder(1)])
        let cache = try store(bench)
        try await cache.queue(try await aReservationToQueue(model))
        let stranger = NamedRecorder(2)

        let sending = await BackgroundWork.sendWaiting(
            client: RecorderClient(host: Bench.host, transport: stranger), store: cache, mac: nil)

        XCTAssertEqual(sending, .anotherRecorder)
        XCTAssertEqual(SendWaitingIntent.saying(sending), Notify.anotherRecorderAnswered)
        let made = await stranger.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 0)
        let left = try await cache.pendingReservations()
        XCTAssertEqual(left.map(\.problem), [nil], "left as it was, for the recorder it was made for")
        let owner = try await cache.owner()
        XCTAssertEqual(owner, NamedRecorder.udn(1), "nothing is taken up without a screen")
    }

    /// What an overnight run told the reader and kept for the screens, in the order it did.
    private actor Told {
        private(set) var said: [String] = []
        func say(_ what: String) { said.append(what) }
    }

    private func telling(_ told: Told) -> BackgroundWork.Telling {
        BackgroundWork.Telling(heldBack: { await told.say("held back") },
                               flushed: { await told.say("sent \($0.sent.count)") },
                               freeSpace: { _, _ in await told.say("free space") },
                               fetched: { _ in Task { await told.say("fetched") } })
    }

    /// The overnight run, with the recorder the cache is of: what waits is sent, the reader is told, the free
    /// space is looked at and the guide asked for, as before any of this.
    func testTheOvernightRunDoesItsWorkWithTheRecorderThePhoneKnows() async throws {
        let bench = try Bench()
        defer { bench.throwAway() }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        let cache = try store(bench)
        try await cache.queue(try await aReservationToQueue(model))
        let guideAsked = await recorder.asked("EPG_TRDEPG_FILE.dat")
        let told = Told()

        _ = await BackgroundWork.refresh(client: RecorderClient(host: Bench.host, transport: recorder),
                                         store: cache, mac: nil, telling: telling(told))

        let made = await recorder.asked("X_CreateRecordSchedule")
        XCTAssertEqual(made, 1)
        let guideAskedAfter = await recorder.asked("EPG_TRDEPG_FILE.dat")
        XCTAssertGreaterThan(guideAskedAfter, guideAsked, "the guide was not asked for")
        let said = await told.said
        XCTAssertEqual(Array(said.prefix(2)), ["sent 1", "free space"])
    }

    /// The overnight run, answered by a recorder the cache is not of: nothing is sent to it, nothing is read
    /// from it into a cache that is the other's, and the reader is told -- when something was waiting to go,
    /// which is what they would otherwise miss, and not on every night after that.
    func testTheOvernightRunLeavesARecorderTheCacheIsNotOfAlone() async throws {
        for somethingWaits in [true, false] {
            let bench = try Bench()
            defer { bench.throwAway() }
            let model = try await connected(bench, at: [Bench.host: NamedRecorder(1)])
            let cache = try store(bench)
            if somethingWaits { try await cache.queue(try await aReservationToQueue(model)) }
            let stranger = NamedRecorder(2)
            let told = Told()

            let refreshed = await BackgroundWork.refresh(
                client: RecorderClient(host: Bench.host, transport: stranger), store: cache, mac: nil,
                telling: telling(told))

            XCTAssertFalse(refreshed)
            let made = await stranger.asked("X_CreateRecordSchedule")
            XCTAssertEqual(made, 0)
            let guideAsked = await stranger.asked("EPG_TRDEPG_FILE.dat")
            XCTAssertEqual(guideAsked, 0, "the stranger's guide would be stored in the other's cache")
            let spaceAsked = await stranger.asked("X_HDLnkGetRecordDestinationInfo")
            XCTAssertEqual(spaceAsked, 0)
            let said = await told.said
            XCTAssertEqual(said, somethingWaits ? ["held back"] : [])
            let left = try await cache.pendingReservations()
            XCTAssertEqual(left.map(\.problem), somethingWaits ? [nil] : [])
            let owner = try await cache.owner()
            XCTAssertEqual(owner, NamedRecorder.udn(1))
            let kept = try await textsKept(bench)
            XCTAssertEqual(kept, 1)
        }
    }
}
