import Foundation
import XCTest
@testable import RecorderKit

/// A television of the 2014 sets' kind (`DemoTV(older:)`), which answers error 12 to a method in a version it does
/// not have: it is connected to all the same, its disk is not known, and what it cannot do is said in words.
@MainActor
final class OlderTelevisionTests: XCTestCase {
    private func attached(older: Bool) async -> (LinkWorld, DeviceLink, DemoTV) {
        let world = LinkWorld()
        let television = DemoTV(older: older)
        await television.knows("BDBridge:test", cookie: "kept")
        world.devices[Stub.host] = television
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let link = DeviceLink(host: Stub.host, session: SessionState(),
                              driver: TVDriver(credentials: credentials, nickname: "RecBridge", inFront: { false }),
                              environment: world.environment)
        link.owner = world
        await link.connect()
        return (world, link, television)
    }

    func testAnOlderTelevisionIsConnectedToWithItsDiskNotKnown() async throws {
        let (world, link, _) = await attached(older: true)
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        XCTAssertNil(world.problem)
        let driver = try XCTUnwrap(link.driver as? TVDriver)
        XCTAssertNil(driver.facts.storage, "a television that does not say its disk has none known")
        XCTAssertEqual(driver.facts.model, DemoTV.model)
    }

    func testWhatAnOlderTelevisionCannotDoIsSaidInWords() async throws {
        let (world, link, _) = await attached(older: true)
        let driver = try XCTUnwrap(link.driver as? TVDriver)
        let read = await driver.reservations()
        XCTAssertNil(read)
        XCTAssertEqual(world.problem, "このテレビは、RecBridge が使う方式での予約の一覧の読み取りに対応していません")
        XCTAssertTrue(link.session.connected, "a method the television does not have is no reason to lose it")
    }

    func testANewerTelevisionStillSaysItsDisk() async throws {
        let (_, link, _) = await attached(older: false)
        let driver = try XCTUnwrap(link.driver as? TVDriver)
        XCTAssertEqual(driver.facts.storage?.mounted, true)
    }

    func testTheStorageOfAnOlderTelevisionIsNoneAndNothingElseIsAsked() async throws {
        let television = DemoTV(older: true)
        await television.knows("BDBridge:test", cookie: "kept")
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let client = ScalarClient(host: Stub.host, transport: television, credentials: credentials)
        let storage = try await client.storage()
        XCTAssertNil(storage)
        let calls = await television.calls
        XCTAssertEqual(calls.count, 1, "the storage was asked once, and nothing in its place")
    }

    /// Nine in the evening in Japan on Sunday 1 November 2026.
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_534_400)

    private func client(of television: DemoTV) async -> ScalarClient {
        await television.knows("BDBridge:test", cookie: "kept")
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        return ScalarClient(host: Stub.host, transport: television, credentials: credentials)
    }

    /// The version each `getContentList` was sent in, in order.
    private func listVersions(_ television: DemoTV) async -> [String] {
        await television.bodies.compactMap { body in
            guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  object["method"] as? String == "getContentList" else { return nil }
            return object["version"] as? String
        }
    }

    func testTheRecordingsOfAnOlderTelevisionAreReadIn1Point2AndThenStraightAway() async throws {
        let television = DemoTV(recordings: [
            DemoTV.Recording(contentID: 1, start: Self.start, durationSec: 1800, sizeMB: 624, protected: true,
                             played: true),
            DemoTV.Recording(contentID: 2, start: Self.start, durationSec: 3600, sizeMB: 3000),
        ], older: true)
        let client = await client(of: television)
        let titles = try await client.recordings()
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles.map(\.durationSec), [1800, 3600], "the length at the top of the row")
        XCTAssertEqual(titles.map(\.protected), [true, false], "the flags as booleans")
        XCTAssertEqual(titles.map(\.isNew), [false, true])
        XCTAssertEqual(titles.map(\.sizeMB), [624, nil], "the size from its bytes, none past 2 GiB")
        XCTAssertEqual(titles.map(\.channelName), ["サンプルテレビ", "サンプルテレビ"])
        XCTAssertEqual(titles.map(\.recording), [false, false])
        var versions = await listVersions(television)
        XCTAssertEqual(versions, ["1.5", "1.2"], "1.5 answered error 12, and 1.2 was asked by source")
        _ = try await client.recordings()
        versions = await listVersions(television)
        XCTAssertEqual(versions, ["1.5", "1.2", "1.2"], "the next read goes straight to the version that answered")
    }

    func testANewerTelevisionsRecordingsAreStillReadIn1Point5() async throws {
        let television = DemoTV(recordings: [DemoTV.Recording(contentID: 1, start: Self.start)])
        let titles = try await client(of: television).recordings()
        XCTAssertEqual(titles.count, 1)
        let versions = await listVersions(television)
        XCTAssertEqual(versions, ["1.5"])
    }

    func testAnOlderTelevisionsRecordingsAreListedByItsDriverWithNothingSaidOfTheDisk() async throws {
        let world = LinkWorld()
        let television = DemoTV(recordings: [DemoTV.Recording(contentID: 1, start: Self.start)], older: true)
        await television.knows("BDBridge:test", cookie: "kept")
        world.devices[Stub.host] = television
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let driver = TVDriver(credentials: credentials, nickname: "RecBridge", inFront: { true })
        let link = DeviceLink(host: Stub.host, session: SessionState(), driver: driver,
                              environment: world.environment)
        link.owner = world
        await link.connect()
        var kept: [TVTitles] = []
        let read = await driver.titles { kept.append($0) }
        XCTAssertTrue(read, world.problem ?? "no reason given")
        XCTAssertEqual(kept.last?.rows.count, 1)
        XCTAssertEqual(kept.last?.account, .addsUp, "no disk known, nothing to set the list against")
        XCTAssertNil(world.problem)
    }

    func testBytesAreMegabytesAsVersionOnePointFiveWritesThem() {
        XCTAssertEqual(RecordedTitle.megabytes(654_213_120), 624, "a recording measured in both")
        XCTAssertEqual(RecordedTitle.megabytes(0), 0)
        XCTAssertNil(RecordedTitle.megabytes(-1), "past what a 32-bit number holds")
        XCTAssertNil(RecordedTitle.megabytes(nil))
    }

    func testAnOlderRowIsReadWithItsBooleansAndItsBytes() throws {
        let row: [String: ScalarValue] = [
            "uri": .string("tv:recStorage?id=1"), "title": .string("サンプル番組"),
            "channelName": .string("サンプルテレビ"), "startDateTime": .string("2026-11-01T21:00:00+0900"),
            "durationSec": .int(1500), "fileSizeByte": .int(1_048_576 * 10), "index": .int(0),
            "isProtected": .bool(true), "isAlreadyPlayed": .bool(false),
        ]
        let title = try XCTUnwrap(RecordedTitle(televisionRow: row))
        XCTAssertEqual(title.durationSec, 1500)
        XCTAssertEqual(title.sizeMB, 10)
        XCTAssertTrue(title.protected)
        XCTAssertTrue(title.isNew)
        XCTAssertFalse(title.recording)
        XCTAssertNil(title.summary)
        XCTAssertNil(title.genreCode)
    }

    func testErrorTwelveIsSomethingTheTelevisionCannotDo() {
        let error = ScalarError.rpc(method: "addSchedule", version: "1.1", code: 12, message: "addSchedule")
        XCTAssertEqual(error.explanation, "このテレビは、RecBridge が使う方式での予約に対応していません")
        XCTAssertEqual(error.failure, .deviceCannot(reason: error.explanation))
    }
}
