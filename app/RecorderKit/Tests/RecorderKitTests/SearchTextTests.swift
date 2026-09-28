import XCTest
@testable import RecorderKit

/// How a query is taken apart, how its words are put to SQLite, and what a result found in a programme's
/// details shows of them.
final class SearchTextTests: XCTestCase {
    func testAQueryIsItsWordsNormalised() {
        XCTAssertEqual(Search.terms("  ドラマ　みほん花子 "), ["ドラマ", "みほん花子"],
                       "full-width spaces separate words too")
        XCTAssertEqual(Search.terms("ＳＡＭＰＬＥ"), ["sample"])
        XCTAssertEqual(Search.terms(""), [])
        XCTAssertEqual(Search.terms("　"), [])
        XCTAssertEqual(Search.terms("a\u{1E}b\u{1F}c"), ["abc"], "the field separators cannot be typed in")
    }

    func testEveryWordHasToBeInTheText() {
        XCTAssertTrue(Search.matches("ドラマ　花子", in: "花子のドラマ"), "in any order")
        XCTAssertTrue(Search.matches("sample", in: "ＳＡＭＰＬＥ劇場"))
        XCTAssertFalse(Search.matches("ドラマ 太郎", in: "花子のドラマ"))
    }

    func testLikeWildcardsAreEscaped() {
        XCTAssertEqual(Search.likePattern("100%"), "%100\\%%")
        XCTAssertEqual(Search.likePattern("a_b"), "%a\\_b%")
        XCTAssertEqual(Search.likePattern("c\\d"), "%c\\\\d%", "and the escape character itself")
        XCTAssertEqual(Search.likePattern("ドラマ"), "%ドラマ%")
    }

    func testTheSearchTextKeepsTheFieldsApart() {
        XCTAssertEqual(Search.text(title: "ＳＡＭＰＬＥ", summary: "要約", extended: "出演\n花子"),
                       "sample\u{1E}要約\u{1F}出演\n花子")
    }

    func testASnippetIsCutAroundTheWordWithEllipsesWhereTheTextGoesOn() {
        let text = String(repeating: "あ", count: 30) + "みほん花子" + String(repeating: "い", count: 50)
        let snippet = Search.snippet(of: "みほん花子", in: text)
        XCTAssertEqual(snippet, Search.Snippet(before: "…" + String(repeating: "あ", count: 10), match: "みほん花子",
                                               after: String(repeating: "い", count: 40) + "…"))
    }

    func testASnippetKeepsTheLabelAtTheStartOfItsLineAndAHeadingOnTheLineBefore() {
        XCTAssertEqual(Search.snippet(of: "花子", in: "番組内容\n海辺の町の話。\n出演：サンプル太郎、みほん花子"),
                       Search.Snippet(before: "…出演：サンプル太郎、みほん", match: "花子", after: ""),
                       "the label sits at the start of the line")
        XCTAssertEqual(Search.snippet(of: "花子", in: "出演者\n  サンプル太郎、みほん花子\n\n（ほか）"),
                       Search.Snippet(before: "出演者 サンプル太郎、みほん", match: "花子", after: " （ほか）"),
                       "a short line before is a heading; lines are trimmed and joined with a space")
    }

    func testASnippetShowsTheTextAsBroadcast() {
        XCTAssertEqual(Search.snippet(of: "サンプル", in: "ｻﾝﾌﾟﾙ太郎"),
                       Search.Snippet(before: "", match: "ｻﾝﾌﾟﾙ", after: "太郎"),
                       "half-width katakana found by its full-width form, ﾌﾟ being one character of it")
        XCTAssertEqual(Search.snippet(of: "平成", in: "㍻の歌"),
                       Search.Snippet(before: "", match: "㍻", after: "の歌"), "one character that normalises to two")
        XCTAssertEqual(Search.snippet(of: "ＡＢＣ", in: "abcの時間"),
                       Search.Snippet(before: "", match: "abc", after: "の時間"))
    }

    func testNoSnippetWhereTheWordIsNotInTheText() {
        XCTAssertNil(Search.snippet(of: "花子", in: "出演：サンプル太郎"))
        XCTAssertNil(Search.snippet(of: "", in: "出演：サンプル太郎"))
        XCTAssertNil(Search.snippet(of: "花子", in: ""))
    }
}
