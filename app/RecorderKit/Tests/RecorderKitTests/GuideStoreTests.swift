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
            let found = try await store.programs(broadcasting: "td", query: query)
            XCTAssertEqual(found.map(\.eventID), [14794], "searching for \(query)")
        }
        let description = try await store.programs(broadcasting: "td", query: "朝のニュース")
        XCTAssertEqual(description.map(\.eventID), [14792], "the short description is searched too")
        let nothing = try await store.programs(broadcasting: "td", query: "そんな番組はない")
        XCTAssertTrue(nothing.isEmpty)
    }

    func testSearchReachesReferencesThroughTheirParent() async throws {
        let store = try await loadedStore()
        let found = try await store.programs(broadcasting: "td", query: "あさの放送", includeReferences: true)
        XCTAssertEqual(found.map(\.serviceID), [1024, 1025])
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

    func testLogosAreAttachedToTheirChannels() async throws {
        let store = try await loadedStore()
        try await store.replaceLogos([(serviceID: 1024, channelNo: 11, png: Data([0x89, 0x50, 0x4E, 0x47]))],
                                     broadcasting: "td")
        let channels = try await store.channels(broadcasting: "td")
        XCTAssertEqual(channels.first?.logo, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertNil(channels.last?.logo, "a channel whose logo the recorder has not received yet")
    }
}
