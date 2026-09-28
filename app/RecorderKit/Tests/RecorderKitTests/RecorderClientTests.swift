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
        // no criteria, as the official client sends for the internal disk; the recorder answers a
        // criteria it cannot parse with everything, so a filter here could never be seen to fail
        XCTAssertTrue(bodies[0].contains("<SearchCriteria></SearchCriteria>"))
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

    /// One tap on 再生 in standby: the 880 turns the recorder on, the status is asked until it says it is on,
    /// and the play goes again. It used to stop at the 880 and take a second button and a second go.
    func testPlayingInStandbyTurnsTheRecorderOnWaitsForItAndPlays() async throws {
        let answers = [
            Stub.fault("880"),
            Stub.soap("X_PowerControl", result: "<power><powerstatus>PowerOn</powerstatus></power>"),
            Stub.soap("X_GetPlayStatus", result: playStatus("PowerInternalOn")),
            Stub.soap("X_GetPlayStatus", result: playStatus("PowerOn")),
            Stub.soap("X_PlayControlTitle"),
        ]
        let transport = StubTransport { _, index in answers[min(index, answers.count - 1)] }
        let client = RecorderClient(host: Stub.host, transport: transport)
        let waits = Waits()

        try await client.play(titleID: "0x1", interval: .milliseconds(1)) { await waits.add($0) }

        let actions = await transport.requests.map(soapAction)
        XCTAssertEqual(actions, ["X_PlayControlTitle", "X_PowerControl", "X_GetPlayStatus", "X_GetPlayStatus",
                                 "X_PlayControlTitle"])
        let bodies = await transport.bodies
        XCTAssertTrue(bodies[1].contains("<Operation>on</Operation>"), bodies[1])
        XCTAssertTrue(bodies[4].contains("<TitleID>0x1</TitleID>"), bodies[4])
        XCTAssertTrue(bodies[4].contains("<Operation>play</Operation>"), bodies[4])
        let said = await waits.seconds
        XCTAssertEqual(said.count, 2, "the screen is told once for each look at the status")
    }

    /// A recorder that is on plays at once, and nothing about power is sent or asked: that is the usual
    /// case, and the demo's recorder does not report its power state at all.
    func testPlayingOnARecorderThatIsOnSendsOnlyThePlay() async throws {
        let transport = StubTransport(always: Stub.soap("X_PlayControlTitle"))
        let client = RecorderClient(host: Stub.host, transport: transport)
        let waits = Waits()

        try await client.play(titleID: "0x1") { await waits.add($0) }

        let actions = await transport.requests.map(soapAction)
        XCTAssertEqual(actions, ["X_PlayControlTitle"])
        let said = await waits.seconds
        XCTAssertEqual(said, [])
    }

    /// Only standby is worth turning the recorder on for. Anything else it answers -- here a recording it no
    /// longer has -- is the answer.
    func testPlayingSomethingTheRecorderRefusesDoesNotTurnItOn() async throws {
        let transport = StubTransport(always: Stub.fault("820"))
        let client = RecorderClient(host: Stub.host, transport: transport)
        do {
            try await client.play(titleID: "0x1") { _ in }
            XCTFail("a fault should throw")
        } catch let error as RecorderError {
            guard case .soap(_, _, let code, _) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(code, "820")
        }
        let actions = await transport.requests.map(soapAction)
        XCTAssertEqual(actions, ["X_PlayControlTitle"])
    }

    /// The wait is bounded. A recorder that never says it is on is sent the play once more all the same, and
    /// its 880 goes back to the caller, which offers to turn it on by hand.
    func testARecorderThatStaysInStandbyIsGivenUpOnAfterTheLimit() async throws {
        let transport = StubTransport { request, _ in
            switch soapAction(request) {
            case "X_PlayControlTitle": return Stub.fault("880")
            case "X_PowerControl":
                return Stub.soap("X_PowerControl", result: "<power><powerstatus>PowerOn</powerstatus></power>")
            default: return Stub.soap("X_GetPlayStatus", result: playStatus("PowerInternalOn"))
            }
        }
        let client = RecorderClient(host: Stub.host, transport: transport)
        do {
            try await client.play(titleID: "0x1", limit: 0.05, interval: .milliseconds(5)) { _ in }
            XCTFail("a recorder still in standby should throw")
        } catch let error as RecorderError {
            XCTAssertTrue(error.needsPowerOn)
        }
        let actions = await transport.requests.map(soapAction)
        XCTAssertEqual(actions.first, "X_PlayControlTitle")
        XCTAssertEqual(actions.last, "X_PlayControlTitle")
        XCTAssertEqual(actions.filter { $0 == "X_PowerControl" }.count, 1, "turned on once, not on every look")
        XCTAssertTrue(actions.contains("X_GetPlayStatus"))
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

    /// A 503 is the recorder busy with somebody else's request, so the same request goes again, twice, and
    /// an answer on the way is taken as if nothing had happened.
    func testA503IsSentAgainAndAnAnswerAfterItIsTheAnswer() async throws {
        let item = try reservationItem()
        let transport = StubTransport { _, index in
            index < 2 ? HTTPResponse(statusCode: 503)
                : Stub.soap("X_GetRecordScheduleList", result: "<xsrs>\(item)</xsrs>", totalMatches: 1)
        }
        let client = RecorderClient(host: Stub.host, transport: transport, busyRetryDelay: 0...0)

        let reservations = try await client.reservations()
        XCTAssertEqual(reservations.count, 1)
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 3, "the first try and the two after it")
    }

    /// Still busy after that, it is said to be busy: not a fault in the request, not silence, and not a
    /// request the recorder refused.
    func testA503ThatDoesNotClearIsThrownAsBusy() async throws {
        let transport = StubTransport(always: HTTPResponse(statusCode: 503))
        let client = RecorderClient(host: Stub.host, transport: transport, busyRetryDelay: 0...0)

        do {
            _ = try await client.reservations()
            XCTFail("busy all three times")
        } catch let error as RecorderError {
            XCTAssertEqual(error, .busy(action: "X_GetRecordScheduleList"))
            XCTAssertFalse(error.unreachable, "the recorder answered")
            XCTAssertFalse(error.refusal, "it said nothing about the request")
        }
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 1 + RecorderClient.busyRetries)
        let heard = await client.lastAnswer
        XCTAssertNotNil(heard, "a 503 is an answer")
    }

    /// Nothing else of the client's goes in between a request and its tries after a 503, so they do not
    /// meet a request of its own and make it busy in turn.
    func testTheTriesAfterA503KeepTheirPlaceInTheQueue() async throws {
        let item = try reservationItem()
        let transport = StubTransport { request, index in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            if body.contains("X_GetRecordScheduleList"), index == 0 { return HTTPResponse(statusCode: 503) }
            return body.contains("X_GetRecordScheduleList")
                ? Stub.soap("X_GetRecordScheduleList", result: "<xsrs>\(item)</xsrs>", totalMatches: 1)
                : Stub.soap("X_DeleteTitle")
        }
        let client = RecorderClient(host: Stub.host, transport: transport, busyRetryDelay: 0.05...0.05)

        async let list = client.reservations()
        try await Task.sleep(for: .milliseconds(10))
        async let delete: Void = client.deleteTitle(id: "0x1")
        _ = try await (list, delete)

        let actions = await transport.bodies.map { $0.contains("X_DeleteTitle") ? "delete" : "list" }
        XCTAssertEqual(actions, ["list", "list", "delete"])
    }

    /// A recorder busy answering somebody else is still a recorder. Read as any other answer that was not a
    /// description, the app said the recorder at the saved address was not a Sony recorder.
    func testDescribeAnswered503IsBusyRatherThanNotARecorder() async throws {
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: HTTPResponse(statusCode: 503)),
                                    busyRetryDelay: 0...0)
        do {
            _ = try await client.describe(timeout: RecorderClient.probeTimeout)
            XCTFail("busy is not a description")
        } catch let error as RecorderError {
            XCTAssertEqual(error, .busy(action: "description.xml"))
            XCTAssertFalse(error.explanation.contains("ソニー製レコーダーとして応答しませんでした"), error.explanation)
        }
    }

    func testGuideFileUrlHasTwoSlashesAndMissingChannelsAreNotAnError() async throws {
        let transport = StubTransport { _, index in
            index == 0 ? HTTPResponse(statusCode: 200, body: Data([0x01, 0x02])) : HTTPResponse(statusCode: 416)
        }
        // The port is given, so nothing goes looking for it: this test is about the path, and the looking
        // has a test of its own.
        let client = RecorderClient(host: Stub.host, transport: transport, streamPort: 60151)

        let terrestrial = try await client.epgFile("td")
        let missing = try await client.epgFile("bs4k")
        XCTAssertEqual(terrestrial?.count, 2)
        XCTAssertNil(missing, "a broadcasting type the recorder cannot receive is not a failure")

        let urls = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls.first, "http://192.0.2.10:60151//EPG_TRDEPG_FILE.dat")
        XCTAssertEqual(urls.last, "http://192.0.2.10:60151//EPG_ADVBSDEPG_FILE.dat")
    }

    /// The port the guide files are served on is looked for when a guide file is wanted, not on the way in:
    /// `describe` is what the app probes with while waking a recorder, and a walk of the DLNA tree behind it
    /// made a two-second probe take minutes. Asked once, whatever the tree says.
    func testTheStreamPortIsLookedForOnTheFirstGuideFileAndNotOnDescribe() async throws {
        let description = try Vectors.load("description.json").string("description_xml")
        let transport = StubTransport { request, _ in
            if request.url.path == "/description.xml" {
                return HTTPResponse(statusCode: 200, body: Data(description.utf8))
            }
            if request.url.path.hasPrefix("/DMSContentDirectory") {
                return Stub.soap("Browse", result: Stub.didl(resourcePort: 60152))
            }
            return HTTPResponse(statusCode: 200, body: Data([0x01]))
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        _ = try await client.describe()
        let afterDescribe = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(afterDescribe, ["http://192.0.2.10:64220/description.xml"],
                       "describing a recorder is one request")

        _ = try await client.epgFile("td")
        _ = try await client.epgFile("bs")
        let paths = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(paths.filter { $0.contains("DMSContentDirectory") }.count, 1,
                       "the tree is walked once per client, not once per file")
        XCTAssertEqual(paths.last, "http://192.0.2.10:60152//EPG_BSEPG_FILE.dat")
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
        let fileURL = try await client.guideFileURL(named: "x.dat")
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

    /// How long the recorder has been quiet is what decides whether to make sure it is up before asking it
    /// for something, so every answer has to count -- a fault included, since only a recorder that is up
    /// can refuse -- and silence must not.
    func testTheLastAnswerIsKeptAndSilenceLeavesItAlone() async throws {
        let silent = RecorderClient(host: Stub.host, transport: StubTransport { _, _ in
            throw RecorderError.transport("timed out")
        })
        _ = try? await silent.reservations()
        let never = await silent.lastAnswer
        XCTAssertNil(never, "nothing answered, so nothing was heard")

        let refusing = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.fault("402")))
        let before = Date()
        _ = try? await refusing.reservations()
        let heard = await refusing.lastAnswer
        let refused = try XCTUnwrap(heard, "a fault is an answer")
        XCTAssertGreaterThanOrEqual(refused, before)

        let answering = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.soap("X_DeleteTitle")))
        try await answering.deleteTitle(id: "0x1")
        let answered = await answering.lastAnswer
        XCTAssertNotNil(answered)
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

    /// Read as zeros, an answer in another shape was a full disk: 残り 0.0 GB, and a low-space warning.
    func testFreeSpaceThatCannotBeReadIsThrownRatherThanReadAsZero() async throws {
        let wrapped = { (inner: String) in "<RecordDestinationInfo>\(Soap.escape(inner))</RecordDestinationInfo>" }
        let answers = [
            "",
            "<RecordDestinationInfo></RecordDestinationInfo>",
            wrapped("<RecordDestinationInfo totalCapacity=\"4294967296000\""),
            wrapped("<RecordDestinationInfo totalCapacity=\"4294967296000\"/>"),
            wrapped("<RecordDestinationInfo totalCapacity=\"4 TB\" availableCapacity=\"790273982464\"/>"),
        ]
        for extra in answers {
            let response = Stub.soap("X_HDLnkGetRecordDestinationInfo", extra: extra)
            let client = RecorderClient(host: Stub.host, transport: StubTransport(always: response))
            do {
                let capacity = try await client.recordDestinationInfo()
                XCTFail("\(extra) read as \(capacity)")
            } catch let error as RecorderError {
                XCTAssertEqual(error, .unexpectedAnswer(action: "X_HDLnkGetRecordDestinationInfo"), extra)
                XCTAssertFalse(error.unreachable, "the recorder answered: \(extra)")
            }
        }
    }

    /// The firmware and the free space are only shown, and a model that will not give them is still a
    /// recorder that is there. Whatever it answers leaves the value unknown; only silence gets out.
    func testOnlySilenceGetsOutOfAReadTheAppCanDoWithout() async throws {
        let firmware = Stub.soap("X_GetFirmwareVersion",
                                 result: "<firmware><version>35.003.1</version></firmware>")
        let answering = RecorderClient(host: Stub.host, transport: StubTransport(always: firmware))
        let version = try await RecorderError.silenceOnly { try await answering.firmwareVersion() }
        XCTAssertEqual(version, "35.003.1")

        let refusing = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.fault("401")))
        let refused = try await RecorderError.silenceOnly { try await refusing.firmwareVersion() }
        XCTAssertNil(refused, "a model without the call")

        let unreadable = RecorderClient(host: Stub.host,
                                        transport: StubTransport(always: Stub.soap("X_HDLnkGetRecordDestinationInfo")))
        let capacity = try await RecorderError.silenceOnly { try await unreadable.recordDestinationInfo() }
        XCTAssertNil(capacity, "an answer in another shape")

        let silent = RecorderClient(host: Stub.host, transport: StubTransport { _, _ in
            throw RecorderError.transport("timed out")
        })
        do {
            _ = try await RecorderError.silenceOnly { try await silent.recordDestinationInfo() }
            XCTFail("silence was taken for an answer")
        } catch let error as RecorderError {
            XCTAssertTrue(error.unreachable)
        }
    }

    private func titleItem(id: String) -> String {
        "<item id=\"\(id)\"><title>t</title><scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
            + "<scheduledDuration>60</scheduledDuration></item>"
    }
}

