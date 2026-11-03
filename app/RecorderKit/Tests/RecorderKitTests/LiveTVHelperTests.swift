import XCTest
@testable import RecorderKit

/// Checks against the helper on a real television, sent by the client and the transport the app sends with,
/// and skipped unless `TV_HOST` names one on the LAN:
///
///     TV_HOST=192.0.2.20 swift test --filter LiveTVHelperTests/testWhoAnswers
///     TV_HOST=192.0.2.20 TV_HELPER_TOKEN=… swift test --filter LiveTVHelperTests/testReadingTheGuide
///
/// The first needs no registration and changes nothing. The second reads with a token the television handed
/// out already (registering needs a code read off the screen, which the app's settings do), and says how many
/// channels and programmes each type has, never what they are.
final class LiveTVHelperTests: XCTestCase {
    private func host() throws -> String {
        guard let host = ProcessInfo.processInfo.environment["TV_HOST"], !host.isEmpty else {
            throw XCTSkip("TV_HOST is not set")
        }
        return host
    }

    private func client(token: String? = nil) throws -> TVHelperClient {
        TVHelperClient(host: try host(), transport: URLSessionTransport.withoutCookies(),
                       tokens: MemoryTVHelperToken(token))
    }

    func testWhoAnswers() async throws {
        let identity = try await client().ping()
        print("helper: \(identity.app) api \(identity.api) version \(identity.version)")
        XCTAssertTrue(identity.isHelper)
    }

    func testReadingTheGuide() async throws {
        guard let token = ProcessInfo.processInfo.environment["TV_HELPER_TOKEN"], !token.isEmpty else {
            throw XCTSkip("TV_HELPER_TOKEN is not set")
        }
        let client = try client(token: token)
        let info = try await client.info()
        print("helper \(info.version), permission \(info.listingsPermission), tuner \(info.tunerInstalled), building \(info.building)")
        for (bt, state) in info.types.sorted(by: { $0.key < $1.key }) {
            print("  \(bt): \(state.channels) channels, \(state.programs) programmes, changed \(state.changedAt)")
        }
        let types = try await client.broadcastingTypes()
        print("types with a channel: \(types)")
        for bt in types {
            let started = Date()
            let services = try await client.guide(bt)
            let logos = try await client.logos(bt)
            let programs = services?.reduce(0) { $0 + $1.programs.count } ?? 0
            let references = services?.reduce(0) { $0 + $1.programs.filter(\.isReference).count } ?? 0
            print("  \(bt): \(services?.count ?? 0) services, \(programs) programmes (\(references) references), "
                  + "\(logos?.count ?? 0) logos, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            XCTAssertNotNil(services)
        }
    }
}
