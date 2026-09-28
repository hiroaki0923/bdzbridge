import Foundation
import zlib

/// One entry of the logo colour table.
public struct LogoColor: Sendable, Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A station's logo, 64x36, ready to hand to an image view.
public struct StationLogo: Sendable, Equatable, Identifiable {
    /// The three-digit channel number without its leading zeroes: 11 for 011, 101 for BS.
    public var channelNo: Int
    public var serviceID: Int
    /// A PNG with the broadcast standard's colour table filled in, so any image viewer can render it.
    public var png: Data

    public var id: Int { serviceID }
}

/// Decoder for the `EPG_*LOGO_FILE.dat` files served next to the guide files.
///
/// Same wrapping as the guide: XOR 0x9D over a run of zlib streams. The first stream is an eight-byte file
/// header; each of the rest is one service: a 20-byte record header, then a 64x36 palette PNG that has no
/// PLTE chunk of its own because the broadcast standard fixes the colour table. That table is inserted here.
/// A service whose logo has not been received yet carries 1152 zero bytes instead and is skipped.
/// See docs/epg-format.md; docs/port/logo-sample.json pins the result down.
public enum LogoFile {
    static let headerLength = 20
    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    /// Where the IHDR chunk ends: signature, length, type, 13 bytes of data, CRC.
    static let afterIHDR = 8 + 4 + 4 + 13 + 4

    /// The fixed colour table for station logos. Opaque entries first, then the same colours at half alpha.
    public static let clut: [LogoColor] = [
        LogoColor(0, 0, 0, 255), LogoColor(255, 0, 0, 255), LogoColor(0, 255, 0, 255), LogoColor(255, 255, 0, 255),
        LogoColor(0, 0, 255, 255), LogoColor(255, 0, 255, 255), LogoColor(0, 255, 255, 255), LogoColor(255, 255, 255, 255),
        LogoColor(0, 0, 0, 0), LogoColor(170, 0, 0, 255), LogoColor(0, 170, 0, 255), LogoColor(170, 170, 0, 255),
        LogoColor(0, 0, 170, 255), LogoColor(170, 0, 170, 255), LogoColor(0, 170, 170, 255), LogoColor(170, 170, 170, 255),
        LogoColor(0, 0, 85, 255), LogoColor(0, 85, 0, 255), LogoColor(0, 85, 85, 255), LogoColor(0, 85, 170, 255),
        LogoColor(0, 85, 255, 255), LogoColor(0, 170, 85, 255), LogoColor(0, 170, 255, 255), LogoColor(0, 255, 85, 255),
        LogoColor(0, 255, 170, 255), LogoColor(85, 0, 0, 255), LogoColor(85, 0, 85, 255), LogoColor(85, 0, 170, 255),
        LogoColor(85, 0, 255, 255), LogoColor(85, 85, 0, 255), LogoColor(85, 85, 85, 255), LogoColor(85, 85, 170, 255),
        LogoColor(85, 85, 255, 255), LogoColor(85, 170, 0, 255), LogoColor(85, 170, 85, 255), LogoColor(85, 170, 170, 255),
        LogoColor(85, 170, 255, 255), LogoColor(85, 255, 0, 255), LogoColor(85, 255, 85, 255), LogoColor(85, 255, 170, 255),
        LogoColor(85, 255, 255, 255), LogoColor(170, 0, 85, 255), LogoColor(170, 0, 255, 255), LogoColor(170, 85, 0, 255),
        LogoColor(170, 85, 85, 255), LogoColor(170, 85, 170, 255), LogoColor(170, 85, 255, 255), LogoColor(170, 170, 85, 255),
        LogoColor(170, 170, 255, 255), LogoColor(170, 255, 0, 255), LogoColor(170, 255, 85, 255), LogoColor(170, 255, 170, 255),
        LogoColor(170, 255, 255, 255), LogoColor(255, 0, 85, 255), LogoColor(255, 0, 255, 255), LogoColor(255, 85, 0, 255),
        LogoColor(255, 85, 85, 255), LogoColor(255, 85, 170, 255), LogoColor(255, 85, 255, 255), LogoColor(255, 170, 0, 255),
        LogoColor(255, 170, 85, 255), LogoColor(255, 170, 170, 255), LogoColor(255, 170, 255, 255), LogoColor(255, 255, 85, 255),
        LogoColor(255, 255, 255, 255), LogoColor(0, 0, 0, 128), LogoColor(255, 0, 0, 128), LogoColor(0, 255, 0, 128),
        LogoColor(255, 255, 0, 128), LogoColor(0, 0, 255, 128), LogoColor(255, 0, 255, 128), LogoColor(0, 255, 255, 128),
        LogoColor(255, 255, 255, 128), LogoColor(170, 0, 0, 128), LogoColor(0, 170, 0, 128), LogoColor(170, 170, 0, 128),
        LogoColor(0, 0, 170, 128), LogoColor(170, 0, 170, 128), LogoColor(0, 170, 170, 128), LogoColor(170, 170, 170, 128),
        LogoColor(0, 0, 85, 128), LogoColor(0, 85, 0, 128), LogoColor(0, 85, 85, 128), LogoColor(0, 85, 170, 128),
        LogoColor(0, 85, 255, 128), LogoColor(0, 170, 85, 128), LogoColor(0, 170, 255, 128), LogoColor(0, 255, 85, 128),
        LogoColor(0, 255, 170, 128), LogoColor(85, 0, 0, 128), LogoColor(85, 0, 85, 128), LogoColor(85, 0, 170, 128),
        LogoColor(85, 0, 255, 128), LogoColor(85, 85, 0, 128), LogoColor(85, 85, 85, 128), LogoColor(85, 85, 170, 128),
        LogoColor(85, 85, 255, 128), LogoColor(85, 170, 0, 128), LogoColor(85, 170, 85, 128), LogoColor(85, 170, 170, 128),
        LogoColor(85, 170, 255, 128), LogoColor(85, 255, 0, 128), LogoColor(85, 255, 85, 128), LogoColor(85, 255, 170, 128),
        LogoColor(85, 255, 255, 128), LogoColor(170, 0, 85, 128), LogoColor(170, 0, 255, 128), LogoColor(170, 85, 0, 128),
        LogoColor(170, 85, 85, 128), LogoColor(170, 85, 170, 128), LogoColor(170, 85, 255, 128), LogoColor(170, 170, 85, 128),
        LogoColor(170, 170, 255, 128), LogoColor(170, 255, 0, 128), LogoColor(170, 255, 85, 128), LogoColor(170, 255, 170, 128),
        LogoColor(170, 255, 255, 128), LogoColor(255, 0, 85, 128), LogoColor(255, 0, 255, 128), LogoColor(255, 85, 0, 128),
        LogoColor(255, 85, 85, 128), LogoColor(255, 85, 170, 128), LogoColor(255, 85, 255, 128), LogoColor(255, 170, 0, 128),
        LogoColor(255, 170, 85, 128), LogoColor(255, 170, 170, 128), LogoColor(255, 170, 255, 128), LogoColor(255, 255, 85, 128),
        LogoColor(255, 255, 255, 128),
    ]