/// The action a request was for, from its `SOAPACTION` header.
private func soapAction(_ request: HTTPRequest) -> String {
    String((request.headers["SOAPACTION"] ?? "").split(separator: "#").last ?? "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

/// What `X_GetPlayStatus` says, in the shape the recorder says it (docs/xsrs-api.md).
private func playStatus(_ power: String) -> String {
    "<status><powerstatus>\(power)</powerstatus><playstatus>Stopped</playstatus></status>"
}

/// The seconds `play` said it had been waiting, collected across the actor boundary.
private actor Waits {
    private(set) var seconds: [Int] = []
    func add(_ value: Int) { seconds.append(value) }
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

/// The decisions a bulk run makes about each recording. The recorder's traps are the point: it refuses a
/// protected recording, it refuses one it is still writing to, and it answers success for one it no longer
/// has.
final class BulkWorkTests: XCTestCase {
    private func title(id: String = "0x1", protected: Bool = false,
                       recording: Bool = false) -> RecordedTitle {
        RecordedTitle(id: id, title: "t", start: Date(), durationSec: 1800, broadcastingType: 2,
                      serviceID: 1024, qualityCode: 230, protected: protected, isNew: true,
                      recording: recording, destination: "HDD", sizeMB: 1000, genreCode: 48,
                      lastPlayed: nil, resumeSec: nil)
    }

    /// A recording in progress: the recorder answers a bare HTTP 500, so nothing is sent at all.
    func testARecordingInProgressIsSkippedWithoutAskingTheRecorder() async throws {
        let transport = StubTransport(always: Stub.soap("X_DeleteTitle"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let outcome = try await client.deleteIfPresent(title(recording: true))

        XCTAssertEqual(outcome, .skipped(reason: "録画中です"))
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 0, "a recording in progress should not be sent to the recorder at all")
    }

    func testAProtectedRecordingIsSkippedWithoutAskingTheRecorder() async throws {
        let transport = StubTransport(always: Stub.soap("X_DeleteTitle"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let outcome = try await client.deleteIfPresent(title(protected: true))

        let sent = await transport.requests.count
        XCTAssertEqual(outcome, .skipped(reason: "保護されています"))
        XCTAssertEqual(sent, 0, "nothing should have been sent")
    }

    func testARecordingTheRecorderNoLongerHasIsNotAnError() async throws {
        let transport = StubTransport(always: Stub.fault("820"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let outcome = try await client.deleteIfPresent(title())

        XCTAssertEqual(outcome, .skipped(reason: "すでに削除されています"))
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

        let outcome = try await client.deleteIfPresent(title(id: "0x0000010000034d78"))

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

        let outcome = try await client.deleteIfPresent(title())

        XCTAssertEqual(outcome.reason?.contains("402"), true, outcome.reason ?? "-")
    }

    func testProtectingSendsOnlyWhenItWouldChangeSomething() async throws {
        let transport = StubTransport(always: Stub.soap("X_UpdateTitle"))
        let client = RecorderClient(host: Stub.host, transport: transport)

        let already = try await client.setProtected(title(protected: true), true)
        XCTAssertEqual(already, .skipped(reason: "すでに保護されています"))
        let notProtected = try await client.setProtected(title(protected: false), false)
        XCTAssertEqual(notProtected, .skipped(reason: "保護されていません"))
        let untouched = await transport.requests.count
        XCTAssertEqual(untouched, 0)

        let changed = try await client.setProtected(title(id: "0x2", protected: false), true)
        XCTAssertEqual(changed, .changed)
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 1)
        // the payload travels as a SOAP argument, so it arrives escaped
        XCTAssertTrue(bodies[0].contains("&lt;item id=&quot;0x2&quot;&gt;&lt;titleProtectFlag&gt;1&lt;"), bodies[0])
    }

    /// A recorder that has gone to sleep says nothing to the question asked first, and the delete is then
    /// not sent at all: it would only wait out the same silence, and the run has to stop rather than skip.
    func testSilenceBeforeTheDeleteStopsTheRunWithoutDeleting() async throws {
        let transport = StubTransport { _, _ in throw RecorderError.transport("timed out") }
        let client = RecorderClient(host: Stub.host, transport: transport)

        do {
            _ = try await client.deleteIfPresent(title())
            XCTFail("silence should be thrown, not turned into a skip")
        } catch let error as RecorderError {
            XCTAssertTrue(error.unreachable)
        }
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies[0].contains("X_GetTitleDetail"), bodies[0])
    }

    /// Silence on the delete itself is thrown too. Whether it arrived is unknown, which is why it must not
    /// come back as a skip that the caller could take for "not deleted" -- or send again.
    func testSilenceOnTheDeleteIsThrownRatherThanSkipped() async throws {
        let transport = StubTransport { request, _ in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            if body.contains("X_GetTitleDetail") { return Stub.soap("X_GetTitleDetail", result: "<detail/>") }
            throw RecorderError.transport("timed out")
        }
        let client = RecorderClient(host: Stub.host, transport: transport)

        do {
            _ = try await client.deleteIfPresent(title())
            XCTFail("silence should be thrown, not turned into a skip")
        } catch let error as RecorderError {
            XCTAssertTrue(error.unreachable)
        }
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 2, "asked once and deleted once, and nothing sent again")
    }

    /// The duplicate scan keeps what it reads for good, so only an answer counts as read -- an empty text
    /// included, since some recordings come with none.
    func testTheTextIsReadAndAnEmptyOneIsAnAnswer() async throws {
        let described = RecorderClient(host: Stub.host, transport: StubTransport(always:
            Stub.soap("X_GetTitleDetail", result: "<detail><summary>あらすじ</summary></detail>")))
        let read = try await described.summary(of: "0x1")
        XCTAssertEqual(read, .read("あらすじ"))

        let bare = RecorderClient(host: Stub.host,
                                  transport: StubTransport(always: Stub.soap("X_GetTitleDetail", result: "<detail/>")))
        let empty = try await bare.summary(of: "0x1")
        XCTAssertEqual(empty, .read(""))
    }

    func testARecordingTheRecorderNoLongerHasIsGoneRatherThanRead() async throws {
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.fault("820")))
        let outcome = try await client.summary(of: "0x1")
        XCTAssertEqual(outcome, .gone)
    }

    /// A refusal is not a text. Kept as an empty one, it would be the same as every other failure's and make
    /// copies of recordings that are nothing alike.
    func testARefusedReadIsAFailureRatherThanAnEmptyText() async throws {
        let client = RecorderClient(host: Stub.host, transport: StubTransport(always: Stub.fault("402")))
        let outcome = try await client.summary(of: "0x1")
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("402"), reason)
    }

    func testSilenceWhileReadingIsThrown() async throws {
        let client = RecorderClient(host: Stub.host, transport: StubTransport { _, _ in
            throw RecorderError.transport("timed out")
        })
        do {
            _ = try await client.summary(of: "0x1")
            XCTFail("silence should be thrown, not turned into a failure to read")
        } catch let error as RecorderError {
            XCTAssertTrue(error.unreachable)
        }
    }

    func testSilenceOnProtectingIsThrown() async throws {
        let transport = StubTransport { _, _ in throw RecorderError.transport("timed out") }
        let client = RecorderClient(host: Stub.host, transport: transport)

        do {
            _ = try await client.setProtected(title(protected: false), true)
            XCTFail("silence should be thrown, not turned into a skip")
        } catch let error as RecorderError {
            XCTAssertTrue(error.unreachable)
        }
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 1)
    }
}
