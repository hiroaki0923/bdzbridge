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

        let outcome = try await GuideRefresh.run(client: client, store: store, onStored: { stored.add($0) })

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

        let outcome = try await GuideRefresh.run(client: client, store: store, types: ["bs"])

        XCTAssertEqual(outcome.answered, ["bs"])
        let urls = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls.count, 2, "the guide and the logos of BS, and nothing of the others")
        XCTAssertTrue(urls.allSatisfy { $0.contains("_BS") }, "\(urls)")
    }

    /// Silence ends it at once: a recorder that has stopped answering will not answer for the next type, and
    /// each file asked of it would cost a long timeout. What came in before stays.
    func testSilenceStopsTheRefreshThere() async throws {
        let (client, transport) = try recorder(serving: ["td"]) { _ in
            throw RecorderError.transport("timed out")
        }
        let store = try GuideStore(path: ":memory:")

        do {
            _ = try await GuideRefresh.run(client: client, store: store)
            XCTFail("silence is thrown")
        } catch let error as RecorderError {
            XCTAssertTrue(error.unreachable)
        }
        let urls = await transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls.last.map { $0.hasSuffix(Codes.epgFiles["bs"]!) }, true, "nothing asked after BS")
        let counts = try await store.counts()
        XCTAssertEqual(counts["td"]?.programs, 4, "the type fetched before it stays")
    }

    /// Silence while fetching a type's logos stops it too, though the logos alone are only looks.
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

        await XCTAssertThrowsErrorAsync(try await GuideRefresh.run(client: client, store: store))
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 2, "the guide and its logos, and then nothing")
    }

    /// Cancelled, it stops before the next type rather than going through all four: the overnight run's time
    /// is up by then, and the task has been completed.
    func testACancelledRefreshStopsBeforeTheNextType() async throws {
        let (client, transport) = try recorder(serving: ["td", "bs", "cs", "bs4k"]) { _ in
            HTTPResponse(statusCode: 416)
        }
        let store = try GuideStore(path: ":memory:")

        let refresh = Task {
            try await GuideRefresh.run(client: client, store: store, onStored: { _ in
                // cancelled from inside, once the first type is in, so that nothing depends on timing
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let outcome = try await refresh.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.answered, ["td"])
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 2, "the first type's guide and logos")
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

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("no error was thrown", file: file, line: line)
    } catch {}
}
