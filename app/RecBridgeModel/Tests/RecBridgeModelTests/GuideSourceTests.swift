import Foundation
import Observation
@testable import RecorderKit
import XCTest
@testable import RecBridgeModel

/// Which device the household's guide comes from, in a home that has both: a recorder saved and a helper
/// registered on the television. The guide is one device's, the one 番組表の取得元 says, and the other is asked
/// for none of it by itself.
///
/// Each test builds such a home on a bench of its own -- an invented recorder whose guide file is the
/// conformance vector (`docs/port/epg-sample.dat`), an invented television with an invented helper beside it at
/// the helper's port -- and tells the two guides apart by their programmes: the recorder's are the vector's four
/// on service 1024 (programme ids 14792, 14793, 14794, 14800), the television's are titled テレビの番組
/// (programme ids from 9001). A cache that is merely empty is neither.
///
/// The clock cannot be moved from a test, so "the next morning" is made by ageing the marks in the cache two
/// days, with a connection of the test's own to the test's own database file (RecorderKit's `Sqlite`): the
/// cache's own writes that take a time either replace a type's rows or say that a device had none to give, and
/// neither is time going by. An hour gone by since the helper was last asked is
/// `TVHelperGuide.forgetTheCheck()`. Nothing here is read by the day on screen, which the invented helper's
/// programmes, three hours from now, fall out of between one and four in the morning: whose guide a screen
/// shows is told by its stations.
@MainActor
final class GuideSourceTests: XCTestCase {
    // MARK: - the rule

    /// One rule, of four facts: the television where a helper is registered and either no recorder is saved, or
    /// the one saved is known to give no guide, or the reader chose the television; the recorder otherwise, a
    /// helper registered or not, and whether or not it gives a guide.
    func testTheSourceIsTheTelevisionWithAHelperRegisteredAndNoRecorderOneWithNoGuideOrTheReadersChoice() {
        func source(_ recorderSaved: Bool, _ givesAGuide: Bool, _ helperRegistered: Bool,
                    _ preference: GuideSourceChoice) -> GuideSourceChoice {
            .of(recorderSaved: recorderSaved, recorderGivesAGuide: givesAGuide, helperRegistered: helperRegistered,
                preference: preference)
        }
        XCTAssertEqual(source(true, true, true, .tv), .tv)
        XCTAssertEqual(source(true, true, true, .recorder), .recorder)
        for preference in [GuideSourceChoice.recorder, .tv] {
            XCTAssertEqual(source(true, false, true, preference), .tv,
                           "a recorder that gives no guide leaves it to the television whatever was chosen")
            for givesAGuide in [true, false] {
                XCTAssertEqual(source(false, givesAGuide, true, preference), .tv,
                               "a television alone gives the guide whatever was chosen")
                for recorderSaved in [true, false] {
                    XCTAssertEqual(source(recorderSaved, givesAGuide, false, preference), .recorder,
                                   "with no helper registered")
                }
            }
        }
    }

