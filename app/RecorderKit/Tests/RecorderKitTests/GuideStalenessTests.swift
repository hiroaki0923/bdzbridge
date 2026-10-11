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

    /// The night's hour is two o'clock by a calendar set to Japan's time, not by the calendar the process
    /// would give: with another zone as the process's default for as long as the assertions take, the next night
    /// is still Japan's. What is held is that the calendar's zone is set; on a machine in Japan, one set to the
    /// phone's own zone would pass.
    func testTheNextNightIsJapansTwoOClockWithAnotherZoneAsTheDefault() throws {
        let was = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        defer { NSTimeZone.default = was }
        XCTAssertEqual(GuideRefresh.nextNightlyRun(after: try time("2026-10-10T01:59:59+09:00")),
                       try time("2026-10-10T02:00:00+09:00"))
        XCTAssertEqual(GuideRefresh.nextNightlyRun(after: try time("2026-10-10T02:00:00+09:00")),
                       try time("2026-10-11T02:00:00+09:00"))
    }

    /// Each type by its own time: one answered since the rebuild is fresh whatever the others are.
    func testATypeIsStaleByItsOwnTime() throws {
        let now = try time("2026-10-01T08:00:00+09:00")
        let all = ["td": counts(checked: "2026-10-01T02:00:00+09:00"),
                   "bs": counts(checked: "2026-09-30T23:00:00+09:00"),
                   "cs": counts(checked: "2026-10-01T07:59:00+09:00")]
        XCTAssertEqual(GuideRefresh.staleTypes(all, now: now, types: ["td", "bs", "cs", "bs4k"]), ["bs", "bs4k"])
    }

    /// By a moment in place of the rebuild: a type is asked for again only when its mark is earlier than the
    /// moment, and one never answered for always. The cache keeps a mark to the whole second, so a moment that
    /// is to be told from the marks written after it is taken to the whole second too: with its fraction it is
    /// later than a mark written within its own second, which would count as from before it.
    func testATypeIsNotAnsweredSinceAMomentWhenItsMarkIsOfAnEarlierSecond() async throws {
        let pressed = try time("2026-10-01T08:00:00+09:00").addingTimeInterval(0.4)
        let moment = GuideRefresh.toTheSecond(pressed)
        XCTAssertEqual(moment, try time("2026-10-01T08:00:00+09:00"))
        let store = try GuideStore(path: ":memory:")
        try await store.noteNoGuide(broadcasting: "td", at: pressed.addingTimeInterval(0.5))
        try await store.noteNoGuide(broadcasting: "bs", at: pressed.addingTimeInterval(-1))
        try await store.noteNoGuide(broadcasting: "cs", at: pressed.addingTimeInterval(1))
        let counts = try await store.counts()

        XCTAssertEqual(GuideRefresh.staleTypes(counts, since: moment), ["bs", "bs4k"])
        XCTAssertEqual(GuideRefresh.staleTypes(counts, since: pressed), ["td", "bs", "bs4k"],
                       "with its fraction the moment was meant to be later than a mark of its own second")
        XCTAssertEqual(GuideRefresh.staleTypes(counts, since: moment, types: ["cs", "td"]), [])
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
