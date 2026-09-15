import XCTest
@testable import RecorderKit

final class RecorderClientTests: XCTestCase {
    private func reservationItem() throws -> String {
        try Vectors.load("xsrs.json").dictionary("parse_reservation").string("item")
    }

    func testReservationListSendsTheRightRequestAndParsesTheAnswer() async throws {
        let item = try reservationItem()
        let transport = StubTransport(always: Stub.soap("X_GetRecordScheduleList",
                                                        result: "<xsrs>\(item)</xsrs>", totalMatches: 1))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let reservations = try await client.reservations()

        XCTAssertEqual(reservations.count, 1)
        XCTAssertEqual(reservations.first?.id, "0x00000000000a9432")
        XCTAssertEqual(reservations.first?.serviceID, 0x400)

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.absoluteString, "http://192.0.2.10:64220/XSRS")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["SOAPACTION"], "\"\(Upnp.xsrsService)#X_GetRecordScheduleList\"")
        XCTAssertEqual(request.headers["Content-Type"], "text/xml; charset=\"utf-8\"")
        XCTAssertEqual(request.headers["Accept-Language"], "ja")

        let bodies = await transport.bodies
        let body = try XCTUnwrap(bodies.first)
        XCTAssertTrue(body.contains("<u:X_GetRecordScheduleList xmlns:u=\"\(Upnp.xsrsService)\">"), body)
        XCTAssertTrue(body.contains("<SortCriteria>-scheduledStartDateTime</SortCriteria>"), body)
    }

    func testAllTitlesFollowsTotalMatches() async throws {
        let first = "<xsrs>" + (0..<2).map { titleItem(id: "0x\($0)") }.joined() + "</xsrs>"
        let second = "<xsrs>\(titleItem(id: "0x2"))</xsrs>"
        let transport = StubTransport { _, index in
            Stub.soap("X_GetTitleList", result: index == 0 ? first : second, totalMatches: 3)
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        let titles = try await client.allTitles(pageSize: 2)

        XCTAssertEqual(titles.map(\.id), ["0x0", "0x1", "0x2"])
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("<StartingIndex>0</StartingIndex>"))
        XCTAssertTrue(bodies[1].contains("<StartingIndex>2</StartingIndex>"))
        // the exact criteria syntax, escaped as the SOAP body carries it: a criteria the recorder cannot
        // parse matches everything instead of failing, so a typo here would go unnoticed
        XCTAssertTrue(bodies[0].contains("<SearchCriteria>recordDestinationID = &quot;HDD&quot;</SearchCriteria>"))
    }

    func testAFaultBecomesAnErrorThatNamesTheCode() async throws {
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.fault("402")))
        do {
            _ = try await client.reservations()
            XCTFail("a fault should throw")
        } catch let error as RecorderError {
            guard case .soap(let action, let status, let code, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(action, "X_GetRecordScheduleList")
            XCTAssertEqual(status, 500)
            XCTAssertEqual(code, "402")
            XCTAssertTrue(error.explanation.contains("402"))
            XCTAssertFalse(error.needsPowerOn)
        }
    }

    /// 831 on a create is the recorder refusing to follow a programme on a channel it cannot receive, seen
    /// on a BDZ-FBT4100 with a pay channel the box is not subscribed to. It reads as a broken app unless it
    /// is told apart, so it has its own flag and its own wording.
    func testAnUnreceivableChannelIsRecognisedOnItsOwn() async throws {
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.fault("831")))
        do {
            _ = try await client.createReservation(ReservationRequest(
                title: "x", start: Date(), durationSec: 1800, repeatCode: "1", broadcastingType: 4,
                serviceID: 298, qualityCode: 240, eventID: 1))
            XCTFail("a fault should throw")
        } catch let error as RecorderError {
            XCTAssertTrue(error.unreceivableChannel)
            XCTAssertFalse(error.unknownReservation)
            XCTAssertTrue(error.explanation.contains("831"))
            XCTAssertTrue(error.explanation.contains("受信"))
        }
    }

    func testStandbyIsRecognisedSoTheCallerCanPowerTheRecorderOn() async throws {
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.fault("880")))
        do {
            try await client.playControl(titleID: "0x1", operation: "play")
            XCTFail("a fault should throw")
        } catch let error as RecorderError {
            XCTAssertTrue(error.needsPowerOn)
        }
    }

    func testRequestsNeverOverlapBecauseTheRecorderAnswers503ToConcurrentCalls() async throws {
        let item = try reservationItem()
        let transport = StubTransport { _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return Stub.soap("X_GetRecordScheduleList", result: "<xsrs>\(item)</xsrs>", totalMatches: 1)
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask { try await client.reservations().count }
            }
            for try await count in group { XCTAssertEqual(count, 1) }
        }

        let sent = await transport.requests.count
        let overlap = await transport.maxConcurrent
        XCTAssertEqual(sent, 5)
        XCTAssertEqual(overlap, 1, "requests overlapped; the recorder would answer 503")
    }

    func testGuideFileUrlHasTwoSlashesAndMissingChannelsAreNotAnError() async throws {
        let transport = StubTransport { _, index in
            index == 0 ? HTTPResponse(statusCode: 200, body: Data([0x01, 0x02])) : HTTPResponse(statusCode: 416)
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        let terrestrial = try await client.epgFile("td")
        let missing = try await client.epgFile("bs4k")
        XCTAssertEqual(terrestrial?.count, 2)
        XCTAssertNil(missing, "a broadcasting type the recorder cannot receive is not a failure")

        let urls = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls.first, "http://192.0.2.10:60151//EPG_TRDEPG_FILE.dat")
        XCTAssertEqual(urls.last, "http://192.0.2.10:60151//EPG_ADVBSDEPG_FILE.dat")
    }

    func testStreamPortIsTakenFromTheDlnaTree() async throws {
        let transport = StubTransport { request, _ in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            if body.contains("<ObjectID>0</ObjectID>") {
                return Stub.soap("Browse", result: Stub.didl(containers: ["1", "2"]))
            }
            return Stub.soap("Browse", result: Stub.didl(resourcePort: 60152))
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        let detected = try await client.detectStreamPort()
        let remembered = await client.streamPort
        let fileURL = await client.guideFileURL(named: "x.dat")
        XCTAssertEqual(detected, 60152)
        XCTAssertEqual(remembered, 60152)
        XCTAssertEqual(fileURL.absoluteString, "http://192.0.2.10:60152//x.dat")
    }

    func testDescribeAcceptsARecorderAndRejectsAnythingElse() async throws {
        let description = try Vectors.load("description.json").string("description_xml")
        let transport = StubTransport { request, _ in
            request.url.path == "/description.xml"
                ? HTTPResponse(statusCode: 200, body: Data(description.utf8))
                : Stub.soap("Browse", result: Stub.didl(resourcePort: 60151))
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        let info = try await client.describe(via: "scan")
        let remembered = await client.info
        XCTAssertEqual(info.product, "BDZ-FBT4100")
        XCTAssertTrue(info.epgCapable)
        XCTAssertEqual(remembered?.udn, info.udn)
        XCTAssertEqual(info.via, "scan")

        let television = "<root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
            + "<manufacturer>Sony Corporation</manufacturer><friendlyName>TV</friendlyName></device></root>"
        let other = RecorderClient(host: "192.0.2.11",
                                   transport: StubTransport(always: HTTPResponse(statusCode: 200,
                                                                                 body: Data(television.utf8))))
        do {
            _ = try await other.describe()
            XCTFail("a television is not a recorder")
        } catch let error as RecorderError {
            XCTAssertEqual(error, .notARecorder(host: "192.0.2.11"))
        }
    }

    func testTitleDetailReadsTheSummaryAndTheDetailParagraphs() async throws {
        let detail = "<detail><summary>あらすじ</summary><detail1>本文1</detail1><detail2>本文2</detail2></detail>"
        let client = RecorderClient(host: Stub.host,
                                    transport: StubTransport(always: Stub.soap("X_GetTitleDetail", result: detail)))
        let (summary, details) = try await client.titleDetail(id: "0x1")
        XCTAssertEqual(summary, "あらすじ")
        XCTAssertEqual(details, ["本文1", "本文2"])
    }

    func testFreeSpaceComesBackInBytes() async throws {
        // The capacity arrives in an element of its own, not in Result, and is escaped XML like Result is.
        let info = "<RecordDestinationInfo totalCapacity=\"4294967296000\" availableCapacity=\"790273982464\"/>"
        let response = Stub.soap("X_HDLnkGetRecordDestinationInfo",
                                 extra: "<RecordDestinationInfo>\(Soap.escape(info))</RecordDestinationInfo>")
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: response))
        let capacity = try await client.recordDestinationInfo()
        XCTAssertEqual(capacity.totalBytes, 4_294_967_296_000)
        XCTAssertEqual(capacity.freeBytes, 790_273_982_464)
    }

    private func titleItem(id: String) -> String {
        "<item id=\"\(id)\"><title>t</title><scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
            + "<scheduledDuration>60</scheduledDuration></item>"
    }
}