    /// A run with no screen has no model to ask, and reads the same four facts from what the screens saved: the
    /// recorder's address, whether it gives a guide and the reader's choice in the defaults, the helper's
    /// registration in the store it is handed -- which counts only with a television saved, as the model has a
    /// helper only with a television. In each home it comes to what a model made in that home says.
    func testARunWithNoScreenComesToTheSourceTheModelSays() async throws {
        let home = try await aHome(recorderGives: [0])
        let defaults = home.bench.defaults
        func both(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> GuideSourceChoice {
            let withNoScreen = BackgroundWork.guideSource(in: noScreen(home))
            XCTAssertEqual(withNoScreen, model(in: home).guideSource, message, file: file, line: line)
            return withNoScreen
        }

        XCTAssertEqual(both("nothing chosen"), .recorder)
        defaults.set(GuideSourceChoice.tv.rawValue, forKey: DefaultsKey.guideSource)
        XCTAssertEqual(both("the television chosen"), .tv)
        home.tokens.remove()
        XCTAssertEqual(both("the television chosen and the helper's registration gone"), .recorder)
        home.tokens.save("token")
        defaults.removeObject(forKey: DefaultsKey.tvHost)
        XCTAssertEqual(both("a token kept and no television saved"), .recorder)
        defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        defaults.set(GuideSourceChoice.recorder.rawValue, forKey: DefaultsKey.guideSource)
        defaults.removeObject(forKey: DefaultsKey.recorderHost)
        XCTAssertEqual(both("a television alone, the recorder chosen before"), .tv)
        defaults.set("", forKey: DefaultsKey.recorderHost)
        XCTAssertEqual(both("an address saved empty is none saved"), .tv)

        defaults.set(Bench.host, forKey: DefaultsKey.recorderHost)
        defaults.set(false, forKey: DefaultsKey.recorderGivesAGuide)
        XCTAssertEqual(both("a recorder that gives no guide, the recorder chosen"), .tv)
        home.tokens.remove()
        XCTAssertEqual(both("a recorder that gives no guide and the helper's registration gone"), .recorder)
        home.tokens.save("token")
        defaults.set(true, forKey: DefaultsKey.recorderGivesAGuide)
        XCTAssertEqual(both("a recorder that gives a guide, the recorder chosen"), .recorder)
    }

    // MARK: - a connect, with the television chosen

    /// The reader chooses the television, and its guide comes into the cache. A connect to the recorder then
    /// reads its reservations as ever and asks it for no guide file: not for the types the television gave, and
    /// not for the ones it did not, whose marks the choice forgot. Nothing says a guide is on its way.
    func testWithTheTelevisionChosenAConnectAsksTheRecorderForNoGuide() async throws {
        let home = try await aHome(recorderGives: [0, 2])
        let model = try await started(home)
        XCTAssertEqual(model.guideSource, .recorder, "nothing chosen is the recorder")
        try await expect("td", .recorders, in: home)

        await model.setGuideSourcePreference(.tv)
        XCTAssertEqual(model.guideSource, .tv)
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
        XCTAssertNotEqual(GuideRefresh.staleTypes(model.counts), [],
                          "set up wrong: nothing is behind by the recorder's own rule")

        let before = await home.recorder.heard.count
        await reconnect(model)
        try await until("the connect never came to rest") { !isConnecting(model) && model.busy == nil }
        let heard = await home.recorder.heard(since: before)
        XCTAssertTrue(heard.contains(Ask.reservations), "set up wrong: the connect read nothing")
        XCTAssertEqual(heard.filter { Ask.guide.contains($0) || Ask.logos.contains($0) }, [],
                       "the connect asked the recorder for a guide with the television chosen")
        XCTAssertFalse(model.guideIsStale)
        XCTAssertFalse(model.guideOnItsWay)
        XCTAssertFalse(model.recorderHost.refreshesTheGuideAfterAConnect)
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
    }

    /// The television chosen in the moment between a connect's look at who gives the guide and the first turn of
    /// the refresh it started on finding the recorder's guide behind: the refresh asks the recorder for nothing.
    /// The choice is made here as the host notes that a refresh is to follow the connect, which is in the turn
    /// of that look and before the refresh's task has had one; only the choice's first step is made, the
    /// setting written, and not the fetch from the television that a press goes on to.
    func testTheTelevisionChosenAsAConnectEndsTheConnectsRefreshAsksTheRecorderForNothing() async throws {
        let home = try await aHome(recorderGives: [0])
        let model = try await started(home)
        try await expect("td", .recorders, in: home)
        try ageTheMarks(in: home)
        let chooses = TheTelevisionChosen(in: home.bench.defaults)
        withObservationTracking({ _ = model.recorderHost.refreshesTheGuideAfterAConnect },
                                onChange: { chooses.now() })

        let before = await home.recorder.heard.count
        await reconnect(model)
        try await until("the connect never came to rest") { !isConnecting(model) && model.busy == nil }

        XCTAssertEqual(model.guideSource, .tv, "set up wrong: the connect started no refresh to choose at")
        let files = await home.recorder.heard(since: before).filter { Ask.guide.contains($0) }
        XCTAssertEqual(files, [], "the recorder was asked for a guide after the television was chosen")
        XCTAssertFalse(model.recorderHost.refreshesTheGuideAfterAConnect)
        try await expect("td", .recorders, in: home, "set up wrong: something fetched the television's guide")
    }

    /// The morning after, every mark in the cache from before the recorder's 01:00 rebuild: the app is launched
    /// with the television chosen. The launch's connect asks the recorder for no guide file; the helper is asked
    /// what it has and, its copies unchanged, for no guide; the cache holds the television's guide as it did.
    func testTheMorningAfterALaunchAsksTheRecorderForNoGuide() async throws {
        let home = try await aHome(recorderGives: [0, 1])
        let evening = try await started(home)
        await evening.setGuideSourcePreference(.tv)
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
        try ageTheMarks(in: home)
        let aged = try await home.cache.counts()
        XCTAssertEqual(GuideRefresh.staleTypes(aged), GuideRefresh.broadcastingTypes,
                       "set up wrong: a type is not behind the last rebuild")

        let heard = await home.recorder.heard.count
        let asked = home.helper.asked.count
        let model = try await started(home, theHelperIsAsked: true)
        XCTAssertEqual(model.guideSource, .tv, "the choice was not kept across the launch")

        let files = await home.recorder.heard(since: heard).filter { Ask.guide.contains($0) }
        XCTAssertEqual(files, [], "the launch's connect asked the recorder for a guide")
        XCTAssertEqual(home.helper.asked(since: asked), ["/v1/info"],
                       "the helper was asked for more than what it has, its copies being unchanged")
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
        XCTAssertEqual(model.channels.map(\.name), [HelperOnTheTelevision.station("td")],
                       "the screen does not show the television's guide")
    }

    // MARK: - the overnight run, with the television chosen

    /// The overnight run in that home keeps its order and all else it does -- it reaches the recorder, sends
    /// what waits for it, reads the slot and the free space -- and leaves the recorder's guide out: no file is
    /// asked of the recorder, though the recorder's marks are two days old. The television's part asks the helper
    /// what it has and, its copies unchanged since the choice fetched them, for no file: the cache holds the
    /// television's guide as it did, 最終自動更新 is not written, and the night hands back that no guide was
    /// stored.
    func testWithTheTelevisionChosenTheNightAsksTheRecorderForNoGuideAndStillSendsWhatWaits() async throws {
        let home = try await aHome(recorderGives: [0])
        let model = try await started(home)
        await model.setGuideSourcePreference(.tv)
        try await expect("td", .televisions, in: home)
        try ageTheMarks(in: home)
        let waiting = aReservationWaiting()
        try await home.cache.queue(waiting)

        let heard = await home.recorder.heard.count
        let asked = home.helper.asked.count
        let stored = await BackgroundWork.refreshNow(in: noScreen(home))

        XCTAssertFalse(stored, "the night said it stored a guide")
        let since = await home.recorder.heard(since: heard)
        XCTAssertEqual(since, [Ask.description, Ask.reservations, Ask.create, Ask.slot, Ask.freeSpace],
                       "the night's order with the guide left out")
        XCTAssertEqual(home.helper.asked(since: asked), ["/v1/info"],
                       "the night asked the helper for more than what it has, its copies being unchanged")
        let left = try await home.cache.pendingReservations()
        XCTAssertEqual(left, [], "what waited was not sent")
        try await expect("td", .televisions, in: home)
        XCTAssertNil(home.bench.defaults.object(forKey: DefaultsKey.lastBackgroundRefresh),
                     "最終自動更新 was written by a night that fetched no guide")
        XCTAssertNil(model.lastOvernightRefresh)
    }

    // MARK: - the overnight run, from the television

    /// Where the television gives the guide, the overnight run fetches it through the helper, in its television's
    /// part: in a home with a television alone, beside a recorder that gives a guide with テレビ chosen, and beside
    /// a recorder that gives none. It asks the helper what it has and fetches the types behind, here both of the
    /// television's, the cache being empty; the cache's rows are the television's, each type's mark is noted, the
    /// time is written, 最終自動更新 says it under テレビ, and the night hands back that a guide was stored. The
    /// recorder is asked for no guide.
    func testWhereTheTelevisionGivesTheGuideTheNightFetchesItThroughTheHelper() async throws {
        let alone = try await aHome(recorderGives: [])
        alone.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        try await expectTheNightFetchesTheTelevisionsGuide(in: alone, "a television alone")

        let chosen = try await aHome(recorderGives: [0])
        chosen.bench.defaults.set(GuideSourceChoice.tv.rawValue, forKey: DefaultsKey.guideSource)
        try await expectTheNightFetchesTheTelevisionsGuide(in: chosen,
                                                           "テレビ chosen beside a recorder that gives a guide")

        let none = try await aHome(recorderGives: [])
        none.bench.defaults.set(false, forKey: DefaultsKey.recorderGivesAGuide)
        try await expectTheNightFetchesTheTelevisionsGuide(in: none, "beside a recorder that gives no guide")
    }

    /// The next night, the helper's copies unchanged, asks the helper what it has and for no guide file: it hands
    /// back that no guide was stored, and the time the settings say stays where it was.
    func testANightAfterWhichTheHelpersCopiesAreUnchangedAsksForNoFileAndLeavesTheTime() async throws {
        let home = try await aHome(recorderGives: [])
        let defaults = home.bench.defaults
        defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let first = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertTrue(first, "set up wrong: the first night stored no guide")
        let earlier = RecorderTime.format(Date(timeIntervalSince1970: 1_700_000_000))
        defaults.set(earlier, forKey: DefaultsKey.lastBackgroundRefresh)

        let asked = home.helper.asked.count
        let stored = await BackgroundWork.refreshNow(in: noScreen(home))

        XCTAssertFalse(stored, "a night with nothing behind said it stored a guide")
        XCTAssertEqual(home.helper.asked(since: asked), ["/v1/info"])
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.lastBackgroundRefresh), earlier, "the time moved")
        XCTAssertEqual(model(in: home).lastOvernightRefresh, "11/15(水) 07:13")
        try await expect("td", .televisions, in: home)
    }

    /// In the demo, with no television saved, and with no token, the night asks the helper nothing and writes
    /// nothing, the rest of a home whose guide the television gives being in place: a token kept with no
    /// television saved is no helper registered. With all of it in place, the night asks it.
    func testInTheDemoWithNoTelevisionOrWithNoTokenTheNightAsksTheHelperNothing() async throws {
        let home = try await aHome(recorderGives: [])
        let defaults = home.bench.defaults
        defaults.removeObject(forKey: DefaultsKey.recorderHost)

        defaults.set(true, forKey: DefaultsKey.demoData)
        _ = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertEqual(home.helper.asked, [], "in the demo")
        defaults.removeObject(forKey: DefaultsKey.demoData)

        defaults.removeObject(forKey: DefaultsKey.tvHost)
        _ = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertEqual(home.helper.asked, [], "with no television saved")
        defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)

        home.tokens.remove()
        _ = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertEqual(home.helper.asked, [], "with no token")
        XCTAssertNil(defaults.object(forKey: DefaultsKey.lastBackgroundRefresh))
        for type in ["td", "bs"] {
            let mark = try await home.cache.helperChanged(broadcasting: type)
            XCTAssertNil(mark, type)
        }

        home.tokens.save("token")
        let stored = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertTrue(stored, "set up wrong: the night asked nothing with all of it in place")
    }

    /// A silent helper: the night writes nothing of the television's guide and says nothing of the helper, and the
    /// rest of it is as in the same home with a helper that answers -- the recorder woken for what waits for it,
    /// its slot and its free space read and no guide asked of it, the television sent what waits for it, and the
    /// same posted, in whichever order the two parts post.
    func testASilentHelperWritesNothingAndLeavesTheRestOfTheNightAsItWas() async throws {
        func aNight(helperSilent: Bool) async throws
            -> (home: Home, stored: Bool, heard: [String], sent: [Int?], posted: [String]) {
            let home = try await aHome(recorderGives: [])
            home.bench.defaults.set(false, forKey: DefaultsKey.recorderGivesAGuide)
            await home.way.television.receives([DemoTV.Station()])
            try await home.cache.queue(aReservationWaiting())
            try await home.cache.queue(aReservationWaiting(programme: 4401, for: .tv))
            if helperSilent { home.helper.goSilent() }
            let posted = Notices()
            let notifications = Notifications(recorder: { _, _ in posted.note("recorder") },
                                              queueFlushed: { _ in posted.note("queueFlushed") },
                                              queueHeldBack: { posted.note("queueHeldBack") },
                                              lowSpace: { _, _, _ in posted.note("lowSpace") },
                                              usbLowSpace: { _ in posted.note("usbLowSpace") },
                                              television: { posted.note("television \($0.queue ?? "")") })
            let stored = await BackgroundWork.refreshNow(in: noScreen(home, notifications: notifications))
            let heard = await home.recorder.heard
            let sent = await home.way.television.schedules.map(\.eventId)
            return (home, stored, heard, sent, posted.all.compactMap { $0 }.sorted())
        }
        let silent = try await aNight(helperSilent: true)
        let answering = try await aNight(helperSilent: false)

        XCTAssertFalse(silent.stored, "a night whose helper was silent said it stored a guide")
        XCTAssertTrue(answering.stored, "set up wrong: the helper that answers gave no guide")
        XCTAssertEqual(silent.home.helper.asked, ["/v1/info"], "the silent helper was asked again")
        XCTAssertNil(silent.home.bench.defaults.object(forKey: DefaultsKey.lastBackgroundRefresh))
        for type in ["td", "bs"] {
            try await expect(type, .nothing, in: silent.home)
            let mark = try await silent.home.cache.helperChanged(broadcasting: type)
            XCTAssertNil(mark, type)
        }
        XCTAssertEqual(silent.heard, [Ask.description, Ask.reservations, Ask.create, Ask.slot, Ask.freeSpace],
                       "the recorder's part was not as it is with no guide to fetch")
        XCTAssertEqual(silent.heard, answering.heard)
        XCTAssertEqual(silent.sent, [4401], "what waited for the television was not sent")
        XCTAssertEqual(silent.sent, answering.sent)
        XCTAssertTrue(silent.posted.contains { $0.hasPrefix("television ") },
                      "set up wrong: nothing posted of the television")
        XCTAssertEqual(silent.posted, answering.posted)
        let left = try await silent.home.cache.pendingReservations()
        XCTAssertEqual(left, [], "what waited was not sent")
    }

    /// What waits for the television is sent before the helper is asked for the guide, the part with a deadline
    /// first: in a home with a television alone, with the helper's first answer held, the television already has
    /// the reservation that waited for it.
    func testTheNightSendsWhatWaitsForTheTelevisionBeforeItAsksTheHelper() async throws {
        let home = try await aHome(recorderGives: [])
        home.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        await home.way.television.receives([DemoTV.Station()])
        try await home.cache.queue(aReservationWaiting(programme: 4401, for: .tv))
        let surroundings = noScreen(home)
        let helper = home.helper
        helper.hold("/v1/info")

        let night = Task { await BackgroundWork.refreshNow(in: surroundings) }
        try await until("the night never asked the helper what it has") { helper.isHolding }
        let sent = await home.way.television.schedules.map(\.eventId)
        helper.letGo()
        let stored = await night.value

        XCTAssertEqual(sent, [4401], "the helper was asked before what waited for the television was sent")
        XCTAssertTrue(stored, "set up wrong: the night stored no guide")
        let left = try await home.cache.pendingReservations()
        XCTAssertEqual(left, [], "what waited was not sent")
    }

    /// A night whose time is up -- its task cancelled, as the system's expiry cancels it -- asks the helper nothing
    /// more and writes no mark and no time. Cancelled before the night begins, the helper is asked nothing; while
    /// 地上デジタル's guide file is out, neither its logos nor BS are asked for after it, and the night hands back
    /// that no guide was stored.
    func testANightWhoseTimeIsUpAsksTheHelperNothingMoreAndWritesNothing() async throws {
        let home = try await aHome(recorderGives: [])
        let defaults = home.bench.defaults
        defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let surroundings = noScreen(home)

        let before = Task {
            while !Task.isCancelled { await Task.yield() }
            return await BackgroundWork.refreshNow(in: surroundings)
        }
        before.cancel()
        var stored = await before.value
        XCTAssertFalse(stored)
        XCTAssertEqual(home.helper.asked, [], "the helper was asked once the time was up")

        let helper = home.helper
        helper.hold("/v1/guide/td")
        let night = Task { await BackgroundWork.refreshNow(in: surroundings) }
        try await until("the night never asked for 地上デジタル's guide") { helper.isHolding }
        night.cancel()
        helper.letGo()
        stored = await night.value

        XCTAssertFalse(stored, "a night whose time was up said it stored a guide")
        XCTAssertEqual(helper.asked, ["/v1/info", "/v1/channels", "/v1/guide/td"],
                       "the helper was asked for more once the time was up")
        for type in ["td", "bs"] {
            let mark = try await home.cache.helperChanged(broadcasting: type)
            XCTAssertNil(mark, "\(type)'s mark was noted once the time was up")
        }
        XCTAssertNil(defaults.object(forKey: DefaultsKey.lastBackgroundRefresh), "最終自動更新 was written")
        try await expect("bs", .nothing, in: home)
    }

    /// The Shortcuts action's entries -- the recorder's sending and the television's -- ask the helper nothing, in
    /// a home whose guide the television gives and with something waiting for each device: the action sends, and
    /// fetches no guide.
    func testTheShortcutsActionsEntriesAskTheHelperNothing() async throws {
        let home = try await aHome(recorderGives: [])
        home.bench.defaults.set(false, forKey: DefaultsKey.recorderGivesAGuide)
        await home.way.television.receives([DemoTV.Station()])
        try await home.cache.queue(aReservationWaiting())
        try await home.cache.queue(aReservationWaiting(programme: 4401, for: .tv))
        let surroundings = noScreen(home)
        XCTAssertEqual(BackgroundWork.guideSource(in: surroundings), .tv)

        let recorders = await BackgroundWork.sendWaiting(in: surroundings)
        let televisions = await BackgroundWork.sendToTheTelevisionNow(in: surroundings)

        guard case .sent = recorders else {
            return XCTFail("set up wrong: the recorder was sent nothing: \(recorders)")
        }
        guard case .sent? = televisions else {
            return XCTFail("set up wrong: the television was sent nothing: \(String(describing: televisions))")
        }
        XCTAssertEqual(home.helper.asked, [], "the action asked the helper")
        XCTAssertNil(home.bench.defaults.object(forKey: DefaultsKey.lastBackgroundRefresh))
        try await expect("td", .nothing, in: home)
    }

    /// A type the television has no guide of, which the cache holds as the recorder's -- CS, the recorder having
    /// given the guide until テレビ was chosen with nothing fetched since -- is emptied by the night as by the
    /// screens' fetch (`testATypeTheChosenDeviceDoesNotHaveIsEmptiedAsInAHomeWithThatDeviceAlone`), and the
    /// types the television has come round to its own.
    func testTheNightEmptiesATypeTheTelevisionHasNoGuideOf() async throws {
        let home = try await aHome(recorderGives: [0, 2])
        _ = try await started(home)
        try await expect("cs", .recorders, in: home)
        try await expect("td", .recorders, in: home)
        home.bench.defaults.set(GuideSourceChoice.tv.rawValue, forKey: DefaultsKey.guideSource)

        let stored = await BackgroundWork.refreshNow(in: noScreen(home))

        XCTAssertTrue(stored)
        try await expect("cs", .nothing, in: home, "the recorder's CS was left under the television's guide")
        let cs = try await home.cache.counts()["cs"]
        XCTAssertEqual(cs?.channels ?? 0, 0)
        XCTAssertNil(cs?.lastAnswered)
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
    }

    /// A model alive in the process the night ran in -- the app kept alive behind it -- shows what the night
    /// stored as it comes back to the front, as it shows what a recorder's night stored once a connect reads the
    /// cache: within the hour of the helper's last check, by reading the cache again, asking the helper nothing;
    /// past it, by that check, which asks the helper what it has and, the night having noted the marks, for no
    /// file.
    func testAModelAliveBesideTheNightShowsWhatTheNightStored() async throws {
        let home = try await aHome(recorderGives: [])
        home.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let model = try await started(home, theHelperIsAsked: true)
        XCTAssertEqual(model.counts["td"]?.programs, 2, "set up wrong")

        home.helper.newCopies(["td": 3, "bs": 1])
        var stored = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertTrue(stored, "set up wrong: the night stored nothing")
        XCTAssertEqual(model.counts["td"]?.programs, 2, "set up wrong: the model read the night's guide by itself")
        var asked = home.helper.asked.count
        model.wentToBackground()
        await model.returnedToForeground()
        XCTAssertEqual(model.counts["td"]?.programs, 3, "the screen does not show the night's guide")
        XCTAssertEqual(home.helper.asked(since: asked), [], "the helper was asked within the hour")

        home.helper.newCopies(["td": 4, "bs": 1])
        stored = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertTrue(stored, "set up wrong: the second night stored nothing")
        model.tvHelper?.forgetTheCheck()
        asked = home.helper.asked.count
        model.wentToBackground()
        await model.returnedToForeground()
        XCTAssertEqual(home.helper.asked(since: asked), ["/v1/info"],
                       "the check after the night asked the helper for more than what it has")
        XCTAssertEqual(model.counts["td"]?.programs, 4, "the screen does not show the second night's guide")
    }

    // MARK: - the recorder chosen

    /// With a helper registered and the recorder the source -- nothing chosen, or the recorder chosen back --
    /// nothing asks the helper for what it has or for a guide: not the registration, not a launch, not a return
    /// to the app, not 番組表を更新, not a connect, not the overnight run, which fetches the recorder's guide as
    /// ever and says so.
    func testWithTheRecorderTheSourceNothingAsksTheHelperForAGuide() async throws {
        let home = try await aHome(registered: false, recorderGives: [0])
        let model = try await started(home)
        let said = await model.registerHelper(code: "123456")
        XCTAssertNil(said)
        XCTAssertTrue(model.guideSourceIsChoosable)
        XCTAssertEqual(model.guideSource, .recorder)
        XCTAssertEqual(home.helper.asked, ["/ping", "/v1/pair"])

        model.wentToBackground()
        await model.returnedToForeground()
        try await untilConnected(model)
        _ = await model.refreshGuideByHandFromSource()
        await reconnect(model)
        let heard = await home.recorder.heard.count
        let stored = await BackgroundWork.refreshNow(in: noScreen(home))
        XCTAssertTrue(stored, "the night stored no guide with the recorder the source")
        let files = await home.recorder.heard(since: heard).filter { Ask.guide.contains($0) }
        XCTAssertEqual(files, Ask.guide, "the night did not ask the recorder for every type")
        XCTAssertNotNil(model.lastOvernightRefresh, "最終自動更新 says nothing")
        XCTAssertEqual(home.helper.asked, ["/ping", "/v1/pair"], "the helper was asked with the recorder the source")
        try await expect("td", .recorders, in: home)

        // A second launch, the helper registered from the start.
        let second = try await started(home)
        XCTAssertTrue(second.helperRegistered)
        XCTAssertEqual(home.helper.asked, ["/ping", "/v1/pair"], "a launch asked the helper")

        // Chosen, and chosen back: the recorder's guide comes back at once, and the helper is left alone again.
        await second.setGuideSourcePreference(.tv)
        try await expect("td", .televisions, in: home)
        let asked = home.helper.asked.count
        await second.setGuideSourcePreference(.recorder)
        try await expect("td", .recorders, in: home)
        second.tvHelper?.forgetTheCheck()
        second.wentToBackground()
        await second.returnedToForeground()
        try await untilConnected(second)
        XCTAssertEqual(home.helper.asked(since: asked), [])
    }

    // MARK: - a type the chosen device does not have

    /// A recorder that says it gives a guide and has no file of any type, added to a home that had a television
    /// alone: the recorder gives the guide from then on by the rule, nothing having been chosen, and has none to
    /// give. Its connect asks it for every type -- the cache a morning old -- and is answered each time that it has
    /// no file; nothing of the television's guide is emptied for it, since it has given no type itself, and the
    /// screen shows the television's stations as it did. One that says it gives none leaves the guide to the
    /// television (`testARecorderThatSaysItGivesNoGuideAddedToAHomeWithATelevisionAloneLeavesItTheGuide`).
    func testARecorderWithNoGuideAddedToAHomeWithATelevisionAloneTakesNothingAway() async throws {
        let home = try await aHome(recorderGives: [])
        home.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let model = try await started(home, theHelperIsAsked: true)
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
        try ageTheMarks(in: home)

        let heard = await home.recorder.heard.count
        await model.adopt(host: Bench.host)
        try await untilConnected(model)
        try await until("the connect's refresh never ended") { !isConnecting(model) && model.busy == nil }

        XCTAssertEqual(model.guideSource, .recorder)
        let files = await home.recorder.heard(since: heard).filter { Ask.guide.contains($0) }
        XCTAssertEqual(files, Ask.guide, "set up wrong: the recorder was not asked for every type")
        try await expect("td", .televisions, in: home, "the television's guide went for a recorder that gives none")
        try await expect("bs", .televisions, in: home)
        XCTAssertEqual(model.channels.map(\.name), [HelperOnTheTelevision.station("td")])
    }

    /// The television chosen: CS, which the television has no guide of and the cache held as the recorder's,
    /// is emptied as the television's guide comes in, and the guide's screen says of it what it says in a home
    /// with a television alone, over a cache that holds of it what that home's holds. The recorder chosen back:
    /// BS, which this recorder has no file of, is emptied of the television's rows in its turn, stands as a type
    /// the recorder answered with no file for, and is not behind to the recorder after that -- judged by its
    /// rule from the moment of the choice, and not by a connect, which rightly asks again once the clock has
    /// passed the recorder's next rebuild.
    func testATypeTheChosenDeviceDoesNotHaveIsEmptiedAsInAHomeWithThatDeviceAlone() async throws {
        let home = try await aHome(recorderGives: [0, 2])
        let model = try await started(home)
        try await expect("cs", .recorders, in: home)

        await model.setGuideSourcePreference(.tv)
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
        try await expect("cs", .nothing, in: home, "the recorder's CS was left under the television's guide")
        model.broadcasting = "cs"
        await model.reloadFromCache()
        XCTAssertEqual(model.guideShows(grid: false), .empty)
        let said = model.guideEmpty(narrowed: false)
        XCTAssertEqual(said, .typeNotAnswered)

        let alone = try await aHome(recorderGives: [])
        alone.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let televisionAlone = try await started(alone, theHelperIsAsked: true)
        try await expect("td", .televisions, in: alone, "set up wrong: the television's guide never came")
        televisionAlone.broadcasting = "cs"
        await televisionAlone.reloadFromCache()
        XCTAssertEqual(televisionAlone.guideShows(grid: false), .empty)
        XCTAssertEqual(televisionAlone.guideEmpty(narrowed: false), said)
        XCTAssertEqual(model.says(said), televisionAlone.says(said))
        XCTAssertEqual(model.counts["cs"], televisionAlone.counts["cs"])

        model.broadcasting = "td"
        let chosen = GuideRefresh.toTheSecond(Date())
        await model.setGuideSourcePreference(.recorder)
        try await expect("td", .recorders, in: home)
        try await expect("cs", .recorders, in: home)
        try await expect("bs", .nothing, in: home, "the television's BS was left under the recorder's guide")
        XCTAssertEqual(model.counts["bs"]?.channels, 0)
        XCTAssertNotNil(model.counts["bs"]?.lastAnswered, "the recorder is not marked as having answered for it")
        XCTAssertEqual(GuideRefresh.staleTypes(model.counts, since: chosen), [],
                       "a type the recorder has no file of is behind still, to be asked for again at the next connect")
    }

    // MARK: - a cache that holds the other device's guide

    /// A cache the fault had mixed -- the recorder's 地上デジタル put where the television's was, under a setting
    /// that says テレビ, the helper's copy unchanged since -- comes back to the television's when the helper is
    /// next asked what it has, with nobody having pressed: the type the recorder gave is fetched again, the one
    /// that is the television's still is not, and the recorder is asked for nothing.
    func testACacheMixedUnderTheTelevisionComesBackToTheTelevisionsWithoutAPress() async throws {
        let home = try await aHome(recorderGives: [0])
        let model = try await started(home)
        await model.setGuideSourcePreference(.tv)
        try await expect("td", .televisions, in: home)
        try await home.cache.replace(try Epg.decode(try vectorFile("epg-sample.dat")), broadcasting: "td")
        try await expect("td", .recorders, in: home, "set up wrong")

        let heard = await home.recorder.heard.count
        let asked = home.helper.asked.count
        model.tvHelper?.forgetTheCheck()
        model.wentToBackground()
        await model.returnedToForeground()
        try await until("the return never came to rest") {
            model.tvHelper?.isFetching == false && !isConnecting(model) && model.busy == nil
        }

        try await expect("td", .televisions, in: home, "the recorder's guide stayed under the television's setting")
        try await expect("bs", .televisions, in: home)
        XCTAssertEqual(home.helper.asked(since: asked), ["/v1/info", "/v1/guide/td", "/v1/logos/td"])
        let files = await home.recorder.heard(since: heard).filter { Ask.guide.contains($0) }
        XCTAssertEqual(files, [])
        XCTAssertEqual(model.channels.map(\.name), [HelperOnTheTelevision.station("td")],
                       "the screen does not show the television's guide")
    }

    /// ヘルパーの登録を解除, with the television chosen: the recorder gives the guide from then on, though nothing
    /// took the guide over. What the cache holds stays the television's until the next connect to the recorder,
    /// which fetches the recorder's over it -- the marks of the television's fetch a moment old -- and empties
    /// the type this recorder has no file of. Registered again, the choice still テレビ, the television gives the
    /// guide again, and its guide is fetched over the recorder's as the registration ends, with no wait for the
    /// helper's next check.
    func testTheGuideComesRoundWhenTheHelperIsForgottenAndWhenItIsRegisteredAgain() async throws {
        let home = try await aHome(recorderGives: [0])
        let model = try await started(home)
        await model.setGuideSourcePreference(.tv)
        try await expect("td", .televisions, in: home)

        model.forgetHelper()
        XCTAssertEqual(model.guideSource, .recorder)
        try await expect("td", .televisions, in: home, "the cache was emptied at the press")
        await reconnect(model)
        try await until("the connect's refresh never ended") { !isConnecting(model) && model.busy == nil }
        try await expect("td", .recorders, in: home, "the television's guide stayed with no helper registered")
        try await expect("bs", .nothing, in: home)

        let said = await model.registerHelper(code: "123456")
        XCTAssertNil(said)
        XCTAssertEqual(model.guideSource, .tv, "the choice was not kept")
        try await expect("td", .televisions, in: home,
                         "the television's guide was not fetched as its helper was registered again")
        try await expect("bs", .televisions, in: home)
        XCTAssertEqual(model.channels.map(\.name), [HelperOnTheTelevision.station("td")])
    }

    /// A recorder added to a home that had a television alone: the recorder gives the guide from then on, nothing
    /// having been chosen, and its first connect fetches every type over the television's, a moment old as its
    /// marks are, and not only the types the television did not have.
    func testTheGuideComesRoundWhenARecorderIsAddedToAHomeWithATelevisionAlone() async throws {
        let home = try await aHome(recorderGives: [0, 1])
        home.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let model = try await started(home, theHelperIsAsked: true)
        XCTAssertEqual(model.guideSource, .tv)
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)

        let heard = await home.recorder.heard.count
        await model.adopt(host: Bench.host)
        try await untilConnected(model)
        XCTAssertEqual(model.guideSource, .recorder)
        let files = await home.recorder.heard(since: heard).filter { Ask.guide.contains($0) }
        XCTAssertEqual(files, Ask.guide, "the connect did not ask the recorder for every type")
        try await expect("td", .recorders, in: home)
        try await expect("bs", .recorders, in: home)
    }

    /// テレビを外す, with the television chosen: the recorder gives the guide, and the next connect to it fetches
    /// its guide over the television's.
    func testTheGuideComesRoundWhenTheTelevisionIsTakenAway() async throws {
        let home = try await aHome(recorderGives: [0, 1])
        let model = try await started(home)
        await model.setGuideSourcePreference(.tv)
        try await expect("td", .televisions, in: home)

        model.removeTV()
        XCTAssertEqual(model.guideSource, .recorder)
        XCTAssertNil(home.tokens.load(), "the helper's registration was kept")
        await reconnect(model)
        try await until("the connect's refresh never ended") { !isConnecting(model) && model.busy == nil }
        try await expect("td", .recorders, in: home)
        try await expect("bs", .recorders, in: home)
    }

    // MARK: - a recorder that gives no guide

    /// What the recorder says of its guide (`RecorderDescription.epgCapable`) is kept as it says it at a connect,
    /// either way, where a launch knows it before its own connect; never heard, it counts as giving one. The demo's
    /// invented recorder, which gives one, leaves what is kept of the real one as it was, and so does leaving the
    /// demo. Another recorder in its place that gives one puts it right.
    func testWhatTheRecorderSaysOfItsGuideIsKeptAndPutRightAndTheDemoLeavesIt() async throws {
        let home = try await aHome(registered: false, recorderGives: [0])
        let defaults = home.bench.defaults
        func kept() -> Bool? {
            defaults.object(forKey: DefaultsKey.recorderGivesAGuide) == nil
                ? nil : GuideSourceChoice.recorderGivesAGuide(in: defaults)
        }
        XCTAssertNil(kept())
        XCTAssertTrue(self.model(in: home).recorderGivesAGuide, "a recorder never heard was taken to give no guide")

        await home.recorder.describeItself(givingAGuide: false)
        let model = try await started(home)
        XCTAssertEqual(model.info?.epgCapable, false, "set up wrong: the recorder said it gives a guide")
        XCTAssertEqual(kept(), false, "what the recorder said was not kept")
        XCTAssertFalse(model.recorderGivesAGuide)
        XCTAssertFalse(self.model(in: home).recorderGivesAGuide, "a launch did not know it before its connect")

        await model.enterDemo()
        try await untilConnected(model, "the demo's recorder was never connected")
        XCTAssertTrue(model.demo, "set up wrong: the demo did not begin")
        XCTAssertEqual(model.info?.epgCapable, true, "set up wrong: the demo's recorder said it gives no guide")
        XCTAssertTrue(model.recorderGivesAGuide, "the demo's recorder was taken to give no guide")
        XCTAssertEqual(kept(), false, "the demo's recorder wrote over what was kept of the real one")
        await model.leaveDemo()
        try await untilConnected(model, "the real recorder was never connected again")
        XCTAssertEqual(kept(), false)
        XCTAssertFalse(model.recorderGivesAGuide)

        await home.recorder.become(2)
        await home.recorder.describeItself(givingAGuide: true)
        await reconnect(model)
        try await until("the connect never came to rest") { !isConnecting(model) && model.busy == nil }
        XCTAssertEqual(kept(), true, "another recorder in its place that gives a guide did not put it right")
        XCTAssertTrue(model.recorderGivesAGuide)
    }

    /// A recorder that says it gives no guide, in a home whose helper is registered: the television gives the guide
    /// from the first connect that hears it, nothing having been chosen, and there is nothing to choose --
    /// 番組表の取得元 is the one line テレビ, as in a home with a television alone -- while the choice saved is left
    /// as it was. That connect starts no refresh of the recorder's guide, and the television's is fetched as the
    /// recorder is heard, once: the next connect fetches it again no more than it refreshes the recorder's. A type
    /// the television has no guide of is said as in a home with a television alone, not as the guide of a recorder
    /// that gives none. A launch after it knows all this before its connect.
    func testARecorderThatGivesNoGuideLeavesTheGuideToTheTelevisionWithNothingToChoose() async throws {
        let home = try await aHome(recorderGives: [])
        await home.recorder.describeItself(givingAGuide: false)
        let model = self.model(in: home)
        XCTAssertEqual(model.guideSource, .recorder,
                       "set up wrong: something was known of the recorder before a connect")
        let refreshes = refreshesAfterAConnect(of: model)

        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        try await until("the television's guide was never fetched") {
            model.tvHelper?.lastCheck != nil && model.tvHelper?.isFetching == false
        }
        try await until("the launch never came to rest") { !isConnecting(model) && model.busy == nil }

        XCTAssertEqual(model.info?.epgCapable, false, "set up wrong: the recorder said it gives a guide")
        XCTAssertEqual(model.guideSource, .tv)
        XCTAssertFalse(model.guideSourceIsChoosable)
        XCTAssertEqual(model.guideSourceAlone, "テレビ")
        XCTAssertNil(home.bench.defaults.object(forKey: DefaultsKey.guideSource), "the choice saved was written")
        XCTAssertEqual(refreshes.all, [], "the connect started a refresh of the recorder's guide")
        XCTAssertEqual(home.helper.asked.filter { $0.hasPrefix("/v1/guide/") }, ["/v1/guide/td", "/v1/guide/bs"],
                       "the television's guide was not fetched once as the recorder was heard")
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)

        let asked = home.helper.asked.count
        let again = refreshesAfterAConnect(of: model)
        await reconnect(model)
        try await until("the connect never came to rest") { !isConnecting(model) && model.busy == nil }
        XCTAssertEqual(home.helper.asked(since: asked), [], "the next connect asked the helper")
        XCTAssertEqual(again.all, [], "the next connect started a refresh of the recorder's guide")

        model.broadcasting = "cs"
        await model.reloadFromCache()
        XCTAssertEqual(model.guideShows(grid: false), .empty)
        XCTAssertEqual(model.guideEmpty(narrowed: false), .typeNotAnswered,
                       "a type the television has no guide of was said as the guide of a recorder that gives none")

        let later = self.model(in: home)
        XCTAssertEqual(later.guideSource, .tv, "a launch did not know before its connect that the recorder gives none")
        XCTAssertFalse(later.guideSourceIsChoosable)
        XCTAssertEqual(later.guideSourceAlone, "テレビ")
    }

    /// With no helper registered nothing changes for a recorder that says it gives no guide: it gives the guide,
    /// its connect starts the refresh it always has, 番組表の取得元 is not said, and an empty day says that the
    /// recorder gives no guide. What it said is kept all the same, so that a helper registered there takes the guide
    /// over to the television at once (`registerHelper`), the choice saved left as it was.
    func testWithNoHelperARecorderThatGivesNoGuideGivesTheGuideAsBefore() async throws {
        let home = try await aHome(registered: false, recorderGives: [])
        await home.recorder.describeItself(givingAGuide: false)
        let model = self.model(in: home)
        let refreshes = refreshesAfterAConnect(of: model)

        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        try await until("the launch never came to rest") { !isConnecting(model) && model.busy == nil }

        XCTAssertEqual(model.info?.epgCapable, false, "set up wrong: the recorder said it gives a guide")
        XCTAssertEqual(model.guideSource, .recorder)
        XCTAssertFalse(model.guideSourceIsChoosable)
        XCTAssertNil(model.guideSourceAlone)
        XCTAssertEqual(refreshes.all, ["started"], "the connect did not start the refresh it always has")
        XCTAssertEqual(model.guideEmpty(narrowed: false), .notCapable)
        XCTAssertEqual(home.helper.asked, [])
        XCTAssertFalse(GuideSourceChoice.recorderGivesAGuide(in: home.bench.defaults), "what it said was not kept")

        let said = await model.registerHelper(code: "123456")
        XCTAssertNil(said)
        XCTAssertEqual(model.guideSource, .tv)
        XCTAssertEqual(model.guideSourceAlone, "テレビ")
        try await expect("td", .televisions, in: home,
                         "the television's guide was not fetched as its helper was registered")
        try await expect("bs", .televisions, in: home)
        XCTAssertNil(home.bench.defaults.object(forKey: DefaultsKey.guideSource), "the choice saved was written")
        model.broadcasting = "cs"
        await model.reloadFromCache()
        XCTAssertEqual(model.guideEmpty(narrowed: false), .typeNotAnswered)
    }

    /// A recorder that says it gives no guide, added to a home that had a television alone: the television goes on
    /// giving the guide. The connect that hears the recorder starts no refresh of the recorder's guide, and the
    /// television's guide stays as it was.
    func testARecorderThatSaysItGivesNoGuideAddedToAHomeWithATelevisionAloneLeavesItTheGuide() async throws {
        let home = try await aHome(recorderGives: [])
        await home.recorder.describeItself(givingAGuide: false)
        home.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let model = try await started(home, theHelperIsAsked: true)
        try await expect("td", .televisions, in: home)
        let refreshes = refreshesAfterAConnect(of: model)

        await model.adopt(host: Bench.host)
        try await untilConnected(model)
        try await until("the connect never came to rest") {
            !isConnecting(model) && model.busy == nil && model.tvHelper?.isFetching == false
        }

        XCTAssertEqual(model.guideSource, .tv)
        XCTAssertEqual(model.guideSourceAlone, "テレビ")
        XCTAssertEqual(refreshes.all, [], "the connect started a refresh of the recorder's guide")
        try await expect("td", .televisions, in: home)
        try await expect("bs", .televisions, in: home)
        XCTAssertEqual(model.channels.map(\.name), [HelperOnTheTelevision.station("td")])
    }

    /// The overnight run reads what the screens kept of the recorder's guide (`BackgroundWork.guideSource(in:)`): in
    /// a home whose recorder said it gives none and whose helper is registered, the television gives the guide, and
    /// the night keeps its order and asks the recorder for no guide -- no type is marked as answered for -- while
    /// its television's part asks the helper what it has and, the launch having fetched its copies, for no file:
    /// 最終自動更新 is not written, and the night hands back that no guide was stored. With the helper's
    /// registration gone, the recorder gives the guide again, and the night asks it for every type, which a
    /// recorder that gives none answers by having none, each type marked as answered for, and asks the helper
    /// nothing.
    func testTheNightReadsThatTheRecorderGivesNoGuide() async throws {
        let home = try await aHome(recorderGives: [])
        await home.recorder.describeItself(givingAGuide: false)
        _ = try await started(home, theHelperIsAsked: true)
        XCTAssertEqual(BackgroundWork.guideSource(in: noScreen(home)), .tv)

        let heard = await home.recorder.heard.count
        var asked = home.helper.asked.count
        let stored = await BackgroundWork.refreshNow(in: noScreen(home))

        XCTAssertFalse(stored, "the night said it stored a guide")
        let since = await home.recorder.heard(since: heard)
        XCTAssertEqual(since, [Ask.description, Ask.slot, Ask.freeSpace], "the night's order with the guide left out")
        XCTAssertEqual(home.helper.asked(since: asked), ["/v1/info"],
                       "the night asked the helper for more than what it has, its copies being unchanged")
        let after = try await home.cache.counts()
        XCTAssertNil(after["cs"]?.checked, "the night asked the recorder for a guide")
        XCTAssertNil(home.bench.defaults.object(forKey: DefaultsKey.lastBackgroundRefresh),
                     "最終自動更新 was written by a night that fetched no guide")

        home.tokens.remove()
        XCTAssertEqual(BackgroundWork.guideSource(in: noScreen(home)), .recorder)
        asked = home.helper.asked.count
        _ = await BackgroundWork.refreshNow(in: noScreen(home))
        let asTheSource = try await home.cache.counts()
        XCTAssertNotNil(asTheSource["cs"]?.checked,
                        "set up wrong: the night with the recorder the source asked it for no guide")
        XCTAssertEqual(home.helper.asked(since: asked), [], "the night asked the helper with the recorder the source")
    }

    // MARK: - what the screens say of the device

    /// The sentences that say which device the guide comes from name the one that gives this home's guide, by
    /// the name 番組表の取得元 has for it: an empty guide's, the stations' screen's reset with its question, and
    /// its empty list's. The recorder with nothing chosen, as these have always read; the television once it is
    /// chosen, and in a home with a television alone. A type the other types came in without is said of the
    /// recorder as one it does not have, and of the television only as one it has no guide of.
    func testTheSentencesNameTheDeviceThatGivesTheGuide() async throws {
        let home = try await aHome(recorderGives: [0])
        let defaults = home.bench.defaults
        func named(_ device: String, _ noType: String, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
            let model = model(in: home)
            XCTAssertEqual(model.guideDeviceName, device, message, file: file, line: line)
            let refresh = "右上の更新ボタンで\(device)から取得できます"
            XCTAssertEqual(model.says(.notFetched), .init("番組表をまだ取得していません", refresh), message,
                           file: file, line: line)
            XCTAssertEqual(model.says(.nothingThatDay), .init("この日の番組表はありません", refresh), message,
                           file: file, line: line)
            XCTAssertEqual(model.says(.typeNotAnswered),
                           .init("地上デジタルの番組表はありません", noType + "。右上の更新ボタンで取得し直せます"), message,
                           file: file, line: line)
            let channels = ChannelsState(broadcasting: "td", model: model)
            XCTAssertEqual(channels.resetLabel, "\(device)の順に戻して、すべて表示", message, file: file, line: line)
            XCTAssertEqual(channels.confirmResetLabel, "\(device)の順に戻す", message, file: file, line: line)
            XCTAssertEqual(channels.resetQuestion, "地上デジタルの局をすべて表示して、\(device)の順に戻しますか？", message,
                           file: file, line: line)
            XCTAssertEqual(channels.empty, .init("地上デジタルの局はありません", "局の一覧は、番組表と一緒に\(device)から取得します"),
                           message, file: file, line: line)
        }

        named("レコーダー", "レコーダーが対応していない放送は空のままです", "nothing chosen")
        defaults.set(GuideSourceChoice.tv.rawValue, forKey: DefaultsKey.guideSource)
        named("テレビ", "テレビに番組表が無い放送は空のままです", "the television chosen")
        home.tokens.remove()
        named("レコーダー", "レコーダーが対応していない放送は空のままです",
               "the television chosen and the helper's registration gone")
        home.tokens.save("token")
        defaults.set(GuideSourceChoice.recorder.rawValue, forKey: DefaultsKey.guideSource)
        defaults.removeObject(forKey: DefaultsKey.recorderHost)
        named("テレビ", "テレビに番組表が無い放送は空のままです", "a television alone")
    }

    /// 最終自動更新 says when a night last fetched a guide, under either source: the recorder's night's time while
    /// nothing is chosen, and under テレビ the same until the television's night fetches its guide, whose time it
    /// says from then on -- with the recorder chosen back, and in a home with a television alone.
    func testTheOvernightRefreshSaysTheTelevisionsNightUnderTheTelevision() async throws {
        let home = try await aHome(recorderGives: [0])
        let defaults = home.bench.defaults
        defaults.set(RecorderTime.format(Date(timeIntervalSince1970: 1_700_000_000)),
                     forKey: DefaultsKey.lastBackgroundRefresh)
        XCTAssertEqual(model(in: home).lastOvernightRefresh, "11/15(水) 07:13", "nothing chosen")
        defaults.set(GuideSourceChoice.tv.rawValue, forKey: DefaultsKey.guideSource)
        XCTAssertEqual(model(in: home).lastOvernightRefresh, "11/15(水) 07:13",
                       "the television chosen, before its night")

        let began = Date()
        let stored = await BackgroundWork.refreshNow(in: noScreen(home))

        XCTAssertTrue(stored, "set up wrong: the television's night stored no guide")
        let written = try XCTUnwrap(defaults.string(forKey: DefaultsKey.lastBackgroundRefresh))
        let fetched = try XCTUnwrap(RecorderTime.parse(written))
        XCTAssertTrue(fetched >= began.addingTimeInterval(-1) && fetched <= Date(), "\(written)")
        let underTheTelevision = model(in: home)
        XCTAssertEqual(underTheTelevision.guideSource, .tv)
        expectTheOvernightRefresh(of: underTheTelevision, says: fetched, "the television's night")
        defaults.set(GuideSourceChoice.recorder.rawValue, forKey: DefaultsKey.guideSource)
        expectTheOvernightRefresh(of: model(in: home), says: fetched, "the recorder chosen back")
        defaults.removeObject(forKey: DefaultsKey.recorderHost)
        expectTheOvernightRefresh(of: model(in: home), says: fetched, "a television alone")
    }

    // MARK: - the home

    /// A home with a recorder and a television, each invented, the helper beside the television.
    private struct Home {
        let bench: Bench
        let recorder: NamedRecorder
        let helper: HelperOnTheTelevision
        let way: TelevisionWithAHelper
        let credentials: MemoryTVCredentials
        /// The helper's token as the app keeps it, across the launches of one test.
        let tokens: MemoryTVHelperToken
        /// A connection of the test's own to the cache, to look with.
        let cache: GuideStore
    }

    /// The recorder gives the vector's guide file for the types numbered (0 地上デジタル, 1 BS, 2 CS, 3 BS4K) and
    /// answers that it has no file for the rest, as the demo's does; the helper has programmes of 地上デジタル and
    /// BS. Both devices' addresses are saved, as after both were added.
    private func aHome(registered: Bool = true, recorderGives types: [Int]) async throws -> Home {
        let bench = try aBench()
        let recorder = NamedRecorder(1)
        let guide = try vectorFile("epg-sample.dat")
        for type in types { await recorder.answer(Ask.guide[type], with: .body(guide), times: 10_000) }
        let television = DemoTV(power: "active")
        let credentials = await self.registered(with: television)
        let helper = HelperOnTheTelevision()
        bench.defaults.set(Bench.host, forKey: DefaultsKey.recorderHost)
        bench.defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        return Home(bench: bench, recorder: recorder, helper: helper,
                    way: TelevisionWithAHelper(television: television, helper: helper), credentials: credentials,
                    tokens: MemoryTVHelperToken(registered ? "token" : nil),
                    cache: try GuideStore(path: bench.guidePath))
    }

    /// A model as the app makes one at a launch in that home. It puts nothing on the network by itself
    /// (`reachesTheLAN`), and what it asks goes to the invented devices.
    private func model(in home: Home) -> AppModel {
        let folder = home.bench.folder, recorder = home.recorder, way = home.way
        var surroundings = Surroundings(defaults: home.bench.defaults, folder: { folder },
                                        transport: { _ in recorder }, networkSignature: { "home" },
                                        reachesTheLAN: false, asksAboutNotifications: false)
        surroundings.busyRetryDelay = 0...0
        surroundings.wireWaitLimit = 0.05
        surroundings.tvTransport = { _ in way }
        surroundings.tvCredentials = home.credentials
        surroundings.tvHelperTokens = home.tokens
        surroundings.tvTitlesWait = TVTitlesWait(every: .milliseconds(5), for: 0.1)
        return AppModel(surroundings: surroundings)
    }

    /// Such a model started, with its first connects over and everything it set going at rest.
    private func started(_ home: Home, theHelperIsAsked: Bool = false) async throws -> AppModel {
        let model = model(in: home)
        await model.start()
        if !model.host.isEmpty { try await untilConnected(model) }
        try await untilTheTelevisionIsConnected(model)
        if theHelperIsAsked {
            try await until("the helper was never asked at the launch") {
                model.tvHelper?.lastCheck != nil && model.tvHelper?.isFetching == false
            }
        }
        try await until("the launch never came to rest") { !isConnecting(model) && model.busy == nil }
        return model
    }

    /// What the overnight run is handed in that home, with notifications that post nowhere unless a test hands
    /// its own. The recorder's MAC is taken out of the defaults first, so that the run, which sends its packet
    /// itself, has none to send.
    private func noScreen(_ home: Home, notifications: Notifications = Notifications()) -> NoScreenSurroundings {
        home.bench.defaults.removeObject(forKey: DefaultsKey.recorderMac)
        let folder = home.bench.folder, recorder = home.recorder, way = home.way
        return NoScreenSurroundings(defaults: home.bench.defaults, folder: { folder }, transport: { _ in recorder },
                                    tvTransport: { _ in way }, tvCredentials: home.credentials,
                                    tvHelperTokens: home.tokens, notifications: notifications)
    }

    /// The overnight run in a home whose guide the television gives, its cache holding nothing of the television's:
    /// what `testWhereTheTelevisionGivesTheGuideTheNightFetchesItThroughTheHelper` expects of it.
    private func expectTheNightFetchesTheTelevisionsGuide(in home: Home, _ which: String,
                                                          file: StaticString = #filePath,
                                                          line: UInt = #line) async throws {
        XCTAssertEqual(BackgroundWork.guideSource(in: noScreen(home)), .tv, "set up wrong: \(which)",
                       file: file, line: line)
        let heard = await home.recorder.heard.count
        let began = Date()

        let stored = await BackgroundWork.refreshNow(in: noScreen(home))

        XCTAssertTrue(stored, "\(which): the night said it stored no guide", file: file, line: line)
        XCTAssertEqual(home.helper.asked, ["/v1/info", "/v1/channels", "/v1/guide/td", "/v1/logos/td",
                                           "/v1/guide/bs", "/v1/logos/bs"], which, file: file, line: line)
        try await expect("td", .televisions, in: home, which, file: file, line: line)
        try await expect("bs", .televisions, in: home, which, file: file, line: line)
        for type in ["td", "bs"] {
            let mark = try await home.cache.helperChanged(broadcasting: type)
            XCTAssertEqual(mark, home.helper.copiesChangedAt, "\(which): \(type)'s mark was not noted",
                           file: file, line: line)
        }
        let files = await home.recorder.heard(since: heard).filter { Ask.guide.contains($0) || Ask.logos.contains($0) }
        XCTAssertEqual(files, [], "\(which): the night asked the recorder for a guide", file: file, line: line)
        let written = try XCTUnwrap(home.bench.defaults.string(forKey: DefaultsKey.lastBackgroundRefresh),
                                    "\(which): 最終自動更新 was not written", file: file, line: line)
        let fetched = try XCTUnwrap(RecorderTime.parse(written), file: file, line: line)
        // Written to the second.
        XCTAssertTrue(fetched >= began.addingTimeInterval(-1) && fetched <= Date(), "\(which): \(written)",
                      file: file, line: line)
        let model = model(in: home)
        XCTAssertEqual(model.guideSource, .tv, which, file: file, line: line)
        expectTheOvernightRefresh(of: model, says: fetched, which, file: file, line: line)
    }

    /// 最終自動更新 says `time`, which a night wrote a moment ago. The model says it against the clock (`Format.when`),
    /// so it is read between two sayings of the test's own and may equal either: a second that turns between the
    /// reads is no failure.
    private func expectTheOvernightRefresh(of model: AppModel, says time: Date, _ message: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let before = Format.when(time)
        let said = model.lastOvernightRefresh
        let after = Format.when(time)
        XCTAssertTrue(said == before || said == after, "\(message): 最終自動更新 says \(said ?? "nothing"), not \(after)",
                      file: file, line: line)
    }

    /// Notes `started` once the refresh a connect starts on finding the recorder's guide behind is started, as
    /// Observation tells of the host's hold for it (`RecorderHost.refreshesTheGuideAfterAConnect`), from now on.
    /// Told once, which is all a look at whether one was started needs.
    private func refreshesAfterAConnect(of model: AppModel) -> Notices {
        let started = Notices()
        withObservationTracking({ _ = model.recorderHost.refreshesTheGuideAfterAConnect },
                                onChange: { started.note("started") })
        return started
    }

    /// Two days go by, as far as the cache's marks of when each type was fetched and answered for can tell.
    private func ageTheMarks(in home: Home) throws {
        let then = RecorderTime.format(Date().addingTimeInterval(-2 * 86_400))
        try Sqlite(path: home.bench.guidePath).run(
            "UPDATE meta SET value=? WHERE key LIKE 'epg_refreshed:%' OR key LIKE 'epg_checked:%'", [.text(then)])
    }

    /// A reservation of the test's own making waiting for the recorder, or for the television (`target`): half
    /// an hour on the demo's first channel, which the invented television receives once a test says so, in DR and
    /// not repeated, starting in half a day.
    private func aReservationWaiting(programme: Int = 4332, for target: DeviceSlot = .recorder) -> PendingReservation {
        let request = ReservationRequest(title: "夜のあいだに送る番組", start: Date().addingTimeInterval(12 * 3600),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        var row = PendingReservation(request: request, serviceName: "サンプルテレビ")
        row.target = target
        return row
    }

    private enum Whose: String {
        case nothing, televisions = "the television's", recorders = "the recorder's", mixed = "a mix of both"
    }

    /// Whose programmes the cache holds of one type.
    private func whose(_ broadcasting: String, in home: Home) async throws -> Whose {
        let rows = try await home.cache.programs(broadcasting: broadcasting, limit: 5000)
        if rows.isEmpty { return .nothing }
        if rows.allSatisfy({ $0.title.hasPrefix(HelperOnTheTelevision.titlePrefix) && $0.eventID >= 9001 }) {
            return .televisions
        }
        if rows.allSatisfy({ [14792, 14793, 14794, 14800].contains($0.eventID) }) { return .recorders }
        return .mixed
    }

    private func expect(_ broadcasting: String, _ expected: Whose, in home: Home, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let held = try await whose(broadcasting, in: home)
        XCTAssertEqual(held.rawValue, expected.rawValue, "\(broadcasting): \(message)", file: file, line: line)
    }
}

