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

    /// Another address reserved for documentation, for a test that chooses another recorder.
    static let otherHost = "192.0.2.11"

    /// A model as the app makes one at launch with a recorder saved, whose requests go to `recorder`. No MAC
    /// is saved, and nothing is put on the network by the model itself (`Surroundings.reachesTheLAN`).
    func model(recorder: any HTTPTransport) -> AppModel {
        model { _ in recorder }
    }

    /// The same on a network where each address has a device of its own: what is sent to an address goes to
    /// the recorder named for it here, and at any other address nothing answers. The address saved is `host`
    /// unless told otherwise.
    func model(recorders: [String: any HTTPTransport], saved: String = Bench.host) -> AppModel {
        let nobody = SilentRecorder()
        return model(saved: saved) { recorders[$0] ?? nobody }
    }

    /// A model as the app makes one at its first launch: no recorder saved, and nothing answering anywhere.
    func modelWithNoRecorder() -> AppModel {
        let nobody = SilentRecorder()
        return model(saved: nil) { _ in nobody }
    }

    private func model(saved: String? = Bench.host,
                       transport: @escaping (String) -> any HTTPTransport) -> AppModel {
        if let saved {
            defaults.set(saved, forKey: DefaultsKey.recorderHost)
        } else {
            defaults.removeObject(forKey: DefaultsKey.recorderHost)
        }
        let folder = folder
        return AppModel(surroundings: Surroundings(
            defaults: defaults,
            folder: { folder },
            transport: transport,
            // Weak: the looks after a network report can outlast the test that made them.
            networkSignature: { [weak self] in self?.network ?? "" },
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

/// The demo's recorder while the phone is at home, and silence while it is not -- which is how a recorder that
/// is up looks from a phone that has left the Wi-Fi. It keeps its MAC to itself, so the model has nothing to
/// wake and gives up at once instead of spending the half minute of waking a real app would. `holding` keeps
/// what was sent while away waiting until `letGo()`, and then it fails however the phone is by then: a request
/// that went out while the Wi-Fi was gone is lost even if the Wi-Fi comes back before it times out. `refusing`
/// names calls it turns down while at home, as `PickyRecorder` does.
actor RecorderAtHome: HTTPTransport {
    private let recorder = DemoRecorder()
    private let refusing: Set<String>
    private var reachable = true
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var asked = 0

    init(refusing: Set<String> = []) {
        self.refusing = refusing
    }

    func setReachable(_ value: Bool, holding: Bool = false) {
        reachable = value
        self.holding = holding
    }

    func letGo() {
        holding = false
        for request in held { request.resume() }
        held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        asked += 1
        guard reachable else {
            if holding { await withCheckedContinuation { held.append($0) } }
            throw RecorderError.transport("The request timed out.")
        }
        if let action = request.headers["SOAPACTION"],
           action.contains("#X_GetPrivateIp") || refusing.contains(where: { action.contains("#\($0)") }) {
            return HTTPResponse(statusCode: 500)
        }
        return try await recorder.send(request)
    }
}

/// A recorder that is there and busy with somebody else: every request is answered 503, as a BDZ answers one
/// that arrives while it is serving another. An answer, so not silence.
actor BusyRecorder: HTTPTransport {
    private(set) var asked = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        asked += 1
        return HTTPResponse(statusCode: 503)
    }
}

/// Something at the address that is not a recorder -- a television, a router's own page: it answers, and
/// every answer is a 404. An answer, so not silence, and nothing that describes a recorder.
actor NotARecorder: HTTPTransport {
    private(set) var asked = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        asked += 1
        return HTTPResponse(statusCode: 404)
    }
}

/// A recorder that says which it is: the demo's answers under a UDN of its own, with the same recordings,
/// reservations and keyword conditions under the same numbers -- which is how two recorders look to the app,
/// each numbering its own from the same start. It keeps its MAC to itself, as `RecorderAtHome` does, and
/// counts what it is asked, by SOAP action or by the file's name.
///
/// `become` has it answer as another recorder from then on: the address the first one had, handed to a second;
/// `stopSayingWhich` has it go on as itself with no UDN in its description.
/// `hold` keeps every request waiting until `letGo()` -- or only the requests of one kind -- for a test that
/// looks at the app in between, and `goQuiet` has it say nothing to a few requests, as a recorder that has
/// left the network does: the next ones, or the ones after it has answered so many. A request held and then
/// let go is one of them.
actor NamedRecorder: HTTPTransport {
    /// Sony's OUI and the rest zeroed, as everywhere in this repository, with a last digit of its own.
    static func udn(_ last: Int) -> String { "uuid:00000000-0000-0000-0000-f84e1700000\(last)" }

    private var recorder = DemoRecorder()
    private var udn: String
    private var quiet = 0
    private var answersBeforeQuiet = 0
    private var holding = false
    private var holdingOnly: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var asked: [String: Int] = [:]

    init(_ last: Int) {
        udn = Self.udn(last)
    }

    /// One that says it is a recorder and not which: its description carries no UDN.
    static func nameless() -> NamedRecorder {
        NamedRecorder(udn: "")
    }

    private init(udn: String) {
        self.udn = udn
    }

    func become(_ last: Int) {
        udn = Self.udn(last)
        recorder = DemoRecorder()
    }

    /// The same recorder, no longer saying which it is.
    func stopSayingWhich() {
        udn = ""
    }

    func hold(only what: String? = nil) {
        holding = true
        holdingOnly = what
    }

    func letGo() {
        holding = false
        holdingOnly = nil
        for request in held { request.resume() }
        held = []
    }

    func goQuiet(for requests: Int, after answering: Int = 0) {
        quiet = requests
        answersBeforeQuiet = answering
    }

    func asked(_ what: String) -> Int { asked[what] ?? 0 }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let action = request.headers["SOAPACTION"].flatMap { $0.split(separator: "#").last }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let what = action ?? request.url.lastPathComponent
        asked[what, default: 0] += 1
        if holding, holdingOnly == nil || holdingOnly == what { await withCheckedContinuation { held.append($0) } }
        if quiet > 0 {
            if answersBeforeQuiet > 0 {
                answersBeforeQuiet -= 1
            } else {
                quiet -= 1
                throw RecorderError.transport("The request timed out.")
            }
        }
        if action == "X_GetPrivateIp" { return HTTPResponse(statusCode: 500) }
        let response = try await recorder.send(request)
        guard request.url.path == "/description.xml" else { return response }
        let described = response.text.replacingOccurrences(of: "uuid:00000000-0000-0000-0000-000000000000", with: udn)
        return HTTPResponse(statusCode: 200, body: Data(described.utf8))
    }
}

