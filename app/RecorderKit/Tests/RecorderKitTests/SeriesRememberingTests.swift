import XCTest
import os
@testable import RecorderKit

/// A title's programme name and key are kept once worked out, since the recordings screen asks for them each
/// time it is drawn. What is kept has to be what working it out would have given, whichever is asked first and
/// from however many threads.
final class SeriesRememberingTests: XCTestCase {
    func testATitleIsWorkedOutOnceAndItsAnswerKept() {
        let unique = UUID().uuidString
        let title = "記憶サンプル\(unique)　第３話"
        XCTAssertFalse(Series.isRemembered(title))

        // the key first, so that the name comes out of what the key's call kept
        XCTAssertEqual(Series.key(title), "記憶サンプル\(unique.lowercased())")
        XCTAssertTrue(Series.isRemembered(title))
        XCTAssertEqual(Series.name(title), "記憶サンプル\(unique)")
        XCTAssertEqual(Series.key(title), "記憶サンプル\(unique.lowercased())")

        // another episode is another title, worked out on its own, and lands in the same programme
        let next = "記憶サンプル\(unique)　第４話"
        XCTAssertFalse(Series.isRemembered(next))
        XCTAssertEqual(Series.key(next), Series.key(title))
    }

    func testAnswersAskedAgainAndFromManyThreadsMatchTheVectors() throws {
        let cases = try Vectors.load("series.json").dictionaries("titles").map {
            (title: $0.string("title"), name: $0.string("series_name"), key: $0.string("series_key"))
        }
        XCTAssertGreaterThan(cases.count, 30)
        let wrong = OSAllocatedUnfairLock(initialState: [String]())
        DispatchQueue.concurrentPerform(iterations: 8) { round in
            for testCase in round.isMultiple(of: 2) ? cases : cases.reversed() {
                // some threads ask for the key first and some for the name
                let name: String, key: String
                if round.isMultiple(of: 3) {
                    name = Series.name(testCase.title)
                    key = Series.key(testCase.title)
                } else {
                    key = Series.key(testCase.title)
                    name = Series.name(testCase.title)
                }
                if name != testCase.name || key != testCase.key {
                    wrong.withLock { $0.append("\(testCase.title): \(name) / \(key)") }
                }
            }
        }
        XCTAssertEqual(wrong.withLock { $0 }, [])
    }

    func testWhatIsKeptStopsGrowingAtTheLimit() {
        let unique = UUID().uuidString
        var last = ""
        for index in 0...Series.rememberLimit {
            last = "上限\(unique)　第\(index)話"
            _ = Series.key(last)
            XCTAssertLessThanOrEqual(Series.rememberedCount, Series.rememberLimit)
        }
        // starting again leaves the newest kept, and its answer is still the right one
        XCTAssertTrue(Series.isRemembered(last))
        XCTAssertEqual(Series.name(last), "上限\(unique)")
    }
}