/// The reader's choice of the television, written where the settings write it, for a test to make from where
/// Observation tells of a change, which is no actor's place: the defaults object is safe to use from any.
private struct TheTelevisionChosen: @unchecked Sendable {
    private let defaults: UserDefaults

    init(in defaults: UserDefaults) {
        self.defaults = defaults
    }

    func now() {
        defaults.set(GuideSourceChoice.tv.rawValue, forKey: DefaultsKey.guideSource)
    }
}

/// The television's address as the app reaches it: the helper at the helper's port, the television itself at
/// every other.
struct TelevisionWithAHelper: HTTPTransport {
    let television: DemoTV
    let helper: HelperOnTheTelevision

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.port == TVHelperClient.port else { return try await television.send(request) }
        return try await helper.respond(to: request)
    }
}

/// An invented helper: programmes of 地上デジタル (service 1024, the recorder's first) and BS (service 101), each
/// titled テレビの番組, the first three hours from now and one an hour after it; any token is taken. Its copies
/// do not change unless a test makes new ones (`newCopies`). `asked` is every path it was asked for, in order,
/// silence and a held answer among them.
final class HelperOnTheTelevision: @unchecked Sendable {
    static let titlePrefix = "テレビの番組"
    /// The name of its one station of a type.
    static func station(_ type: String) -> String { "テレビの局 \(type)" }

