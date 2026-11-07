import XCTest
@testable import RecorderKit

/// What a television says it speaks (`TVCapabilities`, `ScalarClient.capabilities`), as the settings report it.
final class TVCapabilitiesTests: XCTestCase {

    /// An older television: the recording service in version 1.0 alone, an avContent it does not have, and an
    /// accessControl that answers an error. Nothing it is asked needs a registration.
    private func anOlderTelevision() -> StubTransport {
        StubTransport { request, _ in
            XCTAssertNil(request.headers["Cookie"], "a registration was sent")
            let object = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
            let service = String(request.url.path.dropFirst("/sony/".count))
            switch (service, object["method"] as? String ?? "") {
            case ("system", "getInterfaceInformation"):
                return json(["result": [["productCategory": "tv", "productName": "BRAVIA", "modelName": "KDL-SAMPLE",
                                              "serverName": "", "interfaceVersion": "2.4.0"]], "id": 1])
            case ("system", "getVersions"):
                return json(["result": [["1.0"]], "id": 1])
            case ("system", "getMethodTypes"):
                return json(["results": [["getPowerStatus", [], ["{\"status\":\"string\"}"], "1.0"],
                                              ["getCurrentTime", [], ["string"], "1.0"]], "id": 1])
            case ("recording", "getVersions"):
                return json(["result": [["1.0"]], "id": 1])
            case ("recording", "getMethodTypes"):
                // As `result`, which some answer with in place of `results`.
                return json(["result": [["getScheduleList", ["{\"stIdx\":\"int\",\"cnt\":\"int\"}"],
                                              ["{\"id\":\"string\"}*"], "1.0"]], "id": 1])
            case ("avContent", _):
                return HTTPResponse(statusCode: 404)
            default:
                return json(["error": [12, "nope"], "id": 1])
            }
        }
    }

    func testAnOlderTelevisionIsReadServiceByServiceAndWhatCouldNotBeReadIsSaid() async throws {
        let client = ScalarClient(host: Stub.host, transport: anOlderTelevision(), credentials: MemoryTVCredentials())
        let capabilities = await client.capabilities()
        XCTAssertEqual(capabilities.model, "KDL-SAMPLE")
        XCTAssertEqual(capabilities.interfaceVersion, "2.4.0")
        XCTAssertEqual(capabilities.services.map(\.name), TVCapabilities.servicesAsked)
        let recording = try XCTUnwrap(capabilities.services.first { $0.name == "recording" })
        XCTAssertEqual(recording.versions, ["1.0"])
        XCTAssertEqual(recording.methods, [.init(name: "getScheduleList", version: "1.0",
                                                 parameters: ["{\"stIdx\":\"int\",\"cnt\":\"int\"}"],
                                                 results: ["{\"id\":\"string\"}*"])])
        XCTAssertEqual(capabilities.services.first { $0.name == "avContent" }?.failure, "読めませんでした（HTTP 404）")
        XCTAssertEqual(capabilities.services.first { $0.name == "accessControl" }?.failure, "読めませんでした（エラー 12）")

        XCTAssertEqual(capabilities.report(app: "0.5 (1)"), """
            RecBridge 0.5 (1)
            機種: KDL-SAMPLE（2.4.0）
            電源: 読めませんでした（エラー 12）
            録画の状態: 読めませんでした（エラー 12）
            Wake-on-LAN の MAC: 読めませんでした（エラー 12）

            system 1.0
              getPowerStatus 1.0 () → ({"status":"string"})
              ほか: getCurrentTime 1.0

            recording 1.0
              getScheduleList 1.0 ({"stIdx":"int","cnt":"int"}) → ({"id":"string"}*)

            avContent: 読めませんでした（HTTP 404）

            accessControl: 読めませんでした（エラー 12）

            読み取りの試し: このテレビの登録が無いため、していません
            """)
    }

    func testATelevisionThatSaysNothingIsReportedAsSuch() async {
        let silent = StubTransport { _, _ in throw RecorderError.transport("no answer") }
        let capabilities = await ScalarClient(host: Stub.host, transport: silent, credentials: MemoryTVCredentials())
            .capabilities()
        XCTAssertNil(capabilities.model)
        XCTAssertTrue(capabilities.services.allSatisfy { $0.failure != nil })
        XCTAssertTrue(capabilities.report(app: "x").contains("機種: 読めませんでした"))
    }

