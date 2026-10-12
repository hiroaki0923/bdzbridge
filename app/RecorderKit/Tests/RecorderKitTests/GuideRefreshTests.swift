import XCTest
@testable import RecorderKit

/// Fetching the guide a broadcasting type at a time, which the screens and the overnight run share.
final class GuideRefreshTests: XCTestCase {
    private func file(_ vector: String) throws -> Data {
        let expected = try Vectors.load(vector)
        return try Data(contentsOf: Vectors.directory.appendingPathComponent(expected.string("file")))
    }

    /// A recorder serving the sample guide and logos for the types in `serving`, and for the rest what
    /// `otherwise` says. The port is given, so nothing goes looking for it.
    private func recorder(serving: Set<String>,
                          otherwise: @escaping @Sendable (String) throws -> HTTPResponse) throws
        -> (client: RecorderClient, transport: StubTransport) {
        let guide = try file("epg-sample.json")
        let logos = try file("logo-sample.json")
        let transport = StubTransport { request, _ in
            let url = request.url.absoluteString
            for broadcasting in serving {
                if let name = Codes.epgFiles[broadcasting], url.hasSuffix("/" + name) {
                    return HTTPResponse(statusCode: 200, body: guide)
                }
                if let name = Codes.logoFiles[broadcasting], url.hasSuffix("/" + name) {
                    return HTTPResponse(statusCode: 200, body: logos)
                }
            }
            return try otherwise(url)
        }
        return (RecorderClient(host: Stub.host, transport: transport, streamPort: 60151, busyRetryDelay: 0...0),
                transport)
    }

