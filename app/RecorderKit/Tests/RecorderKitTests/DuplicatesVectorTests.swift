import XCTest
@testable import RecorderKit

/// Which copies of a broadcast to keep, and why. The ranking is easy to get subtly wrong, so it is pinned by
/// vectors generated from the server's own code.
final class DuplicatesVectorTests: XCTestCase {
    private func sample() throws -> (titles: [RecordedTitle], summaries: [String: String], vectors: [String: Any]) {
        let vectors = try Vectors.load("titles.json").dictionary("duplicates")
        var titles: [RecordedTitle] = []
        var summaries: [String: String] = [:]
        for row in vectors.dictionaries("titles") {
            titles.append(RecordedTitle(
                id: row.string("id"), title: row.string("title"),
                start: RecorderTime.parse(row.string("start"))!, durationSec: row.int("duration_sec") ?? 0,
                broadcastingType: 2, serviceID: 1024, qualityCode: row.int("quality_code") ?? 230,
                protected: row.bool("protected"), isNew: row.bool("is_new"),
                recording: row.bool("recording"), destination: "HDD",
                sizeMB: row.int("size_mb"), genreCode: 48, lastPlayed: nil, resumeSec: row.int("resume_sec")))
            summaries[row.string("id")] = row.string("summary")
        }
        return (titles, summaries, vectors)
    }

    /// The guide the sets are read against, and the titles whose text it shows on more than one day.
    private func guide() throws -> [(title: String, summary: String, start: Date)] {
        try Vectors.load("titles.json").dictionary("duplicates").dictionaries("guide").map { row in
            (row.string("title"), row.string("summary"), try XCTUnwrap(RecorderTime.parse(row.string("start"))))
        }
    }

    private func fixedBlurbs() throws -> Set<Duplicates.Blurb> {
        Duplicates.fixedBlurbs(in: try guide())
    }

    private func sampleSets() throws -> [DuplicateSet] {
        let (titles, summaries, _) = try sample()
        return Duplicates.sets(candidates: Duplicates.candidates(titles), summaries: summaries,
                               fixedBlurbs: try fixedBlurbs())
    }

    func testCandidatesMatchTheVectors() throws {
        let (titles, _, vectors) = try sample()
        let candidates = Duplicates.candidates(titles)
        XCTAssertEqual(candidates.map { $0.map(\.id) }, vectors.list("candidates") as? [[String]])
    }

    func testFixedBlurbsMatchTheVectors() throws {
        let expected = try Vectors.load("titles.json").dictionary("duplicates").dictionaries("fixed_blurbs").map {
            Duplicates.Blurb(titleKey: $0.string("same_title_key"), summaryKey: $0.string("summary_key"))
        }
        XCTAssertEqual(try fixedBlurbs(), Set(expected))
        XCTAssertFalse(expected.isEmpty)
    }

    func testSetsMatchTheVectors() throws {
        let (_, _, vectors) = try sample()
        let sets = try sampleSets()
        let expected = vectors.dictionaries("sets")

        XCTAssertEqual(sets.count, expected.count)
        for (set, row) in zip(sets, expected) {
            XCTAssertEqual(set.title, row.string("title"))
            XCTAssertEqual(set.confidence.rawValue, row.string("confidence"), set.title)
            XCTAssertEqual(set.sizeMB, row.int("size_mb"), set.title)
            XCTAssertEqual(set.items.map(\.id), row.list("items") as? [String], set.title)
            XCTAssertEqual(set.keep, row.string("keep"), set.title)
            XCTAssertEqual(set.suggestDelete, row.list("suggest_delete") as? [String], set.title)
            XCTAssertEqual(set.reasons, row.dictionary("reasons") as? [String: String], set.title)
        }
    }

    func testARecordingWhoseTextDiffersIsNotACopy() throws {
        let sets = try sampleSets()
        let everyItem = sets.flatMap { $0.items.map(\.id) }
        XCTAssertFalse(everyItem.contains("0xd3"), "its programme text is a different one")
        XCTAssertFalse(everyItem.contains("0xd4"), "half an hour longer, so not the same broadcast")
    }

    func testWatchedPartwayOutranksTheBetterRecordingMode() throws {
        let sets = try sampleSets()
        let set = try XCTUnwrap(sets.first { $0.confidence == .high })
        XCTAssertEqual(set.keep, "0xd2")
        XCTAssertEqual(set.reasons["0xd2"], "視聴途中")
    }

    /// Two recordings with no text agree on the title and the length alone, which is not enough to tick one
    /// of them for deletion on the reader's behalf. Nor is a text the programme carries every time.
    func testOnlyASetConfirmedByItsTextComesUpTicked() throws {
        let sets = try sampleSets()
        XCTAssertEqual(Duplicates.picks(for: sets, shown: [], picked: []), ["0xd1", "0xf1"])
    }