    private let lock = NSLock()
    private let services = ["td": 1024, "bs": 101]
    private var programs = ["td": 2, "bs": 1]
    private let first = Int(Date().addingTimeInterval(3 * 3600).timeIntervalSince1970) * 1000
    private var changedAt = 1_800_000_000_000
    private var paths: [String] = []
    private var silent = false
    /// The path whose answer is held until `letGo`, and the request held there.
    private var holds: String?
    private var held: CheckedContinuation<Void, Never>?

    var asked: [String] { lock.withLock { paths } }
    func asked(since count: Int) -> [String] { Array(asked.dropFirst(count)) }

    /// When the helper last saw its copies change, as the cache notes it from what the helper says.
    var copiesChangedAt: Date {
        lock.withLock { Date(timeIntervalSince1970: TimeInterval(changedAt) / 1000) }
    }

    /// New copies of every type, with so many programmes of each, seen to change a minute after the last.
    func newCopies(_ programs: [String: Int]) {
        lock.withLock {
            self.programs = programs
            changedAt += 60_000
        }
    }

    /// Answers nothing from now on, as a helper that is not running.
    func goSilent() {
        lock.withLock { silent = true }
    }

    /// Holds the answer to `path` until `letGo`.
    func hold(_ path: String) {
        lock.withLock { holds = path }
    }

