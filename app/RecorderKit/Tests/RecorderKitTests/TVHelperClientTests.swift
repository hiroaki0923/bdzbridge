import XCTest
@testable import RecorderKit

/// The client of the helper on the television, against a stubbed helper.
final class TVHelperClientTests: XCTestCase {
    private func json(_ status: Int, _ object: Any) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func client(_ transport: StubTransport, token: String? = "tok") -> TVHelperClient {
        TVHelperClient(host: Stub.host, transport: transport, tokens: MemoryTVHelperToken(token))
    }

    func testPingSaysWhoAnswersAndProbeWantsTheHelper() async throws {
        let helper = StubTransport(always: json(200, ["app": "recbridge-helper", "api": [1], "version": "0.1.0"]))
        let identity = try await client(helper).ping()
        XCTAssertEqual(identity, TVHelperIdentity(app: "recbridge-helper", api: [1], version: "0.1.0"))
        XCTAssertTrue(identity.isHelper)
        try await client(helper).probe(timeout: 2)
        let requests = await helper.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.absoluteString, "http://\(Stub.host):8780/ping")
        XCTAssertNil(request.headers["Authorization"])

        let other = StubTransport(always: json(200, ["app": "something", "api": [1], "version": "9"]))
        do {
            try await client(other).probe(timeout: 2)
            XCTFail("probed something else")
        } catch TVHelperError.notAHelper {
        }

        let page = StubTransport(always: HTTPResponse(statusCode: 200, body: Data("<html>".utf8)))
        do {
            _ = try await client(page).ping()
            XCTFail("read a page as the helper")
        } catch TVHelperError.notAHelper {
        }
    }

    func testPairingKeepsTheTokenAndSaysWhyItWasRefused() async throws {
        let tokens = MemoryTVHelperToken()
        let helper = StubTransport(always: json(200, ["token": "secret", "deviceId": "d1", "api": [1], "version": "0.1.0"]))
        let client = TVHelperClient(host: Stub.host, transport: helper, tokens: tokens)
        XCTAssertFalse(client.isRegistered)
        try await client.pair(code: "123456", label: "iPhone")
        XCTAssertEqual(tokens.load(), "secret")
        XCTAssertTrue(client.isRegistered)
        let requests = await helper.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/v1/pair")
        let body = try XCTUnwrap(request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(body, ["code": "123456", "label": "iPhone"])

        for (status, code) in [(403, "badCode"), (403, "noCode"), (429, "locked")] {
            let refusing = StubTransport(always: json(status, ["error": code]))
            do {
                try await TVHelperClient(host: Stub.host, transport: refusing, tokens: MemoryTVHelperToken()).pair(code: "000000", label: "x")
                XCTFail("paired on \(code)")
            } catch TVHelperError.pairingRefused(let why) {
                XCTAssertEqual(why, code)
            }
        }
        client.forgetRegistration()
        XCTAssertFalse(client.isRegistered)
    }

    func testReadsCarryTheTokenAndReadTheAnswersForWhatTheySay() async throws {
        let channelsAnswer = json(200, ["channels": [["bt": "td", "sid": 1024, "number": "011", "name": "一", "hasPrograms": true]]])
        let guideAnswer = json(200, ["bt": "td", "programs": [
            ["sid": 1024, "eid": 1, "startMs": 1_800_000_000_000, "endMs": 1_800_001_000_000, "title": "a"],
        ]])
        let noSuchType = json(404, ["error": "noSuchType"])
        let logosAnswer = json(200, ["bt": "td", "logos": []])
        let infoAnswer = json(200, [
            "helperVersion": "0.1.0", "listingsPermission": true, "tunerInstalled": true, "building": false,
            "tunerLastWrite": 1_800_000_000_000,
            "types": ["td": ["etag": "x", "changedAt": 1_800_000_000_000, "snapshotAt": 1_800_000_500_000,
                             "programs": 1, "channels": 1]],
        ])
        let notFound = json(404, ["error": "notFound"])
        let helper = StubTransport { request, _ in
            XCTAssertEqual(request.headers["Authorization"], "Bearer tok")
            switch request.url.path {
            case "/v1/channels": return channelsAnswer
            case "/v1/guide/td": return guideAnswer
            case "/v1/guide/cs4k": return noSuchType
            case "/v1/logos/td": return logosAnswer
            case "/v1/info": return infoAnswer
            default: return notFound
            }
        }
        let client = client(helper)
        let services = try await client.guide("td")
        XCTAssertEqual(services?.map(\.serviceID), [1024])
        XCTAssertEqual(services?.first?.name, "一")
        XCTAssertEqual(services?.first?.programs.count, 1)
        let none = try await client.guide("cs4k")
        XCTAssertNil(none)
        let logos = try await client.logos("td")
        XCTAssertEqual(logos, [])
        let types = try await client.broadcastingTypes()
        XCTAssertEqual(types, ["td"])
        let info = try await client.info()
        XCTAssertEqual(info.version, "0.1.0")
        XCTAssertTrue(info.listingsPermission)
        XCTAssertEqual(info.types["td"]?.programs, 1)
        XCTAssertEqual(info.types["td"]?.changedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(info.tunerLastWrite, Date(timeIntervalSince1970: 1_800_000_000))
        // The channels were read once, for every type.
        let requests = await helper.requests
        XCTAssertEqual(requests.map(\.url.path).filter { $0 == "/v1/channels" }.count, 1)
        let atOnce = await helper.maxConcurrent
        XCTAssertEqual(atOnce, 1)
    }

    func testWhatTheHelperSaysInsteadOfAnAnswer() async {
        for (answer, expected) in [
            (json(401, ["error": "unauthorized"]), TVHelperError.unauthorized),
            (json(503, ["error": "noPermission"]), .notReady("noPermission")),
            (json(503, ["error": "building"]), .notReady("building")),
            (HTTPResponse(statusCode: 500), .unexpected("HTTP 500")),
        ] {
            let helper = StubTransport(always: answer)
            do {
                _ = try await client(helper).info()
                XCTFail("read \(expected)")
            } catch let error as TVHelperError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("\(error)")
            }
        }
        // Without a token nothing is sent.
        let helper = StubTransport(always: json(200, [:]))
        do {
            _ = try await client(helper, token: nil).info()
            XCTFail("sent without a token")
        } catch TVHelperError.unauthorized {
        } catch {
            XCTFail("\(error)")
        }
        let sent = await helper.requests
        XCTAssertEqual(sent.count, 0)
    }

    func testSilenceIsSilenceAndTheFailuresReadAsTheRulesDo() async {
        struct Down: Error {}
        let helper = StubTransport { _, _ in throw Down() }
        do {
            _ = try await client(helper).ping()
            XCTFail("answered")
        } catch let error as TVHelperError {
            XCTAssertEqual(error.failure, .silent)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(TVHelperError.unauthorized.failure, .needsPairing)
        XCTAssertEqual(TVHelperError.notReady("building").failure, .busy)
        XCTAssertEqual(TVHelperError.notReady("noPermission").failure,
                       .deviceCannot(reason: TVHelperError.notReady("noPermission").explanation))
        XCTAssertEqual(TVHelperError.pairingRefused("badCode").failure,
                       .refused(reason: "登録の番号が違います"))
    }
}
