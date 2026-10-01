import CryptoKit
import XCTest
import zlib
@testable import RecorderKit

final class LogoVectorTests: XCTestCase {
    private func sample() throws -> (data: Data, expected: [String: Any]) {
        let expected = try Vectors.load("logo-sample.json")
        let data = try Data(contentsOf: Vectors.directory.appendingPathComponent(expected.string("file")))
        return (data, expected)
    }

    /// The chunk types and payload lengths of a PNG, in order.
    private func chunks(_ png: Data) -> [(type: String, length: Int)] {
        var out: [(String, Int)] = []
        var index = png.startIndex + 8
        while index + 8 <= png.endIndex {
            let length = png.subdata(in: index..<index + 4).reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: png.subdata(in: index + 4..<index + 8), as: UTF8.self)
            out.append((type, length))
            index += 12 + length
        }
        return out
    }

    func testTheSampleFileIsTheOneTheVectorDescribes() throws {
        let (data, expected) = try sample()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected.string("sha256"))
    }

    func testDecodingMatchesTheVector() throws {
        let (data, expected) = try sample()
        let logos = try LogoFile.decode(data)
        let expectedLogos = expected.dictionaries("logos")

        XCTAssertEqual(logos.count, expectedLogos.count, "a station with no logo yet is skipped")
        for (logo, expectedLogo) in zip(logos, expectedLogos) {
            XCTAssertEqual(logo.channelNo, expectedLogo.int("channel_no"))
            XCTAssertEqual(logo.serviceID, expectedLogo.int("service_id"))
            XCTAssertEqual(logo.png.base64EncodedString(), expectedLogo.string("png_base64"))
        }
    }

    func testThePaletteIsInsertedAfterTheHeaderAndOnlyOnce() throws {
        let (data, _) = try sample()
        let png = try XCTUnwrap(try LogoFile.decode(data).first?.png)

        XCTAssertEqual(chunks(png).map(\.type), ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"])
        XCTAssertEqual(chunks(png).first { $0.type == "PLTE" }?.length, 3 * LogoFile.clut.count)
        XCTAssertEqual(chunks(png).first { $0.type == "tRNS" }?.length, LogoFile.clut.count)
        XCTAssertEqual(try LogoFile.withPalette(png), png, "inserting twice would break the image")

        // the standard table: white is opaque, and the entry the broadcasters use for transparency is clear
        XCTAssertEqual(LogoFile.clut[7], LogoColor(255, 255, 255, 255))
        XCTAssertEqual(LogoFile.clut[8], LogoColor(0, 0, 0, 0))
    }

    /// ARIB STD-B24 Vol.2 Part 2 App.2 Table 5-7, which TR-B15 App.1 makes the logos' table: every colour of the
    /// 4-level cube once (index 8 is the transparent one), then all but black-transparent again at alpha 128.
    /// That would be 129 entries; the standard drops (255, 255, 170, 128) to keep it at 128.
    func testTheColourTableIsTheStandardCommonFixedColours() {
        let levels: [UInt8] = [0, 85, 170, 255]
        let cube = levels.flatMap { r in levels.flatMap { g in levels.map { b in [r, g, b] } } }
        let clut = LogoFile.clut
        XCTAssertEqual(clut.count, 128)

        let opaque = Array(clut.prefix(65))
        XCTAssertEqual(opaque[8], LogoColor(0, 0, 0, 0))
        let others = opaque.enumerated().filter { $0.offset != 8 }.map(\.element)
        XCTAssertTrue(others.allSatisfy { $0.alpha == 255 })
        let rgb = others.map { [$0.red, $0.green, $0.blue] }
        XCTAssertEqual(rgb.sorted { $0.lexicographicallyPrecedes($1) }, cube, "each colour of the cube exactly once")
        // 0-7 and 9-15 are the eight caption colours at full and two-thirds level, 16-64 the rest of the cube in order
        XCTAssertEqual(Array(rgb.dropFirst(15)), cube.filter { !rgb.prefix(15).contains($0) })
        XCTAssertEqual(Array(clut.dropFirst(65)),
                       opaque.prefix(64).enumerated().filter { $0.offset != 8 }
                           .map { LogoColor($0.element.red, $0.element.green, $0.element.blue, 128) })

        XCTAssertEqual(clut[54], LogoColor(255, 0, 170, 255))
        XCTAssertEqual(clut[64], LogoColor(255, 255, 170, 255))
        XCTAssertEqual(clut[118], LogoColor(255, 0, 170, 128))
    }

    func testTheColourTableMatchesTheVector() throws {
        let expected = try Vectors.load("codes.json")["logo_clut"] as? [[Int]]
        XCTAssertEqual(LogoFile.clut.map { [Int($0.red), Int($0.green), Int($0.blue), Int($0.alpha)] }, expected)
    }

    /// A PNG that stops before the end of its header has nowhere for the palette to go. It is refused rather
    /// than read past its end, and in a logo file only that station goes without its logo.
    func testAPngTooShortForItsHeaderIsSkippedAndTheRestAreRead() throws {
        let short = LogoFile.pngSignature + Data([0x00, 0x00, 0x00, 0x0D]) + Data("IHDR".utf8)
        XCTAssertLessThan(short.count, LogoFile.afterIHDR)
        XCTAssertThrowsError(try LogoFile.withPalette(short)) { error in
            XCTAssertEqual(error as? GuideError, .notAPng)
        }

        let (data, _) = try sample()
        let good = try XCTUnwrap(try LogoFile.decode(data).first)
        let file = try logoFile([record(channel: 11, serviceID: 1024, payload: short),
                                 record(channel: UInt32(good.channelNo), serviceID: UInt16(good.serviceID),
                                        payload: good.png)])
        let logos = try LogoFile.decode(file)
        XCTAssertEqual(logos.map(\.serviceID), [good.serviceID], "the short one is left out, the next one is read")
        XCTAssertEqual(logos.first?.png, good.png)
    }

    /// A logo file as the recorder serves it: XOR 0x9D over zlib streams, an eight-byte header stream first.
    private func logoFile(_ records: [Data]) throws -> Data {
        var out = Data()
        for stream in [Data(count: 8)] + records {
            out += try deflate(stream)
        }
        return Data(out.map { $0 ^ 0x9D })
    }

    /// A 20-byte record header (length, broadcaster index, 0xFF, channel, zero, service id, payload length),
    /// then the payload.
    private func record(channel: UInt32, serviceID: UInt16, payload: Data) -> Data {
        func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        return bigEndian(UInt32(LogoFile.headerLength + payload.count)) + Data([0x00, 0xFF]) + bigEndian(channel)
            + bigEndian(UInt32(0)) + bigEndian(serviceID) + bigEndian(UInt32(payload.count)) + payload
    }

    private func deflate(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var out = Data(count: Int(length))
        let status = out.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compress2(target.bindMemory(to: Bytef.self).baseAddress, &length,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        XCTAssertEqual(status, Z_OK)
        return out.prefix(Int(length))
    }

    func testSomethingThatIsNotAPngIsRejected() {
        XCTAssertThrowsError(try LogoFile.withPalette(Data("not a png".utf8))) { error in
            XCTAssertEqual(error as? GuideError, .notAPng)
        }
        // a truncated or corrupt download should be reported, not quietly treated as "no logos"
        XCTAssertThrowsError(try LogoFile.decode(Data([0x00, 0x01])))
    }
}
