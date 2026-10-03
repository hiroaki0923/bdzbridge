import Foundation
import XCTest
@testable import RecorderKit

/// A television's control API as the client speaks it: the envelope, the answers in their two depths, the
/// errors, the registration with its cookie, and its reservations read and deleted. The answers are written
/// here in the television's shapes with invented values: nothing in them comes from a real one.
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
}
