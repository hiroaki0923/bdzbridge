import XCTest
@testable import RecorderKit

/// Every case the server's heuristic was tuned on, taken from real recordings.
final class SeriesVectorTests: XCTestCase {
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

    func testEpisodesOfOneProgrammeShareAKeyAndOtherEpisodesDoNot() {
        XCTAssertEqual(Series.key("日曜劇場「VIVANT」 第1話"), Series.key("日曜劇場「ＶＩＶＡＮＴ」第１８話"))
        XCTAssertEqual(Series.sameTitleKey("ドラマＡ　第３話[再]"), Series.sameTitleKey("ドラマA 第3話"))
        XCTAssertNotEqual(Series.sameTitleKey("ドラマＡ　第３話"), Series.sameTitleKey("ドラマＡ　第４話"))
    }
}