    /// A file the recorder has not built yet answers 500, and used to end the whole refresh there. It is
    /// passed over now, as is a file that cannot be read, and neither is marked as fetched; the types after
    /// them are fetched, and one the recorder has no file for is marked as answered.
    func testATypeThatFailsIsPassedOverAndTheRestAreFetched() async throws {
        let (client, _) = try recorder(serving: ["td"]) { url in
            if url.hasSuffix(Codes.epgFiles["bs"]!) { return HTTPResponse(statusCode: 500) }
            if url.hasSuffix(Codes.epgFiles["cs"]!) { return HTTPResponse(statusCode: 200, body: Data([1, 2, 3])) }
            return HTTPResponse(statusCode: 416)
        }
        let store = try GuideStore(path: ":memory:")
        let stored = Stored()

        let outcome = await GuideRefresh.run(client: client, store: store, onStored: { stored.add($0) })

        XCTAssertEqual(outcome.stored, 5)
        XCTAssertEqual(outcome.answered, ["td", "bs4k"])
        XCTAssertEqual(outcome.failed.map(\.broadcasting), ["bs", "cs"])
        XCTAssertTrue(outcome.failed[0].reason.contains("HTTP 500"), outcome.failed[0].reason)
        XCTAssertEqual(outcome.failed[1].reason, "レコーダーから受け取った番組表ファイルを読み取れませんでした")
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(stored.types, ["td"])

        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.programs, 4)
        let withLogos = try await store.channels(broadcasting: "td").filter { $0.logo != nil }
        XCTAssertFalse(withLogos.isEmpty, "the logos came with the programmes")
        XCTAssertNil(counts["bs"]?.lastAnswered, "a failed type is asked for again next time")
        XCTAssertNil(counts["cs"]?.lastAnswered)
        XCTAssertNotNil(counts["bs4k"]?.lastAnswered, "one with no file is not asked for again before the rebuild")
        XCTAssertNil(counts["bs4k"]?.refreshed)
    }

    /// Only the types asked for are fetched.
    func testOnlyTheTypesAskedForAreFetched() async throws {
        let (client, transport) = try recorder(serving: ["td", "bs"]) { _ in HTTPResponse(statusCode: 416) }
        let store = try GuideStore(path: ":memory:")

        let outcome = await GuideRefresh.run(client: client, store: store, types: ["bs"])

        XCTAssertEqual(outcome.answered, ["bs"])
        let urls = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls.count, 2, "the guide and the logos of BS, and nothing of the others")
        XCTAssertTrue(urls.allSatisfy { $0.contains("_BS") }, "\(urls)")
    }

    /// Silence ends it at once: a recorder that has stopped answering will not answer for the next type, and
    /// each file asked of it would cost a long timeout. It is handed back as what stopped the refresh, with
    /// what came before it: the type that was stored, and the one that failed.
    func testSilenceStopsTheRefreshThere() async throws {
        let (client, transport) = try recorder(serving: ["td"]) { url in
            if url.hasSuffix(Codes.epgFiles["bs"]!) { return HTTPResponse(statusCode: 500) }
            throw RecorderError.transport("timed out")
        }
        let store = try GuideStore(path: ":memory:")
        let stored = Stored()

        let outcome = await GuideRefresh.run(client: client, store: store, onStored: { stored.add($0) })

        XCTAssertEqual(outcome.stopped, .silent, "silence was not handed back as what stopped it")
        XCTAssertEqual(outcome.stored, 5, "what was stored before the silence was not handed back")
        XCTAssertEqual(outcome.answered, ["td"])
        XCTAssertEqual(outcome.failed.map(\.broadcasting), ["bs"], "the type that failed before the silence")
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(stored.types, ["td"])
        let urls = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls.last.map { $0.hasSuffix(Codes.epgFiles["cs"]!) }, true, "nothing asked after CS")
        expectEqual(try await store.counts()["td"]?.programs, 4, "the type fetched before it stays")
    }

    /// Silence while fetching a type's logos stops it too, though the logos alone are only looks. The type's
    /// programmes are in the cache by then: it is handed back as answered, with what was stored of it, and is
    /// not reported as stored, which is for a type whose logos are in as well.
    func testSilenceOverTheLogosStopsTheRefreshToo() async throws {
        let guide = try file("epg-sample.json")
        let transport = StubTransport { request, _ in
            guard request.url.absoluteString.hasSuffix(Codes.epgFiles["td"]!) else {
                throw RecorderError.transport("timed out")
            }
            return HTTPResponse(statusCode: 200, body: guide)
        }
        let client = RecorderClient(host: Stub.host, transport: transport, streamPort: 60151)
        let store = try GuideStore(path: ":memory:")
        let stored = Stored()

        let outcome = await GuideRefresh.run(client: client, store: store, onStored: { stored.add($0) })

        XCTAssertEqual(outcome.stopped, .silent)
        XCTAssertEqual(outcome.answered, ["td"], "the type whose programmes are in was not handed back")
        XCTAssertEqual(outcome.stored, 5)
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(stored.types, [])
        expectEqual(await transport.requests.count, 2, "the guide and its logos, and then nothing")
    }

    /// One of two recorders, as each says who it is: Sony's OUI and the rest zeroed, with a last digit of its own.
    private func described(_ last: Int) -> RecorderDescription {
        RecorderDescription(host: Stub.host, port: 64220, friendlyName: "サンプルレコーダー \(last)", product: "BDZ",
                            model: "BDZ-SAMPLE", udn: "uuid:00000000-0000-0000-0000-f84e1700000\(last)",
                            epgCapable: true, location: "http://\(Stub.host):64220/description.xml", via: "manual")
    }

    /// A refresh says which recorder its guide is fetched from, and ends where the cache is another's by the
    /// time a file has come: the cache is made over when another recorder describes itself, and a file asked of
    /// the last one can be out then. Here the first type is stored, the cache is made over to another recorder
    /// as that is reported, and the second type's file comes with a guide: nothing of it is stored and nothing
    /// marked, the refresh ends there with what came before -- the first type answered, its programmes counted
    /// -- and nothing is asked for after that file, not its logos and not the next type.
    ///
    /// The logos alone are only looks, and a failure over them passes; but not this one. Made over between a
    /// type's programmes and its logos, the cache takes no logos and the refresh ends: the type is not reported
    /// as stored, and nothing more is asked for.
    func testARefreshEndsWhereTheCacheHasBeenMadeOverToAnotherRecorder() async throws {
        let (client, transport) = try recorder(serving: ["td", "bs", "cs"]) { _ in HTTPResponse(statusCode: 416) }
        let store = try temporaryStore()
        try await store.claim(for: described(1))
        let second = described(2)
        let stored = Stored()

        let outcome = await GuideRefresh.run(client: client, store: store, from: described(1), onStored: {
            stored.add($0)
            _ = try? await store.claim(for: second)
        })

        XCTAssertEqual(outcome.stopped, .letGo, "the refresh went on into a cache that is another recorder's")
        XCTAssertEqual(outcome.answered, ["td"])
        XCTAssertEqual(outcome.stored, 5, "what was stored before the cache was made over")
        XCTAssertEqual(outcome.failed, [], "a cache that is another's was taken for a type that failed")
        XCTAssertEqual(stored.types, ["td"])
        let urls = await transport.requests.map(\.url.lastPathComponent)
        XCTAssertEqual(urls, [Codes.epgFiles["td"]!, Codes.logoFiles["td"]!, Codes.epgFiles["bs"]!],
                       "something was asked for after the file the cache would not take")
        let counts = try await store.counts()
        for type in GuideRefresh.broadcastingTypes {
            XCTAssertEqual(counts[type]?.programs, 0, "\(type): the last recorder's programmes are in the cache")
            XCTAssertNil(counts[type]?.lastAnswered, "\(type) is marked as answered for")
        }
        expectEqual(try await store.owner(), second.udn)

        // Made over as the first type's logos are asked for.
        let guide = try file("epg-sample.json"), logos = try file("logo-sample.json")
        let other = try temporaryStore()
        try await other.claim(for: described(1))
        let atTheLogos = StubTransport { request, _ in
            guard request.url.lastPathComponent == Codes.logoFiles["td"] else {
                return HTTPResponse(statusCode: 200, body: guide)
            }
            _ = try? await other.claim(for: second)
            return HTTPResponse(statusCode: 200, body: logos)
        }
        let asking = RecorderClient(host: Stub.host, transport: atTheLogos, streamPort: 60151, busyRetryDelay: 0...0)
        let reported = Stored()
        let overTheLogos = await GuideRefresh.run(client: asking, store: other, from: described(1),
                                                  onStored: { reported.add($0) })
        XCTAssertEqual(overTheLogos.stopped, .letGo, "logos the cache would not take were passed over")
        XCTAssertEqual(overTheLogos.answered, ["td"])
        XCTAssertEqual(reported.types, [], "a type whose logos the cache would not take was reported stored")
        expectEqual(await atTheLogos.requests.count, 2, "the guide and its logos, and then nothing")
        expectEqual(try await other.channels(broadcasting: "td", includeHidden: true).count, 0)
    }

    /// Whoever asks for a refresh is asked before each type whether to go on, and a no ends it there, before
    /// that type's file is asked for: the screens say no once the recorder they began with has been let go of.
    /// What came before is handed back with it. With no recorder named and nobody to ask, a refresh asks
    /// neither: it fetches every type into the cache it was given.
    func testARefreshAsksBeforeEachTypeWhetherToGoOn() async throws {
        let (client, transport) = try recorder(serving: ["td", "bs"]) { _ in HTTPResponse(statusCode: 416) }
        let store = try temporaryStore()
        let asked = Stored()

        let outcome = await GuideRefresh.run(client: client, store: store, onType: { type in
            asked.add(type)
            return type != "bs"
        })

        XCTAssertEqual(outcome.stopped, .letGo)
        XCTAssertEqual(outcome.answered, ["td"])
        XCTAssertEqual(asked.types, ["td", "bs"], "each type was meant to be asked about as it came to it")
        expectEqual(await transport.requests.count, 2, "the first type's guide and logos, and nothing of the next")
        expectEqual(try await store.counts()["bs"]?.programs, 0)

        // A cache another recorder owns, and a refresh that names none: nothing is asked of whose it is.
        try await store.claim(for: described(2))
        let unasked = await GuideRefresh.run(client: client, store: store, types: ["bs"])
        XCTAssertNil(unasked.stopped)
        XCTAssertEqual(unasked.answered, ["bs"])
        expectEqual(try await store.counts()["bs"]?.programs, 4)
    }

    /// Cancelled, it stops before its next file rather than going through all four types: the overnight run's
    /// time is up by then, and the task has been completed.
    func testACancelledRefreshStopsBeforeTheNextType() async throws {
        let (client, transport) = try recorder(serving: ["td", "bs", "cs", "bs4k"]) { _ in
            HTTPResponse(statusCode: 416)
        }
        let store = try GuideStore(path: ":memory:")

        let refresh = Task {
            await GuideRefresh.run(client: client, store: store, onStored: { _ in
                // cancelled from inside, once the first type is in, so that nothing depends on timing
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let outcome = await refresh.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.answered, ["td"])
        expectEqual(await transport.requests.count, 2, "the first type's guide and logos")
    }

    /// Cancelled while a type's guide is out, it asks for no further file, and not for that type's logos
    /// either, which follow its guide: the overnight run's time is up by then. The request under way is waited
    /// for and what it brings is stored, so the type is among what was answered for, and is reported as
    /// stored, with the logos it had. Held at the recorder here: the first type's guide, which then comes.
    func testARefreshCancelledWhileATypesGuideIsOutAsksForNoLogosAndReportsTheTypeStored() async throws {
        let guide = try file("epg-sample.json")
        let held = Held()
        let transport = StubTransport { _, index in
            if index == 0 { await held.wait() }
            return HTTPResponse(statusCode: 200, body: guide)
        }
        addTeardownBlock { await held.letGo() }
        let client = RecorderClient(host: Stub.host, transport: transport, streamPort: 60151, busyRetryDelay: 0...0)
        let store = try GuideStore(path: ":memory:")
        let stored = Stored()

        let refresh = Task { await GuideRefresh.run(client: client, store: store, onStored: { stored.add($0) }) }
        try await whenHeld(held)
        refresh.cancel()
        await held.letGo()
        let outcome = await refresh.value

        XCTAssertTrue(outcome.cancelled, "the refresh did not say that its task was cancelled")
        XCTAssertNil(outcome.stopped)
        XCTAssertEqual(outcome.answered, ["td"])
        XCTAssertEqual(outcome.stored, 5)
        XCTAssertEqual(stored.types, ["td"], "the type whose guide was out was not reported as stored")
        expectEqual(await transport.requests.count, 1,
                    "the logos of the type that came, or a further type, were asked for once the task was cancelled")
        expectEqual(try await store.counts()["td"]?.programs, 4, "the type whose guide was out is not in the cache")
    }

    /// Two clients of one recorder, as the screens and the overnight run each have one, on one transport that
    /// holds the first request it is sent and answers every file as one the recorder has no channels for.
    private func twoClients() -> (first: RecorderClient, second: RecorderClient, transport: StubTransport, held: Held) {
        let held = Held()
        let transport = StubTransport { _, index in
            if index == 0 { await held.wait() }
            return HTTPResponse(statusCode: 416)
        }
        func client() -> RecorderClient {
            RecorderClient(host: Stub.host, transport: transport, streamPort: 60151, busyRetryDelay: 0...0)
        }
        return (client(), client(), transport, held)
    }

    /// Waits, a bounded while, for the request the two clients' transport holds to have come.
    private func whenHeld(_ held: Held) async throws {
        var turns = 0
        while await !held.isHolding, turns < 100_000 {
            turns += 1
            await Task.yield()
        }
        guard await held.isHolding else {
            XCTFail("the first refresh was meant to have its first file out")
            throw NothingHeld()
        }
    }

    /// One refresh at a time, whichever client asks: a client's own queue keeps apart only what is asked of
    /// that client. With the first refresh's first file out, a second is asked on another client for the
    /// types not answered for since yesterday, which is every type as it is asked. It waits its turn, and
    /// judges once the turn is its own: the first has had every type answered by then, and the second asks
    /// for nothing. Four files in all, where there would be eight, and never two requests at the recorder
    /// at once.
    ///
    /// What is behind, which a connect asks for, is the same judged against the recorder's last rebuild: by
    /// marks a day ahead and two days back, which no hour of the day changes.
    func testARefreshAskedWhileAnotherIsOutWaitsItsTurnAndFetchesOnlyWhatIsStillBehind() async throws {
        let (first, second, transport, held) = twoClients()
        let store = try temporaryStore()
        let yesterday = Date().addingTimeInterval(-86_400)
        expectEqual(await GuideRefresh.types(.notAnsweredSince(yesterday), by: store), GuideRefresh.broadcastingTypes)

        let out = Task { await GuideRefresh.run(client: first, store: store) }
        try await whenHeld(held)
        let begun = Stored()
        let behind = Task {
            begun.add("begun")
            return await GuideRefresh.run(asked: .notAnsweredSince(yesterday),
                                          onTurn: { .fetch(client: second, store: store, from: nil) })
        }
        for _ in 0..<100_000 where begun.types.isEmpty { await Task.yield() }
        XCTAssertEqual(begun.types, ["begun"], "the second refresh was meant to have been asked for")
        await held.letGo()
        let (one, other) = (await out.value, await behind.value)

        XCTAssertEqual(one.answered, GuideRefresh.broadcastingTypes)
        XCTAssertEqual(other.answered, [], "the second fetched what the first had fetched while it waited")
        XCTAssertNil(other.stopped)
        expectEqual(await transport.requests.count, 4, "each file was meant to be asked for once")
        expectEqual(await transport.maxConcurrent, 1, "two refreshes asked the recorder at the same time")

        let ahead = Date().addingTimeInterval(86_400), longAgo = Date().addingTimeInterval(-2 * 86_400)
        for type in GuideRefresh.broadcastingTypes {
            try await store.noteNoGuide(broadcasting: type, at: type == "cs" ? longAgo : ahead)
        }
        expectEqual(await GuideRefresh.types(.whatIsBehind, by: store), ["cs"])
        expectEqual(await GuideRefresh.types(.all, by: store), GuideRefresh.broadcastingTypes)
        expectEqual(await GuideRefresh.types(.only(["bs"]), by: store), ["bs"])
    }

    /// A refresh runs in the task that asked for it, also once it has waited its turn: that task being
    /// cancelled while it waits -- the overnight run's, its time up -- the wait is not cut short, and the look
    /// before the first type, which comes after the wait, ends it with no file asked for.
    func testARefreshCancelledWhileItWaitsItsTurnAsksForNoFile() async throws {
        let (first, second, transport, held) = twoClients()
        let store = try temporaryStore()

        let out = Task { await GuideRefresh.run(client: first, store: store) }
        try await whenHeld(held)
        let begun = Stored()
        let waiting = Task {
            begun.add("begun")
            return await GuideRefresh.run(client: second, store: store)
        }
        for _ in 0..<100_000 where begun.types.isEmpty { await Task.yield() }
        waiting.cancel()
        await held.letGo()
        let (one, cancelled) = (await out.value, await waiting.value)

        XCTAssertEqual(one.answered, GuideRefresh.broadcastingTypes, "the refresh that was out did not end as asked")
        XCTAssertTrue(cancelled.cancelled, "the refresh did not see that its task was cancelled while it waited")
        XCTAssertEqual(cancelled.answered, [])
        expectEqual(await transport.requests.count, 4, "a file was asked for by a refresh cancelled as it waited")
    }

    /// The overnight run looks at its task and at whose cache it is once the turn for its guide has come, as it
    /// did before the wait: the wait can be as long as a refresh of the screens' takes, and the screens can take
    /// another recorder up meanwhile. Here the turn is another refresh's, of the test's own, its first file
    /// held. A night is run beside it on a client and over a cache of its own: it asks who is there, for the
    /// USB slot and for the free space, the two refused, and its guide is next. Then the cache is made over to
    /// another recorder, as the screens make it over, and the file held is let go: the night asks for no file
    /// of the guide, and hands back that nothing was stored. So it is where the night's task is cancelled in
    /// place of the make-over, as when its time runs out.
    ///
    /// Nothing says that the night has come to its wait for the turn. It is given turns to come to it, a
    /// counted number, once it has asked for the free space; whichever comes first, the wait or what happens
    /// beside it, the night asks for no file.
    func testANightsGuideIsNotAskedForOnceItsTurnComesOverACacheMadeOverOrATaskCancelledMeanwhile() async throws {
        for row in ["the cache made over", "the task cancelled"] {
            let held = Held()
            let inFront = StubTransport { _, index in
                if index == 0 { await held.wait() }
                return HTTPResponse(statusCode: 416)
            }
            addTeardownBlock { await held.letGo() }
            let screens = RecorderClient(host: Stub.host, transport: inFront, streamPort: 60151, busyRetryDelay: 0...0)
            let elsewhere = try temporaryStore()
            let out = Task { await GuideRefresh.run(client: screens, store: elsewhere) }
            try await whenHeld(held)

            let description = try Vectors.descriptionXML(udn: described(1).udn)
            let recorder = StubTransport { request, _ in
                guard request.url.lastPathComponent == "description.xml" else { return HTTPResponse(statusCode: 500) }
                return HTTPResponse(statusCode: 200, body: Data(description.utf8))
            }
            let client = RecorderClient(host: Stub.host, transport: recorder, streamPort: 60151, busyRetryDelay: 0...0)
            let store = try temporaryStore()
            try await store.claim(for: described(1))
            let night = Task {
                await RecorderDriver.refreshWithNoScreen(client, store: store, sendPacket: { false }, found: { _ in })
            }
            func askedForTheFreeSpace() async -> Bool {
                await recorder.bodies.contains { $0.contains("X_HDLnkGetRecordDestinationInfo") }
            }
            var turns = 0
            while await !askedForTheFreeSpace(), turns < 100_000 {
                turns += 1
                await Task.yield()
            }
            guard await askedForTheFreeSpace() else {
                XCTFail("\(row): the night never asked for the free space")
                throw NothingHeld()
            }
            for _ in 0..<10_000 { await Task.yield() }
            let asked = await recorder.requests.count
            if row == "the cache made over" {
                expectEqual(try await store.claim(for: described(2)), .another, "the cache was meant to be made over")
            } else {
                night.cancel()
            }
            await held.letGo()
            let (fetched, stored) = (await out.value, await night.value)

            XCTAssertEqual(fetched.answered, GuideRefresh.broadcastingTypes, "\(row): the refresh in front did not end")
            XCTAssertFalse(stored, row)
            expectEqual(await recorder.requests.count, asked,
                        "\(row): the night asked for a file of the guide once its turn had come")
        }
    }
}

/// The types `onStored` was called for, from the main actor.
private final class Stored: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func add(_ broadcasting: String) {
        lock.lock()
        list.append(broadcasting)
        lock.unlock()
    }

    var types: [String] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}

/// Something a test holds one request at until it lets it go.
private actor Held {
    private var waiting: CheckedContinuation<Void, Never>?

    /// Whether something waits here now.
    var isHolding: Bool { waiting != nil }

    /// Waits here until `letGo`.
    func wait() async {
        await withCheckedContinuation { waiting = $0 }
    }

    func letGo() {
        waiting?.resume()
        waiting = nil
    }
}

/// Thrown to end a test whose request never came to be held, once the failure is recorded.
private struct NothingHeld: Error {}
