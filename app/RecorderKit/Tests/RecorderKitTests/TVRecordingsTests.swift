import Foundation
import XCTest
@testable import RecorderKit

/// A television's recordings as the client reads them and as the invented television gives them, in the shapes
/// a real one was measured to: version 1.5 of the list by `uri`, fifty to a page, its flags as strings, its
/// length in an object, its size in `sizeMB`, a row being recorded listed at nought, and the writes' two errors.
/// Every value is invented. What the driver makes of them is in `TVDriverRecordingsTests`.
final class TVRecordingsTests: XCTestCase {
    private static let kept = TVCredentials(clientID: "BDBridge:test", cookie: "kept")

    /// Nine in the evening in Japan on Sunday 1 November 2026, as a television writes it.
    private static let start = Date(timeIntervalSince1970: 1_793_534_400)
    private static let written = "2026-11-01T21:00:00+0900"

    private func ok(_ result: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"result":\#(result),"id":1}"#.utf8))
    }

    private func client(_ transport: any HTTPTransport) -> ScalarClient {
        ScalarClient(host: Stub.host, transport: transport, credentials: MemoryTVCredentials(Self.kept))
    }

    private func television(_ recordings: [DemoTV.Recording] = [], diskMB: Int = 100_000) async -> (DemoTV, ScalarClient) {
        let television = DemoTV(recordings: recordings, diskMB: diskMB)
        await television.knows(Self.kept.clientID, cookie: "kept")
        return (television, client(television))
    }

    private func recording(_ number: Int, sizeMB: Int = 3000, protected: Bool = false,
                           recording: Bool = false) -> DemoTV.Recording {
        DemoTV.Recording(contentID: number, title: "サンプル番組\(number)", start: Self.start, sizeMB: sizeMB,
                         protected: protected, recording: recording)
    }

    /// What an operation was refused with: the code of the method's own error, 0 for any other failure, and
    /// nil when it went through.
    private func code(of operation: () async throws -> Void) async -> Int? {
        do {
            try await operation()
            return nil
        } catch let ScalarError.rpc(_, _, code, _) {
            return code
        } catch {
            return 0
        }
    }

    // MARK: - a row

    /// A row as a real one wrote it: the uri is the row's id, the television's own name for the recording; the
    /// start with no colon in its offset; the length out of its object; the size in `sizeMB`, never in
    /// `fileSizeByte`, which is -1 on a large one; the three flags as the strings they are; the text and the
    /// genre; and nothing a recorder's row has that this one does not.
    func testARowIsReadAsItWasWritten() throws {
        let row: [String: ScalarValue] = [
            "title": "サンプル番組", "channelName": "サンプルテレビ", "uri": "usb:recStorage?contentId=7", "index": 0,
            "startDateTime": .string(Self.written), "duration": .object(["durationSec": 1808]), "sizeMB": 3011,
            "fileSizeByte": -1, "isProtected": "true", "isAlreadyPlayed": "true",
            "recordingInfo": .object(["isRecording": "false"]),
            "description": .object(["summary": "あらすじ", "detail": "くわしい内容"]),
            "broadcastGenreInfo": .list([.object(["genreId": 48]), .object(["genreId": 96])]),
        ]
        let title = try XCTUnwrap(RecordedTitle(televisionRow: row))

        XCTAssertEqual(title.id, "usb:recStorage?contentId=7")
        XCTAssertEqual(title.title, "サンプル番組")
        XCTAssertEqual(title.channelName, "サンプルテレビ")
        XCTAssertEqual(title.start, Self.start)
        XCTAssertEqual(title.durationSec, 1808)
        XCTAssertEqual(title.sizeMB, 3011)
        XCTAssertTrue(title.protected)
        XCTAssertFalse(title.isNew, "a row played is not new")
        XCTAssertFalse(title.recording)
        XCTAssertEqual(title.summary, "あらすじ")
        XCTAssertEqual(title.details, "くわしい内容")
        XCTAssertEqual(title.genreCode, 48)
        XCTAssertEqual(title.device, .tv)
        XCTAssertEqual(title.destination, TVDriver.recordsTo)
        XCTAssertNil(title.readFrom)
        XCTAssertNil(title.qualityName, "a row says no mode")
        XCTAssertNil(title.resumeSec)
    }

