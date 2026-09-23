import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// What a model under test keeps, made fresh for one test and thrown away after it: its settings in a
/// defaults suite of their own, its database in a folder of its own, and the network it takes itself to be on,
/// which a test changes to move the phone. Nothing the app itself keeps on this simulator is read or touched.
@MainActor
final class Bench {
    let defaults: UserDefaults
    let folder: URL
    /// What the model is told the network is. A different value is a different network.
    var network = "home"
    private let suite: String

    /// An address reserved for documentation (RFC 5737). The model never sends anything to it: its requests
    /// go to the transport a test hands it.
    static let host = "192.0.2.10"

    init() throws {
        suite = "BDBridgeTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A model as the app makes one at launch with a recorder saved, whose requests go to `recorder`. No MAC
    /// is saved, and nothing is put on the network by the model itself (`Surroundings.reachesTheLAN`).
    func model(recorder: any HTTPTransport) -> AppModel {
        defaults.set(Self.host, forKey: DefaultsKey.recorderHost)
        let folder = folder
        return AppModel(surroundings: Surroundings(
            defaults: defaults,
            folder: { folder },
            transport: { _ in recorder },
            networkSignature: { [unowned self] in network },
            reachesTheLAN: false,
            asksAboutNotifications: false))
    }

    /// The database a model made here opens for a real recorder.
    var guidePath: String { Storage.guidePath(demo: false, in: folder) }

    /// Puts the demo's invented guide where the model will look, as a guide fetched on an earlier day would
    /// be. Every broadcasting type counts as answered for, so a connect has nothing to fetch.
    func cacheAGuide() async throws {
        try await DemoData.seed(store: GuideStore(path: guidePath))
    }

    func throwAway() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A recorder that says nothing, as one does that has left the network, or that is at home while the phone
/// is not: every request fails the way silence does. `holding` keeps each request waiting until `letGo()`, for
/// a test that looks at the app while it is still waiting on the recorder.
actor SilentRecorder: HTTPTransport {
    private(set) var asked = 0
    private var holding: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(holding: Bool = false) {
        self.holding = holding
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        asked += 1
        if holding { await withCheckedContinuation { held.append($0) } }
        throw RecorderError.transport("The request timed out.")
    }

    func letGo() {
        holding = false
        for request in held { request.resume() }
        held = []
    }
}

/// Thrown to end a test that is waiting for something that is not coming, once the failure is recorded.
struct StillWaiting: Error {}

extension XCTestCase {
    /// Runs `work` and hands back what it returns, failing the test if it has not returned within `seconds`.
    /// What is tested here used to wait for ever, and a test of it has to fail rather than wait with it, so the
    /// work runs in a task of its own that the test can stop waiting for.
    @MainActor
    func within<T: Sendable>(_ seconds: TimeInterval, _ what: String,
                             _ work: @escaping @MainActor () async -> T) async throws -> T {
        let returned = expectation(description: what)
        let task = Task { @MainActor in
            let value = await work()
            returned.fulfill()
            return value
        }
        guard await XCTWaiter().fulfillment(of: [returned], timeout: seconds) == .completed else {
            XCTFail("\(what): still waiting after \(Int(seconds)) seconds")
            throw StillWaiting()
        }
        return await task.value
    }

    /// Waits for something the model does in a task of its own -- the first connect, above all -- to come
    /// about, failing the test if it has not within `seconds`.
    @MainActor
    func until(_ what: String, within seconds: TimeInterval = 10,
               _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail("\(what): not so after \(Int(seconds)) seconds")
                throw StillWaiting()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