    var isHolding: Bool { lock.withLock { held != nil } }

    func letGo() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holds = nil
            defer { held = nil }
            return held
        }
        waiting?.resume()
    }

    func respond(to request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        let (quiet, holding) = lock.withLock { () -> (Bool, Bool) in
            paths.append(path)
            return (silent, holds == path)
        }
        if holding { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
        guard !quiet else { throw TVHelperError.transport("no answer") }
        let (programs, changedAt) = lock.withLock { (self.programs, self.changedAt) }
        let type = path.split(separator: "/").last.map(String.init) ?? ""
        switch path {
        case "/ping":
            return Self.json(200, ["app": "recbridge-helper", "api": [1], "version": "0.1.0"])
        case "/v1/pair":
            return Self.json(200, ["token": "token", "deviceId": "d1", "api": [1], "version": "0.1.0"])
        case "/v1/info":
            var types: [String: Any] = [:]
            for (type, count) in programs {
                types[type] = ["etag": "x", "changedAt": changedAt, "snapshotAt": changedAt,
                               "programs": count, "channels": 1] as [String: Any]
            }
            return Self.json(200, ["helperVersion": "0.1.0", "listingsPermission": true, "tunerInstalled": true,
                                   "building": false, "types": types])
        case "/v1/channels":
            let channels = services.map { type, service -> [String: Any] in
                ["bt": type, "sid": service, "number": "0\(service % 100)", "name": Self.station(type),
                 "hasPrograms": true]
            }
            return Self.json(200, ["channels": channels])
        case "/v1/guide/td", "/v1/guide/bs":
            let listed = (0..<(programs[type] ?? 0)).map { index -> [String: Any] in
                ["sid": services[type] ?? 0, "eid": 9001 + index, "startMs": first + index * 3_600_000,
                 "endMs": first + (index + 1) * 3_600_000, "title": "\(Self.titlePrefix) \(type) \(index + 1)"]
            }
            return Self.json(200, ["bt": type, "programs": listed])
        case "/v1/logos/td", "/v1/logos/bs":
            return Self.json(200, ["bt": type, "logos": [[String: Any]]()])
        default:
            return Self.json(404, ["error": "noSuchType"])
        }
    }

    private static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}