    func testTheDemosTelevisionSaysWhatTheAppSpeaksToIt() async throws {
        let client = ScalarClient(host: DemoTV.host, transport: DemoTV(), credentials: MemoryTVCredentials())
        let capabilities = await client.capabilities()
        XCTAssertEqual(capabilities.model, DemoTV.model)
        XCTAssertTrue(capabilities.services.allSatisfy { $0.failure == nil })
        let recording = try XCTUnwrap(capabilities.services.first { $0.name == "recording" })
        XCTAssertEqual(recording.versions, ["1.0", "1.1", "1.2"])
        let sent = Set(capabilities.services.flatMap(\.methods).map(\.name))
        XCTAssertEqual(sent, TVCapabilities.methodsSent, "the demo says it speaks every method the app sends")
    }
}

/// The reads the app makes, tried with the registration where the app holds one (`TVCapabilities.Trial`), and what
/// of their rows is put in the report: what they are made of, never what they say.
final class TVCapabilityTrialsTests: XCTestCase {
    /// Nine in the evening in Japan on Sunday 1 November 2026.
    private static let start = Date(timeIntervalSince1970: 1_793_534_400)
    private static let title = "見せてはならない題名"
    private static let station = DemoTV.Station(serviceID: 0x428, name: "見せてはならない局")

    private func registered(_ television: DemoTV) async -> ScalarClient {
        await television.knows("BDBridge:test", cookie: "kept")
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        return ScalarClient(host: Stub.host, transport: television, credentials: credentials)
    }

    private func television(older: Bool) async -> DemoTV {
        let television = DemoTV(stations: [Self.station],
                                recordings: [DemoTV.Recording(contentID: 7, title: Self.title, station: Self.station.name,
                                                              start: Self.start, sizeMB: 624, protected: true)],
                                older: older)
        await television.put([DemoTV.Schedule(id: "recording.3", serviceID: Self.station.serviceID,
                                              station: Self.station.name, title: Self.title, start: Self.start,
                                              eventId: 5)])
        return television
    }

    private func trial(_ label: String, in capabilities: TVCapabilities) throws -> TVCapabilities.Trial {
        try XCTUnwrap(capabilities.trials?.first { $0.label == label }, label)
    }

