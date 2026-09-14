import XCTest
@testable import RecorderKit

/// The watch states and the grouping are derived from the recorder's fields, so they are pinned by vectors
/// generated from the server's own code.
final class TitlesVectorTests: XCTestCase {
    private func sample() throws -> (titles: [RecordedTitle], vectors: [String: Any]) {
        let vectors = try Vectors.load("titles.json")
        let titles = vectors.dictionaries("titles").map { row in
            RecordedTitle(id: row.string("id"), title: row.string("title"),
                          start: RecorderTime.parse(row.string("start"))!,
                          durationSec: row.int("duration_sec") ?? 0, broadcastingType: 2, serviceID: 1024,
                          qualityCode: 230, protected: row.bool("protected"), isNew: row.bool("is_new"),
                          destination: "HDD", sizeMB: row.int("size_mb"), genreCode: row.int("genre_code"),
                          lastPlayed: nil, resumeSec: row.int("resume_sec"))
        }
        return (titles, vectors)
    }

    func testWatchStatesAndSeriesNamesMatchTheVectors() throws {
        let (titles, vectors) = try sample()
        let rows = vectors.dictionaries("titles")
        XCTAssertEqual(titles.count, rows.count)
        for (title, row) in zip(titles, rows) {
            let expected = row.dictionary("expected")
            XCTAssertEqual(title.watchState.rawValue, expected.string("watch_state"), title.title)
            XCTAssertEqual(title.seriesKey, expected.string("series_key"), title.title)
            XCTAssertEqual(title.seriesName, expected.string("series_name"), title.title)
        }
    }

    func testGroupingMatchesTheVectors() throws {
        let (titles, vectors) = try sample()
        assertGroups(TitleGroup.group(titles), match: vectors.dictionaries("groups"))
    }

    func testGroupingByGenreMatchesTheVectors() throws {
        let (titles, vectors) = try sample()
        let filtered = vectors.dictionary("groups_drama_only")
        let genre = try XCTUnwrap(filtered.int("genre"))
        assertGroups(TitleGroup.group(titles, genre: genre), match: filtered.dictionaries("groups"))
    }

    func testTheCommonestSpellingNamesTheGroupAndTheFirstWinsATie() throws {
        let (titles, _) = try sample()
        let groups = TitleGroup.group(titles)
        let drama = try XCTUnwrap(groups.first { $0.count == 3 })
        XCTAssertEqual(drama.name, "ドラマＡＢＣ", "two full-width spellings against one half-width")
        let news = try XCTUnwrap(groups.first { $0.count == 2 })
        XCTAssertEqual(news.name, "ニュース７", "one each, so the first one seen")
    }

    private func assertGroups(_ groups: [TitleGroup], match expected: [[String: Any]]) {
        XCTAssertEqual(groups.count, expected.count)
        for (group, row) in zip(groups, expected) {
            XCTAssertEqual(group.key, row.string("key"))
            XCTAssertEqual(group.name, row.string("name"), group.key)
            XCTAssertEqual(group.count, row.int("count"), group.key)
            XCTAssertEqual(group.sizeMB, row.int("size_mb"), group.key)
            XCTAssertEqual(RecorderTime.format(group.latest), row.string("latest"), group.key)
            XCTAssertEqual(RecorderTime.format(group.earliest), row.string("earliest"), group.key)
            XCTAssertEqual(group.protectedCount, row.int("protected_count"), group.key)
            XCTAssertEqual(group.newCount, row.int("new_count"), group.key)
        }
    }
}
