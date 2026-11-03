import XCTest
@testable import RecorderKit

/// The television's guide, as the helper hands it over, turned into what the recorder's files decode to. The
/// rows are invented in the helper's shape (`helper/README.md`); nothing here came from a television.
final class TVGuideDecoderTests: XCTestCase {
    private func data(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private let channels = [
        TVGuideDecoder.Channel(broadcasting: "td", serviceID: 1032, number: "021", name: "第二テレビ"),
        TVGuideDecoder.Channel(broadcasting: "td", serviceID: 1024, number: "011", name: "第一テレビ"),
        TVGuideDecoder.Channel(broadcasting: "bs", serviceID: 101, number: "101", name: "BS第一"),
    ]

    func testChannelsComeOutByTypeAndServiceIDWithWhatTheTelevisionSaid() throws {
        let json = data(["channels": [
            ["bt": "td", "sid": 1032, "onid": 32736, "tsid": 32736, "number": "021", "name": "第二テレビ",
             "browsable": true, "hasPrograms": true],
            ["bt": "td", "sid": 1024, "onid": 32736, "tsid": 32736, "number": "011", "name": NSNull(),
             "browsable": false, "hasPrograms": false],
        ]])
        let decoded = try TVGuideDecoder.decodeChannels(json)
        XCTAssertEqual(decoded.map(\.serviceID), [1024, 1032])
        XCTAssertEqual(decoded[0].name, "")
        XCTAssertEqual(decoded[0].channelNo, 11)
        XCTAssertFalse(decoded[0].browsable)
        XCTAssertFalse(decoded[0].hasPrograms)
        XCTAssertEqual(decoded[1].originalNetworkID, 32736)
    }

    func testAGuideRowBecomesTheProgrammeTheRecorderWouldGive() throws {
        let json = data(["bt": "td", "programs": [[
            "sid": 1024, "eid": 4660, "startMs": 1_800_000_000_000, "endMs": 1_800_003_600_000,
            "title": "\u{1F211}ニュース\u{1F21E}", "short": "きょうの出来事",
            "longTail": "出演 ほか", "genre": "news:weather report,weal:captions",
            "rating": "com.android.tv/ISDB/ISDB_15", "flag1": 0, "flag2": 0, "siblings": [1024], "siblingEids": [4660],
        ]]])
        let services = try TVGuideDecoder.decodeGuide(json, channels: channels)
        XCTAssertEqual(services.map(\.serviceID), [1024, 1032])
        XCTAssertEqual(services[0].name, "第一テレビ")
        XCTAssertEqual(services[1].programs, [])
        let program = try XCTUnwrap(services[0].programs.first)
        XCTAssertEqual(program.eventID, 4660)
        XCTAssertEqual(program.start, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(program.durationSec, 3600)
        XCTAssertEqual(program.title, "[字]ニュース[再]")
        XCTAssertEqual(program.summary, "きょうの出来事")
        XCTAssertEqual(program.extended, "出演 ほか")
        XCTAssertEqual(program.genres, [Genre(level1: 0, level2: 1), Genre(level1: 0xB, level2: 5)])
        XCTAssertEqual(program.parentalRating, 15)
        XCTAssertEqual(program.copyControl, 0)
        XCTAssertFalse(program.isReference)
    }

    func testASubChannelsCopyOfItsParentBecomesAReference() throws {
        let row: [String: Any] = [
            "sid": 1025, "eid": 4660, "startMs": 1_800_000_000_000, "endMs": 1_800_003_600_000,
            "title": "ニュース", "short": "同じ", "flag2": 1, "siblings": [1024], "siblingEids": [4660],
        ]
        let program = try XCTUnwrap(TVGuideDecoder.decodeProgram(row))
        XCTAssertTrue(program.isReference)
        XCTAssertEqual(program.referenceServiceID, 1024)
        XCTAssertEqual(program.referenceEventID, 4660)
        XCTAssertEqual(program.title, "")
        // The parent lists its siblings and is not a reference to itself.
        var parent = row
        parent["sid"] = 1024
        parent["flag2"] = 0
        parent["siblings"] = [1024, 1025]
        XCTAssertFalse(try XCTUnwrap(TVGuideDecoder.decodeProgram(parent)).isReference)
    }

    func testTheLongDescriptionIsTakenWhenThereIsNoTail() throws {
        let row: [String: Any] = ["sid": 1, "eid": 2, "startMs": 0, "endMs": 1000, "title": "t", "long": "全文"]
        XCTAssertEqual(try XCTUnwrap(TVGuideDecoder.decodeProgram(row)).extended, "全文")
        XCTAssertNil(TVGuideDecoder.decodeProgram(["sid": 1, "eid": 2, "startMs": 0]))
    }

    func testRatings() {
        XCTAssertEqual(TVGuideDecoder.rating("com.sony.dtv/ISDB/ISDB_NONE"), 0)
        XCTAssertEqual(TVGuideDecoder.rating("com.android.tv/ISDB/ISDB_15"), 15)
        XCTAssertEqual(TVGuideDecoder.rating(nil), 0)
        XCTAssertEqual(TVGuideDecoder.rating("x"), 0)
    }

    func testGenresAsAndroidSpellsThem() {
        XCTAssertEqual(TVGenres.labels("news:regular/general,drama:other"), ["news:regular/general", "drama:other"])
        XCTAssertEqual(TVGenres.labels("cs-movie\",japanese movies:period dramas"), ["cs-movie,japanese movies:period dramas"])
        XCTAssertEqual(TVGenres.labels("hobby/education:japanese chess (shogi) and \"\"go\"\""),
                       ["hobby/education:japanese chess (shogi) and \"go\""])
        XCTAssertEqual(TVGenres.labels(""), [])
        XCTAssertEqual(TVGenres.decode("information/tabloid show:shopping/mail-order business"), [Genre(code: 0x24)])
        XCTAssertEqual(TVGenres.decode("drama:other"), [Genre(code: 0x3F)])
        XCTAssertEqual(TVGenres.decode("hobby/education:educational problem"), [Genre(code: 0xAC)])
        XCTAssertEqual(TVGenres.decode("weal:audio descriptions"), [Genre(code: 0xB6)])
        XCTAssertEqual(TVGenres.decode("cs-sports:american football"), [Genre(code: 0xE1)])
        XCTAssertEqual(TVGenres.decode("other"), [Genre(code: 0xFF)])
        // An unknown sub-genre of a known level is that level's "other"; an unknown level is nothing.
        XCTAssertEqual(TVGenres.decode("music:kazoo"), [Genre(code: 0x4F)])
        XCTAssertEqual(TVGenres.decode("podcast:x"), [])
    }

    func testLogosAreKeyedByTheChannelsNumbers() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let json = data(["bt": "td", "logos": [
            ["sid": 1032, "hash": "a", "png": png.base64EncodedString()],
            ["sid": 1024, "hash": "b", "png": png.base64EncodedString()],
            ["sid": 9999, "hash": "c", "png": Data("notapng".utf8).base64EncodedString()],
        ]])
        let logos = try TVGuideDecoder.decodeLogos(json, channels: channels)
        XCTAssertEqual(logos.map(\.serviceID), [1024, 1032])
        XCTAssertEqual(logos.map(\.channelNo), [11, 21])
    }

    func testAnAnswerOfAnotherShapeIsRefused() {
        XCTAssertThrowsError(try TVGuideDecoder.decodeChannels(Data("[]".utf8)))
        XCTAssertThrowsError(try TVGuideDecoder.decodeGuide(data(["programs": []]), channels: []))
    }
}