/// A recorder that is busy with somebody else when it is asked who it is -- 503 to its description -- and
/// answers everything else: one that is there, and has not said which it is. It says so once `comeFree()` has
/// been called. It counts the reservations it is asked to make, and keeps its MAC to itself, as
/// `RecorderAtHome` does.
actor RecorderBusyAtTheDoor: HTTPTransport {
    private let recorder = DemoRecorder()
    private var busy = true
    private(set) var made = 0

    func comeFree() {
        busy = false
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if busy, request.url.path == "/description.xml" { return HTTPResponse(statusCode: 503) }
        let action = request.headers["SOAPACTION"] ?? ""
        if action.contains("#X_GetPrivateIp") { return HTTPResponse(statusCode: 500) }
        if action.contains("#X_CreateRecordSchedule") { made += 1 }
        return try await recorder.send(request)
    }
}

/// The demo's recorder with one broadcast on its disk twice: its list gives two of its recordings one title,
/// and what it says each is about is the same, as it is for every recording of the demo's. A scan for
/// duplicates therefore finds one set and ticks a copy. It keeps its MAC to itself, as `RecorderAtHome` does,
/// so that a model which has met it wakes nothing afterwards.
actor RecorderWithACopy: HTTPTransport {
    private let recorder = DemoRecorder()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let action = request.headers["SOAPACTION"] ?? ""
        if action.contains("#X_GetPrivateIp") { return HTTPResponse(statusCode: 500) }
        let response = try await recorder.send(request)
        guard action.contains("#X_GetTitleList") else { return response }
        let twice = response.text.replacingOccurrences(of: "第３話", with: "第４話")
        return HTTPResponse(statusCode: response.statusCode, body: Data(twice.utf8))
    }
}

/// The demo's recorder, except that it turns down the SOAP actions named in `refusing` with a 500 and nothing
/// in it: how another model of the series might answer a call the app only makes to show something.
actor PickyRecorder: HTTPTransport {
    private let recorder = DemoRecorder()
    private let refusing: Set<String>

    init(refusing: Set<String>) {
        self.refusing = refusing
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if let action = request.headers["SOAPACTION"], refusing.contains(where: { action.contains("#\($0)") }) {
            return HTTPResponse(statusCode: 500)
        }
        return try await recorder.send(request)
    }
}

/// The demo's recorder, away or at home as the test says, which can be made to keep the read that follows its
/// description waiting until `letGo()`: a recorder that has said who it is and nothing else yet, held there
/// for a test to look at the app in between. It keeps its MAC to itself, as `RecorderAtHome` does, so that a
/// model which has met it wakes nothing afterwards.
actor RecorderPartWayThroughAnAttach: HTTPTransport {
    private let recorder = DemoRecorder()
    private var reachable = true
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func setReachable(_ value: Bool) {
        reachable = value
    }

    func holdAfterTheDescription() {
        holding = true
    }

    func letGo() {
        holding = false
        for request in held { request.resume() }
        held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard reachable else { throw RecorderError.transport("The request timed out.") }
        let action = request.headers["SOAPACTION"] ?? ""
        if action.contains("#X_GetPrivateIp") { return HTTPResponse(statusCode: 500) }
        if holding, action.contains("#X_GetFirmwareVersion") {
            await withCheckedContinuation { held.append($0) }
        }
        return try await recorder.send(request)
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
