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

            system 1.0
              getPowerStatus 1.0 () → ({"status":"string"})
              ほか: getCurrentTime 1.0

            recording 1.0
              getScheduleList 1.0 ({"stIdx":"int","cnt":"int"}) → ({"id":"string"}*)

            avContent: 読めませんでした（HTTP 404）

            accessControl: 読めませんでした（エラー 12）
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

private func json(_ object: Any) -> HTTPResponse {
    HTTPResponse(statusCode: 200, body: try! JSONSerialization.data(withJSONObject: object))
}
