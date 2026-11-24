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

    /// One rule, of three facts: the television where a helper is registered and either no recorder is saved or
    /// the reader chose the television; the recorder otherwise, a helper registered or not.
    func testTheSourceIsTheTelevisionWithAHelperRegisteredAndNoRecorderOrTheReadersChoice() {
        func source(_ recorderSaved: Bool, _ helperRegistered: Bool, _ preference: GuideSourceChoice)
            -> GuideSourceChoice {
            .of(recorderSaved: recorderSaved, helperRegistered: helperRegistered, preference: preference)
        }
        XCTAssertEqual(source(true, true, .tv), .tv)
        XCTAssertEqual(source(true, true, .recorder), .recorder)
        XCTAssertEqual(source(false, true, .recorder), .tv, "a television alone gives the guide whatever was chosen")
        XCTAssertEqual(source(false, true, .tv), .tv)
        for recorderSaved in [true, false] {
            for preference in [GuideSourceChoice.recorder, .tv] {
                XCTAssertEqual(source(recorderSaved, false, preference), .recorder, "with no helper registered")
            }
        }
    }

    /// A run with no screen has no model to ask, and reads the same three facts from what the screens saved: the
    /// recorder's address and the reader's choice in the defaults, the helper's registration in the store it is
    /// handed -- which counts only with a television saved, as the model has a helper only with a television. In
    /// each home it comes to what a model made in that home says.
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
    /// what waits for it, reads the slot and the free space -- and leaves the guide out: no file is asked for,
    /// the cache holds the television's guide as it did, and 最終自動更新 is not written. It hands back that no
    /// guide was stored, as the night of a home with a television alone does.
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
        XCTAssertEqual(home.helper.asked(since: asked), [], "the night asked the helper")
        let left = try await home.cache.pendingReservations()
        XCTAssertEqual(left, [], "what waited was not sent")
        try await expect("td", .televisions, in: home)
        XCTAssertNil(home.bench.defaults.object(forKey: DefaultsKey.lastBackgroundRefresh),
                     "最終自動更新 was written by a night that fetched no guide")
        XCTAssertNil(model.lastOvernightRefresh)

        // A home with a television alone: its night hands back the same.
        let alone = try await aHome(recorderGives: [])
        alone.bench.defaults.removeObject(forKey: DefaultsKey.recorderHost)
        let aloneStored = await BackgroundWork.refreshNow(in: noScreen(alone))
        XCTAssertEqual(aloneStored, stored)
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

    /// A recorder that gives no guide, added to a home that had a television alone: the recorder gives the guide
    /// from then on by the rule, nothing having been chosen, and has none to give. Its connect asks it for every
    /// type -- the cache a morning old -- and is answered each time that it has no file; nothing of the
    /// television's guide is emptied for it, since it has given no type itself, and the screen shows the
    /// television's stations as it did.
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

    /// What the overnight run is handed in that home. The recorder's MAC is taken out of the defaults first, so
    /// that the run, which sends its packet itself, has none to send.
    private func noScreen(_ home: Home) -> NoScreenSurroundings {
        home.bench.defaults.removeObject(forKey: DefaultsKey.recorderMac)
        let folder = home.bench.folder, recorder = home.recorder, way = home.way
        return NoScreenSurroundings(defaults: home.bench.defaults, folder: { folder }, transport: { _ in recorder },
                                    tvTransport: { _ in way }, tvCredentials: home.credentials,
                                    tvHelperTokens: home.tokens, notifications: Notifications())
    }

    /// Two days go by, as far as the cache's marks of when each type was fetched and answered for can tell.
    private func ageTheMarks(in home: Home) throws {
        let then = RecorderTime.format(Date().addingTimeInterval(-2 * 86_400))
        try Sqlite(path: home.bench.guidePath).run(
            "UPDATE meta SET value=? WHERE key LIKE 'epg_refreshed:%' OR key LIKE 'epg_checked:%'", [.text(then)])
    }

    /// A reservation of the test's own making waiting for the recorder: half an hour on the demo's first
    /// channel, in DR and not repeated, starting in half a day.
    private func aReservationWaiting() -> PendingReservation {
        let request = ReservationRequest(title: "夜のあいだに送る番組", start: Date().addingTimeInterval(12 * 3600),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: 4332)
        return PendingReservation(request: request, serviceName: "サンプルテレビ")
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
private struct TelevisionWithAHelper: HTTPTransport {
    let television: DemoTV
    let helper: HelperOnTheTelevision

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.port == TVHelperClient.port else { return try await television.send(request) }
        return try await helper.respond(to: request)
    }
}

/// An invented helper: programmes of 地上デジタル (service 1024, the recorder's first) and BS (service 101), each
/// titled テレビの番組, the first three hours from now and one an hour after it; any token is taken. Its copies
/// do not change. `asked` is every path it was asked for, in order.
private final class HelperOnTheTelevision: @unchecked Sendable {
    static let titlePrefix = "テレビの番組"
    /// The name of its one station of a type.
    static func station(_ type: String) -> String { "テレビの局 \(type)" }

    private let lock = NSLock()
    private let services = ["td": 1024, "bs": 101]
    private let programs = ["td": 2, "bs": 1]
    private let first = Int(Date().addingTimeInterval(3 * 3600).timeIntervalSince1970) * 1000
    private let changedAt = 1_800_000_000_000
    private var paths: [String] = []

    var asked: [String] { lock.withLock { paths } }
    func asked(since count: Int) -> [String] { Array(asked.dropFirst(count)) }

    func respond(to request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        lock.withLock { paths.append(path) }
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
