import XCTest
@testable import RecorderKit

/// The code tables and constants must match the ones the server uses. `logo_clut` is left for the logo decoder
/// and the EPG-specific vectors for the guide decoder; those arrive with their steps.
final class CodesVectorTests: XCTestCase {
    func testTablesMatchTheVectors() throws {
        let vectors = try Vectors.load("codes.json")

        XCTAssertEqual(Codes.broadcasting, vectors.dictionary("broadcasting") as? [String: Int])
        XCTAssertEqual(Codes.broadcastingLabel, vectors.dictionary("broadcasting_label") as? [String: String])
        XCTAssertEqual(Codes.epgFiles, vectors.dictionary("epg_files") as? [String: String])
        XCTAssertEqual(Codes.logoFiles, vectors.dictionary("logo_files") as? [String: String])
        XCTAssertEqual(Codes.quality, vectors.dictionary("quality") as? [String: Int])
        XCTAssertEqual(Codes.qualityElsewhere, vectors.dictionary("quality_elsewhere") as? [String: Int])
        XCTAssertEqual(Codes.ruleLogicLabel, vectors.dictionary("rule_logic_label") as? [String: String])
        XCTAssertEqual(Codes.timeScopeLabel, vectors.dictionary("time_scope_label") as? [String: String])
        XCTAssertEqual(Codes.broadcastingScopeLabel, vectors.dictionary("broadcasting_scope_label") as? [String: String])
        XCTAssertEqual(Codes.quality(code: 101), "3x")
        XCTAssertEqual(Codes.qualityLabel, vectors.dictionary("quality_label") as? [String: String])
        XCTAssertEqual(Codes.repeatCodes, vectors.dictionary("repeat") as? [String: String])
        XCTAssertEqual(Codes.repeatLabel, vectors.dictionary("repeat_label") as? [String: String])
        XCTAssertEqual(Codes.weekdayRepeat, vectors.list("weekday_repeat") as? [String])

        let genres = Dictionary(uniqueKeysWithValues: Codes.genreLabel.map { ("0x" + String($0.key, radix: 16), $0.value) })
        XCTAssertEqual(genres, vectors.dictionary("genre_label") as? [String: String])
        let subGenres = Dictionary(uniqueKeysWithValues: Codes.subGenreLabel.map { level1, subs in
            ("0x" + String(level1, radix: 16),
             Dictionary(uniqueKeysWithValues: subs.map { ("0x" + String($0.key, radix: 16), $0.value) }))
        })
        XCTAssertEqual(subGenres, vectors.dictionary("sub_genre_label") as? [String: [String: String]])
        XCTAssertEqual(Codes.subGenre(level1: 5, level2: 0), "クイズ")
        XCTAssertNil(Codes.subGenre(level1: 5, level2: nil), "a whole genre has no sub-genre name")
        XCTAssertNil(Codes.subGenre(level1: 3, level2: 0xD), "a code the standard does not use")

        let symbols = Dictionary(uniqueKeysWithValues: Arib.symbols.map {
            (String(format: "U+%04X", $0.key.value), $0.value)
        })
        XCTAssertEqual(symbols, vectors.dictionary("arib_symbols") as? [String: String])
    }

    func testPortsAndServiceNamesMatchTheVectors() throws {
        let vectors = try Vectors.load("codes.json")

        let ports = vectors.dictionary("ports")
        XCTAssertEqual(Upnp.port, ports.int("upnp"))
        XCTAssertEqual(Upnp.defaultStreamPort, ports.int("stream_default"))
        XCTAssertEqual("\(Upnp.ssdpAddress):\(Upnp.ssdpPort)", ports.string("ssdp"))

        let namespaces = vectors.dictionary("namespaces")
        XCTAssertEqual(Upnp.xsrsService, namespaces.string("xsrs_service"))
        XCTAssertEqual(Upnp.pvrService, namespaces.string("pvr_service"))
        XCTAssertEqual(Upnp.contentDirectoryService, namespaces.string("cds_service"))
        XCTAssertEqual(Upnp.xsrsMetadataNamespace, namespaces.string("xsrs_metadata"))

        let controlURLs = vectors.dictionary("control_urls")
        XCTAssertEqual(Upnp.xsrsControlURL, controlURLs.string("xsrs"))
        XCTAssertEqual(Upnp.pvrControlURL, controlURLs.string("pvr"))
        XCTAssertEqual(Upnp.contentDirectoryControlURL, controlURLs.string("cds"))
    }

    func testGenreCodeSplitsIntoAribNibbles() {
        XCTAssertEqual(Codes.genreLevels(168).level1, 0xA)
        XCTAssertEqual(Codes.genreLevels(168).level2, 0x8)
        XCTAssertEqual(Codes.genreLabel[Codes.genreLevels(48).level1], "ドラマ")
    }
}
