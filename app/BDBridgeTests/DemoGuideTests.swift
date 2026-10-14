import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The demo's guide as its seed writes it into a cache, read back as the screens read it: the stations with
/// their logos, four days of each one's programmes with their ids, times and details, and what is noted of the
/// broadcasting types it has no guide of. Every station, count and text here is a literal, so that where the
/// invented line-up is kept can change under the seed with nothing here changed.
///
/// The seed places the programmes by the clock, on the broadcast day on air when it runs. So nothing here reads
/// the clock: a programme is found by its id, and its start is held as a time of day in Japan and against
/// another programme's.
@MainActor
final class DemoGuideTests: XCTestCase {
    private static let japan: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        return calendar
    }()

    /// A cache in a bench's folder with the demo's guide written into it, and the bench to throw away after.
    private func seeded(before: ((GuideStore) async throws -> Void)? = nil) async throws -> (GuideStore, Bench) {
        let bench = try Bench()
        let store = try GuideStore(path: bench.guidePath)
        try await before?(store)
        try await DemoData.seed(store: store)
        return (store, bench)
    }

    /// Six terrestrial stations and three on BS, by their ids and names in the guide's order, each with a logo
    /// drawn as a PNG.
    func testItsStationsAndTheirLogos() async throws {
        let (store, bench) = try await seeded()
        defer { bench.throwAway() }

        let terrestrial = try await store.channels(broadcasting: "td")
        XCTAssertEqual(terrestrial.map { "\($0.serviceID) \($0.name)" }, [
            "1024 サンプルテレビ", "1032 サンプル教育", "1040 みほんテレビ", "1048 テレビみほん", "1056 サンプル放送",
            "1064 ひなたテレビ",
        ])
        let satellite = try await store.channels(broadcasting: "bs")
        XCTAssertEqual(satellite.map { "\($0.serviceID) \($0.name)" }, ["2048 サンプルBS", "2056 みほんBS", "2064 BSみほん"])

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for channel in terrestrial + satellite {
            XCTAssertEqual(channel.logo?.prefix(8), png, "\(channel.serviceID) has no logo drawn")
        }
    }

    /// Each station's day, on four days, numbered by the day and the place in it; the evening's drama at eight
    /// and on the next day at the same time; the late-night drama at half past midnight closing the same
    /// broadcast day; a drama's details with its cast and the line that says it is invented, and none for a
    /// programme with nothing to say; one genre each.
    func testItsProgrammes() async throws {
        let (store, bench) = try await seeded()
        defer { bench.throwAway() }

        let days: [(String, Int, Int)] = [
            ("td", 1024, 23), ("td", 1032, 18), ("td", 1040, 16), ("td", 1048, 16), ("td", 1056, 13), ("td", 1064, 13),
            ("bs", 2048, 12), ("bs", 2056, 10), ("bs", 2064, 9),
        ]
        for (broadcasting, serviceID, slots) in days {
            let programs = try await store.programs(broadcasting: broadcasting, serviceID: serviceID, since: nil)
            let ids = (0..<4).flatMap { day in (0..<slots).map { 1000 + day * 100 + $0 } }
            XCTAssertEqual(programs.map(\.eventID), ids, "\(serviceID)'s programmes")
            XCTAssertEqual(programs.filter { $0.genres.count != 1 }.map(\.eventID), [], "\(serviceID)'s genres")
        }

        let drama = try await store.program(broadcasting: "td", serviceID: 1024, eventID: 1013)
        let first = try XCTUnwrap(drama)
        XCTAssertEqual(first.title, "サンプル劇場「ひかりの街」第５話")
        let time = Self.japan.dateComponents([.hour, .minute, .second], from: first.start)
        XCTAssertEqual([time.hour, time.minute, time.second], [20, 0, 0])
        XCTAssertEqual(first.durationSec, 2700)
        XCTAssertEqual(first.summary, "港町にもどった主人公が、古い灯台の記録を読みはじめる。")
        XCTAssertEqual(first.extended,
                       "港町にもどった主人公が、古い灯台の記録を読みはじめる。\n出演　サンプル太郎、みほん花子\n（これはサンプルの番組情報です）")
        XCTAssertEqual(first.genres, [Genre(level1: 3, level2: 0)])

        let next = try await store.program(broadcasting: "td", serviceID: 1024, eventID: 1113)
        XCTAssertEqual(next?.title, "サンプル劇場「ひかりの街」第５話")
        XCTAssertEqual(next?.start, first.start.addingTimeInterval(86_400))

        let night = try await store.program(broadcasting: "td", serviceID: 1024, eventID: 1019)
        XCTAssertEqual(night?.title, "深夜サンプル劇場")
        XCTAssertEqual(night?.start, first.start.addingTimeInterval(4 * 3600 + 30 * 60))
        XCTAssertEqual(night.map { GuideStore.broadcastDay(containing: $0.start) },
                       GuideStore.broadcastDay(containing: first.start), "the night is not the same broadcast day's")

        let quiet = try await store.program(broadcasting: "td", serviceID: 1024, eventID: 1000)
        XCTAssertEqual(quiet?.title, "早朝サンプル便り")
        XCTAssertEqual(quiet?.summary, "")
        XCTAssertEqual(quiet?.extended, "")
    }

    /// Terrestrial and BS are written and counted as refreshed; CS and BS 4K are noted as answered with none, so
    /// that a connect does not ask the demo's recorder for them; CS 4K is left as it was. A reservation waiting
    /// for the television is taken away, as the demo's television is in memory alone; one waiting for the
    /// recorder stays.
    func testWhatIsNotedAndWhatIsTaken() async throws {
        let request = ReservationRequest(title: "テスト予約", start: Date(timeIntervalSince1970: 1_793_534_400),
                                         durationSec: 3600, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 220, eventID: 0x1234)
        let (store, bench) = try await seeded { store in
            try await store.queue(PendingReservation(request: request, serviceName: "サンプルテレビ", target: .tv))
            try await store.queue(PendingReservation(request: request, serviceName: "サンプルテレビ"))
        }
        defer { bench.throwAway() }

        let counts = try await store.counts()
        XCTAssertEqual(counts.keys.sorted().map { type in
            let count = counts[type]
            return "\(type) \(count?.channels ?? -1) \(count?.programs ?? -1)"
                + " \(count?.refreshed == nil ? "-" : "refreshed") \(count?.checked == nil ? "-" : "checked")"
        }, [
            "bs 3 124 refreshed checked",
            "bs4k 0 0 - checked",
            "cs 0 0 - checked",
            "cs4k 0 0 - -",
            "td 6 396 refreshed checked",
        ])

        let waiting = try await store.pendingReservations()
        XCTAssertEqual(waiting.map(\.target), [.recorder])
    }
}