    /// A row being recorded says nought for its length and its size, which do not grow until it ends: it is
    /// said to be recorded, with no size and no length known. Text may be absent, or there and empty, and a row
    /// with no flags is one that is neither protected nor played.
    func testARowBeingRecordedHasNoSizeAndNoLength() throws {
        let recording: [String: ScalarValue] = [
            "title": "サンプル番組", "uri": "usb:recStorage?contentId=8", "startDateTime": .string(Self.written),
            "duration": .object(["durationSec": 0]), "sizeMB": 0, "fileSizeByte": 0,
            "isProtected": "false", "isAlreadyPlayed": "false", "recordingInfo": .object(["isRecording": "true"]),
            "description": .object(["summary": "", "detail": ""]),
        ]
        let title = try XCTUnwrap(RecordedTitle(televisionRow: recording))
        XCTAssertTrue(title.recording)
        XCTAssertFalse(title.lengthKnown)
        XCTAssertNil(title.sizeMB)
        XCTAssertNil(title.summary, "an empty text is none")
        XCTAssertNil(title.details)
        XCTAssertTrue(title.isNew)
        XCTAssertFalse(title.protected)

        let bare = try XCTUnwrap(RecordedTitle(televisionRow: ["uri": "usb:recStorage?contentId=9",
                                                               "startDateTime": .string(Self.written)]))
        XCTAssertEqual(bare.title, "")
        XCTAssertEqual(bare.durationSec, 0)
        XCTAssertTrue(bare.lengthKnown, "only a row being recorded has its length unknown")
        XCTAssertFalse(bare.protected)
        XCTAssertNil(bare.channelName)
        XCTAssertNil(bare.genreCode)

        XCTAssertNil(RecordedTitle(televisionRow: ["startDateTime": .string(Self.written)]), "a row with no uri")
        XCTAssertNil(RecordedTitle(televisionRow: ["uri": "x", "startDateTime": "yesterday"]), "a start that does not read")
        XCTAssertNil(RecordedTitle(televisionRow: ["uri": "x"]), "a row with no start")
    }

    /// Rows of the two devices are told apart in one list: a television's by its uri behind the device, whatever
    /// a recorder's row of the same id is called. A recorder's keep what they had, and the length of a recording
    /// being recorded on one is known, the recorder listing what it was set to.
    func testTheTwoDevicesRowsAreToldApart() throws {
        let row = try XCTUnwrap(RecordedTitle(televisionRow: ["uri": "usb:recStorage?contentId=7",
                                                              "startDateTime": .string(Self.written)]))
        XCTAssertEqual(row.listKey, "tv|usb:recStorage?contentId=7")
        var recorders = RecordedTitle(id: "7", title: "", start: Self.start, durationSec: 60, broadcastingType: 0,
                                      serviceID: 0, qualityCode: 0, protected: false, isNew: false, recording: true,
                                      destination: RecorderDisk.internalID)
        XCTAssertEqual(recorders.listKey, "7")
        XCTAssertTrue(recorders.lengthKnown)
        recorders.readFrom = RecorderDisk(destination: RecorderDisk.usbID, name: "", mounted: true, freeMB: 1,
                                          totalMB: 1, registered: "at")
        XCTAssertEqual(recorders.listKey, "at|7")
    }

    // MARK: - the list