    func testANewerTelevisionsReadsAreTriedInEveryVersionTheAppMaySend() async throws {
        let newer = await television(older: false)
        let capabilities = await registered(newer).capabilities()
        XCTAssertEqual(capabilities.power, "standby")
        XCTAssertEqual(capabilities.recordingStatus, "notStarted")
        XCTAssertEqual(capabilities.trials?.map(\.label), [
            "getStorageList 1.1", "getScheduleList 1.1", "getScheduleList 1.0", "getContentList 1.5（録画）",
            "getContentList 1.2（録画）", "getContentList 1.0（録画）", "getContentList 1.0（地上デジタルの局）",
            "getContentList 1.0（BSの局）", "getContentList 1.0（CSの局）",
            "getConflictScheduleList 1.0（アプリが送る予約の形で）",
        ])
        XCTAssertEqual(capabilities.wakeOnLAN, "あり")
        let storage = try trial("getStorageList 1.1", in: capabilities)
        XCTAssertEqual([storage.rows, storage.taken], [1, 1])
        XCTAssertTrue(storage.forms.contains("mounted: mounted"), "\(storage.forms)")
        let schedules = try trial("getScheduleList 1.1", in: capabilities)
        XCTAssertEqual([schedules.rows, schedules.taken], [1, 1])
        XCTAssertTrue(schedules.fields.contains("eventId:string"), "\(schedules.fields)")
        XCTAssertTrue(schedules.forms.contains("startDateTime: 9999-99-99T99:99:99+9999（アプリが読める）"))
        XCTAssertTrue(schedules.forms.contains("uri: tv:isdbt?trip&srvName"), "\(schedules.forms)")
        XCTAssertEqual(try trial("getScheduleList 1.0", in: capabilities).failure, "エラー 7（Illegal State）",
                       "listed among its methods and answered with an error, as a real one does")
        let newest = try trial("getContentList 1.5（録画）", in: capabilities)
        XCTAssertEqual([newest.rows, newest.taken], [1, 1])
        XCTAssertTrue(newest.fields.contains("duration.durationSec:int"), "\(newest.fields)")
        XCTAssertTrue(newest.fields.contains("isProtected:string"), "\(newest.fields)")
        let older = try trial("getContentList 1.2（録画）", in: capabilities)
        XCTAssertEqual([older.rows, older.taken], [1, 1])
        XCTAssertTrue(older.fields.contains("isProtected:bool"), "\(older.fields)")
        let stations = try trial("getContentList 1.0（地上デジタルの局）", in: capabilities)
        XCTAssertEqual([stations.rows, stations.taken], [1, 1])
        let question = try trial("getConflictScheduleList 1.0（アプリが送る予約の形で）", in: capabilities)
        XCTAssertNil(question.failure, "the television took a reservation as the app writes one")
        let calls = await newer.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("addSchedule") || $0.hasPrefix("deleteSchedule") }, "\(calls)")
    }

    func testAnOlderTelevisionSaysWhichVersionsAnswer() async throws {
        let capabilities = await registered(await television(older: true)).capabilities()
        XCTAssertEqual(try trial("getStorageList 1.1", in: capabilities).failure, "エラー 12（getStorageList）")
        XCTAssertEqual(try trial("getScheduleList 1.1", in: capabilities).failure, "エラー 12（getScheduleList）")
        let schedules = try trial("getScheduleList 1.0", in: capabilities)
        XCTAssertNil(schedules.failure)
        XCTAssertEqual([schedules.rows, schedules.taken], [1, 1])
        XCTAssertFalse(schedules.fields.contains("eventId:string"), "\(schedules.fields)")
        XCTAssertEqual(try trial("getContentList 1.5（録画）", in: capabilities).failure, "エラー 12（getContentList）")
        let recordings = try trial("getContentList 1.2（録画）", in: capabilities)
        XCTAssertEqual([recordings.rows, recordings.taken], [1, 1])
    }

    func testNothingTheRowsSayIsInTheReport() async throws {
        let report = await registered(await television(older: false)).capabilities().report(app: "x")
        XCTAssertTrue(report.contains("読み取りの試し（"), report)
        for secret in [Self.title, Self.station.name, "trip=", "srvName=", "2026-", "recording.3", "contentId=",
                       DemoTV.mac] {
            XCTAssertFalse(report.contains(secret), "\(secret) is in the report:\n\(report)")
        }
    }

    func testWithNoRegistrationNothingIsTriedAndNoCookieIsSent() async throws {
        let television = await television(older: false)
        let capabilities = await ScalarClient(host: Stub.host, transport: television,
                                              credentials: MemoryTVCredentials()).capabilities()
        XCTAssertNil(capabilities.trials)
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.contains("cookie=yes") }, "\(calls)")
    }

    func testATelevisionThatStopsAnsweringEndsTheTrials() async throws {
        let stops = StubTransport { request, _ in
            if request.headers["Cookie"] != nil { throw RecorderError.transport("no answer") }
            return json(["error": [12, "nope"], "id": 1])
        }
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let capabilities = await ScalarClient(host: Stub.host, transport: stops, credentials: credentials).capabilities()
        XCTAssertEqual(capabilities.trials?.map(\.label), ["getStorageList 1.1", "ここで止めました"])
    }

    func testTheFormsSayNothingOfWhatIsNamed() {
        XCTAssertEqual(TVCapabilities.uriForm("tv:isdbt?trip=32736.32736.1024&srvName=ＮＨＫ"), "tv:isdbt?trip&srvName")
        XCTAssertEqual(TVCapabilities.uriForm("usb:recStorage?contentId=12"), "usb:recStorage?contentId")
        XCTAssertEqual(TVCapabilities.uriForm("usb:recStorage"), "usb:recStorage")
        XCTAssertEqual(TVCapabilities.uriForm("file:///番組/1.mts"), "file:///…/9.mts")
        XCTAssertEqual(TVCapabilities.timeForm("2026-11-01T21:00:00+0900"), "9999-99-99T99:99:99+9999")
        XCTAssertEqual(TVCapabilities.word("DR"), "DR")
        XCTAssertEqual(TVCapabilities.word("毎週"), "…")
        XCTAssertEqual(TVCapabilities.word(""), "(空)")
        XCTAssertEqual(TVCapabilities.phrase("Illegal State"), "Illegal State")
        XCTAssertEqual(TVCapabilities.phrase("番組が見つかりません"), "…")
    }

    func testTheFieldsSayTheirTypesAndHowManyRowsHaveThem() {
        let rows: [[String: ScalarValue]] = [
            ["title": .string("a"), "duration": .object(["durationSec": .int(60)]),
             "broadcastGenreInfo": .list([.object(["genreId": .int(1)])]), "isProtected": .bool(true)],
            ["title": .string("b"), "duration": .object(["durationSec": .int(30)]), "isProtected": .string("true"),
             "tags": .list([])],
        ]
        XCTAssertEqual(TVCapabilities.fields(of: rows), [
            "broadcastGenreInfo[].genreId:int (1/2)", "duration.durationSec:int", "isProtected:bool|string",
            "tags:[] (1/2)", "title:string",
        ])
        XCTAssertEqual(TVCapabilities.shape(of: .list([.object(["b": .int(1), "a": .null])])), "[{a,b}]")
    }
}

private func json(_ object: Any) -> HTTPResponse {
    HTTPResponse(statusCode: 200, body: try! JSONSerialization.data(withJSONObject: object))
}
