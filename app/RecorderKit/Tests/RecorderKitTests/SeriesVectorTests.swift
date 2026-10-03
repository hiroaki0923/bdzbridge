import XCTest
@testable import RecorderKit

/// Every case the server's heuristic was tuned on, taken from real recordings.
final class SeriesVectorTests: XCTestCase {
    /// Among the cases: one programme's episodes share a key however it is spelled (日曜劇場「SAMPLE」 第1話 and
    /// 日曜劇場「ＳＡＭＰＬＥ」第１８話…), a showing again shares its episode's same-title key (ドラマＡ　第３話[再] and
    /// ドラマA 第3話), and the next episode has one of its own (ドラマＡ　第４話).
    func testProgrammeNamesAndKeysMatchTheVectors() throws {
        let cases = try Vectors.load("series.json").dictionaries("titles")
        XCTAssertGreaterThan(cases.count, 30)
        for testCase in cases {
            let title = testCase.string("title")
            XCTAssertEqual(Series.name(title), testCase.string("series_name"), "name of \(title)")
            XCTAssertEqual(Series.key(title), testCase.string("series_key"), "key of \(title)")
            XCTAssertEqual(Series.sameTitleKey(title), testCase.string("same_title_key"), "same-title key of \(title)")
        }
    }

    func testSummaryKeysMatchTheVectors() throws {
        let cases = try Vectors.load("series.json").dictionaries("summaries")
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            XCTAssertEqual(Series.summaryKey(testCase.string("summary")), testCase.string("summary_key"))
        }
        XCTAssertEqual(Series.summaryKey(nil), "")
    }

    /// The marks `Arib.clean` spells out for the guide's symbols are not part of a programme's name. The
    /// vectors carry [字][再][無][初][S][吹][終]; these five are among the ones they do not.
    func testEveryMarkTheGuideSpellsOutIsLeftOutOfTheKeys() {
        XCTAssertEqual(Series.key("[HV][双][N][前][声]サンプル紀行"), Series.key("サンプル紀行"))
    }
}
