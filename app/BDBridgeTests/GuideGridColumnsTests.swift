import XCTest
@testable import BDBridge

/// Which of the guide grid's columns are drawn, for where the grid is scrolled to. Columns are 132 points
/// wide behind a gutter of 30; the offset is the content's origin in the scroll view, so it goes negative as
/// the grid scrolls to the right.
@MainActor
final class GuideGridColumnsTests: XCTestCase {
    /// An offset measured against a wider grid, read once more after the grid has fewer columns: the window
    /// comes out empty at the end rather than starting past it. This is the demo's six stations after a grid of
    /// more, scrolled to where the window would have started at the eighth column.
    func testAnOffsetPastTheLastColumnGivesNothingAtTheEnd() {
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: -1100, viewportWidth: 402, count: 6), 6..<6)
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: -50_000, viewportWidth: 402, count: 6), 6..<6)
    }

    /// Ordinary offsets: at the start, part way across, and near the end, where the window is cut at the
    /// last column. A viewport not measured yet is taken as a point wide.
    func testOrdinaryOffsets() {
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: 0, viewportWidth: 402, count: 6), 0..<6)
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: -500, viewportWidth: 402, count: 20), 2..<8)
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: -1000, viewportWidth: 402, count: 9), 6..<9)
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: 0, viewportWidth: 0, count: 6), 0..<3)
    }

    func testNoColumns() {
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: 0, viewportWidth: 402, count: 0), 0..<0)
        XCTAssertEqual(GuideGridView.visibleColumns(offsetX: -1100, viewportWidth: 402, count: 0), 0..<0)
    }
}
