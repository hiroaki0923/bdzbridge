import Foundation
import XCTest
@testable import RecorderKit

/// A television's control API as the client speaks it: the envelope, the answers in their two depths, the
/// errors, and the registration with its cookie. The answers are written here in the television's shapes with
/// invented values: nothing in them comes from a real one.
final class ScalarClientTests: XCTestCase {
    private func ok(_ result: String, id: Int = 1) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"result":\#(result),"id":\#(id)}"#.utf8))
    }

    private func failed(_ code: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"error":[\#(code),"\#(message)"],"id":1}"#.utf8))
    }

    private func client(_ transport: StubTransport, _ credentials: TVCredentials? = nil) -> (ScalarClient, MemoryTVCredentials) {
        let store = MemoryTVCredentials(credentials)
        return (ScalarClient(host: Stub.host, transport: transport, credentials: store), store)
    }

    private func json(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    /// Every request is a POST of `{method, id, params, version}` to `/sony/<service>` on port 80, and the id
    /// counts up.
    func testTheEnvelope() async throws {
        let transport = StubTransport(always: ok(#"[{"status":"standby"}]"#))
        let (tv, _) = client(transport)

        let status = try await tv.powerStatus()
        _ = try await tv.powerStatus()

        XCTAssertEqual(status, "standby")
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].method, "POST")
        XCTAssertEqual(sent[0].url.absoluteString, "http://\(Stub.host):80/sony/system")
        XCTAssertEqual(sent[0].headers["Content-Type"], "application/json")
        XCTAssertNil(sent[0].headers["Cookie"], "a request that needs no registration carried the cookie")
        let first = try json(sent[0]), second = try json(sent[1])
        XCTAssertEqual(first["method"] as? String, "getPowerStatus")
        XCTAssertEqual(first["version"] as? String, "1.0")
        XCTAssertEqual((first["params"] as? [Any])?.count, 0)
        XCTAssertNotEqual(first["id"] as? Int, second["id"] as? Int)
    }

    /// What the television says it is, and the MAC it wakes on, which tells it from any other.
    func testWhatTheTelevisionSaysOfItself() async throws {
        let transport = StubTransport { request, _ in
            let method = (try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])?["method"] as? String
            if method == "getInterfaceInformation" {
                return HTTPResponse(statusCode: 200, body: Data(#"""
                {"result":[{"productCategory":"tv","productName":"BRAVIA","modelName":"KJ-SAMPLE","serverName":"","interfaceVersion":"5.7.0"}],"id":1}
                """#.utf8))
            }
            return HTTPResponse(statusCode: 200, body: Data(#"""
            {"result":[[{"option":"WOL","value":"f8:4e:17:00:00:02"}]],"id":2}
            """#.utf8))
        }
        let (tv, _) = client(transport)

        let interface = try await tv.interface()
        let mac = try await tv.wakeOnLANAddress()

        XCTAssertEqual(interface, TVInterface(productCategory: "tv", productName: "BRAVIA", modelName: "KJ-SAMPLE",
                                              interfaceVersion: "5.7.0"))
        XCTAssertEqual(mac, "f8:4e:17:00:00:02")
    }

    /// The method's own errors come as HTTP 200, and are read by code: only the codes seen from the methods the
    /// app calls mean anything to the rules.
    func testErrorsAreReadByTheirCode() async throws {
        let cases: [(HTTPResponse, DeviceFailure)] = [
            (failed(40005, "not power-on"), .needsPower),
            (failed(41222, "Overlapped with Other Schedules"), .alreadyThere),
            (failed(41200, "Schedule not found"), .unknownItem),
            (HTTPResponse(statusCode: 403), .needsPairing),
            (HTTPResponse(statusCode: 503), .busy),
        ]
        for (answer, expected) in cases {
            let (tv, _) = client(StubTransport(always: answer))
            do {
                _ = try await tv.powerStatus()
                XCTFail("no error for \(expected)")
            } catch let error as ScalarError {
                XCTAssertEqual(error.failure, expected)
            }
        }
        let (tv, _) = client(StubTransport(always: failed(7, "Illegal Request")))
        do {
            _ = try await tv.powerStatus()
            XCTFail("no error")
        } catch let error as ScalarError {
            XCTAssertEqual(error, .rpc(method: "getPowerStatus", version: "1.0", code: 7, message: "Illegal Request"))
            guard case .unexpected = error.failure else { return XCTFail("an unknown code read as \(error.failure)") }
            XCTAssertFalse(error.failure.turnsTheRequestDown, "an unknown code held a request back for good")
        }
    }

    /// Nothing answering is silence; an address that is not one sends nothing.
    func testSilenceAndABadAddress() async throws {
        let silent = StubTransport { _, _ in throw RecorderError.transport("The request timed out.") }
        let (tv, _) = client(silent)
        do {
            _ = try await tv.powerStatus()
            XCTFail("no error")
        } catch let error as ScalarError {
            XCTAssertEqual(error.failure, .silent)
            XCTAssertTrue(error.explanation.contains("テレビ"), error.explanation)
        }

        let nothing = StubTransport(always: ok("[]"))
        let bad = ScalarClient(host: "192.0.2.10:80", transport: nothing, credentials: MemoryTVCredentials())
        do {
            _ = try await bad.powerStatus()
            XCTFail("no error")
        } catch let error as ScalarError {
            XCTAssertEqual(error.failure, .badAddress)
        }
        let sent = await nothing.requests
        XCTAssertTrue(sent.isEmpty)
    }

    /// Unregistered, the television answers 401 and the app asks for the PIN; the same request with the PIN
    /// as a Basic password registers, and the cookie it brings is kept with its Max-Age. Neither carries a cookie.
    func testRegistering() async throws {
        let transport = StubTransport { request, _ in
            guard request.headers["Authorization"] != nil else {
                return HTTPResponse(statusCode: 401, body: Data(#"{"error":[401,"Unauthorized"],"id":1}"#.utf8),
                                    headers: ["WWW-Authenticate": #"Basic realm="Private Page""#])
            }
            return HTTPResponse(statusCode: 200, body: Data(#"{"result":[],"id":2}"#.utf8),
                                headers: ["Set-Cookie": "auth=invented-cookie; Path=/sony/; Max-Age=1209600; Expires=x"])
        }
        let (tv, store) = client(transport)

        let first = try await tv.register(clientID: "BDBridge:test", nickname: "BD Bridge", pin: nil)
        XCTAssertEqual(first, .pinNeeded)
        XCTAssertNil(store.load(), "a 401 kept something")

        let before = Date()
        let second = try await tv.register(clientID: "BDBridge:test", nickname: "BD Bridge", pin: "1234")
        XCTAssertEqual(second, .registered)
        let kept = try XCTUnwrap(store.load())
        XCTAssertEqual(kept.clientID, "BDBridge:test")
        XCTAssertEqual(kept.cookie, "invented-cookie")
        XCTAssertEqual(kept.cookieMaxAge, 1_209_600)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(kept.cookieReceived), before)

        let sent = await transport.requests
        XCTAssertEqual(sent.map { $0.url.path }, ["/sony/accessControl", "/sony/accessControl"])
        XCTAssertNil(sent[0].headers["Authorization"])
        XCTAssertEqual(sent[1].headers["Authorization"], "Basic " + Data(":1234".utf8).base64EncodedString())
        XCTAssertTrue(sent.allSatisfy { $0.headers["Cookie"] == nil }, "the registration carried a cookie")
        let params = try XCTUnwrap(try json(sent[1])["params"] as? [Any])
        let client = try XCTUnwrap(params.first as? [String: Any])
        XCTAssertEqual(client["clientid"] as? String, "BDBridge:test")
        XCTAssertEqual(client["level"] as? String, "private")
    }

    /// A renewal is a registration with no PIN for the client id in the store, and its cookie is kept only while
    /// the store still holds that registration: one taken away while the request was out stays away.
    func testARenewalIsKeptOnlyWhileTheRegistrationIs() async throws {
        let renewed = HTTPResponse(statusCode: 200, body: Data(#"{"result":[],"id":1}"#.utf8),
                                   headers: ["Set-Cookie": "auth=renewed; Path=/sony/; Max-Age=1209600"])
        let (tv, store) = client(StubTransport(always: renewed), TVCredentials(clientID: "BDBridge:test", cookie: "kept"))
        let kept = try await tv.renew(nickname: "BD Bridge")
        XCTAssertTrue(kept)
        XCTAssertEqual(store.load()?.clientID, "BDBridge:test")
        XCTAssertEqual(store.load()?.cookie, "renewed")

        let taken = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept"))
        let away = ScalarClient(host: Stub.host, transport: StubTransport { _, _ in
            taken.remove()
            return renewed
        }, credentials: taken)
        let keptAfterwards = try await away.renew(nickname: "BD Bridge")
        XCTAssertFalse(keptAfterwards)
        XCTAssertNil(taken.load(), "a registration taken away while the renewal was out came back")
    }

    /// With its display off the television shows no PIN: a client it does not list is turned down with error
    /// 40005, which is not the television asking for its PIN, and nothing is kept. A renewal turned down -- that
    /// way, or with a 401 by a television that has let go of the app -- leaves the cookie in hand as it was.
    func testARegistrationTurnedDownKeepsNothing() async throws {
        let displayOff = failed(40005, "display off")
        let (tv, store) = client(StubTransport(always: displayOff))
        do {
            _ = try await tv.register(clientID: "BDBridge:test", nickname: "BD Bridge", pin: nil)
            XCTFail("a registration turned down passed for one that wants a PIN")
        } catch let error as ScalarError {
            XCTAssertEqual(error.failure, .needsPower)
        }
        XCTAssertNil(store.load())

        let kept = TVCredentials(clientID: "BDBridge:test", cookie: "kept")
        let (off, held) = client(StubTransport(always: displayOff), kept)
        do {
            _ = try await off.renew(nickname: "BD Bridge")
            XCTFail("a renewal turned down passed for one that went through")
        } catch let error as ScalarError {
            XCTAssertEqual(error.failure, .needsPower)
        }
        XCTAssertEqual(held.load(), kept)

        let (asked, same) = client(StubTransport(always: HTTPResponse(statusCode: 401)), kept)
        let renewed = try await asked.renew(nickname: "BD Bridge")
        XCTAssertFalse(renewed)
        XCTAssertEqual(same.load(), kept)
    }

    /// A read that needs the registration sends the cookie kept, and sends nothing without one.
    func testWhatNeedsTheRegistrationSendsTheCookie() async throws {
        let transport = StubTransport(always: ok(#"[[{"uri":"usb:recStorage","mounted":"mounted","wholeCapacityMB":1000,"freeCapacityMB":400}]]"#))
        let (tv, _) = client(transport, TVCredentials(clientID: "BDBridge:test", cookie: "kept"))

        let storage = try await tv.storage()

        XCTAssertEqual(storage, TVStorage(mounted: true, freeMB: 400, totalMB: 1000))
        let sent = await transport.requests
        XCTAssertEqual(sent.first?.headers["Cookie"], "auth=kept")
        XCTAssertEqual(try json(XCTUnwrap(sent.first))["version"] as? String, "1.1")

        let nothing = StubTransport(always: ok("[]"))
        let (unregistered, _) = client(nothing)
        do {
            _ = try await unregistered.storage()
            XCTFail("no error")
        } catch let error as ScalarError {
            XCTAssertEqual(error.failure, .needsPairing)
        }
        let none = await nothing.requests
        XCTAssertTrue(none.isEmpty, "sent without a registration")
    }

    /// A 403 is sent again once when another client has renewed the cookie in between, with the new one; a 403
    /// with the cookie the store still holds is a cookie the television no longer takes.
    func testA403IsSentAgainOnceWithANewerCookie() async throws {
        let store = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "old"))
        let transport = StubTransport { request, index in
            if index == 0 {
                store.save(TVCredentials(clientID: "BDBridge:test", cookie: "new"))
                return HTTPResponse(statusCode: 403)
            }
            return HTTPResponse(statusCode: 200, body: Data(#"{"result":[[{"uri":"usb:recStorage","mounted":"unmounted"}]],"id":2}"#.utf8))
        }
        let tv = ScalarClient(host: Stub.host, transport: transport, credentials: store)

        let storage = try await tv.storage()

        XCTAssertEqual(storage, TVStorage(mounted: false, freeMB: nil, totalMB: nil))
        let sent = await transport.requests
        XCTAssertEqual(sent.map { $0.headers["Cookie"] }, ["auth=old", "auth=new"])

        let refusing = StubTransport(always: HTTPResponse(statusCode: 403))
        let (gone, _) = client(refusing, TVCredentials(clientID: "BDBridge:test", cookie: "kept"))
        do {
            _ = try await gone.storage()
            XCTFail("no error")
        } catch let error as ScalarError {
            XCTAssertEqual(error.failure, .needsPairing)
        }
        let once = await refusing.requests
        XCTAssertEqual(once.count, 1, "sent again with the same cookie")
    }

    func testTheCookieIsReadFromItsHeader() {
        let read = ScalarClient.authCookie("auth=abc123; Path=/sony/; Max-Age=1209600; Expires=x, 1 1月 2026 00:00:00 GMT+00:00")
        XCTAssertEqual(read?.value, "abc123")
        XCTAssertEqual(read?.maxAge, 1_209_600)
        XCTAssertNil(ScalarClient.authCookie("other=1; Path=/"))
        XCTAssertNil(ScalarClient.authCookie("auth=; Path=/sony/"))
    }

    /// A cookie is renewed once it is past half its life, and one whose age is not known is renewed.
    func testWhenACookieIsRenewed() {
        let received = Date(timeIntervalSince1970: 1_000_000)
        let credentials = TVCredentials(clientID: "x", cookie: "c", cookieReceived: received, cookieMaxAge: 14 * 86_400)
        XCTAssertFalse(credentials.renewalDue(now: received.addingTimeInterval(6 * 86_400)))
        XCTAssertTrue(credentials.renewalDue(now: received.addingTimeInterval(8 * 86_400)))
        XCTAssertTrue(TVCredentials(clientID: "x", cookie: "c").renewalDue(now: received))
        XCTAssertFalse(TVCredentials(clientID: "x").renewalDue(now: received), "renewed with no cookie to renew")
    }
}