    public static func decode(_ data: Data) throws -> [StationLogo] {
        let streams = try Epg.splitStreams(data)
        guard streams.count > 1 else { return [] }

        var logos: [StationLogo] = []
        for record in streams.dropFirst() where record.count >= headerLength {
            let bytes = Bytes([UInt8](record))
            // >IBBIIHI: record length, broadcaster index, 0xFF, channel number, zero, service id, payload length
            let channel = bytes.be32(6)
            let serviceID = bytes.be16(14)
            let payloadLength = bytes.be32(16)
            let end = min(headerLength + payloadLength, record.count)
            guard end > headerLength else { continue }
            let payload = record.subdata(in: record.startIndex + headerLength..<record.startIndex + end)
            guard payload.starts(with: pngSignature) else { continue }   // 1152 zero bytes: no logo received
            // A PNG that stops before the end of its header has nowhere to put the palette: that station goes
            // without a logo, as one not received yet does, and the rest of the file is still read.
            guard let png = try? withPalette(payload) else { continue }
            logos.append(StationLogo(channelNo: channel & 0xFFFFFF, serviceID: serviceID, png: png))
        }
        return logos
    }

    /// Inserts the standard palette after IHDR, unless the PNG already carries one. Throws for anything that
    /// is not a PNG at least as long as its signature and header, rather than reading past its end.
    public static func withPalette(_ png: Data) throws -> Data {
        guard png.starts(with: pngSignature), png.count >= afterIHDR else { throw GuideError.notAPng }
        let typeStart = png.startIndex + afterIHDR + 4
        if png.count >= afterIHDR + 8, png.subdata(in: typeStart..<typeStart + 4) == Data("PLTE".utf8) {
            return png
        }
        let split = png.startIndex + afterIHDR
        return png.subdata(in: png.startIndex..<split) + palette + transparency
            + png.subdata(in: split..<png.endIndex)
    }

    private static let palette = chunk("PLTE", Data(clut.flatMap { [$0.red, $0.green, $0.blue] }))
    private static let transparency = chunk("tRNS", Data(clut.map(\.alpha)))

    /// A PNG chunk: length, type, payload, CRC32 of type and payload.
    static func chunk(_ type: String, _ payload: Data) -> Data {
        let body = Data(type.utf8) + payload
        var crc = crc32(0, nil, 0)
        body.withUnsafeBytes { raw in
            crc = crc32(crc, raw.bindMemory(to: UInt8.self).baseAddress, uInt(raw.count))
        }
        var out = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(body)
        withUnsafeBytes(of: UInt32(crc).bigEndian) { out.append(contentsOf: $0) }
        return out
    }
}
