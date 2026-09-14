import Foundation

/// Decoder for the `EPG_*_FILE.dat` files the recorder serves on its media server port.
///
/// The file is XOR 0x9D over a run of zlib streams, one per service. Each stream is an `@SRV` record: a
/// 156-byte header, then `@DAY` blocks holding `@EVT` blocks. Times are seconds since 1970-01-01 00:00 *JST*.
/// See docs/epg-format.md; docs/port/epg-sample.json pins the result down.
public enum Epg {
    static let xorKey: UInt8 = 0x9D
    static let jstEpochOffset = 32400
    static let serviceHeaderLength = 156
    static let eventHeaderLength = 56

    public static func decode(_ data: Data) throws -> [GuideService] {
        try splitStreams(data).compactMap { try? parseService($0) }
    }

    /// Un-XORs the file and inflates every stream in it.
    static func splitStreams(_ data: Data) throws -> [Data] {
        var bytes = [UInt8](data)
        for index in bytes.indices { bytes[index] ^= xorKey }

        var streams: [Data] = []
        var position = 0
        while position < bytes.count {
            let (output, consumed) = try Inflate.first(Array(bytes[position...]))
            if consumed <= 0 { break }
            streams.append(output)
            position += consumed
        }
        return streams
    }

    static func parseService(_ record: Data) throws -> GuideService {
        let bytes = Bytes([UInt8](record))
        guard bytes.marker("@SRV", at: 0) else { throw GuideError.notAServiceRecord }

        let serviceID = bytes.be16(8)
        let nameLength = bytes.be16(26)
        var programs: [GuideProgram] = []

        var day = serviceHeaderLength
        while day + 16 <= bytes.count, bytes.marker("@DAY", at: day) {
            let blockLength = bytes.be32(day + 8)
            guard blockLength > 16 else { break }
            let blockEnd = day + blockLength

            var event = day + 16
            while event + 12 <= blockEnd, bytes.marker("@EVT", at: event) {
                let eventLength = bytes.be16(event + 8)
                guard eventLength >= 28 else { break }
                programs.append(parseEvent(bytes, at: event, serviceID: serviceID))
                event += eventLength
            }
            day += blockLength
        }
        return GuideService(serviceID: serviceID, name: bytes.text(28, nameLength), programs: programs)
    }

    private static func parseEvent(_ bytes: Bytes, at event: Int, serviceID: Int) -> GuideProgram {
        var program = GuideProgram(
            serviceID: serviceID,
            eventID: bytes.be16(event + 6),
            start: date(bytes.be32(event + 16)),
            end: date(bytes.be32(event + 20)),
            title: "", summary: "", extended: "",
            genres: [], copyControl: 0, parentalRating: 0
        )

        let flags = bytes.byte(event + 10)
        let isReference = (flags >> 6) & 1 == 1 && (flags >> 5) & 1 == 0
        if isReference {
            // A simulcast on a sub-channel: start and end, plus which programme on the parent service it is.
            program.referenceServiceID = bytes.be16(event + 24)
            program.referenceEventID = bytes.be16(event + 26)
            return program
        }

        // Three two-byte slots: the content nibbles, then the user nibbles.
        program.genres = (0..<3).compactMap { slot in
            let content = bytes.byte(event + 30 + 2 * slot)
            let user = bytes.byte(event + 31 + 2 * slot)
            guard content != 0 || user != 0 else { return nil }
            return Genre(level1: content >> 4, level2: content & 0xF)
        }
        program.copyControl = (bytes.byte(event + 40) & 0x0C) >> 2
        let rating = bytes.byte(event + 41) & 0x1F
        program.parentalRating = rating < 4 ? 0 : rating - 3

        let titleLength = bytes.be16(event + 44)
        let summaryLength = bytes.be16(event + 46)
        let summaryOffset = bytes.be16(event + 48)
        let extendedOffset = bytes.be16(event + 50)
        let extendedLength = bytes.be16(event + 52)
        let text = event + eventHeaderLength
        program.title = bytes.text(text, titleLength)
        program.summary = bytes.text(text + summaryOffset, summaryLength)
        program.extended = bytes.text(text + extendedOffset, extendedLength)
        return program
    }

    static func date(_ recorderSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(recorderSeconds - jstEpochOffset))
    }
}

/// Reads big-endian fields without trapping on a short or malformed record.
struct Bytes {
    private let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    func byte(_ index: Int) -> Int {
        bytes.indices.contains(index) ? Int(bytes[index]) : 0
    }

    func be16(_ index: Int) -> Int {
        byte(index) << 8 | byte(index + 1)
    }

    func be32(_ index: Int) -> Int {
        byte(index) << 24 | byte(index + 1) << 16 | byte(index + 2) << 8 | byte(index + 3)
    }

    func marker(_ marker: String, at index: Int) -> Bool {
        let expected = [UInt8](marker.utf8)
        guard index >= 0, index + expected.count <= bytes.count else { return false }
        return Array(bytes[index..<index + expected.count]) == expected
    }

    /// UTF-8 text of a field, with the recorder's padding and ARIB symbols dealt with.
    func text(_ index: Int, _ length: Int) -> String {
        guard length > 0, index >= 0, index < bytes.count else { return "" }
        let end = min(index + length, bytes.count)
        return Arib.clean(String(decoding: bytes[index..<end], as: UTF8.self))
    }
}
