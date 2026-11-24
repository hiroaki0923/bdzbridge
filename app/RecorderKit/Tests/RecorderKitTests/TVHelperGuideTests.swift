import XCTest
@testable import RecorderKit

/// When the stubbed helper's copies changed, unless a test says otherwise.
private let copiesChanged = Date(timeIntervalSince1970: 1_800_000_000)

/// The television's guide through its helper (`TVHelperGuide`), against a stubbed helper and a cache in memory.
@MainActor
final class TVHelperGuideTests: XCTestCase {
    /// What the stubbed helper has and how it answers, changed by a test between fetches.
    private final class Helper: @unchecked Sendable {
        private let lock = NSLock()
        private var _programs: [String: Int] = ["td": 1, "bs": 1]
        private var _changedAt: [String: Date] = ["td": copiesChanged, "bs": copiesChanged]
        /// What the helper answers to a path in place of what it has; a nil answer is silence.
        private var _instead: [String: HTTPResponse?] = [:]
        /// Holds the answer to /v1/info until `release`.
        private var held: CheckedContinuation<Void, Never>?
        private var _holdsInfo = false
        private var _infoAsked = 0
        var infoAsked: Int { lock.withLock { _infoAsked } }

        var programs: [String: Int] {
            get { lock.withLock { _programs } }
            set { lock.withLock { _programs = newValue } }
        }
        var changedAt: [String: Date] {
            get { lock.withLock { _changedAt } }
            set { lock.withLock { _changedAt = newValue } }
        }
        func answer(_ path: String, with response: HTTPResponse?) { lock.withLock { _instead[path] = .some(response) } }
        func holdInfo() { lock.withLock { _holdsInfo = true } }
        func release() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                _holdsInfo = false
                defer { held = nil }
                return held
            }
            waiting?.resume()
        }
        var isHoldingInfo: Bool { lock.withLock { held != nil } }

        func respond(to request: HTTPRequest) async throws -> HTTPResponse {
            let path = request.url.path
            if let instead = lock.withLock({ _instead[path] }) {
                guard let instead else { throw TVHelperError.transport("no answer") }
                return instead
            }
            switch path {
            case "/v1/info":
                let hold = lock.withLock { () -> Bool in
                    _infoAsked += 1
                    return _holdsInfo
                }
                if hold { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
                let changedAt = changedAt
                let types: [String: Any] = Dictionary(uniqueKeysWithValues: programs.map { type, count -> (String, Any) in
                    let changed = Int((changedAt[type] ?? copiesChanged).timeIntervalSince1970 * 1000)
                    let state: [String: Any] = ["etag": "x", "changedAt": changed, "snapshotAt": 1_800_000_500_000,
                                                "programs": count, "channels": 1]
                    return (type, state)
                })
                return Self.json(200, ["helperVersion": "0.1.0", "listingsPermission": true, "tunerInstalled": true,
                                       "building": false, "types": types])
            case "/v1/channels":
                return Self.json(200, ["channels": [
                    ["bt": "td", "sid": 1024, "number": "011", "name": "一", "hasPrograms": true],
                    ["bt": "bs", "sid": 101, "number": "101", "name": "二", "hasPrograms": true],
                ]])
            case "/v1/guide/td", "/v1/guide/bs":
                let type = String(path.dropFirst("/v1/guide/".count))
                let sid = type == "td" ? 1024 : 101
                let listed = (0..<(programs[type] ?? 0)).map { index -> [String: Any] in
                    ["sid": sid, "eid": index + 1, "startMs": 1_800_000_000_000 + index * 1_000_000,
                     "endMs": 1_800_001_000_000 + index * 1_000_000, "title": "番組"]
                }
                return Self.json(200, ["bt": type, "programs": listed])
            case "/v1/logos/td", "/v1/logos/bs":
                return Self.json(200, ["bt": String(path.dropFirst("/v1/logos/".count)), "logos": []])
            case "/ping":
                return Self.json(200, ["app": "recbridge-helper", "api": [1], "version": "0.1.0"])
            case "/v1/pair":
                return Self.json(200, ["token": "secret", "deviceId": "d1", "api": [1], "version": "0.1.0"])
            default:
                return Self.json(404, ["error": "notFound"])
            }
        }

        static func json(_ status: Int, _ object: Any) -> HTTPResponse {
            HTTPResponse(statusCode: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }

    private var helper = Helper()
    private var transport: StubTransport!
    private var tokens: MemoryTVHelperToken!
    private var store: GuideStore!
    private var guide: TVHelperGuide!

    override func setUp() async throws {
        helper = Helper()
        let helper = helper
        transport = StubTransport { request, _ in try await helper.respond(to: request) }
        tokens = MemoryTVHelperToken("tok")
        store = try GuideStore(path: ":memory:")
        guide = TVHelperGuide(client: TVHelperClient(host: Stub.host, transport: transport, tokens: tokens))
    }

    private func guideRequests() async -> [String] {
        await transport.requests.map(\.url.path).filter { $0.hasPrefix("/v1/guide/") }
    }

    private func programmes(_ broadcasting: String) async throws -> Int {
        try await store.counts()[broadcasting]?.programs ?? 0
    }

    func testEveryTypeTheHelperHasProgrammesOfIsFetchedAndMarked() async throws {
        helper.programs = ["td": 2, "bs": 0]
        let stored = Stored()
        let said = await guide.fetch(every: true, into: store, on: nil, stored: { await stored.note($0) })
        XCTAssertNil(said)
        let asked = await guideRequests()
        XCTAssertEqual(asked, ["/v1/guide/td"], "a type the helper has no programmes of is not asked for")
        let held = try await programmes("td")
        XCTAssertEqual(held, 2)
        let mark = try await store.helperChanged(broadcasting: "td")
        XCTAssertEqual(mark, copiesChanged)
        let noted = await stored.types
        XCTAssertEqual(noted, ["td"])
        XCTAssertNotNil(guide.lastCheck)
        XCTAssertFalse(guide.isFetching)
        let givenBy = try await store.counts()["td"]?.givenBy
        XCTAssertEqual(givenBy, .tv, "what the helper gives is written down as the television's")
    }

    /// A type the television has no guide of, which the cache holds as the recorder's, is emptied once the
    /// helper has said what it has, and stands as it does in a home with a television alone: no channels, no
    /// programmes, no mark. So is one the television has channels of and no programmes. No file is asked for
    /// either; the types the helper has programmes of are fetched over the recorder's.
    func testATypeTheTelevisionHasNoGuideOfIsEmptiedOfTheRecordersRows() async throws {
        helper.programs = ["td": 1, "bs": 0]
        let recorders = [GuideService(serviceID: 301, name: "レコーダーの局", programs: [])]
        for type in ["td", "bs", "cs"] { try await store.replace(recorders, broadcasting: type) }

        let said = await guide.fetch(into: store, on: nil, stored: { _ in })

        XCTAssertNil(said)
        let asked = await guideRequests()
        XCTAssertEqual(asked, ["/v1/guide/td"])
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.givenBy, .tv)
        for type in ["bs", "cs"] {
            XCTAssertEqual(counts[type]?.channels, 0, "\(type): the recorder's rows were left under the television's guide")
            XCTAssertNil(counts[type]?.lastAnswered, type)
            XCTAssertNil(counts[type]?.refreshed, type)
        }
    }

    /// A helper that has no copy yet says nothing of what the television has, and nothing is emptied for it. Nor
    /// is a type that is the television's own emptied when the helper has no programmes of it for the moment:
    /// what the cache holds of it stays until the helper's next copy.
    func testNothingIsEmptiedForAHelperWithNoCopyNorOfTheTelevisionsOwnRows() async throws {
        let recorders = [GuideService(serviceID: 301, name: "レコーダーの局", programs: [])]
        try await store.replace(recorders, broadcasting: "cs")
        helper.programs = [:]
        var said = await guide.fetch(every: true, into: store, on: nil, stored: { _ in })
        XCTAssertNil(said)
        var counts = try await store.counts()
        XCTAssertEqual(counts["cs"]?.channels, 1, "emptied for a helper that has no copy")

        helper.programs = ["td": 1, "bs": 1]
        said = await guide.fetch(every: true, into: store, on: nil, stored: { _ in })
        XCTAssertNil(said)
        helper.programs = ["td": 1, "bs": 0]
        guide.forgetTheCheck()
        said = await guide.fetch(into: store, on: nil, stored: { _ in })
        XCTAssertNil(said)
        counts = try await store.counts()
        XCTAssertEqual(counts["bs"]?.programs, 1, "the television's own rows went")
        XCTAssertEqual(counts["cs"]?.channels, 0, "set up wrong: the recorder's type was not emptied")
    }

    /// The emptying is decided and done with the guide's turn in hand, by what the cache holds then. A refresh
    /// of the recorder's that has the turn as the television's fetch comes -- out since before the television
    /// was chosen -- stores CS, which the television has no guide of, while the fetch waits behind it: the cache
    /// held nothing of CS as the fetch asked the helper what it has, and holds the recorder's as its turn comes.
    /// It ends with CS empty, and the television's own type fetched.
    func testWhatARecordersRefreshInFrontPutInIsEmptiedOnceTheTurnHasCome() async throws {
        helper.programs = ["td": 1]
        let sample = try Vectors.load("epg-sample.json").string("file")
        let file = try Data(contentsOf: Vectors.directory.appendingPathComponent(sample))
        let recorder = RecorderClient(host: Stub.host, transport: StubTransport { request, _ in
            let isCS = request.url.lastPathComponent == Codes.epgFiles["cs"]
            return isCS ? HTTPResponse(statusCode: 200, body: file) : HTTPResponse(statusCode: 404)
        }, streamPort: 60151, busyRetryDelay: 0...0)
        let held = Held()
        let store = store!
        let inFront = Task {
            await GuideRefresh.run(asked: .only(["cs"]), onTurn: {
                await held.wait()
                return .fetch(client: recorder, store: store, from: nil)
            })
        }
        await held.untilWaitedOn()

        let fetch = Task { await guide.fetch(into: store, on: nil, stored: { _ in }) }
        // The fetch has asked the helper and read the cache for what is behind, and waits for the turn.
        let waits = await eventually { guide.lastCheck != nil }
        XCTAssertTrue(waits, "the fetch never came to wait for its turn")
        var counts = try await store.counts()
        XCTAssertEqual(counts["cs"]?.channels, 0, "set up wrong: the recorder's refresh has stored already")
        await held.letGo()
        let recorders = await inFront.value
        let said = await fetch.value

        XCTAssertEqual(recorders.answered, ["cs"], "set up wrong: the recorder's refresh stored nothing")
        XCTAssertNil(said)
        counts = try await store.counts()
        XCTAssertEqual(counts["cs"]?.channels, 0, "what the recorder's refresh put in stayed under the television's guide")
        XCTAssertNil(counts["cs"]?.lastAnswered)
        XCTAssertEqual(counts["td"]?.givenBy, .tv)
        XCTAssertEqual(counts["td"]?.programs, 1)
    }

    /// With nothing to fetch, the helper's copies being the ones the cache was filled from, a type the
    /// television has no guide of is emptied all the same.
    func testATypeIsEmptiedByAFetchThatHasNothingToFetch() async throws {
        await guide.fetch(into: store, on: nil, stored: { _ in })
        try await store.replace([GuideService(serviceID: 301, name: "レコーダーの局", programs: [])],
                                broadcasting: "cs")
        let asked = await guideRequests().count

        guide.forgetTheCheck()
        let said = await guide.fetch(into: store, on: nil, stored: { _ in })

        XCTAssertNil(said)
        let since = await guideRequests().count
        XCTAssertEqual(since, asked, "set up wrong: something was fetched")
        let channels = try await store.counts()["cs"]?.channels
        XCTAssertEqual(channels, 0)
    }

    func testOnlyTheTypesTheHelperHasNewerCopiesOfAreFetched() async throws {
        await guide.fetch(into: store, on: nil, stored: { _ in })
        var asked = await guideRequests()
        XCTAssertEqual(asked, ["/v1/guide/td", "/v1/guide/bs"], "an empty cache is behind on every type")

        guide.forgetTheCheck()
        let said = await guide.fetch(into: store, on: nil, stored: { _ in })
        XCTAssertNil(said)
        asked = await guideRequests()
        XCTAssertEqual(asked.count, 2, "nothing is fetched where nothing changed")
        XCTAssertNotNil(guide.lastCheck, "the check is noted all the same")

        helper.changedAt["bs"] = copiesChanged.addingTimeInterval(60)
        await guide.fetch(into: store, on: nil, stored: { _ in })
        asked = await guideRequests()
        XCTAssertEqual(Array(asked.dropFirst(2)), ["/v1/guide/bs"])
        let mark = try await store.helperChanged(broadcasting: "bs")
        XCTAssertEqual(mark, copiesChanged.addingTimeInterval(60))

        // 番組表を更新 asks for every type however fresh the marks.
        await guide.fetch(every: true, into: store, on: nil, stored: { _ in })
        asked = await guideRequests()
        XCTAssertEqual(Array(asked.dropFirst(3)), ["/v1/guide/td", "/v1/guide/bs"])
    }

    /// A type whose rows the cache holds as the recorder's is fetched though the helper's copy is the one the
    /// cache was last filled from: the television gives this home's guide, and what the recorder put in its
    /// place since is not it. The type that is the television's still is left alone.
    func testATypeTheRecorderGaveIsFetchedThoughTheHelpersCopyIsUnchanged() async throws {
        await guide.fetch(into: store, on: nil, stored: { _ in })
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let programme = GuideProgram(serviceID: 1024, eventID: 7, start: start, end: start.addingTimeInterval(3600),
                                     title: "レコーダーの番組")
        try await store.replace([GuideService(serviceID: 1024, name: "レコーダーの局", programs: [programme])],
                                broadcasting: "td")
        let mark = try await store.helperChanged(broadcasting: "td")
        XCTAssertEqual(mark, copiesChanged, "set up wrong: the mark of the helper's copy went")

        guide.forgetTheCheck()
        let said = await guide.fetch(into: store, on: nil, stored: { _ in })

        XCTAssertNil(said)
        let asked = await guideRequests()
        XCTAssertEqual(Array(asked.dropFirst(2)), ["/v1/guide/td"])
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.givenBy, .tv)
        let titles = try await store.programs(broadcasting: "td").map(\.title)
        XCTAssertEqual(titles, ["番組"])
    }

    func testATypeTheCacheHoldsNoProgrammesOfIsFetchedThoughItsMarkIsFresh() async throws {
        try await store.noteHelperChanged(broadcasting: "td", at: copiesChanged)
        try await store.noteHelperChanged(broadcasting: "bs", at: copiesChanged)
        await guide.fetch(into: store, on: nil, stored: { _ in })
        let asked = await guideRequests()
        XCTAssertEqual(asked, ["/v1/guide/td", "/v1/guide/bs"])
    }

    func testWhatTheHelperSaysInsteadOfWhatItHasIsSaidAndTheCheckIsNotNoted() async {
        helper.answer("/v1/info", with: Helper.json(503, ["error": "building"]))
        let said = await guide.fetch(into: store, on: nil, stored: { _ in })
        XCTAssertEqual(said, TVHelperError.notReady("building").explanation)
        XCTAssertNil(guide.lastCheck)
        XCTAssertTrue(guide.isDue())
        let asked = await guideRequests()
        XCTAssertEqual(asked, [])
    }

    func testATypeThatFailsIsSaidAndLeftUnmarkedAndTheRestAreStored() async throws {
        helper.answer("/v1/guide/bs", with: HTTPResponse(statusCode: 500))
        let said = await guide.fetch(into: store, on: nil, stored: { _ in })
        XCTAssertEqual(said, "BS の番組表：" + TVHelperError.unexpected("HTTP 500").explanation)
        let held = try await programmes("td")
        XCTAssertEqual(held, 1)
        let marks = (try await store.helperChanged(broadcasting: "td"), try await store.helperChanged(broadcasting: "bs"))
        XCTAssertEqual(marks.0, copiesChanged)
        XCTAssertNil(marks.1, "a type that failed is fetched again next time")
    }

    func testSilenceEndsTheFetchAndIsSaid() async throws {
        helper.answer("/v1/guide/td", with: nil)
        let said = await guide.fetch(into: store, on: nil, stored: { _ in })
        XCTAssertEqual(said, TVHelperError.transport("").explanation)
        let asked = await guideRequests()
        XCTAssertEqual(asked, ["/v1/guide/td"], "nothing is asked after the silence")
        let mark = try await store.helperChanged(broadcasting: "td")
        XCTAssertNil(mark)
    }

    /// With the television answering beside it, the helper's silence says that the helper is not running there
    /// and how to start it; with the television not answering either, it is said as it always was.
    func testTheHelpersSilenceBesideATelevisionThatAnswersSaysToOpenIt() async throws {
        let world = LinkWorld()
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        world.devices[Stub.host] = television
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let link = DeviceLink(host: Stub.host, session: SessionState(),
                              driver: TVDriver(credentials: credentials, nickname: "RecBridge", inFront: { false }),
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "the television was not connected")

        helper.answer("/v1/info", with: nil)
        let unopened = await guide.fetch(into: store, on: link, stored: { _ in })
        XCTAssertEqual(unopened, TVHelperGuide.notRunning)

        helper.answer("/v1/info", with: nil)
        let away = await guide.fetch(into: store, on: nil, stored: { _ in })
        XCTAssertEqual(away, TVHelperError.transport("").explanation)
    }

    func testAFetchAskedForWhileOneIsOutWaitsForItAndSaysWhatItSaid() async throws {
        helper.holdInfo()
        helper.answer("/v1/guide/bs", with: HTTPResponse(statusCode: 500))
        let guide = guide!
        let store = store!
        let first = Task { await guide.fetch(into: store, on: nil, stored: { _ in }) }
        let helper = helper
        let held = await eventually { helper.isHoldingInfo }
        XCTAssertTrue(held, "the first fetch never asked the helper")
        XCTAssertTrue(guide.isFetching)
        let second = Task { await guide.fetch(every: true, into: store, on: nil, stored: { _ in }) }
        await Task.yield()
        helper.release()
        let said = (await first.value, await second.value)
        XCTAssertNotNil(said.0)
        XCTAssertEqual(said.0, said.1)
        XCTAssertEqual(helper.infoAsked, 1, "one fetch was made")
        XCTAssertFalse(guide.isFetching)
    }

    func testTheHelperIsAskedAgainAnHourAfterItLastSaidWhatItHas() async throws {
        XCTAssertTrue(guide.isDue())
        await guide.fetch(into: store, on: nil, stored: { _ in })
        let checked = try XCTUnwrap(guide.lastCheck)
        XCTAssertFalse(guide.isDue(at: checked.addingTimeInterval(TVHelperGuide.checkInterval - 1)))
        XCTAssertTrue(guide.isDue(at: checked.addingTimeInterval(TVHelperGuide.checkInterval)))
        guide.forgetTheCheck()
        XCTAssertTrue(guide.isDue(at: checked))
    }

    func testTheFetchIsUnderALineOfTheTelevisionsThatSaysEachType() async throws {
        let world = LinkWorld()
        let link = DeviceLink(host: Stub.host, session: SessionState(),
                              driver: TVDriver(credentials: MemoryTVCredentials(), nickname: "RecBridge",
                                               inFront: { false }),
                              environment: world.environment)
        link.owner = world
        await guide.fetch(into: store, on: link, stored: { _ in })
        XCTAssertEqual(world.begun, [TVHelperGuide.line])
        XCTAssertEqual(world.updated, ["番組表を取得中（テレビ: 地上デジタル）", "番組表を取得中（テレビ: BS）"])
    }

    func testRegisteringMakesSureOfTheHelperAndSaysWhyItCouldNot() async throws {
        tokens.remove()
        guide = TVHelperGuide(client: TVHelperClient(host: Stub.host, transport: transport, tokens: tokens))
        XCTAssertFalse(guide.isRegistered)

        helper.answer("/v1/pair", with: Helper.json(403, ["error": "badCode"]))
        var said = await guide.register(code: "000000", label: "RecBridge")
        XCTAssertEqual(said, TVHelperError.pairingRefused("badCode").explanation)
        XCTAssertFalse(guide.isRegistered)

        helper.answer("/v1/pair", with: Helper.json(200, ["token": "secret", "deviceId": "d1", "api": [1], "version": "0.1.0"]))
        said = await guide.register(code: "123456", label: "RecBridge")
        XCTAssertNil(said)
        XCTAssertTrue(guide.isRegistered)
        XCTAssertEqual(tokens.load(), "secret")
        let pairing = await transport.requests.last { $0.url.path == "/v1/pair" }
        let body = try XCTUnwrap(pairing?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(body, ["code": "123456", "label": "RecBridge"])

        guide.forgetRegistration()
        XCTAssertFalse(guide.isRegistered)
        XCTAssertNil(tokens.load())

        // Something other than the helper at the address: nothing is sent to pair with.
        helper.answer("/ping", with: Helper.json(200, ["app": "something", "api": [1], "version": "9"]))
        let before = await transport.requests.count
        said = await guide.register(code: "123456", label: "RecBridge")
        XCTAssertEqual(said, TVHelperError.notAHelper.explanation)
        let sent = await transport.requests.dropFirst(before).map(\.url.path)
        XCTAssertEqual(sent, ["/ping"])
        XCTAssertFalse(guide.isRegistered)
    }
}

/// The types a fetch said were stored, in order.
@MainActor
private final class Stored {
    private(set) var types: [String] = []
    func note(_ broadcasting: String) { types.append(broadcasting) }
}

/// Holds whoever waits on it until it is let go, and says when somebody waits.
private actor Held {
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { waiting = $0 }
    }

    func untilWaitedOn() async {
        while waiting == nil { await Task.yield() }
    }

    func letGo() {
        waiting?.resume()
        waiting = nil
    }
}
