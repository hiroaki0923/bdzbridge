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
            expectEqual(try await store.search(query).hits.map(\.program.title), expected, "searching for \(query)")
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

        expectEqual(try await store.counts()["td"], before["td"], "nothing was thrown away or fetched")
        let channels = try await store.channels(broadcasting: "td")
        XCTAssertEqual(channels.map(\.serviceID), [1024], "what the reader set is untouched")

        expectEqual(try await store.updateSearchText(), 0)
        let reopened = try GuideStore(path: path)
        expectEqual(try await reopened.updateSearchText(), 0, "the mark is kept in the database, so it is done once")
    }

    func testASearchBringsAnOldCacheUpToDateItself() async throws {
        let path = try temporaryPath()
        try await oldCache(at: path)

        let store = try GuideStore(path: path)
        expectEqual(try await store.search("詳細テキスト", broadcasting: "td").hits.map(\.program.eventID), [14792],
                    "a search made before the app got round to it waits for it rather than missing the details")
        expectEqual(try await store.updateSearchText(), 0, "and it is not done twice")
    }

    func testANewCacheHasNothingToBringUpToDate() async throws {
        let store = try GuideStore(path: ":memory:")
        expectEqual(try await store.updateSearchText(), 0)
        try await store.replace(try sampleServices(), broadcasting: "td")
        expectEqual(try await store.updateSearchText(), 0, "what replace writes is already current")
    }

    func testHidingAChannelRemovesItAndItsProgrammes() async throws {
        let store = try await loadedStore()
        try await store.setChannelPreferences(broadcasting: "td", hidden: [1025])

        expectEqual(try await store.channels(broadcasting: "td").map(\.serviceID), [1024])
        let all = try await store.channels(broadcasting: "td", includeHidden: true)
        XCTAssertEqual(all.map(\.serviceID), [1024, 1025])
        XCTAssertEqual(all.last?.hidden, true)

        let programs = try await store.programs(broadcasting: "td", includeReferences: true)
        XCTAssertTrue(programs.allSatisfy { $0.serviceID == 1024 })
        let including = try await store.programs(broadcasting: "td", includeReferences: true, includeHidden: true)
        XCTAssertEqual(including.count, 5)

        try await store.setChannelPreferences(broadcasting: "td", hidden: [])
        expectEqual(try await store.channels(broadcasting: "td").count, 2, "an empty list shows everything again")
    }

    func testChannelOrderFollowsWhatTheUserSet() async throws {
        let store = try await loadedStore()

        try await store.setChannelPreferences(broadcasting: "td", order: [1025, 1024])
        expectEqual(try await store.channels(broadcasting: "td").map(\.serviceID), [1025, 1024])

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

        expectTrue(try await store.nowOnAir(broadcasting: "td", at: jst("2026-09-14T10:00:00+09:00")).isEmpty)
    }

    func testCountsReportWhatIsCachedAndWhen() async throws {
        let store = try await loadedStore()
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.channels, 2)
        XCTAssertEqual(counts["td"]?.programs, 4, "references are not counted as programmes")
        XCTAssertEqual(counts["td"]?.refreshed, "2026-09-14T03:00:00+09:00")
        XCTAssertEqual(counts["td"]?.checked, "2026-09-14T03:00:00+09:00", "a type fetched is a type answered")
        XCTAssertEqual(counts["bs"]?.channels, 0)
        XCTAssertNil(counts["bs"]?.refreshed)
        XCTAssertNil(counts["bs"]?.lastAnswered, "never asked for")
    }

    /// A type the recorder has no file for is marked as answered, so that it is not asked for again until
    /// the next rebuild, and what the cache holds for it is left alone.
    func testATypeWithNoGuideIsMarkedAnsweredAndKeepsItsCache() async throws {
        let store = try await loadedStore()
        let later = jst("2026-09-15T03:00:00+09:00")
        try await store.noteNoGuide(broadcasting: "td", at: later)
        try await store.noteNoGuide(broadcasting: "bs4k", at: later)

        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.programs, 4, "nothing is thrown away")
        XCTAssertEqual(counts["td"]?.refreshed, "2026-09-14T03:00:00+09:00", "and the guide is as old as it was")
        XCTAssertEqual(counts["td"]?.lastAnswered, later)
        XCTAssertEqual(counts["bs4k"]?.programs, 0)
        XCTAssertNil(counts["bs4k"]?.refreshed)
        XCTAssertEqual(counts["bs4k"]?.lastAnswered, later)
    }

    /// A cache written before the mark was kept goes by when it was refreshed, rather than counting every type
    /// as never asked for and fetching them all again.
    func testACacheFromBeforeTheMarkGoesByWhenItWasRefreshed() async throws {
        let path = try temporaryPath()
        do {
            let store = try GuideStore(path: path)
            try await store.replace(try sampleServices(), broadcasting: "td", at: jst("2026-09-14T03:00:00+09:00"))
        }
        try Sqlite(path: path).run("DELETE FROM meta WHERE key LIKE 'epg_checked:%'")

        let counts = try await GuideStore(path: path).counts()
        XCTAssertNil(counts["td"]?.checked)
        XCTAssertEqual(counts["td"]?.lastAnswered, jst("2026-09-14T03:00:00+09:00"))
    }

    /// Counting a type's programmes, asked each time the day changes, is answered from an index rather than by
    /// reading every programme -- and a cache made before the index gets it when it is next opened.
    func testCountsAreAnsweredFromAnIndexWhichAnOldCacheGetsOnOpening() async throws {
        let path = try temporaryPath()
        do {
            let store = try GuideStore(path: path)
            try await store.replace(try sampleServices(), broadcasting: "td")
        }
        let db = try Sqlite(path: path)
        try db.run("DROP INDEX ix_programs_ref")

        _ = try GuideStore(path: path)
        let indexes = try db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='programs'") {
            $0.string("name")
        }
        XCTAssertTrue(indexes.contains("ix_programs_ref"), "\(indexes)")
        let plan = try db.query("EXPLAIN QUERY PLAN SELECT COUNT(*) FROM programs WHERE bt=? AND ref_event_id IS NULL",
                                ["td"]) { $0.string("detail") }
        XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX ix_programs_ref") }, "\(plan)")
    }

    /// The overnight run and the screens each open the file, and can write at once. The second waits for the
    /// first rather than failing with "database is locked".
    func testAWriteWaitsForAnotherConnectionsWriteRatherThanFailing() throws {
        let path = try temporaryPath()
        let holder = Holder(try Sqlite(path: path))
        let waiter = try Sqlite(path: path)
        try holder.db.execute("CREATE TABLE t (x INTEGER)")
        try holder.db.execute("BEGIN IMMEDIATE")
        try holder.db.run("INSERT INTO t VALUES (1)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? holder.db.execute("COMMIT")
        }

        let started = Date()
        try waiter.run("INSERT INTO t VALUES (2)")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2, "it waited for the other write")
        XCTAssertEqual(try waiter.count("SELECT COUNT(*) FROM t"), 2)
    }

    /// Lets a connection be committed from another thread, which SQLite allows (it is opened fully mutexed).
    private final class Holder: @unchecked Sendable {
        let db: Sqlite
        init(_ db: Sqlite) { self.db = db }
    }

    /// A full disk is the reader's to put right, so it is said in words they can use, with SQLite's code kept.
    func testAFullDiskIsExplainedAndKeepsItsCode() throws {
        let db = try Sqlite(path: try temporaryPath())
        try db.execute("CREATE TABLE t (x BLOB)")
        let pages = try db.count("PRAGMA page_count")
        try db.execute("PRAGMA max_page_count=\(pages)")
        do {
            try db.run("INSERT INTO t VALUES (?)", [.blob(Data(count: 64 * 1024))])
            XCTFail("there is no room for it")
        } catch let error as SqliteError {
            XCTAssertEqual(error.primaryCode, 13, "SQLITE_FULL")
            XCTAssertTrue(error.explanation.contains("空き容量"), error.explanation)
            XCTAssertTrue(error.explanation.hasSuffix("(SQLite 13)"), error.explanation)
            XCTAssertEqual("\(error)", error.explanation, "what the screens interpolate is the explanation")
            XCTAssertTrue(error.detail.contains("INSERT INTO t"), "the statement is kept for a log")
        }
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
        expectEqual(try await reopened.counts()["td"]?.programs, 4)
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

    // MARK: - whose cache it is

    /// Two recorders, as each says who it is. Sony's OUI and the rest zeroed, with a last digit of their own.
    private func recorder(_ last: Int, host: String = "192.0.2.10") -> RecorderDescription {
        RecorderDescription(host: host, port: 64220, friendlyName: "サンプルレコーダー \(last)", product: "BDZ",
                            model: "BDZ-SAMPLE", udn: "uuid:00000000-0000-0000-0000-f84e1700000\(last)",
                            epgCapable: true, location: "http://\(host):64220/description.xml", via: "manual")
    }

    private func waiting() -> PendingReservation {
        PendingReservation(request: ReservationRequest(title: "サンプル番組", start: jst("2026-09-20T21:00:00+09:00"),
                                                       durationSec: 3600, repeatCode: "1", broadcastingType: 2,
                                                       serviceID: 0x428, qualityCode: 240, eventID: 0x311f),
                           serviceName: "サンプルテレビ")
    }

    /// A cache with something of everything a recorder leaves in it, and of what the reader does: a guide
    /// with its marks and a logo, a type the recorder had no file for, a recording's text, a channel hidden
    /// and a reservation waiting.
    private func usedStore() async throws -> GuideStore {
        let store = try await loadedStore()
        try await store.replaceLogos([(serviceID: 1024, channelNo: 1, png: Data([1, 2, 3]))], broadcasting: "td")
        try await store.noteNoGuide(broadcasting: "bs4k", at: jst("2026-09-14T03:00:00+09:00"))
        try await store.setTitleSummary("0x0000010000000001", "港町にもどった主人公が、古い灯台の記録を読みはじめる。")
        try await store.setChannelPreferences(broadcasting: "td", hidden: [1025])
        try await store.queue(waiting())
        return store
    }

    /// The address is only where to knock: the cache is the recorder's that filled it, known by its UDN. The
    /// first to answer is written down as its owner, and the same one answering again -- at this address or
    /// another -- finds everything as it left it.
    func testTheFirstRecorderToAnswerOwnsTheCacheAndTheSameOneKeepsIt() async throws {
        let store = try await usedStore()
        expectNil(try await store.owner())

        expectEqual(try await store.claim(for: recorder(1), holdingTheQueueWith: "別のレコーダー"), .first)
        expectEqual(try await store.owner(), "uuid:00000000-0000-0000-0000-f84e17000001")

        let moved = try await store.claim(for: recorder(1, host: "192.0.2.11"), holdingTheQueueWith: "別のレコーダー")
        XCTAssertEqual(moved, .same)
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.programs, 4)
        XCTAssertEqual(counts["td"]?.refreshed, "2026-09-14T03:00:00+09:00")
        XCTAssertEqual(counts["bs4k"]?.checked, "2026-09-14T03:00:00+09:00")
        let texts = try await store.titleSummaries(["0x0000010000000001"])
        XCTAssertEqual(texts.count, 1, "the texts take one request a recording to gather again")
        let queue = try await store.pendingReservations()
        XCTAssertEqual(queue.map(\.problem), [nil], "the queue goes to it as before")
    }

    /// Another recorder answering takes the cache, and what the other one left in it goes in the same
    /// transaction: the programme texts, which are kept by a recording's number alone and each recorder
    /// numbers its own; the guide with its logos; and the marks that say a type need not be fetched, without
    /// which the new one would not be asked for its guide until the next night. The reader's own stays --
    /// which channels are hidden -- and so does the queue, held with a reason rather than sent to a recorder
    /// it was not made for.
    func testAnotherRecorderTakesTheCacheAndWhatTheOtherLeftGoes() async throws {
        let store = try await usedStore()
        try await store.claim(for: recorder(1))
        // One the first recorder had refused, with its reason, beside the one still waiting.
        var refused = waiting()
        refused.request.eventID = 0x3120
        try await store.queue(refused)
        try await store.setPendingProblem(refused.id, "契約していないチャンネルです")

        let asked = try await store.recognises(recorder(2))
        XCTAssertEqual(asked, .another)
        let untouched = try await store.titleSummaries(["0x0000010000000001"])
        XCTAssertEqual(untouched.count, 1, "asking who it is changes nothing")
        expectEqual(try await store.owner(), "uuid:00000000-0000-0000-0000-f84e17000001")

        let taken = try await store.claim(for: recorder(2), holdingTheQueueWith: "別のレコーダーが応答しました")
        XCTAssertEqual(taken, .another)
        expectEqual(try await store.owner(), "uuid:00000000-0000-0000-0000-f84e17000002")

        let texts = try await store.titleSummaries(["0x0000010000000001"])
        XCTAssertTrue(texts.isEmpty, "another recorder's text would confirm a duplicate on this one")
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.programs, 0)
        XCTAssertEqual(counts["td"]?.channels, 0)
        XCTAssertNil(counts["td"]?.lastAnswered, "the mark would keep this recorder from being asked for its guide")
        XCTAssertNil(counts["bs4k"]?.lastAnswered, "nor has this one been asked for the type the other lacked")
        XCTAssertEqual(GuideRefresh.staleTypes(counts), GuideRefresh.broadcastingTypes)

        // The reader's own arrangement is still there when the guide comes back, and the other's logo is not.
        try await store.replace(try sampleServices(), broadcasting: "td")
        let channels = try await store.channels(broadcasting: "td")
        XCTAssertEqual(channels.map(\.serviceID), [1024], "the hidden channel is still hidden")
        XCTAssertNil(channels.first?.logo)

        // Both rows, the one the first recorder had refused among them: what it said of a reservation is
        // nothing this one has said, and the line that counts what is held counts by this reason.
        let queue = try await store.pendingReservations()
        XCTAssertEqual(queue.map(\.problem), ["別のレコーダーが応答しました", "別のレコーダーが応答しました"])
        XCTAssertFalse(PendingQueue.hasSomethingToSend(queue, now: jst("2026-09-20T20:00:00+09:00")),
                       "held until the reader asks, as one the recorder refused is")

        let again = try await store.claim(for: recorder(2), holdingTheQueueWith: "別のレコーダーが応答しました")
        XCTAssertEqual(again, .same, "it is the one known now")
    }

    /// There and back: the first recorder taking the cache again finds none of what it left, and what waits
    /// stays held, whichever of the two it was made for -- a row does not say. The reader sends each again.
    func testGoingBackToTheFirstRecorderIsATakeoverToo() async throws {
        let store = try await usedStore()
        try await store.claim(for: recorder(1))
        try await store.claim(for: recorder(2), holdingTheQueueWith: "別のレコーダー")
        var later = waiting()
        later.request.eventID = 0x3120
        try await store.queue(later)

        expectEqual(try await store.claim(for: recorder(1), holdingTheQueueWith: "別のレコーダー"), .another)
        expectEqual(try await store.owner(), "uuid:00000000-0000-0000-0000-f84e17000001")
        expectEqual(try await store.pendingReservations().map(\.problem), ["別のレコーダー", "別のレコーダー"])
        expectTrue(try await store.titleSummaries(["0x0000010000000001"]).isEmpty)
    }

    /// With no reason to hold it for, the queue is left as it was, and goes to whichever recorder answers.
    func testTheQueueIsHeldOnlyWhenAReasonIsGiven() async throws {
        let store = try await usedStore()
        try await store.claim(for: recorder(1))
        try await store.claim(for: recorder(2))
        expectEqual(try await store.pendingReservations().map(\.problem), [nil])
    }

    /// A cache filled before its owner was written down does not say whose it is, and nothing in it is
    /// guessed at: whoever answers first is put down as the owner and finds it as it is. For nearly every
    /// phone that is the one recorder it has ever had, and its texts and its queue are not to be lost to a
    /// guess on the day the app is updated.
    func testACacheFromBeforeItsOwnerWasWrittenDownIsTheFirstAnswerers() async throws {
        let store = try await usedStore()

        expectEqual(try await store.recognises(recorder(2)), .first)
        expectEqual(try await store.claim(for: recorder(2), holdingTheQueueWith: "別のレコーダー"), .first)
        expectEqual(try await store.titleSummaries(["0x0000010000000001"]).count, 1)
        expectEqual(try await store.pendingReservations().map(\.problem), [nil])
        expectEqual(try await store.owner(), "uuid:00000000-0000-0000-0000-f84e17000002")
    }

    /// Unless the caller knows better. The session keeps which recorder its lists were read from, and when
    /// another one answers it, a cache with no owner written is that other one's all the same: its owner
    /// could not be put down the first time, or it is from before owners were kept. Left as the first
    /// answerer's, what waited for the last recorder went to this one, with the last one's texts kept under
    /// this one's numbers. An owner that is written down is what counts, whatever the caller says.
    func testACacheWithNoOwnerIsAnothersWhenTheCallerKnowsTheRecorderToBeAnother() async throws {
        let store = try await usedStore()

        let taken = try await store.claim(for: recorder(2), holdingTheQueueWith: "別のレコーダー",
                                          knownToBeAnother: true)
        XCTAssertEqual(taken, .another)
        expectTrue(try await store.titleSummaries(["0x0000010000000001"]).isEmpty)
        expectEqual(try await store.pendingReservations().map(\.problem), ["別のレコーダー"])
        let owner = try await store.owner()
        XCTAssertEqual(owner, "uuid:00000000-0000-0000-0000-f84e17000002")

        try await store.setTitleSummary("0x0000010000000001", "あらすじ")
        let known = try await store.claim(for: recorder(2), holdingTheQueueWith: "別のレコーダー",
                                          knownToBeAnother: true)
        XCTAssertEqual(known, .same, "the owner written down is what counts")
        expectEqual(try await store.titleSummaries(["0x0000010000000001"]).count, 1)

        // One that does not say which it is has no name to be put down under, and takes nothing over.
        var nameless = recorder(3)
        nameless.udn = ""
        let unowned = try await usedStore()
        let nobody = try await unowned.claim(for: nameless, holdingTheQueueWith: "別のレコーダー",
                                             knownToBeAnother: true)
        XCTAssertEqual(nobody, .first)
        expectEqual(try await unowned.titleSummaries(["0x0000010000000001"]).count, 1)
        expectNil(try await unowned.owner())
    }

    /// A recorder that gives no UDN cannot be told from any other: it is taken for the one known, and is not
    /// written down as anybody.
    func testARecorderThatDoesNotSayWhichItIsLeavesTheCacheAsItIs() async throws {
        var nameless = recorder(1)
        nameless.udn = ""
        let store = try await usedStore()

        expectEqual(try await store.claim(for: nameless, holdingTheQueueWith: "別のレコーダー"), .first)
        expectNil(try await store.owner())

        try await store.claim(for: recorder(1))
        expectEqual(try await store.claim(for: nameless, holdingTheQueueWith: "別のレコーダー"), .same)
        expectEqual(try await store.owner(), "uuid:00000000-0000-0000-0000-f84e17000001")
        expectEqual(try await store.titleSummaries(["0x0000010000000001"]).count, 1)
    }

    /// The recorder the cache is of is nearly every answer there is, and knowing it again writes nothing. A
    /// write would wait behind whoever else is writing to the cache -- the overnight run storing a guide, the
    /// queue being sent from another connection -- for as long as the busy timeout, and then fail: the connect
    /// held up for five seconds, and what was waiting not sent by it.
    func testTheOwnerAnsweringAgainIsKnownWithoutWaitingForAWrite() async throws {
        let path = try temporaryPath()
        let store = try GuideStore(path: path)
        try await store.claim(for: recorder(1))
        try await store.setTitleSummary("0x0000010000000001", "あらすじ")

        let other = try Sqlite(path: path)
        try other.execute("BEGIN IMMEDIATE")
        defer { try? other.execute("ROLLBACK") }
        let began = Date()
        let known = try await store.claim(for: recorder(1, host: "192.0.2.11"), holdingTheQueueWith: "別のレコーダー")
        let asked = try await store.recognises(recorder(1))
        XCTAssertEqual(known, .same)
        XCTAssertEqual(asked, .same)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "it waited for the other connection's write")
    }

    /// Who it is is asked again once the write has its turn. Another connection can put an owner down between
    /// the first look and the write -- here it holds the cache while it does, so that the claim is waiting
    /// behind it -- and the answer of the first look, that nobody owned the cache, would then name this
    /// recorder the owner of what the other had just been given.
    func testAClaimThatWaitedForAnotherWriterLooksAgainAtWhoseTheCacheIs() async throws {
        let path = try temporaryPath()
        let store = try GuideStore(path: path)
        try await store.setTitleSummary("0x0000010000000001", "あらすじ")
        try await store.queue(waiting())

        let other = try Sqlite(path: path)
        try other.execute("BEGIN IMMEDIATE")
        let second = recorder(2)
        async let claimed = store.claim(for: second, holdingTheQueueWith: "別のレコーダー")
        // Long enough for the claim to have looked and to be waiting for its write; should it not have
        // looked yet, it finds the owner on its first look and the outcome is the same.
        try await Task.sleep(for: .milliseconds(300))
        try other.execute("INSERT OR REPLACE INTO meta (key, value) VALUES "
            + "('recorder_udn', 'uuid:00000000-0000-0000-0000-f84e17000001')")
        try other.execute("COMMIT")

        let who = try await claimed
        XCTAssertEqual(who, .another, "taken for the first to answer, on a look made before the other's write")
        expectTrue(try await store.titleSummaries(["0x0000010000000001"]).isEmpty)
        expectEqual(try await store.pendingReservations().map(\.problem), ["別のレコーダー"])
        expectEqual(try await store.owner(), "uuid:00000000-0000-0000-0000-f84e17000002")
    }

    /// A UDN is a UUID, which reads the same in either case. A recorder that spelled its own another way --
    /// after an update, say -- is the one known, and nothing kept of it goes.
    func testTheOwnerIsKnownHoweverItsUDNIsCased() async throws {
        let store = try await usedStore()
        try await store.claim(for: recorder(1))
        var shouting = recorder(1)
        shouting.udn = shouting.udn.uppercased()

        expectEqual(try await store.recognises(shouting), .same)
        expectEqual(try await store.claim(for: shouting, holdingTheQueueWith: "別のレコーダー"), .same)
        expectEqual(try await store.titleSummaries(["0x0000010000000001"]).count, 1)
        expectEqual(try await store.pendingReservations().map(\.problem), [nil])
        let owner = try await store.owner()
        XCTAssertEqual(owner, "uuid:00000000-0000-0000-0000-f84e17000001", "written as it was first given")
    }

    /// Whose cache it is is kept with the cache: across a launch, and across a schema change that throws the
    /// guide away, since the programme texts it also covers are not thrown away with it.
    func testTheOwnerOutlivesReopeningAndASchemaChange() async throws {
        let path = try temporaryPath()
        do {
            let store = try GuideStore(path: path, schemaVersion: "1")
            try await store.claim(for: recorder(1))
            try await store.setTitleSummary("0x0000010000000001", "あらすじ")
        }
        let reopened = try GuideStore(path: path, schemaVersion: "1")
        expectEqual(try await reopened.recognises(recorder(1)), .same)

        let upgraded = try GuideStore(path: path, schemaVersion: "2")
        expectEqual(try await upgraded.claim(for: recorder(2)), .another)
        expectTrue(try await upgraded.titleSummaries(["0x0000010000000001"]).isEmpty)
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
        expectEqual(try await store.fixedBlurbs(among: every), expected)
        let others = try await store.fixedBlurbs(among: every.subtracting(expected.map(\.titleKey)))
        XCTAssertEqual(others, [], "the titles asked about, and no others")
        expectEqual(try await store.fixedBlurbs(among: []), [])
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