    /// One request a page, each version 1.5 with `uri`, `stIdx` and `cnt`, fifty to a page, and a short page
    /// ends it. No row is sorted: the list is handed back in the television's order.
    func testTheListIsAskedForAsItWasMeasured() async throws {
        let rows = (1...123).reversed().map { recording($0) }
        let (television, tv) = await television(rows)

        let titles = try await tv.recordings()

        XCTAssertEqual(titles.map(\.id), rows.map(\.uri))
        expectEqual(await television.calls, Array(repeating: "getContentList cookie=yes pin=no", count: 3))
        let bodies = await television.bodies
        XCTAssertEqual(bodies.first, #"{"id":1,"method":"getContentList","params":[{"cnt":50,"stIdx":0,"#
                       + #""uri":"usb:recStorage"}],"version":"1.5"}"#)
        XCTAssertEqual(bodies.last, #"{"id":3,"method":"getContentList","params":[{"cnt":50,"stIdx":100,"#
                       + #""uri":"usb:recStorage"}],"version":"1.5"}"#)
    }

    /// A list that ends on a whole page ends on the empty page after it, which is no error; an empty list is
    /// one request.
    func testAWholeLastPageEndsOnTheEmptyPageAfterIt() async throws {
        let (television, tv) = await television((1...50).map { recording($0) })
        expectEqual(try await tv.recordings().count, 50)
        expectEqual(await television.calls.count, 2)

        let (none, empty) = await self.television()
        expectEqual(try await empty.recordings(), [])
        expectEqual(await none.calls.count, 1)
    }

    /// A row that cannot be read is left out and counted all the same, so that a page of them still says that a
    /// page follows.
    func testARowThatCannotBeReadIsLeftOutAndCounted() async throws {
        let row = #"{"uri":"usb:recStorage?contentId=1","startDateTime":"\#(Self.written)"}"#
        let first = "[[" + Array(repeating: #"{"uri":"x"}"#, count: 50).joined(separator: ",") + "]]"
        let answers = [ok(first), ok("[[\(row)]]")]
        let transport = StubTransport { _, index in answers[index] }
        expectEqual(try await client(transport).recordings().map(\.id), ["usb:recStorage?contentId=1"])
    }

    /// A failure on any page throws, nothing being handed back of the pages before it: a list cut short would
    /// say of the rows past that page that they are not there. A list that does not end is not one that was read.
    func testAListCutShortIsNoList() async throws {
        let page = ok("[[" + Array(repeating: #"{"uri":"x"}"#, count: 50).joined(separator: ",") + "]]")
        let cut = StubTransport { _, index in
            if index == 0 { return page }
            throw RecorderError.transport("The request timed out.")
        }
        expectEqual(await failure { _ = try await client(cut).recordings() }, .silent)

        let endless = StubTransport(always: page)
        expectEqual(await failure { _ = try await client(endless).recordings() },
                    ScalarError.unreadable(method: "getContentList").failure)
        expectEqual(await endless.requests.count, ScalarClient.recordingPages)
    }

    /// A delete's two refusals: 41001, a uri the television does not list, is a row gone, as a recorder's 820 is.
    func testAnUnknownRecordingIsARowGone() {
        XCTAssertEqual(ScalarError.rpc(method: "deleteContent", version: "1.0", code: 41001, message: "").failure,
                       .unknownItem)
    }

    // MARK: - the invented television

    /// It writes a row as a real one wrote it, down to the types: strings for the flags, the length in an object,
    /// `sizeMB` a whole number, `fileSizeByte` -1 on a large one, `index` its place, and no text where it has none.
    func testTheInventedTelevisionWritesARowAsARealOneDid() async throws {
        var large = recording(1, sizeMB: 7000)
        large.summary = "あらすじ"
        large.details = "くわしい内容"
        large.genre = 48
        large.played = true
        let small = recording(2, sizeMB: 100)
        let (_, tv) = await television([large, small, recording(3, recording: true)])

        let page = try await tv.contentPage(version: "1.5", params: ["uri": "usb:recStorage", "stIdx": 0, "cnt": 50])

        XCTAssertEqual(page[0], [
            "title": "サンプル番組1", "channelName": "サンプルテレビ", "uri": "usb:recStorage?contentId=1", "index": 0,
            "startDateTime": .string(Self.written), "duration": .object(["durationSec": 1800]), "sizeMB": 7000,
            "fileSizeByte": -1, "isProtected": "false", "isAlreadyPlayed": "true",
            "recordingInfo": .object(["isRecording": "false"]),
            "description": .object(["summary": "あらすじ", "detail": "くわしい内容"]),
            "broadcastGenreInfo": .list([.object(["genreId": 48])]),
        ])
        XCTAssertEqual(page[1]["fileSizeByte"], 100_000_000)
        XCTAssertEqual(page[1]["index"], 1)
        XCTAssertNil(page[1]["description"], "text where it has none")
        XCTAssertEqual(page[2]["duration"], .object(["durationSec": 0]), "a row being recorded")
        XCTAssertEqual(page[2]["sizeMB"], 0)
        XCTAssertEqual(page[2]["fileSizeByte"], 0)
        XCTAssertEqual(page[2]["recordingInfo"], .object(["isRecording": "true"]))
    }

    /// Its disk adds up: what it holds comes off its free space, what is deleted goes back on, and a row being
    /// recorded fills the disk while its row says nought. A count matches the rows. With its disk away the list,
    /// the count and the writes answer 41020, and with a cookie it does not know, 403.
    func testItsDiskAddsUpAndItsCountMatches() async throws {
        let (television, tv) = await television([recording(1, sizeMB: 5000), recording(2, sizeMB: 3000, recording: true)],
                                                diskMB: 20_000)
        expectEqual(try await tv.storage(), TVStorage(mounted: true, freeMB: 11_400, totalMB: 20_000))
        expectEqual(try await tv.contentCount(version: "1.0", params: ["source": "usb:recStorage"]), 2)
        expectEqual(try await tv.contentCount(version: "1.1", params: ["source": "usb:recStorage", "target": "all"]), 2)

        try await tv.deleteContent(uri: "usb:recStorage?contentId=1")
        expectEqual(try await tv.storage(), TVStorage(mounted: true, freeMB: 16_400, totalMB: 20_000))

        await television.unmount()
        let list = ["uri": ScalarValue.string("usb:recStorage"), "stIdx": 0, "cnt": 50]
        expectEqual(await code { _ = try await tv.contentPage(version: "1.5", params: list) }, 41020)
        expectEqual(await code { _ = try await tv.contentCount(version: "1.1", params: ["source": "usb:recStorage"]) },
                    41020)
        expectEqual(await code { try await tv.deleteContent(uri: "usb:recStorage?contentId=2") }, 41020)
        await television.unmount(false)

        let stranger = ScalarClient(host: Stub.host, transport: television, credentials: MemoryTVCredentials(
            TVCredentials(clientID: "BDBridge:test", cookie: "stale")))
        expectEqual(await failure { _ = try await stranger.recordings() }, .needsPairing)
        expectEqual(await failure { try await stranger.deleteContent(uri: "x") }, .needsPairing)
    }

    /// A row can be kept out of its list, as a real one kept rows out that its own screen showed: the disk goes
    /// on counting it, and a write finds it. Put back, it is listed again.
    func testARowLeftOutOfTheListIsStillOnTheDisk() async throws {
        let rows = [recording(1, sizeMB: 2000), recording(2, sizeMB: 4000)]
        let (television, tv) = await television(rows, diskMB: 20_000)

        await television.leavesOutOfItsList([rows[1].uri])
        expectEqual(try await tv.recordings().map(\.id), [rows[0].uri])
        expectEqual(try await tv.contentCount(version: "1.1", params: ["source": "usb:recStorage"]), 1)
        expectEqual(try await tv.storage().freeMB, 13_400)

        await television.leavesOutOfItsList([])
        expectEqual(try await tv.recordings().count, 2)
    }

    /// A protect goes through and shows in the list; a delete of a protected row is 41000 and leaves it, of an
    /// unknown uri 41001, and once its protection is off it goes, the others untouched. A row being recorded is
    /// answered with the invented error: no real one was sent a write of one.
    func testWritesAreAnsweredAsARealOneAnswered() async throws {
        let rows = [recording(1), recording(2), recording(3, recording: true)]
        let (_, tv) = await television(rows)

        try await tv.setDeleteProtection(uri: rows[0].uri, true)
        expectEqual(try await tv.recordings().map(\.protected), [true, false, false])
        expectEqual(await code { try await tv.deleteContent(uri: rows[0].uri) }, 41000)
        expectEqual(try await tv.recordings().count, 3)

        expectEqual(await code { try await tv.deleteContent(uri: "usb:recStorage?contentId=99") }, 41001)
        expectEqual(await code { try await tv.setDeleteProtection(uri: "usb:recStorage?contentId=99", true) }, 41001)

        expectEqual(await code { try await tv.deleteContent(uri: rows[2].uri) }, DemoTV.inventedError)
        expectEqual(await code { try await tv.setDeleteProtection(uri: rows[2].uri, true) }, DemoTV.inventedError)

        try await tv.setDeleteProtection(uri: rows[0].uri, false)
        try await tv.deleteContent(uri: rows[0].uri)
        expectEqual(try await tv.recordings().map(\.id), [rows[1].uri, rows[2].uri])
        expectEqual(await code { try await tv.deleteContent(uri: rows[0].uri) }, 41001, "the same delete again")
    }

    /// It takes a list and a write only as a real one was sent them: another field, or another source, is
    /// answered with the invented error.
    func testAListOrAWriteAskedOtherwiseIsRefused() async throws {
        let (_, tv) = await television([recording(1)])
        for params: [String: ScalarValue] in [["uri": "usb:recStorage", "stIdx": 0],
                                              ["uri": "usb:other", "stIdx": 0, "cnt": 50],
                                              ["uri": "usb:recStorage", "stIdx": 0, "cnt": 50, "target": "all"]] {
            expectEqual(await code { _ = try await tv.contentPage(version: "1.5", params: params) },
                        DemoTV.inventedError, "\(params)")
        }
    }

    /// What a failure throws, as the rules read it.
    private func failure(_ operation: () async throws -> Void) async -> DeviceFailure? {
        do {
            try await operation()
            return nil
        } catch let error as any DeviceError {
            return error.failure
        } catch {
            return nil
        }
    }
}
