import Foundation
import XCTest
@testable import RecorderKit

/// A television's control API as the client speaks it: the envelope, the answers in their two depths, the
/// errors, the registration with its cookie, its reservations read and deleted, its stations, and a
/// reservation asked about and made. The answers are written here in the television's shapes with invented
/// values: nothing in them comes from a real one.
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

    /// What is at an address, asked with nothing registered and nothing changed there: a television, in
    /// standby or on, by its model; nothing, where nothing answers or the address is not one, which is sent
    /// nothing; and something that is no television, by what it calls itself or by answering as none does.
    func testWhatIsAtAnAddress() async {
        let standby = DemoTV(), on = DemoTV(power: "active"), silent = DemoTV()
        await silent.goSilent()
        let recorder = StubTransport(always: ok(#"[{"status":"active","productCategory":"recorder"}]"#))
        let stranger = StubTransport(always: HTTPResponse(statusCode: 404))
        let cases: [(any HTTPTransport, String, TVPresence)] = [
            (standby, Stub.host, .standby(model: DemoTV.model)), (on, Stub.host, .on(model: DemoTV.model)),
            (silent, Stub.host, .nothing), (standby, "192.0.2.10:80", .nothing),
            (recorder, Stub.host, .notATelevision), (stranger, Stub.host, .notATelevision),
        ]
        for (transport, host, expected) in cases {
            let tv = ScalarClient(host: host, transport: transport, credentials: MemoryTVCredentials(Self.kept))
            expectEqual(await tv.presence(), expected, "\(expected) at \(host)")
        }
        expectEqual(await standby.calls, ["getPowerStatus cookie=no pin=no",
                                          "getInterfaceInformation cookie=no pin=no"])
        expectEqual(await stranger.requests.count, 1, "asked on after an answer no television gives")

        // Short, and the caller's to say: the reader is waiting at a sheet for it.
        let asked = StubTransport(always: ok(#"[{"status":"active","productCategory":"tv","modelName":"KJ-SAMPLE"}]"#))
        let tv = ScalarClient(host: Stub.host, transport: asked, credentials: MemoryTVCredentials())
        _ = await tv.presence()
        _ = await tv.presence(timeout: 2)
        expectEqual(await asked.requests.map(\.timeout), [5, 5, 2, 2])
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

    /// What asking to be registered comes to, as the steps of it, each on an invented television. One that is
    /// on and does not list the app wants its PIN; the same request with the PIN registers, the cookie is kept
    /// and the MAC it wakes on is handed back in the form the app keeps, or none when it gives none. One whose
    /// display is off turns the request down, which is said as that and not as the error it answered with.
    /// One that does not answer is found out at the first ask, the MAC, and the registration is not sent.
    func testWhatAskingToBeRegisteredComesTo() async {
        let first = "getSystemSupportedFunction cookie=no pin=no"
        let bare = "actRegister cookie=no pin=no", withPIN = "actRegister cookie=no pin=yes"
        // The MAC as a television might spell it, which is not how the app keeps one.
        let on = DemoTV(power: "active", mac: DemoTV.mac.uppercased().replacingOccurrences(of: ":", with: "-"))
        let noMAC = DemoTV(power: "active", mac: ""), off = DemoTV(), silent = DemoTV(power: "active")
        await silent.goSilent()
        let noAnswer = ScalarError.transport("no answer").explanation
        let turnedDown = ScalarError.rpc(method: "actRegister", version: "1.0", code: 40005, message: "display off")
        XCTAssertNotEqual(ScalarClient.screenIsOff, turnedDown.explanation)
        let cases: [(String, DemoTV, String?, TVEnrolment, [String])] = [
            ("no PIN", on, nil, .pinNeeded, [first, bare]),
            ("the PIN", on, DemoTV.pin, .registered(mac: DemoTV.mac), [first, withPIN]),
            ("no MAC given", noMAC, DemoTV.pin, .registered(mac: nil), [first, withPIN]),
            ("the display off", off, nil, .failed(ScalarClient.screenIsOff), [first, bare]),
            ("nothing answering", silent, DemoTV.pin, .failed(noAnswer), [first]),
        ]
        for (name, television, pin, expected, sent) in cases {
            let store = MemoryTVCredentials()
            let tv = ScalarClient(host: Stub.host, transport: television, credentials: store)
            let before = await television.calls.count

            expectEqual(await tv.enrol(clientID: "BDBridge:test", nickname: "BD Bridge", pin: pin), expected, name)

            expectEqual(Array(await television.calls.dropFirst(before)), sent, name)
            guard case .registered = expected else {
                XCTAssertNil(store.load(), "\(name): something was kept")
                continue
            }
            XCTAssertEqual(store.load()?.clientID, "BDBridge:test", name)
            expectNil(await failure { _ = try await tv.storage() }, "\(name): the cookie kept is not taken")
        }

        // The first ask is short, and the caller's to say: the reader is waiting at a sheet for it. The
        // registration waits as long as any request.
        let mac = ok(#"[[{"option":"WOL","value":"\#(DemoTV.mac)"}]]"#)
        let asked = StubTransport { _, index in index % 2 == 0 ? mac : HTTPResponse(statusCode: 401) }
        let (tv, _) = client(asked)
        _ = await tv.enrol(clientID: "BDBridge:test", nickname: "BD Bridge", pin: nil)
        _ = await tv.enrol(clientID: "BDBridge:test", nickname: "BD Bridge", pin: nil, timeout: 2)
        expectEqual(await asked.requests.map(\.timeout), [5, ScalarClient.timeout, 2, ScalarClient.timeout])
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

    // MARK: - reservations

    private static let uri = "tv:isdbt?trip=65534.65533.1024&srvName=サンプルテレビ"
    private static let kept = TVCredentials(clientID: "BDBridge:test", cookie: "kept")

    /// What an operation failed as, for the rules; nil when it went through.
    private func failure(of operation: () async throws -> Void) async -> DeviceFailure? {
        do {
            try await operation()
            return nil
        } catch {
            return (error as? any DeviceError)?.failure ?? .unexpected(String(describing: error))
        }
    }

    /// The list is asked for once, 130 rows from the first, with the cookie; and each row is kept as it was
    /// written -- one that follows its programme, one made by its times, which has no `eventId`, and a reminder
    /// to watch, which has no `quality` and starts a second early.
    func testTheReservationsAreReadInOneRequest() async throws {
        let transport = StubTransport(always: ok(#"""
        [[{"id":"recording.31","type":"recording","uri":"\#(Self.uri)","title":"サンプル劇場",
           "channelName":"サンプルテレビ","startDateTime":"2026-11-01T21:00:00+0900","durationSec":3600,
           "repeatType":"w7","overlapStatus":"fullyOverlapped","recordingStatus":"notStarted","quality":"DR",
           "eventId":"12345"},
          {"id":"recording.30","type":"recording","uri":"\#(Self.uri)","title":"サンプル天気",
           "channelName":"サンプルテレビ","startDateTime":"2026-11-02T06:30:00+0900","durationSec":900,
           "repeatType":"1","overlapStatus":"notOverlapped","recordingStatus":"notStarted","quality":"DR"},
          {"id":"reminder.22","type":"reminder","uri":"\#(Self.uri)","title":"サンプル劇場",
           "channelName":"サンプルテレビ","startDateTime":"2026-11-01T20:59:59+0900","durationSec":3600,
           "repeatType":"1","overlapStatus":"notOverlapped","recordingStatus":"notStarted","eventId":"12345"}]]
        """#))
        let (tv, _) = client(transport, Self.kept)

        let rows = try await tv.schedules()

        XCTAssertEqual(rows, [
            TVScheduleRow(id: "recording.31", type: "recording", uri: Self.uri,
                          startDateTime: "2026-11-01T21:00:00+0900", durationSec: 3600, title: "サンプル劇場",
                          channelName: "サンプルテレビ", repeatType: "w7", overlapStatus: "fullyOverlapped",
                          recordingStatus: "notStarted", quality: "DR", eventId: "12345"),
            TVScheduleRow(id: "recording.30", type: "recording", uri: Self.uri,
                          startDateTime: "2026-11-02T06:30:00+0900", durationSec: 900, title: "サンプル天気",
                          channelName: "サンプルテレビ", repeatType: "1", overlapStatus: "notOverlapped",
                          recordingStatus: "notStarted", quality: "DR"),
            TVScheduleRow(id: "reminder.22", type: "reminder", uri: Self.uri,
                          startDateTime: "2026-11-01T20:59:59+0900", durationSec: 3600, title: "サンプル劇場",
                          channelName: "サンプルテレビ", repeatType: "1", overlapStatus: "notOverlapped",
                          recordingStatus: "notStarted", eventId: "12345"),
        ])
        let sent = await transport.requests
        XCTAssertEqual(sent.map { $0.url.path }, ["/sony/recording"], "read a second page, or another service")
        XCTAssertEqual(sent[0].headers["Cookie"], "auth=kept")
        let body = try json(sent[0])
        XCTAssertEqual(body["method"] as? String, "getScheduleList")
        XCTAssertEqual(body["version"] as? String, "1.1")
        XCTAssertEqual(body["params"] as? NSArray, [["stIdx": 0, "cnt": 130]] as NSArray)
    }

    /// A row without one of the five fields every row has, or with a start that is no time, is left out and
    /// the rest of the list is read; an empty list is one; and an answer that is no list of rows is not taken
    /// for a television with nothing reserved.
    func testARowThatCannotBeReadIsLeftOut() async throws {
        let whole: [String: Any] = ["id": "recording.31", "type": "recording", "uri": Self.uri,
                                    "startDateTime": "2026-11-01T21:00:00+0900", "durationSec": 3600]
        var rows: [Any] = whole.keys.sorted().map { field in whole.filter { $0.key != field } }
        rows.append(whole.merging(["startDateTime": "あした"]) { $1 })
        rows.append(7)
        rows.append(whole)
        let answer = HTTPResponse(statusCode: 200,
                                  body: try JSONSerialization.data(withJSONObject: ["result": [rows], "id": 1]))
        let (tv, _) = client(StubTransport(always: answer), Self.kept)

        let read = try await tv.schedules()

        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(read, [TVScheduleRow(id: "recording.31", type: "recording", uri: Self.uri,
                                            startDateTime: "2026-11-01T21:00:00+0900", durationSec: 3600)])

        let (empty, _) = client(StubTransport(always: ok("[[]]")), Self.kept)
        let none = try await empty.schedules()
        XCTAssertEqual(none, [])
        for shape in ["[]", #"[{"id":"recording.31"}]"#, #"{"rows":[]}"#] {
            let (other, _) = client(StubTransport(always: ok(shape)), Self.kept)
            do {
                _ = try await other.schedules()
                XCTFail("\(shape) was read as a list")
            } catch let error as ScalarError {
                XCTAssertEqual(error, .unreadable(method: "getScheduleList"))
            }
        }
    }

    /// A delete sends the row back as it was read, in a list of its own inside the parameters: the six fields
    /// and no others, the start as the television wrote it, the title in the television's form whatever is in
    /// it -- a character outside the BMP, an ideographic space, a slash, a quotation mark -- and not escaped
    /// into ASCII. A row that came with no title sends an empty one.
    func testADeleteSendsTheRowBackAsItWasRead() async throws {
        let title = "\u{1F211}サンプル劇場\u{3000}第５話/前編 \"夜\""
        let listed: [String: Any] = [
            "id": "recording.31", "type": "recording", "uri": Self.uri, "title": title, "channelName": "サンプルテレビ",
            "startDateTime": "2026-11-01T20:59:59+0900", "durationSec": 3541, "repeatType": "1",
            "overlapStatus": "notOverlapped", "recordingStatus": "notStarted", "quality": "DR", "eventId": "12345",
        ]
        let list = try JSONSerialization.data(withJSONObject: ["result": [[listed]], "id": 1])
        let transport = StubTransport { _, index in
            HTTPResponse(statusCode: 200, body: index == 0 ? list : Data(#"{"result":[],"id":2}"#.utf8))
        }
        let (tv, _) = client(transport, Self.kept)

        let row = try await tv.schedules()[0]
        try await tv.deleteSchedule(row)
        var untitled = row
        untitled.title = nil
        try await tv.deleteSchedule(untitled)

        let sent = await transport.requests
        XCTAssertEqual(sent.map { $0.url.path }, Array(repeating: "/sony/recording", count: 3))
        XCTAssertEqual(sent[1].headers["Cookie"], "auth=kept")
        let body = try json(sent[1])
        XCTAssertEqual(body["method"] as? String, "deleteSchedule")
        XCTAssertEqual(body["version"] as? String, "1.1")
        var expected: [String: Any] = ["id": "recording.31", "startDateTime": "2026-11-01T20:59:59+0900",
                                       "title": title, "durationSec": 3541, "type": "recording", "uri": Self.uri]
        XCTAssertEqual(body["params"] as? NSArray, [[expected]] as NSArray)
        expectTrue(await transport.bodies[1].contains("\u{1F211}サンプル劇場\u{3000}第５話/前編"), "escaped")
        expected["title"] = ""
        XCTAssertEqual(try json(sent[2])["params"] as? NSArray, [[expected]] as NSArray)
    }

    /// The start goes back as the string that was read, and is not written again from the time it names: here
    /// one spelled with a colon in its offset, as the television has not been seen to spell one.
    func testADeleteSendsTheStartAsItWasSpelled() async throws {
        let start = "2026-11-01T21:00:00+09:00"
        let list = ok(#"""
        [[{"id":"recording.34","type":"recording","uri":"\#(Self.uri)","startDateTime":"\#(start)","durationSec":1800}]]
        """#)
        let done = ok("[]")
        let transport = StubTransport { _, index in index == 0 ? list : done }
        let (tv, _) = client(transport, Self.kept)

        let row = try await tv.schedules()[0]
        try await tv.deleteSchedule(row)

        XCTAssertEqual(row.reservation()?.start, Date(timeIntervalSince1970: 1_793_534_400))
        let params = try json(await transport.requests[1])["params"] as? [[[String: Any]]]
        XCTAssertEqual(params?.first?.first?["startDateTime"] as? String, start)
    }

    /// An answer of 130 rows, all that was asked for, is not read on from: one request, as for any other.
    func testAFullAnswerIsNotReadOnFrom() async throws {
        let rows: [[String: Any]] = (100..<230).map { number in
            ["id": "recording.\(number)", "type": "recording", "uri": Self.uri,
             "startDateTime": "2026-11-01T21:00:00+0900", "durationSec": 1800]
        }
        let answer = HTTPResponse(statusCode: 200,
                                  body: try JSONSerialization.data(withJSONObject: ["result": [rows], "id": 1]))
        let transport = StubTransport(always: answer)
        let (tv, _) = client(transport, Self.kept)

        let read = try await tv.schedules()

        XCTAssertEqual(read.map(\.id), (100..<230).map { "recording.\($0)" })
        expectEqual(await transport.requests.count, 1)
    }

    /// The same against the invented television, which holds what it is given: the rows put on it are read
    /// back in its order, a reminder among them; a delete takes one off; the same delete again, and a row sent
    /// with another title, are answered as a row it does not have; and a cookie it does not know is refused,
    /// for the list and for a delete.
    func testReadingAndDeletingOnTheInventedTelevision() async throws {
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let followed = DemoTV.Schedule(id: "recording.24", start: start, eventId: 12345)
        let weekly = DemoTV.Schedule(id: "recording.105", scheme: "isdbbs", serviceID: 2048, station: "サンプルBS",
                                     title: "サンプル音楽館", start: start.addingTimeInterval(3600), repeatType: "w7")
        let reminder = DemoTV.Schedule(id: "reminder.23", type: "reminder", start: start.addingTimeInterval(-1),
                                       quality: nil, eventId: 12345)
        await television.put([followed, reminder, weekly])
        let tv = ScalarClient(host: Stub.host, transport: television, credentials: MemoryTVCredentials(Self.kept))

        let rows = try await tv.schedules()
        XCTAssertEqual(rows, [weekly.row, followed.row, reminder.row])

        try await tv.deleteSchedule(rows[1])
        expectEqual(await television.schedules, [reminder, weekly])
        expectEqual(await failure { try await tv.deleteSchedule(rows[1]) }, .unknownItem)
        var retitled = rows[0]
        retitled.title = "サンプル討論"
        expectEqual(await failure { try await tv.deleteSchedule(retitled) }, .unknownItem)

        let stale = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "stale"))
        let stranger = ScalarClient(host: Stub.host, transport: television, credentials: stale)
        expectEqual(await failure { _ = try await stranger.schedules() }, .needsPairing)
        expectEqual(await failure { try await stranger.deleteSchedule(rows[0]) }, .needsPairing)
        expectEqual(await television.schedules, [reminder, weekly])
    }

    /// The invented television takes a delete only for the row as it holds it. One that differs in any of the
    /// six fields is answered as a row it does not have, and the row stays: the id among them, a start that
    /// names the same time in another spelling, and a title that is the same text in other scalars. A reminder
    /// it holds is listed without a mode, whatever it was made with.
    func testTheInventedTelevisionTakesOnlyTheRowAsItHoldsIt() async throws {
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        let held = DemoTV.Schedule(id: "recording.24", start: Date(timeIntervalSince1970: 1_790_000_000),
                                   eventId: 12345)
        await television.put([held])
        let tv = ScalarClient(host: Stub.host, transport: television, credentials: MemoryTVCredentials(Self.kept))
        let decomposed = "サンフ\u{309A}ル番組"
        XCTAssertEqual(decomposed, held.title, "the same text to a comparison of strings")
        let changes: [(String, (inout TVScheduleRow) -> Void)] = [
            ("id", { $0.id = "recording.25" }),
            ("startDateTime", { $0.startDateTime = String($0.startDateTime.dropLast(5)) + "+09:00" }),
            ("title", { $0.title = decomposed }),
            ("durationSec", { $0.durationSec += 1 }),
            ("type", { $0.type = "reminder" }),
            ("uri", { $0.uri += "2" }),
        ]
        for (field, change) in changes {
            var row = held.row
            change(&row)
            expectEqual(await failure { try await tv.deleteSchedule(row) }, .unknownItem, field)
            expectEqual(await television.schedules, [held], field)
        }
        try await tv.deleteSchedule(held.row)
        expectEqual(await television.schedules, [])

        let reminder = DemoTV.Schedule(id: "reminder.23", type: "reminder", start: held.start, quality: "DR")
        await television.put([reminder])
        expectEqual(try await tv.schedules().map(\.quality), [nil])
        XCTAssertNil(reminder.row.quality)
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

    // MARK: - stations, and making a reservation

    /// A station's row as a television lists one: seven fields.
    private static func stationRow(_ index: Int) -> [String: Any] {
        let triplet = "65534.65533.\(1500 + index)"
        return ["uri": "tv:isdbbs?trip=\(triplet)&srvName=サンプル局\(index)", "title": "サンプル局\(index)", "index": index,
                "dispNum": "999", "tripletStr": triplet, "programMediaType": "tv", "directRemoteNum": -1]
    }

    /// A television with `count` stations of one kind: each request is answered with the page it asks for,
    /// by its `stIdx` and its `cnt`, and with an empty page past the end.
    private static func television(stations count: Int) -> StubTransport {
        StubTransport { request, _ in
            let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            let asked = (body?["params"] as? [[String: Any]])?.first ?? [:]
            let rows = (0..<count).dropFirst(asked["stIdx"] as? Int ?? 0).prefix(asked["cnt"] as? Int ?? 0)
                .map(stationRow)
            return HTTPResponse(statusCode: 200,
                                body: try JSONSerialization.data(withJSONObject: ["result": [rows], "id": 1]))
        }
    }

    private static let start = Date(timeIntervalSince1970: 1_793_534_400)

    /// A reservation as it is sent: a programme on the station of `uri`, once unless said.
    private func body(repeating: String = "1", title: String = "サンプル劇場") throws -> TVReservationBody {
        let request = ReservationRequest(title: title, start: Self.start, durationSec: 1800, repeatCode: repeating,
                                         broadcastingType: 2, serviceID: 1024, qualityCode: 100, eventID: 12345)
        return try XCTUnwrap(TVReservationBody(request, on: TVStation(broadcastingType: 2, serviceID: 1024,
                                                                      uri: Self.uri)))
    }

    /// The stations of one kind of broadcast are asked for fifty at a time, from `/sony/avContent` and with
    /// the cookie. A page of fifty is followed by the one after it; a shorter one ends the list and is not
    /// read on from; and so does an empty one, after a last page of exactly fifty. Each kind is asked for
    /// under the television's name for it, and a kind it has no name for is not asked for: it has no stations.
    /// A page is as long as the rows the television sent, whatever they read as.
    func testTheStationsAreReadFiftyAtATime() async throws {
        let cases: [(Int, [Int])] = [(0, [0]), (3, [0]), (49, [0]), (50, [0, 50]), (61, [0, 50]), (100, [0, 50, 100])]
        for (count, pages) in cases {
            let transport = Self.television(stations: count)
            let (tv, _) = client(transport, Self.kept)

            let stations = try await tv.stations(of: 3)

            XCTAssertEqual(stations.map(\.serviceID), (0..<count).map { 1500 + $0 }, "\(count) stations")
            XCTAssertEqual(stations.map(\.uri), (0..<count).map { Self.stationRow($0)["uri"] as? String })
            XCTAssertTrue(stations.allSatisfy { $0.broadcastingType == 3 }, "\(count) stations")
            let sent = await transport.requests
            XCTAssertEqual(sent.map { $0.url.path }, pages.map { _ in "/sony/avContent" }, "\(count) stations")
            XCTAssertTrue(sent.allSatisfy { $0.headers["Cookie"] == "auth=kept" }, "\(count) stations")
            for (request, from) in zip(sent, pages) {
                let body = try json(request)
                XCTAssertEqual(body["method"] as? String, "getContentList")
                XCTAssertEqual(body["version"] as? String, "1.0")
                XCTAssertEqual(body["params"] as? NSArray,
                               [["source": "tv:isdbbs", "stIdx": from, "cnt": 50]] as NSArray, "\(count) stations")
            }
        }

        let none = StubTransport(always: ok("[[]]"))
        let (tv, _) = client(none, Self.kept)
        let sources = [(2, "tv:isdbt"), (3, "tv:isdbbs"), (4, "tv:isdbcs"), (23, "tv:isdbs3bs"), (24, "tv:isdbs3cs")]
        for type in sources.map(\.0) + [0, 1, 5, 25] {
            expectEqual(try await tv.stations(of: type), [], "type \(type)")
        }
        let asked = try await none.requests.map { (try json($0)["params"] as? [[String: Any]])?.first?["source"] }
        XCTAssertEqual(asked.map { $0 as? String }, sources.map(\.1))

        // A row that is no station is left out and counted all the same. Of fifty-three rows the eighth has
        // no triplet: the first page is still a full one, the next starts fifty rows on and not forty-nine,
        // and every station that reads is in the list once.
        let holed = StubTransport { request, _ in
            let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            let from = (body?["params"] as? [[String: Any]])?.first?["stIdx"] as? Int ?? 0
            let rows = (0..<53).dropFirst(from).prefix(50).map { index in
                index == 7 ? Self.stationRow(index).filter { $0.key != "tripletStr" } : Self.stationRow(index)
            }
            return HTTPResponse(statusCode: 200,
                                body: try JSONSerialization.data(withJSONObject: ["result": [rows], "id": 1]))
        }
        let (holedTV, _) = client(holed, Self.kept)
        expectEqual(try await holedTV.stations(of: 3).map(\.serviceID), (0..<53).filter { $0 != 7 }.map { 1500 + $0 },
                    "a page with a row that is no station")
        let pages = try await holed.requests.map { (try json($0)["params"] as? [[String: Any]])?.first?["stIdx"] }
        XCTAssertEqual(pages.map { $0 as? Int }, [0, 50], "a page with a row that is no station")
    }

    /// A list that cannot be read whole is not read at all. A failure on any page is thrown -- on the first,
    /// and on the one after a full page, where it is not taken for the end of the list: what a television
    /// answers a page past the end with has not been seen -- and nothing is asked after it. Nor is a list
    /// whose every page is full read on for ever.
    func testAStationListThatCannotBeReadWholeIsNotRead() async throws {
        let full = try JSONSerialization.data(withJSONObject: ["result": [(0..<50).map(Self.stationRow)], "id": 1])
        // Each with what it is thrown as; no answer at all, and no error to hold it against, for silence.
        let failures: [(String, HTTPResponse?, ScalarError?)] = [
            ("the method's own error", failed(3, "Illegal Argument"),
             .rpc(method: "getContentList", version: "1.0", code: 3, message: "Illegal Argument")),
            ("a cookie not taken", HTTPResponse(statusCode: 403), .http(status: 403, method: "getContentList")),
            ("an answer that is no list", ok("[]"), .unreadable(method: "getContentList")),
            ("silence", nil, nil),
        ]
        for (name, answer, expected) in failures {
            for before in [0, 1] {
                let transport = StubTransport { _, index in
                    if index < before { return HTTPResponse(statusCode: 200, body: full) }
                    guard let answer else { throw RecorderError.transport("The request timed out.") }
                    return answer
                }
                let (tv, _) = client(transport, Self.kept)
                do {
                    let read = try await tv.stations(of: 3)
                    XCTFail("\(name) after \(before) full pages was read as a list of \(read.count)")
                } catch let error as ScalarError {
                    XCTAssertEqual(error.failure, expected?.failure ?? .silent, "\(name) after \(before) full pages")
                    if let expected { XCTAssertEqual(error, expected, "\(name) after \(before) full pages") }
                }
                expectEqual(await transport.requests.count, before + 1, "asked on after \(name)")
            }
        }

        let endless = StubTransport(always: HTTPResponse(statusCode: 200, body: full))
        let (tv, _) = client(endless, Self.kept)
        do {
            let read = try await tv.stations(of: 3)
            XCTFail("a list that did not end was read as one of \(read.count)")
        } catch let error as ScalarError {
            XCTAssertEqual(error, .unreadable(method: "getContentList"))
        }
        let asked = try await endless.requests.map { (try json($0)["params"] as? [[String: Any]])?.first?["stIdx"] }
        XCTAssertEqual(asked.map { $0 as? Int }, (0..<20).map { $0 * 50 }, "twenty pages, and no more")
    }

    /// The question of what a reservation would stop from recording is five fields and no others, in the
    /// version that takes them. An empty list is nothing lost. The rows named are handed back as they came,
    /// each of them: a reminder as well as a recording, for the caller to say what it means.
    func testTheClashQuestionIsFiveFieldsAndEveryRowNamedComesBack() async throws {
        let named = #"""
        [[{"id":"recording.31","type":"recording","uri":"\#(Self.uri)","title":"サンプル天気",
           "startDateTime":"2026-11-01T20:45:00+0900","durationSec":1800,"repeatType":"w7"},
          {"id":"reminder.22","type":"reminder","uri":"\#(Self.uri)","title":"サンプル音楽館",
           "startDateTime":"2026-11-01T20:59:59+0900","durationSec":3600,"repeatType":"1"}]]
        """#
        let transport = StubTransport { _, index in
            HTTPResponse(statusCode: 200, body: Data(#"{"result":\#(index == 0 ? "[[]]" : named),"id":1}"#.utf8))
        }
        let (tv, _) = client(transport, Self.kept)
        let asked = try body()

        expectEqual(try await tv.wouldPushOut(asked), [])
        expectEqual(try await tv.wouldPushOut(asked), [
            TVScheduleRow(id: "recording.31", type: "recording", uri: Self.uri,
                          startDateTime: "2026-11-01T20:45:00+0900", durationSec: 1800, title: "サンプル天気",
                          repeatType: "w7"),
            TVScheduleRow(id: "reminder.22", type: "reminder", uri: Self.uri,
                          startDateTime: "2026-11-01T20:59:59+0900", durationSec: 3600, title: "サンプル音楽館",
                          repeatType: "1"),
        ])

        let sent = await transport.requests
        XCTAssertEqual(sent.map { $0.url.path }, ["/sony/recording", "/sony/recording"])
        XCTAssertEqual(sent[0].headers["Cookie"], "auth=kept")
        let question = try json(sent[0])
        XCTAssertEqual(question["method"] as? String, "getConflictScheduleList")
        XCTAssertEqual(question["version"] as? String, "1.0")
        XCTAssertEqual(question["params"] as? NSArray, [[
            "uri": Self.uri, "title": "サンプル劇場", "startDateTime": "2026-11-01T21:00:00+0900", "durationSec": 1800,
            "repeatType": "1",
        ]] as NSArray)
    }

    /// An answer to the question that cannot be read is not taken for "nothing would be lost": one that is no
    /// list of rows, and one with a row among them that is no row, which left out would pass for a reservation
    /// that costs nobody anything.
    func testAClashAnswerThatCannotBeReadIsNotTakenForNone() async throws {
        let row = #"{"id":"recording.31","type":"recording","uri":"\#(Self.uri)","title":"サンプル天気","#
            + #""startDateTime":"2026-11-01T20:45:00+0900","durationSec":1800,"repeatType":"1"}"#
        let shapes = ["[]", #"[{"annotation":0}]"#, #"{"rows":[]}"#, "[[7]]", #"[[\#(row),{"id":"recording.32"}]]"#,
                      #"[[{"id":"reminder.22","type":"reminder","uri":"x","startDateTime":"あした","durationSec":60}]]"#]
        let asked = try body()
        for shape in shapes {
            let (tv, _) = client(StubTransport(always: ok(shape)), Self.kept)
            do {
                let named = try await tv.wouldPushOut(asked)
                XCTFail("\(shape) was read as \(named.count) rows")
            } catch let error as ScalarError {
                XCTAssertEqual(error, .unreadable(method: "getConflictScheduleList"), shape)
            }
        }
        let (tv, _) = client(StubTransport(always: ok("[[\(row)]]")), Self.kept)
        expectEqual(try await tv.wouldPushOut(asked).map(\.id), ["recording.31"], "and a row that reads is read")
    }

    /// A create is seven fields and no others, in the version that follows a programme by its id: the start
    /// with its offset as the television writes one, the length a number, the programme id text, and no mode.
    /// The repeat by the programme's name goes as `title`. The television's answer to the same programme a
    /// second time is read as that; and nothing is sent a second time, for silence or for a cookie not taken.
    func testACreateIsSevenFieldsInTheTelevisionsSpellings() async throws {
        let transport = StubTransport(always: ok(#"[{"annotation":0}]"#))
        let (tv, _) = client(transport, Self.kept)

        try await tv.addSchedule(try body())
        try await tv.addSchedule(try body(repeating: "S001"))

        let sent = await transport.requests
        XCTAssertEqual(sent.map { $0.url.path }, ["/sony/recording", "/sony/recording"])
        XCTAssertEqual(sent[0].headers["Cookie"], "auth=kept")
        let create = try json(sent[0])
        XCTAssertEqual(create["method"] as? String, "addSchedule")
        XCTAssertEqual(create["version"] as? String, "1.1")
        var expected: [String: Any] = [
            "type": "recording", "uri": Self.uri, "title": "サンプル劇場", "startDateTime": "2026-11-01T21:00:00+0900",
            "durationSec": 1800, "repeatType": "1", "eventId": "12345",
        ]
        XCTAssertEqual(create["params"] as? NSArray, [expected] as NSArray)
        expected["repeatType"] = "title"
        XCTAssertEqual(try json(sent[1])["params"] as? NSArray, [expected] as NSArray)

        let again = StubTransport(always: failed(41222, "Overlapped with Other Schedules"))
        let silent = StubTransport { _, _ in throw RecorderError.transport("The request timed out.") }
        let refusing = StubTransport(always: HTTPResponse(statusCode: 403))
        let cases: [(StubTransport, DeviceFailure)] = [
            (again, .alreadyThere), (silent, .silent), (refusing, .needsPairing),
        ]
        for (transport, expected) in cases {
            let (tv, _) = client(transport, Self.kept)
            let asked = try body()
            expectEqual(await failure { try await tv.addSchedule(asked) }, expected)
            expectEqual(await transport.requests.count, 1, "sent again after \(expected)")
        }
    }

    /// A create hands back the number its answer says, as it came: nought, which is all a television has been
    /// seen to say, and any other. An answer that says none -- an object with nothing in it, a list with
    /// nothing in it, a number written as text -- hands back nothing, and is a create taken all the same.
    func testACreateHandsBackWhatItsAnswerSays() async throws {
        let cases: [(String, Int?)] = [
            (#"[{"annotation":0}]"#, 0), (#"[{"annotation":1}]"#, 1), ("[{}]", nil), ("[]", nil),
            (#"[{"annotation":"1"}]"#, nil),
        ]
        for (answer, expected) in cases {
            let transport = StubTransport(always: ok(answer))
            let (tv, _) = client(transport, Self.kept)
            expectEqual(try await tv.addSchedule(try body()), expected, answer)
            expectEqual(await transport.requests.count, 1, answer)
        }
    }

    /// The bytes of a request are the same every time it is written: the keys in order at every depth, so
    /// that what a television was sent once is what it is sent ever after. Each request the client has, by
    /// what goes on the wire.
    func testTheKeysOfEveryBodyAreInOrder() async throws {
        let answers = [
            "getPowerStatus": #"[{"status":"active"}]"#,
            "getStorageList": #"[[{"uri":"usb:recStorage","mounted":"mounted"}]]"#,
            "getScheduleList": "[[]]", "getContentList": "[[]]", "getConflictScheduleList": "[[]]",
            "addSchedule": #"[{"annotation":0}]"#, "deleteSchedule": "[]", "actRegister": "[]",
        ]
        let transport = StubTransport { request, _ in
            let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            let result = answers[body?["method"] as? String ?? ""] ?? "[]"
            return HTTPResponse(statusCode: 200, body: Data(#"{"result":\#(result),"id":1}"#.utf8),
                                headers: ["Set-Cookie": "auth=kept; Path=/sony/; Max-Age=1209600"])
        }
        let (tv, _) = client(transport, Self.kept)
        let asked = try body()

        _ = try await tv.powerStatus()
        _ = try await tv.storage()
        _ = try await tv.schedules()
        _ = try await tv.stations(of: 2)
        _ = try await tv.wouldPushOut(asked)
        try await tv.addSchedule(asked)
        try await tv.deleteSchedule(TVScheduleRow(id: "recording.31", type: "recording", uri: Self.uri,
                                                  startDateTime: "2026-11-01T21:00:00+0900", durationSec: 1800,
                                                  title: "サンプル劇場"))
        _ = try await tv.register(clientID: "BDBridge:test", nickname: "BD Bridge", pin: nil)

        let reservation = #""repeatType":"1","startDateTime":"2026-11-01T21:00:00+0900","title":"サンプル劇場","#
        expectEqual(await transport.bodies, [
            #"{"id":1,"method":"getPowerStatus","params":[],"version":"1.0"}"#,
            #"{"id":2,"method":"getStorageList","params":[{"uri":"usb:recStorage"}],"version":"1.1"}"#,
            #"{"id":3,"method":"getScheduleList","params":[{"cnt":130,"stIdx":0}],"version":"1.1"}"#,
            #"{"id":4,"method":"getContentList","params":[{"cnt":50,"source":"tv:isdbt","stIdx":0}],"version":"1.0"}"#,
            #"{"id":5,"method":"getConflictScheduleList","params":[{"durationSec":1800,"#
                + reservation + #""uri":"\#(Self.uri)"}],"version":"1.0"}"#,
            #"{"id":6,"method":"addSchedule","params":[{"durationSec":1800,"eventId":"12345","#
                + reservation + #""type":"recording","uri":"\#(Self.uri)"}],"version":"1.1"}"#,
            #"{"id":7,"method":"deleteSchedule","params":[[{"durationSec":1800,"id":"recording.31","#
                + #""startDateTime":"2026-11-01T21:00:00+0900","title":"サンプル劇場","type":"recording","#
                + #""uri":"\#(Self.uri)"}]],"version":"1.1"}"#,
            #"{"id":8,"method":"actRegister","params":[{"clientid":"BDBridge:test","level":"private","#
                + #""nickname":"BD Bridge"},[{"function":"WOL","value":"no"}]],"version":"1.0"}"#,
        ])
    }

    // MARK: - the same on the invented television

    /// What the invented television answers a request put to it as it is written here, which the client
    /// could not be made to write.
    private func answer(of television: DemoTV, _ service: String, _ method: String, _ version: String,
                        _ asked: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(
            withJSONObject: ["method": method, "id": 1, "params": [asked], "version": version] as [String: Any])
        let url = try XCTUnwrap(URL(string: "http://\(Stub.host):80/sony/\(service)"))
        let answer = try await television.send(HTTPRequest(url: url, method: "POST", headers: ["Cookie": "auth=kept"],
                                                           body: body))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: answer.body) as? [String: Any])
    }

    /// The code of the error such a request was answered with, or nil when it was taken.
    private func refusal(by television: DemoTV, _ service: String, _ method: String, _ version: String,
                         _ asked: [String: Any]) async throws -> Int? {
        (try await answer(of: television, service, method, version, asked)["error"] as? [Any])?.first as? Int
    }

    /// The invented television lists the stations put on it by their kind, fifty to a page whatever more is
    /// asked for, and an empty page past the end; its rows are read as stations, each with the uri a
    /// reservation on it is sent with. It is asked as a real one has been: the three fields, in the version
    /// and at the service the client sends, with a cookie it knows.
    func testTheInventedTelevisionListsItsStationsInPages() async throws {
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        let terrestrial = DemoTV.Station(name: "サンプル\u{3000}テレビ")
        let satellite = (0..<61).map { DemoTV.Station(scheme: "isdbbs", serviceID: 1500 + $0, name: "サンプルBS \($0)") }
        await television.receives([terrestrial] + satellite)
        let tv = ScalarClient(host: Stub.host, transport: television, credentials: MemoryTVCredentials(Self.kept))

        expectEqual(try await tv.stations(of: 3),
                    satellite.map { TVStation(broadcastingType: 3, serviceID: $0.serviceID, uri: $0.uri) })
        expectEqual(try await tv.stations(of: 2),
                    [TVStation(broadcastingType: 2, serviceID: 1024, uri: terrestrial.uri)])
        expectEqual(try await tv.stations(of: 4), [])
        let page = "getContentList cookie=yes pin=no"
        expectEqual(await television.calls, [page, page, page, page])

        let whole: [String: Any] = ["source": "tv:isdbbs", "stIdx": 0, "cnt": 50]
        func with(_ change: [String: Any]) -> [String: Any] { whole.merging(change) { $1 } }
        let most = try await answer(of: television, "avContent", "getContentList", "1.0", with(["cnt": 200]))
        XCTAssertEqual((most["result"] as? [[Any]])?.first?.count, 50, "more than fifty stations in one answer")
        let cases: [(String, String, String, [String: Any], Int?)] = [
            ("as a real one has been asked", "avContent", "1.0", whole, nil),
            ("another version", "avContent", "1.2", whole, 12),
            ("another service", "recording", "1.0", whole, 12),
            ("a source that is no kind of broadcast", "avContent", "1.0", with(["source": terrestrial.uri]), 3),
            ("a field more", "avContent", "1.0", with(["target": "all"]), DemoTV.inventedError),
            ("a field less", "avContent", "1.0", whole.filter { $0.key != "cnt" }, DemoTV.inventedError),
            ("an index that is no number", "avContent", "1.0", with(["stIdx": "0"]), DemoTV.inventedError),
        ]
        for (name, service, version, asked, expected) in cases {
            expectEqual(try await refusal(by: television, service, "getContentList", version, asked), expected, name)
        }
        let stale = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "stale"))
        let stranger = ScalarClient(host: Stub.host, transport: television, credentials: stale)
        expectEqual(await failure { _ = try await stranger.stations(of: 3) }, .needsPairing)

        await television.receives(Array(satellite.prefix(50)))
        let before = await television.calls.count
        expectEqual(try await tv.stations(of: 3).count, 50)
        expectEqual(await television.calls.count, before + 2, "a list of exactly fifty did not end with an empty page")
        expectEqual(try await tv.stationPage(of: 3, from: 50).rows, 0)
        expectEqual(try await tv.stationPage(of: 3, from: 40).stations.map(\.serviceID), Array(1540..<1550))
    }

    /// The invented television makes a recording for a create, listed under a number above any it has held,
    /// in DR, its title in the television's own form; the same programme a second time is answered as a real
    /// one answers it, whatever the repeat, and a reminder for it does not stand in the way, not even one
    /// at the programme's own start; a number is not given twice, whatever was deleted; the question before
    /// a create is answered with nothing; and a cookie it does not know is refused for both, with nothing made.
    func testTheInventedTelevisionMakesARecordingAndNumbersItAfresh() async throws {
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        await television.receives([DemoTV.Station()])
        let other = DemoTV.Schedule(id: "recording.41", serviceID: 1032, start: Self.start)
        let reminder = DemoTV.Schedule(id: "reminder.43", type: "reminder", start: Self.start, quality: nil,
                                       eventId: 12345)
        await television.put([other, reminder])
        let tv = ScalarClient(host: Stub.host, transport: television, credentials: MemoryTVCredentials(Self.kept))
        let asked = try body(title: "サンプル劇場 前編")

        expectEqual(try await tv.wouldPushOut(asked), [])
        try await tv.addSchedule(asked)
        let made = DemoTV.Schedule(id: "recording.44", title: "サンプル劇場\u{3000}前編", start: Self.start, eventId: 12345)
        expectEqual(await television.schedules, [other, reminder, made])
        expectEqual(try await tv.schedules().first, made.row)

        var weekly = asked
        weekly.repeatType = "w7"
        expectEqual(await failure { try await tv.addSchedule(asked) }, .alreadyThere)
        expectEqual(await failure { try await tv.addSchedule(weekly) }, .alreadyThere, "whatever the repeat")
        expectEqual(await television.schedules, [other, reminder, made])

        try await tv.deleteSchedule(made.row)
        try await tv.addSchedule(weekly)
        expectEqual(await television.schedules.map(\.id), ["recording.41", "reminder.43", "recording.45"])
        expectEqual(await television.schedules.last?.repeatType, "w7")

        let stale = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "stale"))
        let stranger = ScalarClient(host: Stub.host, transport: television, credentials: stale)
        var another = asked
        another.eventId = "12346"
        expectEqual(await failure { _ = try await stranger.wouldPushOut(another) }, .needsPairing)
        expectEqual(await failure { try await stranger.addSchedule(another) }, .needsPairing)
        expectEqual(await television.schedules.count, 3)
    }

    /// The invented television lists a title as a real one was seen to list the one it was sent: a half-width
    /// space made full-width, and each of the four marks a guide writes in brackets turned into its enclosed
    /// character, with or without a space in the title. A title with neither is listed as sent. So a row
    /// with a mark in its title is never found again by the title it was made with, and is deleted as read.
    func testTheInventedTelevisionListsATitleAsARealOneWasSeenTo() async throws {
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        await television.receives([DemoTV.Station()])
        let tv = ScalarClient(host: Stub.host, transport: television, credentials: MemoryTVCredentials(Self.kept))
        let titles = [
            ("サンプル劇場[字]", "サンプル劇場\u{1F211}"),
            ("[二][S]サンプル映画 [再]", "\u{1F214}\u{1F142}サンプル映画\u{3000}\u{1F21E}"),
            ("サンプル劇場 前編", "サンプル劇場\u{3000}前編"), ("サンプル紀行", "サンプル紀行"),
        ]
        for (index, (sent, listed)) in titles.enumerated() {
            var asked = try body(title: sent)
            asked.eventId = String(12345 + index)
            try await tv.addSchedule(asked)
            let made = try await tv.schedules().first
            XCTAssertEqual(made?.title.map { Array($0.unicodeScalars) }, Array(listed.unicodeScalars), sent)
            XCTAssertEqual(DemoTV.listedTitle(sent), listed, sent)
        }
        for row in try await tv.schedules() { try await tv.deleteSchedule(row) }
        expectEqual(await television.schedules, [])
    }

    /// The invented television takes a create, and the question before it, only as a real one has been sent
    /// them: the seven fields and the five, each in its spelling and its type, in the version and at the
    /// service the client sends. Anything else is answered with an error no real one gives -- another version
    /// or service as a method it does not have -- and nothing is made.
    func testTheInventedTelevisionTakesACreateOnlyAsARealOneHasBeenSentIt() async throws {
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        await television.receives([DemoTV.Station()])
        let create: [String: Any] = [
            "type": "recording", "uri": Self.uri, "title": "サンプル劇場", "startDateTime": "2026-11-01T21:00:00+0900",
            "durationSec": 1800, "repeatType": "1", "eventId": "12345",
        ]
        let question = create.filter { $0.key != "type" && $0.key != "eventId" }
        var changes: [(String, [String: Any])] = create.keys.sorted().map { field in
            ("no \(field)", create.filter { $0.key != field })
        }
        changes += [
            ("a mode among them", ["quality": "DR"]), ("a reminder", ["type": "reminder"]),
            ("a station it does not receive", ["uri": Self.uri + "2"]),
            ("the start as the recorder spells one", ["startDateTime": "2026-11-01T21:00:00+09:00"]),
            ("the start with no offset", ["startDateTime": "2026-11-01T21:00:00"]),
            ("the length as text", ["durationSec": "1800"]), ("no length to speak of", ["durationSec": 0]),
            ("the programme as a number", ["eventId": 12345]), ("the programme not in decimal", ["eventId": "0x3039"]),
            ("the programme with a sign", ["eventId": "+12345"]),
            ("a repeat as the recorder spells it", ["repeatType": "S001"]),
        ].map { ($0.0, create.merging($0.1) { $1 }) }
        for (name, body) in changes {
            expectEqual(try await refusal(by: television, "recording", "addSchedule", "1.1", body),
                        DemoTV.inventedError, name)
        }
        for (service, version) in [("recording", "1.0"), ("recording", "1.2"), ("avContent", "1.1")] {
            expectEqual(try await refusal(by: television, service, "addSchedule", version, create), 12,
                        "\(service) \(version)")
        }

        let asked: [(String, String, String, [String: Any], Int?)] = [
            ("as a real one has been asked", "recording", "1.0", question, nil),
            ("the create's seven", "recording", "1.0", create, DemoTV.inventedError),
            ("the programme left in", "recording", "1.0", question.merging(["eventId": "12345"]) { $1 },
             DemoTV.inventedError),
            ("no title", "recording", "1.0", question.filter { $0.key != "title" }, DemoTV.inventedError),
            ("a repeat as the recorder spells it", "recording", "1.0", question.merging(["repeatType": "S001"]) { $1 },
             DemoTV.inventedError),
            ("another version", "recording", "1.1", question, 12),
        ]
        for (name, service, version, body, expected) in asked {
            expectEqual(try await refusal(by: television, service, "getConflictScheduleList", version, body),
                        expected, name)
        }

        expectEqual(await television.schedules, [], "something was made of a request it does not take")
        expectNil(try await refusal(by: television, "recording", "addSchedule", "1.1", create))
        expectEqual(await television.schedules.map(\.id), ["recording.1"])
    }
}
