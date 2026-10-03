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
    /// How long the model's writes to its cache wait for another connection: the app's five seconds, unless a
    /// test that holds the lock on purpose shortens it before making the model.
    var storeBusyTimeoutMilliseconds: Int32 = 5000
    /// How many clients a model made here has made, whatever the address: one for each attempt at a recorder.
    private(set) var clientsMade = 0
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

    /// Another address reserved for documentation, for the television.
    static let tvHost = "192.0.2.30"

    /// A model with the recorder saved as `model(recorder:)` makes it, and a television at `tvHost` that answers
    /// through `television`: saved as the app's when `saved`, with its registration in `credentials`.
    func model(recorder: any HTTPTransport, television: any HTTPTransport, credentials: any TVCredentialStore,
               saved: Bool = true) -> AppModel {
        if saved {
            defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        } else {
            defaults.removeObject(forKey: DefaultsKey.tvHost)
        }
        return model(transport: { _ in recorder }, tvTransport: { $0 == Bench.tvHost ? television : NoTelevision() },
                     tvCredentials: credentials)
    }

    /// A model as the app makes one in a home with a television and no recorder: no recorder saved and nothing
    /// answering as one anywhere, and the television saved at `tvHost` with its registration in `credentials`.
    func modelWithNoRecorder(television: any HTTPTransport, credentials: any TVCredentialStore) -> AppModel {
        defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        let nobody = SilentRecorder()
        return model(saved: nil, transport: { _ in nobody },
                     tvTransport: { $0 == Bench.tvHost ? television : NoTelevision() }, tvCredentials: credentials)
    }

    private func model(saved: String? = Bench.host,
                       transport: @escaping (String) -> any HTTPTransport,
                       tvTransport: @escaping (String) -> any HTTPTransport = { _ in NoTelevision() },
                       tvCredentials: any TVCredentialStore = MemoryTVCredentials()) -> AppModel {
        if let saved {
            defaults.set(saved, forKey: DefaultsKey.recorderHost)
        } else {
            defaults.removeObject(forKey: DefaultsKey.recorderHost)
        }
        let folder = folder
        return AppModel(surroundings: Surroundings(
            defaults: defaults,
            folder: { folder },
            transport: { [weak self] host in
                self?.clientsMade += 1
                return transport(host)
            },
            // Weak: the looks after a network report can outlast the test that made them.
            networkSignature: { [weak self] in self?.network ?? "" },
            reachesTheLAN: false,
            asksAboutNotifications: false,
            busyRetryDelay: 0...0,
            storeBusyTimeoutMilliseconds: storeBusyTimeoutMilliseconds,
            tvTransport: tvTransport,
            tvCredentials: tvCredentials))
    }

    /// The database a model made here opens for a real recorder.
    var guidePath: String { Storage.guidePath(demo: false, in: folder) }

    /// Puts the demo's invented guide where the model will look, as a guide fetched on an earlier day would
    /// be. Every broadcasting type counts as answered for, so a connect has nothing to fetch.
    func cacheAGuide() async throws {
        try await DemoData.seed(store: GuideStore(path: guidePath))
    }

    /// Saves a MAC as the app keeps one for waking the recorder, with the address it was read at. A model made
    /// here sends nothing to it (`model(recorder:)`).
    func keep(mac: String, readAt host: String? = Bench.host) {
        defaults.set(mac, forKey: DefaultsKey.recorderMac)
        defaults.set(host, forKey: DefaultsKey.recorderMacHost)
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
/// names SOAP actions it turns down with a 500 and nothing in it while at home: how another model of the series
/// might answer a call the app only makes to show something.
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

/// Something at the address that is not a recorder -- a television, a router's own page: it answers, and
/// every answer is a 404. An answer, so not silence, and nothing that describes a recorder.
actor NotARecorder: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 404)
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
/// left the network does: the next ones, or the ones after it has answered so many, or the next of one kind.
/// A request held and then let go is one of them. `busyAtTheDoor` has it busy with somebody else whenever it is
/// asked who it is -- a 503 to its description, as a BDZ answers a request that arrives while it is serving
/// another -- and answering everything else: there, and not saying which it is, until `comeFree()`.
actor NamedRecorder: HTTPTransport {
    /// Sony's OUI and the rest zeroed, as everywhere in this repository, with a last digit of its own.
    static func udn(_ last: Int) -> String { "uuid:00000000-0000-0000-0000-f84e1700000\(last)" }

    private var recorder = DemoRecorder()
    private var udn: String
    private var quiet = 0
    private var answersBeforeQuiet = 0
    private var quietOn: String?
    private var holding = false
    private var holdingOnly: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    private var busy = false
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

    /// Silent to the next request of one kind -- a SOAP action, or a file by its name -- whatever comes before it.
    func goQuiet(on what: String) {
        quietOn = what
    }

    func busyAtTheDoor() {
        busy = true
    }

    func comeFree() {
        busy = false
    }

    /// How often it has been asked for `what` -- a SOAP action, or a file by its name: since it was made, or
    /// since `before`, which is its `asked` at an earlier moment.
    func asked(_ what: String, since before: [String: Int] = [:]) -> Int {
        (asked[what] ?? 0) - (before[what] ?? 0)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let action = request.headers["SOAPACTION"].flatMap { $0.split(separator: "#").last }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let what = action ?? request.url.lastPathComponent
        asked[what, default: 0] += 1
        if holding, holdingOnly == nil || holdingOnly == what { await withCheckedContinuation { held.append($0) } }
        if quietOn == what {
            quietOn = nil
            throw RecorderError.transport("The request timed out.")
        }
        if quiet > 0 {
            if answersBeforeQuiet > 0 {
                answersBeforeQuiet -= 1
            } else {
                quiet -= 1
                throw RecorderError.transport("The request timed out.")
            }
        }
        if busy, request.url.path == "/description.xml" { return HTTPResponse(statusCode: 503) }
        if action == "X_GetPrivateIp" { return HTTPResponse(statusCode: 500) }
        let response = try await recorder.send(request)
        guard request.url.path == "/description.xml" else { return response }
        let described = response.text.replacingOccurrences(of: "uuid:00000000-0000-0000-0000-000000000000", with: udn)
        return HTTPResponse(statusCode: 200, body: Data(described.utf8))
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

/// The invented television with its answers held until `letGo()`. Unless told otherwise it holds every answer
/// from the first: a television part way through an attach. Made `holding: false` it answers, until `hold` has
/// it keep its requests waiting -- or only those of one method -- for a test that looks at the app while a read
/// or a delete is out. A request held is not among the television's `calls` until it is let go.
actor HeldTelevision: HTTPTransport {
    private let television: DemoTV
    private var holding: Bool
    private var holdingOnly: String?
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ television: DemoTV, holding: Bool = true) {
        self.television = television
        self.holding = holding
    }

    var isHolding: Bool { !held.isEmpty }

    func hold(only method: String? = nil) {
        holding = true
        holdingOnly = method
    }

    func letGo() {
        holding = false
        holdingOnly = nil
        for request in held { request.resume() }
        held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if holding, holdingOnly == nil || holdingOnly == Self.method(of: request) {
            await withCheckedContinuation { held.append($0) }
        }
        return try await television.send(request)
    }

    /// The method a request asks for, as the television's API names it in the body.
    private static func method(of request: HTTPRequest) -> String? {
        let body = try? JSONSerialization.jsonObject(with: request.body ?? Data())
        return (body as? [String: Any])?["method"] as? String
    }
}

/// Thrown to end a test that is waiting for something that is not coming, once the failure is recorded.
struct StillWaiting: Error {}

extension XCTestCase {
    /// A bench for this test, thrown away when the test is over.
    @MainActor
    func aBench() throws -> Bench {
        let bench = try Bench()
        addTeardownBlock { await bench.throwAway() }
        return bench
    }

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

    /// Waits for what the model has under way to be over, whichever way it went: a connect made in a task of
    /// its own, and the reads that follow it.
    @MainActor
    func untilIdle(_ model: AppModel, _ what: String = "the connect never finished",
                   within seconds: TimeInterval = 10) async throws {
        try await until(what, within: seconds) { !isConnecting(model) && model.busy == nil }
    }

    /// Waits for a connect that met silence to have given up.
    @MainActor
    func untilGivenUp(_ model: AppModel, _ what: String = "the first connect never gave up",
                      within seconds: TimeInterval = 10) async throws {
        try await until(what, within: seconds) { model.gaveUp && !isConnecting(model) }
    }

    /// Waits for the model to be connected with nothing under way. The first connect of a launch above all,
    /// which has the cache to open first, and gets longer for it.
    @MainActor
    func untilConnected(_ model: AppModel, _ what: String = "the first connect never finished",
                        within seconds: TimeInterval = 20) async throws {
        try await until(what, within: seconds) { model.connected && !isConnecting(model) && model.busy == nil }
    }

    /// Waits for the connect under way to end, whichever way it went.
    @MainActor
    func untilTheConnectEnds(_ model: AppModel, _ what: String = "the connect never ended",
                             within seconds: TimeInterval = 10) async throws {
        try await until(what, within: seconds) { !isConnecting(model) }
    }

    /// Waits for the television to be connected and its connect to be over, which is once its reservations
    /// have been read: that read is inside the connect.
    @MainActor
    func untilTheTelevisionIsConnected(_ model: AppModel, _ what: String = "the television was never connected",
                                       within seconds: TimeInterval = 10) async throws {
        try await until(what, within: seconds) {
            model.tv?.session.connected == true && model.tv?.session.connecting == false
        }
    }

    /// Credentials the television knows, with a cookie it gave out `daysAgo`.
    @MainActor
    func registered(with television: DemoTV, daysAgo: Double = 1) async -> MemoryTVCredentials {
        await television.knows("BDBridge:test", cookie: "kept")
        return MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                 cookieReceived: Date().addingTimeInterval(-daysAgo * 86_400),
                                                 cookieMaxAge: 1_209_600))
    }

    /// A programme from the cached guide that starts an hour or more from now: the first, or the one after
    /// as many as `skipping`.
    @MainActor
    func aProgramme(_ model: AppModel, skipping: Int = 0) async throws -> GuideProgramRow {
        let later = Date().addingTimeInterval(3600)
        let found = await model.search("サンプル").hits.filter { $0.program.start > later }.dropFirst(skipping).first
        return try XCTUnwrap(found?.program, "the cached guide had nothing more an hour or more ahead")
    }
}

