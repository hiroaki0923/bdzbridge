import XCTest
@testable import RecorderKit

/// The cache is loaded from the sample guide file, so these also show what the decoder and the store look like
/// end to end.
final class GuideStoreTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private func sampleServices() throws -> [GuideService] {
        let expected = try Vectors.load("epg-sample.json")
        let data = try Data(contentsOf: Vectors.directory.appendingPathComponent(expected.string("file")))
        return try Epg.decode(data)
    }

    private func loadedStore() async throws -> GuideStore {
        let store = try GuideStore(path: ":memory:")
        let stored = try await store.replace(try sampleServices(), broadcasting: "td",
                                             at: jst("2026-09-14T03:00:00+09:00"))
        XCTAssertEqual(stored, 5, "four programmes on the main channel and one reference on the sub-channel")
        return store
    }

    private func jst(_ text: String) -> Date {
        RecorderTime.parse(text)!
    }

    private func temporaryPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        return directory.appendingPathComponent("guide.sqlite3").path
    }

    func testChannelsAndProgrammesComeBackAsStored() async throws {
        let store = try await loadedStore()

        let channels = try await store.channels(broadcasting: "td")
        XCTAssertEqual(channels.map(\.serviceID), [1024, 1025])
        XCTAssertEqual(channels.first?.name, "ＮＨＫ総合１・東京")
        XCTAssertEqual(channels.first?.sort, 0)
        XCTAssertNil(channels.first?.logo, "no logo file has been decoded yet")

        let programs = try await store.programs(broadcasting: "td", serviceID: 1024)
        XCTAssertEqual(programs.map(\.eventID), [14792, 14793, 14794, 14800], "in broadcast order")
        let news = try XCTUnwrap(programs.first)
        XCTAssertEqual(news.title, "サンプルニュース　あさの放送[字]")
        XCTAssertEqual(news.summary, "朝のニュース")
        XCTAssertEqual(news.extended, "詳細テキスト")
        XCTAssertEqual(news.serviceName, "ＮＨＫ総合１・東京")
        XCTAssertEqual(news.genres, [Genre(level1: 0, level2: 0), Genre(level1: 0, level2: 1)])
        XCTAssertEqual(news.genre?.label, "ニュース／報道")
        XCTAssertEqual(news.copyControl, 2)
        XCTAssertEqual(news.durationSec, 3600)
        XCTAssertFalse(news.isReference)
    }

    func testAReferenceTakesItsTextFromTheProgrammeItPointsAt() async throws {
        let store = try await loadedStore()

        let onSubChannel = try await store.programs(broadcasting: "td", serviceID: 1025, includeReferences: true)
        let reference = try XCTUnwrap(onSubChannel.first)
        XCTAssertTrue(reference.isReference)
        XCTAssertEqual(reference.referenceServiceID, 1024)
        XCTAssertEqual(reference.referenceEventID, 14792)
        XCTAssertEqual(reference.title, "サンプルニュース　あさの放送[字]", "resolved from the parent service")
        XCTAssertEqual(reference.summary, "朝のニュース")
        XCTAssertEqual(reference.serviceName, "ＮＨＫ総合２・東京")

        let withoutReferences = try await store.programs(broadcasting: "td", serviceID: 1025)
        XCTAssertTrue(withoutReferences.isEmpty, "references are left out unless asked for")
    }

    func testSearchIgnoresWidthAndCase() async throws {
        let store = try await loadedStore()

        for query in ["sample", "SAMPLE", "ＳＡＭＰＬＥ", "日曜劇場"] {
            let found = try await store.search(query, broadcasting: "td")
            XCTAssertEqual(found.hits.map(\.program.eventID), [14794], "searching for \(query)")
        }
        let description = try await store.search("朝のニュース", broadcasting: "td")
        XCTAssertEqual(description.hits.map(\.program.eventID), [14792], "the short description is searched too")
        let details = try await store.search("詳細テキスト", broadcasting: "td")
        XCTAssertEqual(details.hits.map(\.program.eventID), [14792], "and so are the details")
        let nothing = try await store.search("そんな番組はない", broadcasting: "td")
        XCTAssertTrue(nothing.hits.isEmpty)
        XCTAssertFalse(nothing.more)
        let blank = try await store.search(" 　", broadcasting: "td")
        XCTAssertTrue(blank.hits.isEmpty, "spaces alone are not a search for everything")
    }

    func testSearchReachesReferencesThroughTheirParent() async throws {
        let store = try await loadedStore()
        let found = try await store.search("あさの放送", broadcasting: "td", includeReferences: true)
        XCTAssertEqual(found.hits.map(\.program.serviceID), [1024, 1025])
    }

    // MARK: - searching by the cast, and the order results come in

    /// Four programmes with the same name in them: in the title of two, in the description of one, and only
    /// among the cast in the details of the earliest of them all.
    private func castStore() async throws -> GuideStore {
        let store = try GuideStore(path: ":memory:")
        func program(_ id: Int, at hour: Int, _ title: String, summary: String = "",
                     extended: String = "") -> GuideProgram {
            let start = jst("2026-09-14T00:00:00+09:00").addingTimeInterval(TimeInterval(hour * 3600))
            return GuideProgram(serviceID: 1024, eventID: id, start: start, end: start.addingTimeInterval(3600),
                                title: title, summary: summary, extended: extended)
        }
        let programs = [
            program(1, at: 8, "朝の連続ドラマ「みなと」", summary: "港町の一家の物語。",
                    extended: "番組内容\n港町に暮らす一家の三代を描く。\n出演者\nサンプル太郎、みほん花子"),
            program(2, at: 9, "サンプル太郎アワー"),
            program(3, at: 10, "旅の時間", summary: "サンプル太郎が海辺の町を歩く。"),
            program(4, at: 11, "特集　サンプル太郎の部屋", extended: "ゲスト　みほん花子"),
            program(5, at: 12, "夜のニュース", extended: "出演：ＳＡＭＰＬＥ次郎"),
        ]
        try await store.replace([GuideService(serviceID: 1024, name: "サンプルテレビ", programs: programs)],
                                broadcasting: "td")
        return store
    }

    func testTitlesComeFirstThenDescriptionsThenDetailsAndTimeWithinEach() async throws {
        let store = try await castStore()
        let found = try await store.search("サンプル太郎")
        XCTAssertEqual(found.hits.map(\.program.eventID), [2, 4, 3, 1],
                       "the two titles by time, then the description, then the cast list, although it starts first")
        XCTAssertEqual(found.hits.map(\.match), [.title, .title, .summary, .extended])
        XCTAssertEqual(found.hits.map(\.snippet), [nil, nil, nil,
                                                   Search.Snippet(before: "…出演者 ", match: "サンプル太郎",
                                                                  after: "、みほん花子")],
                       "only a programme found in its details says where; the heading on the line before is kept")
    }

    func testEveryWordHasToBeThereAndTheOneFoundFurthestDownRanks() async throws {
        let store = try await castStore()

        let both = try await store.search("ドラマ　みほん花子")
        XCTAssertEqual(both.hits.map(\.program.eventID), [1], "the title has one word and the cast the other")
        XCTAssertEqual(both.hits.first?.match, .extended)
        XCTAssertEqual(both.hits.first?.snippet?.match, "みほん花子",
                       "the snippet is about the word that is only in the details")

        let two = try await store.search("サンプル太郎 部屋")
        XCTAssertEqual(two.hits.map(\.program.eventID), [4])
        XCTAssertEqual(two.hits.first?.match, .title)

        let none = try await store.search("ドラマ 旅")
        XCTAssertTrue(none.hits.isEmpty, "each word in a different programme is not a match")
    }

    func testADetailsMatchShowsTheTextAsBroadcast() async throws {
        let store = try await castStore()
        let found = try await store.search("sample次郎")
        XCTAssertEqual(found.hits.map(\.program.eventID), [5])
        XCTAssertEqual(found.hits.first?.snippet,
                       Search.Snippet(before: "出演：", match: "ＳＡＭＰＬＥ次郎", after: ""),
                       "found in half width, shown in the full width that was sent, with its label")
    }

    func testAWordDoesNotRunFromOneFieldIntoTheNext() async throws {
        let store = try await castStore()
        let found = try await store.search("みなと」港町")
        XCTAssertTrue(found.hits.isEmpty, "the end of a title and the start of its description are not one word")
    }

    /// LIKE's wildcards in a query are the characters themselves.
    func testPercentAndUnderscoreAreSearchedForAsTyped() async throws {
        let store = try GuideStore(path: ":memory:")
        let start = jst("2026-09-14T08:00:00+09:00")
        let titles = ["100%の力", "1000回目の朝", "a_b", "axb", "c\\d", "cd"]
        let programs = titles.enumerated().map { index, title in
            GuideProgram(serviceID: 1024, eventID: index + 1, start: start.addingTimeInterval(TimeInterval(index * 60)),
                         end: start.addingTimeInterval(TimeInterval(index * 60 + 60)), title: title)
        }
        try await store.replace([GuideService(serviceID: 1024, name: "サンプルテレビ", programs: programs)],
                                broadcasting: "td")

        for (query, expected) in [("100%", ["100%の力"]), ("100", ["100%の力", "1000回目の朝"]), ("a_b", ["a_b"]),
                                  ("c\\d", ["c\\d"]), ("%", ["100%の力"]), ("_", ["a_b"])] {
            let found = try await store.search(query)
            XCTAssertEqual(found.hits.map(\.program.title), expected, "searching for \(query)")
        }
    }

    func testOneMoreThanTheLimitIsAskedForToTellThereAreMore() async throws {
        let store = try await castStore()
        let cut = try await store.search("サンプル太郎", limit: 3)
        XCTAssertEqual(cut.hits.map(\.program.eventID), [2, 4, 3], "the best of them are the ones kept")
        XCTAssertTrue(cut.more)
        let whole = try await store.search("サンプル太郎", limit: 4)
        XCTAssertEqual(whole.hits.count, 4)
        XCTAssertFalse(whole.more, "exactly the limit is not more than it")
    }

    // MARK: - a cache from before the details were searched

    /// What an older build left: the guide in place, its search text made of the title and the description
    /// joined by a space, and no mark saying otherwise.
    private func oldCache(at path: String) async throws {
        do {
            let store = try GuideStore(path: path)
            try await store.replace(try sampleServices(), broadcasting: "td")
            try await store.setChannelPreferences(broadcasting: "td", hidden: [1025])
        }
        let db = try Sqlite(path: path)
        try db.run("""
        UPDATE programs SET search_text = lower(COALESCE(title,'') || ' ' || COALESCE(description,''))
        WHERE ref_event_id IS NULL
        """)
        try db.run("DELETE FROM meta WHERE key='search_text_version'")
    }

    func testAnOldCacheIsBroughtUpToDateWhereItIsOnce() async throws {
        let path = try temporaryPath()
        try await oldCache(at: path)

        let store = try GuideStore(path: path)
        let before = try await store.counts()
        XCTAssertEqual(before["td"]?.programs, 4, "opening it keeps the guide: the schema version is not bumped")
        let rewritten = try await store.updateSearchText()
        XCTAssertEqual(rewritten, 4, "every programme but the reference, which is searched through its parent")

        let found = try await store.search("詳細テキスト", broadcasting: "td", includeReferences: true,
                                           includeHidden: true)
        XCTAssertEqual(found.hits.map(\.program.serviceID), [1024, 1025],
                       "the details are searched, the simulcast on the sub-channel with them")
        XCTAssertEqual(found.hits.first?.match, .extended)
        let title = try await store.search("あさの放送", broadcasting: "td")
        XCTAssertEqual(title.hits.first?.match, .title, "and the fields are told apart")

        let after = try await store.counts()
        XCTAssertEqual(after["td"], before["td"], "nothing was thrown away or fetched")
        let channels = try await store.channels(broadcasting: "td")
        XCTAssertEqual(channels.map(\.serviceID), [1024], "what the reader set is untouched")

        let again = try await store.updateSearchText()
        XCTAssertEqual(again, 0)
        let reopened = try GuideStore(path: path)
        let afterReopening = try await reopened.updateSearchText()
        XCTAssertEqual(afterReopening, 0, "the mark is kept in the database, so it is done once")
    }

    func testASearchBringsAnOldCacheUpToDateItself() async throws {
        let path = try temporaryPath()
        try await oldCache(at: path)

        let store = try GuideStore(path: path)
        let found = try await store.search("詳細テキスト", broadcasting: "td")
        XCTAssertEqual(found.hits.map(\.program.eventID), [14792],
                       "a search made before the app got round to it waits for it rather than missing the details")
        let rewritten = try await store.updateSearchText()
        XCTAssertEqual(rewritten, 0, "and it is not done twice")
    }

    func testANewCacheHasNothingToBringUpToDate() async throws {
        let store = try GuideStore(path: ":memory:")
        let rewritten = try await store.updateSearchText()
        XCTAssertEqual(rewritten, 0)
        try await store.replace(try sampleServices(), broadcasting: "td")
        let later = try await store.updateSearchText()
        XCTAssertEqual(later, 0, "what replace writes is already current")
    }

    func testHidingAChannelRemovesItAndItsProgrammes() async throws {
        let store = try await loadedStore()
        try await store.setChannelPreferences(broadcasting: "td", hidden: [1025])

        let visible = try await store.channels(broadcasting: "td")
        XCTAssertEqual(visible.map(\.serviceID), [1024])
        let all = try await store.channels(broadcasting: "td", includeHidden: true)
        XCTAssertEqual(all.map(\.serviceID), [1024, 1025])
        XCTAssertEqual(all.last?.hidden, true)

        let programs = try await store.programs(broadcasting: "td", includeReferences: true)
        XCTAssertTrue(programs.allSatisfy { $0.serviceID == 1024 })
        let including = try await store.programs(broadcasting: "td", includeReferences: true, includeHidden: true)
        XCTAssertEqual(including.count, 5)

        try await store.setChannelPreferences(broadcasting: "td", hidden: [])
        let shownAgain = try await store.channels(broadcasting: "td")
        XCTAssertEqual(shownAgain.count, 2, "an empty list shows everything again")
    }

    func testChannelOrderFollowsWhatTheUserSet() async throws {
        let store = try await loadedStore()

        try await store.setChannelPreferences(broadcasting: "td", order: [1025, 1024])
        let reordered = try await store.channels(broadcasting: "td")
        XCTAssertEqual(reordered.map(\.serviceID), [1025, 1024])

        try await store.setChannelPreferences(broadcasting: "td", order: [])
        let restored = try await store.channels(broadcasting: "td")
        XCTAssertEqual(restored.map(\.serviceID), [1024, 1025], "back to the recorder's order")
    }

    func testABroadcastDayRunsFromFourToFour() async throws {
        let store = try await loadedStore()

        let range = store.dayRange(containing: jst("2026-09-14T12:00:00+09:00"))
        XCTAssertEqual(RecorderTime.format(range.start), "2026-09-14T04:00:00+09:00")
        XCTAssertEqual(RecorderTime.format(range.end), "2026-09-15T04:00:00+09:00")

        let day = try await store.day(jst("2026-09-14T12:00:00+09:00"), broadcasting: "td", serviceID: 1024)
        XCTAssertEqual(day.map(\.eventID), [14792, 14793, 14794], "the programme on the 15th belongs to that day")

        let next = try await store.day(jst("2026-09-15T22:00:00+09:00"), broadcasting: "td", serviceID: 1024)
        XCTAssertEqual(next.map(\.eventID), [14800])
    }

    /// The first day is the one on air, and until four in the morning that is yesterday's: a late-night
    /// programme at half past midnight is on the previous day's guide, and has to be on a day in the strip.
    func testTheDaysStartWithTheBroadcastDayOnAir() {
        let cases = [
            ("2026-09-23T00:30:00+09:00", "2026-09-22"),
            ("2026-09-23T03:59:00+09:00", "2026-09-22"),
            ("2026-09-23T04:00:00+09:00", "2026-09-23"),
            ("2026-09-23T12:00:00+09:00", "2026-09-23"),
        ]
        for (now, first) in cases {
            let moment = jst(now)
            let days = GuideStore.broadcastDays(from: moment)
            XCTAssertEqual(days.count, 8, now)
            XCTAssertEqual(days.map(RecorderTime.format).first, "\(first)T00:00:00+09:00", now)
            XCTAssertEqual(days.first, GuideStore.broadcastDay(containing: moment), now)
            // and the day it names is the one that has this moment in it, which is what the guide shows
            let range = GuideStore.dayRange(containing: days[0])
            XCTAssertTrue(range.start <= moment && moment < range.end, now)
            XCTAssertEqual(days.last.map { GuideStore.dayRange(containing: $0).end },
                           range.start.addingTimeInterval(8 * 86400), "eight days on end, \(now)")
        }
    }

    func testNowOnAirTakesTheChannelOrderAndKeepsReferences() async throws {
        let store = try await loadedStore()
        let onAir = try await store.nowOnAir(broadcasting: "td", at: jst("2026-09-14T05:30:00+09:00"))
        XCTAssertEqual(onAir.map(\.serviceID), [1024, 1025], "a sub-channel simulcast is on air as well")
        XCTAssertTrue(onAir.allSatisfy { $0.title == "サンプルニュース　あさの放送[字]" })

        let quiet = try await store.nowOnAir(broadcasting: "td", at: jst("2026-09-14T10:00:00+09:00"))
        XCTAssertTrue(quiet.isEmpty)
    }

    func testCountsReportWhatIsCachedAndWhen() async throws {
        let store = try await loadedStore()
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.channels, 2)
        XCTAssertEqual(counts["td"]?.programs, 4, "references are not counted as programmes")
        XCTAssertEqual(counts["td"]?.refreshed, "2026-09-14T03:00:00+09:00")
        XCTAssertEqual(counts["bs"]?.channels, 0)
        XCTAssertNil(counts["bs"]?.refreshed)
    }

    func testASchemaChangeRebuildsTheCacheButKeepsWhatTheUserSet() async throws {
        let path = try temporaryPath()
        let services = try sampleServices()

        do {
            let store = try GuideStore(path: path, schemaVersion: "1")
            try await store.replace(services, broadcasting: "td")
            try await store.setChannelPreferences(broadcasting: "td", hidden: [1025])
        }

        let upgraded = try GuideStore(path: path, schemaVersion: "2")
        let counts = try await upgraded.counts()
        XCTAssertEqual(counts["td"]?.programs, 0, "the guide is a cache and is fetched again")
        XCTAssertNil(counts["td"]?.refreshed)

        try await upgraded.replace(services, broadcasting: "td")
        let channels = try await upgraded.channels(broadcasting: "td")
        XCTAssertEqual(channels.map(\.serviceID), [1024], "the hidden channel is still hidden after the rebuild")
    }

    func testReopeningWithTheSameSchemaKeepsTheCache() async throws {
        let path = try temporaryPath()
        do {
            let store = try GuideStore(path: path)
            try await store.replace(try sampleServices(), broadcasting: "td")
        }
        let reopened = try GuideStore(path: path)
        let counts = try await reopened.counts()
        XCTAssertEqual(counts["td"]?.programs, 4)
    }

    /// An empty text left by an older build may be a read that failed, so it is thrown away once and asked
    /// about again. One read after that is the recorder saying there is no text, and stays.
    func testEmptySummariesFromBeforeAreClearedOnceAndOnlyOnce() async throws {
        let path = try temporaryPath()
        do {
            let store = try GuideStore(path: path)
            try await store.setTitleSummary("0x1", "")
            try await store.setTitleSummary("0x2", "あらすじ")
            // what a database written by an older build looks like: the rows, and no mark that they were seen to
            try Sqlite(path: path).run("DELETE FROM meta WHERE key='blank_summaries_cleared'")
        }

        let upgraded = try GuideStore(path: path)
        let cleared = try await upgraded.titleSummaries(["0x1", "0x2"])
        XCTAssertEqual(cleared, ["0x2": "あらすじ"], "the empty one is asked about again; the text is kept")

        try await upgraded.setTitleSummary("0x1", "")
        let reopened = try GuideStore(path: path)
        let kept = try await reopened.titleSummaries(["0x1"])
        XCTAssertEqual(kept, ["0x1": ""], "an empty text read now is an answer, and is not thrown away again")
    }

    /// The vectors' guide, stored and read back, tells the same fixed texts as it does handed over directly,
    /// and the store looks only at the titles asked about.
    func testFixedBlurbsAreReadFromTheCachedGuide() async throws {
        let vectors = try Vectors.load("titles.json").dictionary("duplicates")
        let guide = vectors.dictionaries("guide")
        let programs = guide.enumerated().map { index, row in
            let start = jst(row.string("start"))
            return GuideProgram(serviceID: 101, eventID: index + 1, start: start, end: start.addingTimeInterval(180),
                                title: row.string("title"), summary: row.string("summary"))
        }
        let store = try GuideStore(path: ":memory:")
        try await store.replace([GuideService(serviceID: 101, name: "ＢＳサンプル", programs: programs)],
                                broadcasting: "bs")

        let expected = Set(vectors.dictionaries("fixed_blurbs").map {
            Duplicates.Blurb(titleKey: $0.string("same_title_key"), summaryKey: $0.string("summary_key"))
        })
        let every = Set(guide.map { Series.sameTitleKey($0.string("title")) })
        let found = try await store.fixedBlurbs(among: every)
        XCTAssertEqual(found, expected)
        let others = try await store.fixedBlurbs(among: every.subtracting(expected.map(\.titleKey)))
        XCTAssertEqual(others, [], "the titles asked about, and no others")
        let nothing = try await store.fixedBlurbs(among: [])
        XCTAssertEqual(nothing, [])
    }

    func testLogosAreAttachedToTheirChannels() async throws {
        let store = try await loadedStore()
        try await store.replaceLogos([(serviceID: 1024, channelNo: 11, png: Data([0x89, 0x50, 0x4E, 0x47]))],
                                     broadcasting: "td")
        let channels = try await store.channels(broadcasting: "td")
        XCTAssertEqual(channels.first?.logo, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertNil(channels.last?.logo, "a channel whose logo the recorder has not received yet")
    }
}
