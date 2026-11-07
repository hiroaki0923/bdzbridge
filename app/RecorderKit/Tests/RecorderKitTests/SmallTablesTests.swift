import XCTest
@testable import RecorderKit

/// The small rules and tables the screens read from the package: where a broadcast day begins, the broadcasts'
/// short names, the modes the recorder records in, and what a keyword condition's row says.
final class SmallTablesTests: XCTestCase {
    func testATimeIsCountedFromFourInTheMorning() {
        XCTAssertEqual(GuideStore.dayStartHour, 4)
        XCTAssertEqual(GuideStore.minuteOfTheBroadcastDay("04:00"), 0)
        XCTAssertEqual(GuideStore.minuteOfTheBroadcastDay("19:00"), 15 * 60)
        XCTAssertEqual(GuideStore.minuteOfTheBroadcastDay("01:30"), 21.5 * 60, "after midnight is the day's end")
        XCTAssertNil(GuideStore.minuteOfTheBroadcastDay("25:00"))
        XCTAssertNil(GuideStore.minuteOfTheBroadcastDay("now"))
    }

    func testTheShortNamesAreAWordAndOnlyTheGroundWaveDiffers() {
        XCTAssertEqual(Codes.broadcastingShortLabel["td"], "地デジ")
        for type in ["bs", "cs", "bs4k"] {
            XCTAssertEqual(Codes.broadcastingShortLabel[type], Codes.broadcastingLabel[type], type)
        }
    }

    func testTheModesTheRecorderRecordsInAreThoseItHasCodesFor() {
        XCTAssertEqual(RecorderDriver.recordsIn.first, "DR")
        XCTAssertEqual(Set(RecorderDriver.recordsIn), Set(Codes.quality.keys))
        XCTAssertEqual(RecorderDriver.recordsIn.map { Codes.quality[$0] ?? 0 },
                       RecorderDriver.recordsIn.map { Codes.quality[$0] ?? 0 }.sorted(),
                       "from the best picture to the longest")
    }

    func testAConditionsRowSaysWhatItLooksForAndWhereItRecords() {
        var rule = RecorderRule(id: "1", name: "天気", keywords: ["天気", "予報"], excluded: ["再"], logic: "AND",
                                genreLevel1: nil, genreLevel2: nil, timeScope: "NIGHT", broadcastingScope: "BSD",
                                qualityCode: 230, qualityCode4K: nil, destination: RecorderDisk.internalID)
        XCTAssertEqual(rule.details(), "天気、予報 · 除外: 再 · すべて含む · BS放送 · 夜 · SR(標準)")
        rule.logic = "OR"
        rule.excluded = []
        rule.qualityCode4K = 100
        XCTAssertEqual(rule.details(disk: "外付け"), "天気、予報 · いずれか含む · BS放送 · 夜 · SR(標準) · 4K: DR(高画質) · 外付け")
    }
}