// MARK: - what the tests do to the connection
//
// By what each does rather than by the model's name for it. Where the connection lives can change; the tests
// go on calling these, and only the bodies here change with it.

/// Makes sure of the recorder as the check before an operation does, however short a time it has been since it
/// last answered. Whether it is there to ask.
@MainActor
func makeSure(_ model: AppModel) async -> Bool {
    await model.wakeIfDozing(evenIfRecent: true)
}

/// One look at the network, of the kind the app takes after a change is reported. Whether it led to an attempt
/// at the recorder, or to making sure of it.
@MainActor
@discardableResult
func lookAtTheNetwork(_ model: AppModel) async -> Bool {
    await model.networkChangedWhileOpen()
}

/// Whether the check before an operation is out.
@MainActor
func isMakingSure(_ model: AppModel) -> Bool {
    model.wakeCheck != nil
}

/// Whether a connect is under way.
@MainActor
func isConnecting(_ model: AppModel) -> Bool {
    model.connecting
}

/// `XCTAssertEqual` for a value that has to be awaited, and the three beside it for theirs. XCTest's own take
/// their arguments as autoclosures, which cannot await, so each such check took a line to read the value and
/// another to compare it. An ordinary argument is read before the call, and a failure is still reported at
/// the line that asked.
func expectEqual<T: Equatable>(_ value: T, _ expected: T, _ message: @autoclosure () -> String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(value, expected, message(), file: file, line: line)
}

func expectTrue(_ value: Bool, _ message: @autoclosure () -> String = "",
                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, message(), file: file, line: line)
}

func expectFalse(_ value: Bool, _ message: @autoclosure () -> String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value, message(), file: file, line: line)
}

func expectNil<T>(_ value: T?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, message(), file: file, line: line)
}
