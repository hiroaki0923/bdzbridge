import XCTest
@testable import RecorderKit

/// The form of a new keyword condition (`RecorderRuleDraft`): what it offers, what it asks for, and what it sends.
final class RecorderRuleDraftTests: XCTestCase {
    func testTheWordsAreSentTrimmedWithTheEmptyRowsLeftOut() {
        var draft = RecorderRuleDraft(quality: "DR")
        draft.keywords = [.init(" 天気 "), .init(""), .init("　"), .init("ニュース")]
        draft.excluded = [.init("再放送 "), .init(" ")]
        XCTAssertEqual(draft.words, ["天気", "ニュース"], "a full-width space is a space too")
        XCTAssertEqual(draft.excludedWords, ["再放送"])
    }

    func testAConditionNamesAKeywordOrAGenre() {
        var draft = RecorderRuleDraft(quality: "DR")
        XCTAssertEqual(draft.problem, RecorderRuleDraft.needsAKeywordOrAGenre)
        draft.keywords = [.init("  ")]
        XCTAssertEqual(draft.problem, RecorderRuleDraft.needsAKeywordOrAGenre, "spaces are no keyword")
        draft.keywords = [.init("天気")]
        XCTAssertNil(draft.problem)
        draft.keywords = [.init("")]
        draft.genre = 0x0
        XCTAssertNil(draft.problem, "a genre alone is enough")
    }

    func testTheRecorderTakesFiveKeywordsAndTwoExclusions() {
        var draft = RecorderRuleDraft(quality: "DR")
        XCTAssertEqual(draft.keywords.count, 1, "one row to type into")
        XCTAssertFalse(draft.mayRemoveKeyword)
        while draft.mayAddKeyword { draft.keywords.append(.init()) }
        XCTAssertEqual(draft.keywords.count, 5)
        XCTAssertTrue(draft.mayRemoveKeyword)
        while draft.mayAddExclusion { draft.excluded.append(.init()) }
        XCTAssertEqual(draft.excluded.count, 2)
    }

    func testHowTheKeywordsAreCombinedIsAskedOnlyOfMoreThanOne() {
        var draft = RecorderRuleDraft(quality: "DR")
        draft.keywords = [.init("天気"), .init("")]
        XCTAssertFalse(draft.asksHowToCombine)
        draft.keywords[1].text = "ニュース"
        XCTAssertTrue(draft.asksHowToCombine)
        XCTAssertEqual(RecorderRuleDraft.logics.map(\.code), ["OR", "AND"])
    }

    func testAnotherGenreTakesTheSubGenreAway() {
        var draft = RecorderRuleDraft(quality: "DR")
        draft.genre = 0x0
        draft.subGenre = RecorderRuleDraft.subGenres(of: 0x0).first
        XCTAssertNotNil(draft.subGenre)
        draft.genre = 0x0
        XCTAssertNotNil(draft.subGenre, "the same genre chosen again keeps it")
        draft.genre = 0x1
        XCTAssertNil(draft.subGenre)
        XCTAssertEqual(RecorderRuleDraft.subGenres(of: nil), [])
    }

    func testTheGenresAreTheTwelveKindsOfProgramme() {
        XCTAssertEqual(RecorderRuleDraft.genres, Array(0x0...0xB))
        XCTAssertFalse(RecorderRuleDraft.subGenres(of: 0x0).isEmpty)
    }

    func testThe4KBroadcastsAreOfferedOnlyWhereTheGuideHas4KChannels() {
        let plain = ["td": GuideCounts(channels: 10, programs: 100, refreshed: nil, checked: nil), "bs": GuideCounts(channels: 20, programs: 200, refreshed: nil, checked: nil)]
        XCTAssertEqual(RecorderRuleDraft.broadcastingScopes(guide: plain).map(\.code), ["ALL", "TRD", "BSD", "CSD"])
        var fourK = plain
        fourK["bs4k"] = GuideCounts(channels: 5, programs: 50, refreshed: nil, checked: nil)
        let offered = RecorderRuleDraft.broadcastingScopes(guide: fourK)
        XCTAssertEqual(offered.map(\.code), ["ALL", "TRD", "BSD", "CSD", "ADVBSD", "ADVCSD"])
        XCTAssertEqual(offered.map(\.label), ["すべての放送", "地上放送", "BS放送", "CS放送", "BS4K放送", "CS4K放送"])
        XCTAssertEqual(RecorderRuleDraft.timeScopes.map(\.label), ["すべての時間帯", "朝", "昼", "夜", "深夜"])
    }

    func testWhatIsSent() {
        var draft = RecorderRuleDraft(quality: "XR")
        draft.keywords = [.init("天気"), .init(" ニュース")]
        draft.excluded = [.init("再放送")]
        draft.logic = "AND"
        draft.genre = 0x0
        draft.subGenre = 0x1
        draft.broadcastingScope = "BSD"
        draft.timeScope = "NIGHT"
        XCTAssertEqual(draft.request(to: nil),
                       RecorderRuleRequest(keywords: ["天気", "ニュース"], excluded: ["再放送"], logic: "AND",
                                           genreLevel1: 0x0, genreLevel2: 0x1, timeScope: "NIGHT",
                                           broadcastingScope: "BSD", qualityCode: 210,
                                           destination: RecorderDisk.internalID))
        XCTAssertEqual(draft.request(to: "usb").destination, "usb")
        draft.quality = "nothing the recorder offers"
        XCTAssertEqual(draft.request(to: nil).qualityCode, RecorderRuleDraft.fallbackQualityCode)
        XCTAssertEqual(Codes.quality["LSR"], RecorderRuleDraft.fallbackQualityCode)
    }
}
