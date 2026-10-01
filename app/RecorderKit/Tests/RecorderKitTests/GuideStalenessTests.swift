import Foundation
import XCTest
@testable import RecorderKit

/// Which broadcasting types are worth fetching again: the ones the recorder has not answered for since it
/// last rebuilt its guide files, at one in the morning its own time.
final class GuideStalenessTests: XCTestCase {
    private func time(_ text: String) throws -> Date {
        try XCTUnwrap(RecorderTime.parse(text))
    }

    private func counts(checked: String? = nil, refreshed: String? = nil) -> GuideCounts {
        GuideCounts(channels: 1, programs: 1, refreshed: refreshed, checked: checked)
    }

    func testTheLastRebuildIsOneInTheMorningJapanTimeTodayOrYesterday() throws {
        XCTAssertEqual(GuideRefresh.lastRebuild(before: try time("2026-10-01T12:00:00+09:00")),
                       try time("2026-10-01T01:00:00+09:00"))
        XCTAssertEqual(GuideRefresh.lastRebuild(before: try time("2026-10-01T01:30:00+09:00")),
                       try time("2026-10-01T01:00:00+09:00"))
        XCTAssertEqual(GuideRefresh.lastRebuild(before: try time("2026-10-01T00:59:00+09:00")),
                       try time("2026-09-30T01:00:00+09:00"))
    }

    /// Japan's one o'clock, wherever the phone thinks it is: at 16:30 UTC on the 30th it is 01:30 on the 1st.
    func testTheRebuildIsJapansOneOClockWhateverTheTimeZoneOfTheText() throws {
        XCTAssertEqual(GuideRefresh.lastRebuild(before: try time("2026-09-30T16:30:00+00:00")),
                       try time("2026-10-01T01:00:00+09:00"))
    }

    /// Each type by its own time: one answered since the rebuild is fresh whatever the others are.
    func testATypeIsStaleByItsOwnTime() throws {
        let now = try time("2026-10-01T08:00:00+09:00")
        let all = ["td": counts(checked: "2026-10-01T02:00:00+09:00"),
                   "bs": counts(checked: "2026-09-30T23:00:00+09:00"),
                   "cs": counts(checked: "2026-10-01T07:59:00+09:00")]
        XCTAssertEqual(GuideRefresh.staleTypes(all, now: now, types: ["td", "bs", "cs", "bs4k"]), ["bs", "bs4k"])
    }

    func testATypeNeverAskedForIsStale() throws {
        let now = try time("2026-10-01T08:00:00+09:00")
        XCTAssertEqual(GuideRefresh.staleTypes([:], now: now), GuideRefresh.broadcastingTypes)
        XCTAssertEqual(GuideRefresh.staleTypes(["td": counts()], now: now, types: ["td"]), ["td"])
    }

    /// A cache written before `checked` was kept has only `refreshed`, which stands in for it; with both, the
    /// one that says when the recorder last answered decides.
    func testTheTimeTheRecorderLastAnsweredDecides() throws {
        let now = try time("2026-10-01T08:00:00+09:00")
        let after = "2026-10-01T02:00:00+09:00", before = "2026-09-30T02:00:00+09:00"
        XCTAssertEqual(GuideRefresh.staleTypes(["td": counts(refreshed: after)], now: now, types: ["td"]), [])
        XCTAssertEqual(GuideRefresh.staleTypes(["td": counts(refreshed: before)], now: now, types: ["td"]), ["td"])
        XCTAssertEqual(GuideRefresh.staleTypes(["td": counts(checked: after, refreshed: before)], now: now,
                                               types: ["td"]), [])
    }
}