extension RecorderClientTests {
    func testDeletingAReservationSendsItsIDAndNothingElse() async throws {
        let transport = StubTransport(always: Stub.soap("X_DeleteRecordSchedule"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        try await client.deleteReservation(id: "0x00000000000d37f7")

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.absoluteString, "http://192.0.2.10:64220/XSRS")
        XCTAssertEqual(request.headers["SOAPACTION"], "\"\(Upnp.xsrsService)#X_DeleteRecordSchedule\"")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("<RecordScheduleID>0x00000000000d37f7</RecordScheduleID>"), body)
    }
}

/// The decisions a bulk run makes about each recording. The recorder's two traps are the point: it refuses a
/// protected recording, and it answers success for one it no longer has.
final class BulkWorkTests: XCTestCase {
    private func title(id: String = "0x1", protected: Bool = false) -> RecordedTitle {
        RecordedTitle(id: id, title: "t", start: Date(), durationSec: 1800, broadcastingType: 2,
                      serviceID: 1024, qualityCode: 230, protected: protected, isNew: true,
                      destination: "HDD", sizeMB: 1000, genreCode: 48, lastPlayed: nil, resumeSec: nil)
    }

    func testAProtectedRecordingIsSkippedWithoutAskingTheRecorder() async throws {
        let transport = StubTransport(always: Stub.soap("X_DeleteTitle"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let outcome = await client.deleteIfPresent(title(protected: true))

        let sent = await transport.requests.count
        XCTAssertEqual(outcome, .skipped(reason: "保護されています"))
        XCTAssertEqual(sent, 0, "nothing should have been sent")
    }

    func testARecordingTheRecorderNoLongerHasIsNotAnError() async throws {
        let transport = StubTransport(always: Stub.fault("820"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let outcome = await client.deleteIfPresent(title())

        XCTAssertEqual(outcome, .skipped(reason: "すでにありません"))
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 1, "it asked, and then knew better than to delete")
        XCTAssertTrue(bodies[0].contains("X_GetTitleDetail"), bodies[0])
    }

    func testDeletingAsksFirstAndThenDeletes() async throws {
        let transport = StubTransport { request, _ in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            return body.contains("X_GetTitleDetail")
                ? Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")
                : Stub.soap("X_DeleteTitle")
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        let outcome = await client.deleteIfPresent(title(id: "0x0000010000034d78"))

        XCTAssertEqual(outcome, .changed)
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[1].contains("<TitleID>0x0000010000034d78</TitleID>"), bodies[1])
    }

    func testARefusedDeleteReportsWhyRatherThanThrowing() async throws {
        let transport = StubTransport { request, _ in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            return body.contains("X_GetTitleDetail") ? Stub.soap("X_GetTitleDetail", result: "<detail/>")
                                                     : Stub.fault("402")
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        let outcome = await client.deleteIfPresent(title())

        XCTAssertEqual(outcome.reason?.contains("402"), true, outcome.reason ?? "-")
    }

    func testProtectingSendsOnlyWhenItWouldChangeSomething() async throws {
        let transport = StubTransport(always: Stub.soap("X_UpdateTitle"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let already = await client.setProtected(title(protected: true), true)
        XCTAssertEqual(already, .skipped(reason: "すでに保護されています"))
        let notProtected = await client.setProtected(title(protected: false), false)
        XCTAssertEqual(notProtected, .skipped(reason: "保護されていません"))
        let untouched = await transport.requests.count
        XCTAssertEqual(untouched, 0)

        let changed = await client.setProtected(title(id: "0x2", protected: false), true)
        XCTAssertEqual(changed, .changed)
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 1)
        // the payload travels as a SOAP argument, so it arrives escaped
        XCTAssertTrue(bodies[0].contains("&lt;item id=&quot;0x2&quot;&gt;&lt;titleProtectFlag&gt;1&lt;"), bodies[0])
    }
}
