import CryptoKit
import XCTest
@testable import RecorderKit

/// The guide file is the one part of the recorder that is a binary format of its own, so the sample file and
/// its decoded form are checked field by field.
final class EpgVectorTests: XCTestCase {
    private func sample() throws -> (data: Data, expected: [String: Any]) {
        let expected = try Vectors.load("epg-sample.json")
        let data = try Data(contentsOf: Vectors.directory.appendingPathComponent(expected.string("file")))
        return (data, expected)
    }

    func testTheSampleFileIsTheOneTheVectorDescribes() throws {
        let (data, expected) = try sample()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected.string("sha256"))
    }

    func testStreamsAreSplitAtTheirZlibBoundaries() throws {
        let (data, _) = try sample()
        let streams = try Epg.splitStreams(data)
        XCTAssertEqual(streams.count, 2, "one zlib stream per service")
        for stream in streams {
            XCTAssertEqual(String(decoding: stream.prefix(4), as: UTF8.self), "@SRV")
        }
    }

    func testDecodingMatchesTheVector() throws {
        let (data, expected) = try sample()
        let services = try Epg.decode(data)
        let expectedServices = expected.dictionaries("services")

        XCTAssertEqual(services.count, expectedServices.count)
        for (service, expectedService) in zip(services, expectedServices) {
            XCTAssertEqual(service.serviceID, expectedService.int("service_id"))
            XCTAssertEqual(service.name, expectedService.string("name"))

            let expectedPrograms = expectedService.dictionaries("programs")
            XCTAssertEqual(service.programs.count, expectedPrograms.count, "service \(service.serviceID)")
            for (program, expectedProgram) in zip(service.programs, expectedPrograms) {
                let where_ = "service \(service.serviceID) event \(program.eventID)"
                XCTAssertEqual(program.serviceID, expectedProgram.int("service_id"), where_)
                XCTAssertEqual(program.eventID, expectedProgram.int("event_id"), where_)
                XCTAssertEqual(RecorderTime.format(program.start), expectedProgram.string("start"), where_)
                XCTAssertEqual(RecorderTime.format(program.end), expectedProgram.string("end"), where_)
                XCTAssertEqual(program.durationSec, expectedProgram.int("duration_sec"), where_)

                if expectedProgram.bool("reference") {
                    XCTAssertTrue(program.isReference, where_)
                    XCTAssertEqual(program.referenceServiceID, expectedProgram.int("ref_service_id"), where_)
                    XCTAssertEqual(program.referenceEventID, expectedProgram.int("ref_event_id"), where_)
                } else {
                    XCTAssertFalse(program.isReference, where_)
                    XCTAssertEqual(program.title, expectedProgram.string("title"), where_)
                    XCTAssertEqual(program.summary, expectedProgram.string("description"), where_)
                    XCTAssertEqual(program.extended, expectedProgram.string("extended"), where_)
                    XCTAssertEqual(program.copyControl, expectedProgram.int("copy_control"), where_)
                    XCTAssertEqual(program.parentalRating, expectedProgram.int("parental_rating"), where_)
                    XCTAssertEqual(program.genres.map { [$0.level1, $0.level2] },
                                   expectedProgram["genres"] as? [[Int]], where_)
                }
            }
        }
    }

    func testAribSymbolsInTitlesAreSpelledOut() throws {
        let (data, _) = try sample()
        let title = try XCTUnwrap(Epg.decode(data).first?.programs.first?.title)
        XCTAssertTrue(title.hasSuffix("[字]"), title)
    }

    func testAShortRecordIsRejectedRatherThanTrapping() {
        XCTAssertThrowsError(try Epg.parseService(Data([0x40, 0x44, 0x41, 0x59])))
        XCTAssertEqual(try? Epg.decode(Data([0x00, 0x01, 0x02])).count, nil)
    }
}