    /// A daily show whose text the guide repeats, and a mini anime whose text is a line long, agree on their
    /// text without that making them the same broadcast. The daily show is told only by the guide: without
    /// it, its text is long enough to pass for an episode's.
    func testATextTheProgrammeCarriesEveryTimeDoesNotConfirmACopy() throws {
        let sets = try sampleSets()
        let daily = try XCTUnwrap(sets.first { $0.items.contains { $0.id == "0xb1" } })
        let mini = try XCTUnwrap(sets.first { $0.items.contains { $0.id == "0xa1" } })
        XCTAssertEqual(daily.confidence, .boilerplate)
        XCTAssertEqual(mini.confidence, .boilerplate)
        XCTAssertEqual(daily.confidence.label, "説明文が毎回同じ（内容は未確認）")

        let (titles, summaries, _) = try sample()
        let withoutGuide = Duplicates.sets(candidates: Duplicates.candidates(titles), summaries: summaries)
        XCTAssertEqual(withoutGuide.first { $0.items.contains { $0.id == "0xb1" } }?.confidence, .high)
        XCTAssertEqual(withoutGuide.first { $0.items.contains { $0.id == "0xa1" } }?.confidence, .boilerplate)
    }

    /// Twice in one night, either side of midnight, is one broadcast day: a showing again, not a text used
    /// every day. And a title the guide has on two days with two different texts has no fixed one.
    func testOnlyATextOnTwoBroadcastDaysIsAFixedOne() throws {
        let fixed = try fixedBlurbs()
        XCTAssertFalse(fixed.contains { $0.titleKey == Series.sameTitleKey("深夜のサンプル") })
        XCTAssertFalse(fixed.contains { $0.titleKey == Series.sameTitleKey("刑事サンプル（４８）「幻の宝石」") })
        XCTAssertEqual(Duplicates.fixedBlurbs(in: try guide(), among: [Series.sameTitleKey("深夜のサンプル")]), [],
                       "narrowed to one title, the others are not looked at")
        XCTAssertEqual(Duplicates.fixedBlurbs(in: try guide(), among: [Series.sameTitleKey("サンプル体操")]), fixed)
    }

    /// Deleting or protecting something elsewhere builds the sets again. One still made of the same
    /// recordings keeps what the reader chose -- here the other copy of the first, and one of the pair with no
    /// text -- while a recording that can no longer be deleted drops out.
    func testASetStillOnScreenKeepsTheReadersTicks() throws {
        let sets = try sampleSets()
        let picked: Set<String> = ["0xd2", "0xe1", "0xf2"]
        XCTAssertEqual(Duplicates.picks(for: sets, shown: sets, picked: picked), ["0xd2", "0xe1"],
                       "0xf2 is still being recorded, and 0xf1 was unticked")

        let changed = sets.filter { $0.keep != "0xd2" }
        XCTAssertEqual(Duplicates.picks(for: sets, shown: changed, picked: picked), ["0xd1", "0xe1"],
                       "a set the reader has not seen in this shape is ticked as suggested")
    }

    /// A scan run before the guide had the daily show's second day called it the same broadcast and ticked a
    /// copy. Once the guide says its text is a fixed one, the tick goes with the confidence it came from.
    func testASetFoundToCarryAFixedTextLosesItsTicks() throws {
        let (titles, summaries, _) = try sample()
        let before = Duplicates.sets(candidates: Duplicates.candidates(titles), summaries: summaries)
        let ticked = Duplicates.picks(for: before, shown: [], picked: [])
        XCTAssertTrue(ticked.contains("0xb2"), "without the guide, the daily show looked confirmed")

        let after = try sampleSets()
        let picks = Duplicates.picks(for: after, shown: before, picked: ticked)
        XCTAssertFalse(picks.contains("0xb2"))
        XCTAssertEqual(picks, ["0xd1", "0xf1"], "the sets that are as sure as before keep their ticks")
    }

    func testASetThatWouldLoseEveryCopyIsNamed() throws {
        let sets = try sampleSets()
        let everything: Set<String> = ["0xd1", "0xd2", "0xe1", "0xf1", "0xf2"]
        XCTAssertEqual(Duplicates.emptied(sets, picked: everything).map(\.keep), ["0xd2"],
                       "the recorder keeps 0xf2 whatever is ticked, and 0xe2 is not ticked")
        XCTAssertTrue(Duplicates.emptied(sets, picked: ["0xd1", "0xf1", "0xe2"]).isEmpty)
    }
}
