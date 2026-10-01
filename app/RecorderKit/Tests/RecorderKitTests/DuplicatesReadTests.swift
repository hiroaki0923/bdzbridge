import Foundation
import XCTest
@testable import RecorderKit

/// The sets of duplicates as the screens should build them: from the recordings whose programme text has
/// actually been read. `Duplicates.sets` takes a missing text for an empty one, as the server its vectors come
/// from does, and two recordings nobody has read then agree with each other on nothing -- same title, same
/// length -- and come up as copies, one of them ticked for deletion.
final class DuplicatesReadTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func recording(_ id: String, title: String = "サンプルドラマ　第１話", durationSec: Int = 1800,
                           sizeMB: Int = 1000) -> RecordedTitle {
        RecordedTitle(id: id, title: title, start: start, durationSec: durationSec, broadcastingType: 2,
                      serviceID: 0x400, qualityCode: 230, protected: false, isNew: false, recording: false,
                      destination: "HDD", sizeMB: sizeMB, genreCode: nil, lastPlayed: nil, resumeSec: nil)
    }

    private let story = "架空の町で起きた出来事を追う連続ドラマの第１話。主人公が町に着くところから始まる。"

    func testTwoRecordingsNobodyHasReadAreNotASet() {
        let found = Duplicates.readSets([recording("a"), recording("b")], summaries: [:])

        XCTAssertTrue(found.sets.isEmpty, "two recordings were called copies on their title and length alone")
        XCTAssertEqual(found.unread, 2)
        // What the function it guards would have said of the same two.
        let unguarded = Duplicates.sets(candidates: Duplicates.candidates([recording("a"), recording("b")]),
                                        summaries: [:])
        XCTAssertEqual(unguarded.count, 1, "the trap this is here for has gone, and so may the guard")
    }

    func testOneReadAndOneNotAreNotASet() {
        let found = Duplicates.readSets([recording("a"), recording("b")], summaries: ["a": story])

        XCTAssertTrue(found.sets.isEmpty)
        XCTAssertEqual(found.unread, 1)
    }

    func testTwoThatWereReadAndSayTheSameAreASet() {
        let found = Duplicates.readSets([recording("a"), recording("b")], summaries: ["a": story, "b": story])

        XCTAssertEqual(found.sets.map { $0.items.map(\.id).sorted() }, [["a", "b"]])
        XCTAssertEqual(found.unread, 0)
    }

    /// An empty text is an answer too: some recordings come with none, and the recorder said so.
    func testAnEmptyTextThatWasReadCounts() {
        let found = Duplicates.readSets([recording("a"), recording("b")], summaries: ["a": "", "b": ""])

        XCTAssertEqual(found.sets.count, 1)
        XCTAssertEqual(found.unread, 0)
    }

    /// The unread one is left out and the two that were read still make their set.
    func testAnUnreadRecordingIsLeftOutOfASetOfThree() {
        let found = Duplicates.readSets([recording("a"), recording("b"), recording("c")],
                                        summaries: ["a": story, "c": story])

        XCTAssertEqual(found.sets.map { $0.items.map(\.id).sorted() }, [["a", "c"]])
        XCTAssertEqual(found.unread, 1)
    }

    /// Only candidates are counted: a recording with no other like it was never going to be read.
    func testARecordingThatIsNobodysCandidateIsNotCountedAsUnread() {
        let found = Duplicates.readSets([recording("a"), recording("x", title: "サンプル紀行")], summaries: [:])

        XCTAssertTrue(found.sets.isEmpty)
        XCTAssertEqual(found.unread, 0)
    }
}
