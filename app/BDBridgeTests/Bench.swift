import Foundation
import RecorderKit
import SQLite3
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
    /// How long after an attach found the USB slot answering none, while a disk was known, a model made here reads
    /// it again: the app's minute, unless a test that waits for that read shortens it before making the model.
    var slotReadAgainAfter = RecorderDriver.slotReadAgainAfter
    /// How long a model made here waits for the USB slot before something that names it is sent while the slot has
    /// not answered the disk known: the app's two seconds for ten, unless a test that waits for it shortens it
    /// first.
    var slotSettling = SlotSettling.afterAWaking
    /// How many clients a model made here has made, whatever the address: one for each attempt at a recorder.
    private(set) var clientsMade = 0
    /// What the searches of the models made here wrote for the log, in order: kept here in place of the
    /// system's log, for a test to read.
    private(set) var scanLog: [String] = []
    /// The Wi-Fi the phone is on, once a test has put it on one (`joinWiFi`) and until it takes it off
    /// (`leaveWiFi`), and who answers a search: the subnet of the Wi-Fi the phone was last put on.
    private var wifi: LocalNetwork.Interface?
    private var subnet: Subnet?
    /// How many times a model made here read the interfaces a search looks round, and made the transport a
    /// search sends through: what a search in the demo is to read and make none of.
    private(set) var interfacesRead = 0
    private(set) var scanTransportsMade = 0
    /// The addresses a model made here took the surroundings' way to a television for, in order: what nothing in
    /// the demo is to take, the demo's own address least of all.
    private(set) var televisionTransportsMade: [String] = []
    /// Each pause a search of a model made here asked for between one single request and the next, by how
    /// long it asked for, in order and from the moment it asked.
    private(set) var scanPauses: [Duration] = []
    /// Whether those pauses are held (`holdTheSingleRequests`), how many more may end, and the searches
    /// waiting in one.
    private var pausesHeld = false
    private var pausesToLetGo = 0
    private var pausing: [CheckedContinuation<Void, Never>] = []
    /// What the one look at the local network permission says at an address given for a television
    /// (`Surroundings.localNetworkAccess`): allowed, unless a test has the system keep the app off.
    var permissionLookSays: LocalNetwork.Access? = .allowed
    /// The addresses such looks of the models made here were aimed at, and those the waits for the permission
    /// that followed were aimed at, in order.
    private(set) var permissionLooks: [String] = []
    private(set) var permissionWaits: [String] = []
    /// The waits still under way. Each lasts until the test ends it (`permissionComes`), whether or not its task
    /// was cancelled meanwhile: a real one ends when its task is, and one of these stands for a wait the
    /// permission ended in that same moment.
    private var waitingForPermission: [CheckedContinuation<LocalNetwork.Access, Never>] = []
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
    /// answering as one anywhere, and the television at `tvHost` answering through `television`, saved with its
    /// registration in `credentials` unless `saved` is false, as at a first launch.
    func modelWithNoRecorder(television: any HTTPTransport, credentials: any TVCredentialStore,
                             saved: Bool = true) -> AppModel {
        if saved {
            defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        } else {
            defaults.removeObject(forKey: DefaultsKey.tvHost)
        }
        let nobody = SilentRecorder()
        return model(saved: nil, transport: { _ in nobody },
                     tvTransport: { $0 == Bench.tvHost ? television : NoTelevision() }, tvCredentials: credentials)
    }

    /// The phone's own address on a Wi-Fi a test puts it on, reserved for documentation like the others.
    static let phone = "192.0.2.20"

    /// The phone's address on another Wi-Fi, for a test that moves it there: from another range reserved for
    /// documentation, so on another subnet.
    static let phoneElsewhere = "198.51.100.20"

    /// Puts the phone on a Wi-Fi for a search for a recorder and a television to look round, before or after
    /// the model is made: a /24 as a home's is, so 253 addresses around `phone`, with `recorders` at theirs on
    /// the recorder's port, `televisions` at theirs on port 80, and nobody at the rest, who are silent but for
    /// those the test has refuse (`refusing`). The search's requests go to the subnet handed back and nowhere
    /// else. Until a test calls this the phone is on no Wi-Fi, and a search by a model made here says so and
    /// asks nobody.
    @discardableResult
    func joinWiFi(with recorders: [String: any HTTPTransport] = [:],
                  televisions: [String: any HTTPTransport] = [:], refusing: Set<String> = [],
                  as phone: String = Bench.phone) -> Subnet {
        let subnet = Subnet(recorders, televisions: televisions, refusing: refusing)
        wifi = LocalNetwork.Interface(name: "en0", address: phone, netmask: "255.255.255.0", broadcasts: true)
        self.subnet = subnet
        return subnet
    }

    /// Takes the phone off its Wi-Fi: a search finds no interface to look round. What one sent all the same
    /// would still go to the subnet of the Wi-Fi the phone was on, and be counted there.
    func leaveWiFi() {
        wifi = nil
    }

    /// Holds a search at each pause it makes before a single request, which is where one is after a look that
    /// was turned away: none is made until the test lets it (`letSingleRequestsGo`). Unless a test calls this a
    /// pause takes no time.
    func holdTheSingleRequests() {
        pausesHeld = true
    }

    /// Lets `count` pauses end, those waiting now or the next to be asked for: a search makes one single
    /// request after each.
    func letSingleRequestsGo(_ count: Int = 1) {
        pausesToLetGo += count
        while pausesToLetGo > 0, !pausing.isEmpty {
            pausesToLetGo -= 1
            pausing.removeFirst().resume()
        }
    }

    /// Holds no pause any more, and ends those waiting.
    func letEverySingleRequestGo() {
        pausesHeld = false
        pausesToLetGo = 0
        for pause in pausing { pause.resume() }
        pausing = []
    }

    /// Whether a model made here is waiting for the local network permission at an address given for a
    /// television.
    var isWaitingForPermission: Bool { !waitingForPermission.isEmpty }

    /// Ends every wait for the permission under way with `access`: the reader allowed the local network, unless
    /// the test says the wait came to something else.
    func permissionComes(_ access: LocalNetwork.Access = .allowed) {
        for wait in waitingForPermission { wait.resume(returning: access) }
        waitingForPermission = []
    }

    private func lookAtThePermission(at host: String) -> LocalNetwork.Access? {
        permissionLooks.append(host)
        return permissionLookSays
    }

    private func waitForThePermission(at host: String) async -> LocalNetwork.Access {
        permissionWaits.append(host)
        return await withCheckedContinuation { waitingForPermission.append($0) }
    }

    /// The pause a search of a model made here makes before a single request. It does not end for the
    /// search being stopped: a test ends it, and looks at what the search did then.
    private func pause(for time: Duration) async {
        scanPauses.append(time)
        guard pausesHeld else { return }
        if pausesToLetGo > 0 {
            pausesToLetGo -= 1
        } else {
            await withCheckedContinuation { pausing.append($0) }
        }
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
            slotReadAgainAfter: slotReadAgainAfter,
            slotSettling: slotSettling,
            tvTransport: { [weak self] host in
                self?.televisionTransportsMade.append(host)
                return tvTransport(host)
            },
            tvCredentials: tvCredentials,
            localNetworkAccess: { [weak self] host in
                guard let self else { return .allowed }
                return await self.lookAtThePermission(at: host)
            },
            waitForLocalNetwork: { [weak self] in await self?.waitForThePermission(at: $0) ?? .unavailable },
            lanInterfaces: { [weak self] in
                self?.interfacesRead += 1
                return (self?.wifi).map { [$0] } ?? []
            },
            scanTransport: { [weak self] in
                self?.scanTransportsMade += 1
                return self?.subnet ?? Subnet()
            },
            scanPause: { [weak self] in await self?.pause(for: $0) },
            scanLog: { [weak self] in self?.scanLog.append($0) }))
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
        // A search still held at a pause would wait for good, and so would a wait for the permission.
        letEverySingleRequestGo()
        permissionComes(.unavailable)
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

/// The subnet of a Wi-Fi a test has put the phone on (`Bench.joinWiFi`), as a search for a recorder and a
/// television meets it: what is sent to an address goes, by its port, to the recorder the test put there (the
/// recorder's port) or to the television (port 80), and anywhere else nobody answers -- a recorder's address
/// at port 80 among them. A request to such an address and port fails as the system has one fail, in the text
/// a search's tally reads the system's code out of (`ScanTally`): timed out where the address is silent -- at
/// once, where a real one is silent for as long as the request waits -- or refused, at either port of the
/// addresses the subnet was made to have refuse.
/// `turnEverythingAway` is the phone letting nothing out, as it may behind the system's question about the
/// local network: every request, a recorder's address included, fails at once for want of a network to send
/// on, until `letEverythingOut` -- every one but those to the address the test names as let through unasked,
/// as the system lets through a DNS server or a proxy on the local network (TN3179), which come back as they
/// would with nothing turned away. `hold` keeps each request waiting until `letGo()` -- from now, or once so
/// many more have gone by, all but those to one address if the test names one -- and it then comes back
/// however the subnet is by then. `asked` counts the
/// requests, `askedOf` has the addresses they were for, in order, and `askedAt` the addresses with their
/// ports and methods.
actor Subnet: HTTPTransport {
    private let recorders: [String: any HTTPTransport]
    private let televisions: [String: any HTTPTransport]
    private let refusing: Set<String>
    private(set) var asked = 0
    private(set) var askedOf: [String] = []
    private(set) var askedAt: [(host: String, port: Int, method: String)] = []
    private var turnsAway = false
    private var letThrough: String?
    /// How many requests had been asked when the holding began: each one after them is held, but those to the
    /// address named as not held.
    private var holdingAfter: Int?
    private var notHeld: String?
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ recorders: [String: any HTTPTransport] = [:], televisions: [String: any HTTPTransport] = [:],
         refusing: Set<String> = []) {
        self.recorders = recorders
        self.televisions = televisions
        self.refusing = refusing
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        asked += 1
        let host = request.url.host() ?? ""
        let port = request.url.port ?? 80
        askedOf.append(host)
        askedAt.append((host, port, request.method))
        if let holdingAfter, asked > holdingAfter, host != notHeld {
            await withCheckedContinuation { held.append($0) }
        }
        guard !turnsAway || host == letThrough else { throw Self.failure(-1009) }
        let device = port == Upnp.port ? recorders[host] : port == 80 ? televisions[host] : nil
        guard let device else { throw Self.failure(refusing.contains(host) ? -1004 : -1001) }
        return try await device.send(request)
    }

    func turnEverythingAway(but letThrough: String? = nil) {
        turnsAway = true
        self.letThrough = letThrough
    }

    func letEverythingOut() {
        turnsAway = false
    }

    func hold(after more: Int = 0, but host: String? = nil) {
        holdingAfter = asked + more
        notHeld = host
    }

    func letGo() {
        holdingAfter = nil
        notHeld = nil
        for request in held { request.resume() }
        held = []
    }

    /// A failure in transit as `URLSessionTransport` keeps one: the system's text for it, which names the
    /// domain and the code first. No address follows here, where the system's own names the one asked.
    private static func failure(_ code: Int) -> RecorderError {
        .transport("Error Domain=NSURLErrorDomain Code=\(code) \"(null)\"")
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
/// `hold` keeps every request waiting until `letGo()` -- or only the requests of one kind, or with `holdTheNext`
/// only the next of one kind -- for a test that looks at the app in between; `letGo(only:)` lets those of one
/// kind go and keeps the rest. `goQuiet` has it say nothing to a few requests, as a recorder that has left the
/// network does: the next ones, or the ones after it has answered so many, or the next of one kind. A request
/// held and then let go is one of them. `busyAtTheDoor` has it busy with somebody else whenever it is asked who
/// it is -- a 503 to its description, as a BDZ answers a request that arrives while it is serving another -- and
/// answering everything else: there, and not saying which it is, until `comeFree()`.
///
/// `answer` has it say something of the test's own in place of the demo's answer to the next requests of one
/// kind -- a fault with a code, a bare status, a `Result` -- `beBusy` is that for one whole call that fails as
/// busy, and `beAMomentBehind` has the list after its next delete or change be the one from before it. `heard` is
/// everything it was asked, in the order it arrived, and `elements(of:)` what the last of one kind carried.
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
    private var holdingNext: String?
    /// The requests held, each with its kind, in the order they arrived.
    private var held: [(what: String, request: CheckedContinuation<Void, Never>)] = []
    private var busy = false
    private(set) var asked: [String: Int] = [:]
    /// Everything it was asked, in the order it arrived, by SOAP action or by the file's name.
    private(set) var heard: [String] = []
    /// What it was told to answer, by kind (`answer`).
    private var told: [String: (answer: Answer, times: Int, after: Int)] = [:]
    /// Whether the list after its next delete or change of a reservation is to be an old one (`beAMomentBehind`), the
    /// last list it gave, and the old one it is about to give.
    private var behind = false
    private var lastList: HTTPResponse?
    private var staleList: HTTPResponse?
    /// The `Elements` argument of the last request of each kind that carried one (`elements(of:)`).
    private var lastElements: [String: String] = [:]

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
        // The list it was behind with was the other recorder's. What a test told it with `answer` stays.
        (behind, lastList, staleList) = (false, nil, nil)
    }

    /// The same recorder, no longer saying which it is.
    func stopSayingWhich() {
        udn = ""
    }

    func hold(only what: String? = nil) {
        holding = true
        holdingOnly = what
    }

    /// Holds the next request of one kind -- a SOAP action, or a file by its name -- until `letGo()`, and lets
    /// every other through, the ones of that kind after it among them.
    func holdTheNext(_ what: String) {
        holdingNext = what
    }

    func letGo() {
        holding = false
        holdingOnly = nil
        holdingNext = nil
        for (_, request) in held { request.resume() }
        held = []
    }

    /// Lets the requests of one kind that are held go, and holds no more of that kind. The requests of other
    /// kinds that are held stay held, and a hold of the next of another kind stays set.
    func letGo(only what: String) {
        if holdingOnly == what { (holding, holdingOnly) = (false, nil) }
        if holdingNext == what { holdingNext = nil }
        for (kind, request) in held where kind == what { request.resume() }
        held.removeAll { $0.what == what }
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

    /// Answers the next `times` requests of one kind -- a SOAP action, or a file by its name -- with `answer` in
    /// place of the demo's, once it has let `skipping` more of that kind through. One script to a kind. A request
    /// held and then let go meets it; one `goQuiet` took does not count. Counted in `asked` like any other.
    func answer(_ what: String, with answer: Answer, times: Int = 1, after skipping: Int = 0) {
        told[what] = (answer, times, skipping)
    }

    /// Busy with somebody else for one whole call of one kind: a 503 to the request and to both tries the client
    /// makes after it, which is three in `asked`. Fewer than three is a call that goes through late.
    func beBusy(with what: String, after skipping: Int = 0) {
        answer(what, with: .status(503), times: 3, after: skipping)
    }

    /// A moment behind itself, once: the list it gives after the next reservation it deletes or changes still has
    /// it, as it was.
    /// The old list is the last one it gave, so it has to have given one: armed before any read, it does
    /// nothing.
    func beAMomentBehind() {
        behind = true
    }

    /// How often it has been asked for `what` -- a SOAP action, or a file by its name: since it was made, or
    /// since `before`, which is its `asked` at an earlier moment.
    func asked(_ what: String, since before: [String: Int] = [:]) -> Int {
        (asked[what] ?? 0) - (before[what] ?? 0)
    }

    /// What it has been asked since it had been asked `count` things (`heard.count` at an earlier moment).
    func heard(since count: Int) -> [String] {
        Array(heard.dropFirst(count))
    }

    /// The `Elements` the last request of one kind carried, as it was sent -- a create, a change, a clash check,
    /// a condition -- whatever was answered; nil when no request of that kind carried any.
    func elements(of what: String) -> String? {
        lastElements[what]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let action = request.headers["SOAPACTION"].flatMap { $0.split(separator: "#").last }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let what = action ?? request.url.lastPathComponent
        asked[what, default: 0] += 1
        heard.append(what)
        if let body = request.body, let elements = (try? XmlNode.parse(body))?.firstDescendantText("Elements") {
            lastElements[what] = elements
        }
        if holdingNext == what {
            holdingNext = nil
            await withCheckedContinuation { held.append((what, $0)) }
        }
        if holding, holdingOnly == nil || holdingOnly == what {
            await withCheckedContinuation { held.append((what, $0)) }
        }
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
        if var script = told[what] {
            if script.after > 0 {
                script.after -= 1
                told[what] = script
            } else {
                script.times -= 1
                told[what] = script.times > 0 ? script : nil
                return script.answer.response
            }
        }
        if busy, request.url.path == "/description.xml" { return HTTPResponse(statusCode: 503) }
        if action == "X_GetPrivateIp" { return HTTPResponse(statusCode: 500) }
        let list = "X_GetRecordScheduleList"
        if what == list, let stale = staleList {
            staleList = nil
            return stale
        }
        let response = try await recorder.send(request)
        if what == list { lastList = response }
        if what == "X_DeleteRecordSchedule" || what == "X_UpdateRecordSchedule", behind {
            behind = false
            staleList = lastList
        }
        guard request.url.path == "/description.xml" else { return response }
        let described = response.text.replacingOccurrences(of: "uuid:00000000-0000-0000-0000-000000000000", with: udn)
        return HTTPResponse(statusCode: 200, body: Data(described.utf8))
    }
}

extension NamedRecorder {
    /// What it answers in place of the demo's answer, when a test has it do so (`answer`).
    ///
    /// Some of these a BDZ-FBT4100 has been seen to give (docs/xsrs-api.md, docs/porting.md): 804 to a change or
    /// a delete of a reservation it no longer has, 820 to a recording it no longer has, 831 to a reservation
    /// that follows a programme on a channel it cannot receive, 880 to playback in standby, a 503 while it is
    /// busy with somebody else, a 500 for a guide file it has not built. The rest stand in for a recorder that
    /// turns something down, or answers oddly, where none has been seen to: 402 to anything but a request of
    /// the wrong shape -- to a read, above all -- a `Result` that is not XML, and the list a moment behind
    /// (`beAMomentBehind`).
    enum Answer: Sendable, Equatable {
        /// A SOAP fault as a BDZ gives one: HTTP 500 with the UPnP error code in its body.
        case fault(Int)
        /// A status and nothing with it.
        case status(Int)
        /// HTTP 200 and this text as the `Result` of a SOAP answer, escaped as the recorder sends one.
        case result(String)

        /// The fault's body is the one the package's own tests use (`StubTransport.fault`), and the code in it
        /// has nothing around it: it is compared as text. The `Result` is in the envelope the demo builds.
        var response: HTTPResponse {
            let open = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
                + "<s:Body>"
            let close = "</s:Body></s:Envelope>"
            switch self {
            case .status(let status):
                return HTTPResponse(statusCode: status)
            case .fault(let code):
                let fault = "<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>"
                    + "<UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>\(code)</errorCode></UPnPError>"
                    + "</detail></s:Fault>"
                return HTTPResponse(statusCode: 500, body: Data((open + fault + close).utf8))
            case .result(let text):
                let result = "<u:Response xmlns:u=\"\(Upnp.xsrsService)\"><Result>\(Soap.escape(text))</Result>"
                    + "</u:Response>"
                return HTTPResponse(statusCode: 200, body: Data((open + result + close).utf8))
            }
        }
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

/// Another connection writing to the cache, until it lets go: a write of the app's waits behind it for as
/// long as the busy timeout, and then fails.
final class Writer {
    private var connection: OpaquePointer?

    init(to path: String) {
        XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
    }

    func letGo() {
        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil), SQLITE_OK)
    }

    deinit { sqlite3_close(connection) }
}

/// Another connection that has put the queue's table out of the app's reach, until it puts it back: whatever
/// the app asks of its queue meanwhile fails at once, a read as well, which a writer's lock does not stop.
final class QueueOutOfReach {
    private var connection: OpaquePointer?

    init(in path: String) {
        XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
        XCTAssertEqual(run("ALTER TABLE pending_reservations RENAME TO out_of_reach"), SQLITE_OK)
    }

    func putBack() {
        XCTAssertEqual(run("ALTER TABLE out_of_reach RENAME TO pending_reservations"), SQLITE_OK)
    }

    private func run(_ statement: String) -> Int32 { sqlite3_exec(connection, statement, nil, nil, nil) }

    deinit { sqlite3_close(connection) }
}

/// Another connection that has put the queue's table behind a view of the same name, until it puts it back: a
/// row the app writes to the queue meanwhile goes into the table, and every read of the queue that comes upon a
/// row fails at once. (A read of an empty queue works nothing out, and goes through.) A write that went through
/// and a read of it that did not, which neither a writer's lock nor the table out of reach gives: each stops the
/// write as well.
final class QueueUnreadable {
    private var connection: OpaquePointer?

    init(in path: String) {
        XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
        let columns = columnsOfTheQueue()
        XCTAssertFalse(columns.isEmpty, "the queue's table was not found")
        let named = columns.joined(separator: ", ")
        let new = columns.map { "NEW.\($0)" }.joined(separator: ", ")
        XCTAssertEqual(run("ALTER TABLE pending_reservations RENAME TO behind_a_view"), SQLITE_OK)
        // A whole number too large to be one, worked out for each row a read of the view comes upon: an error.
        XCTAssertEqual(run("CREATE VIEW pending_reservations AS "
                               + "SELECT *, abs(-9223372036854775807 - 1) AS overflow FROM behind_a_view"), SQLITE_OK)
        XCTAssertEqual(run("CREATE TRIGGER written_through INSTEAD OF INSERT ON pending_reservations BEGIN "
                               + "INSERT OR REPLACE INTO behind_a_view (\(named)) VALUES (\(new)); END"), SQLITE_OK)
    }

    /// The view goes, its trigger with it, and the table is the queue again.
    func putBack() {
        XCTAssertEqual(run("DROP VIEW pending_reservations"), SQLITE_OK)
        XCTAssertEqual(run("ALTER TABLE behind_a_view RENAME TO pending_reservations"), SQLITE_OK)
    }

    private func columnsOfTheQueue() -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(pending_reservations)", -1, &statement, nil)
            == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let name = sqlite3_column_text(statement, 1) {
            names.append(String(cString: name))
        }
        return names
    }

    private func run(_ statement: String) -> Int32 { sqlite3_exec(connection, statement, nil, nil, nil) }

    deinit { sqlite3_close(connection) }
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

    /// `count` programmes of the cached guide, an hour or more ahead, that the recorder holds no reservation of
    /// and none waits for: for a test that looks at whether one was made. (`aProgramme` can hand back one the demo
    /// has reserved already.)
    @MainActor
    func programmesNotReserved(_ model: AppModel, _ count: Int) async throws -> [GuideProgramRow] {
        let later = Date().addingTimeInterval(3600)
        let free = await model.search("サンプル").hits.map(\.program).filter {
            $0.start > later && model.reservation(for: $0) == nil && model.pending(for: $0) == nil
        }
        return try XCTUnwrap(free.count >= count ? Array(free.prefix(count)) : nil,
                             "the cached guide had only \(free.count) programmes ahead that are not reserved")
    }

    /// The usual start of a gate: a bench, the first recorder at `Bench.host`, and a model started and connected
    /// to it with nothing under way. `guide: false` leaves the cache empty, for a gate that needs no programme:
    /// the first connect then asks for the four guide files, which the demo answers with none. `wakeable` saves
    /// the MAC the recorder's UDN carries; the model sends no packet (`Surroundings.reachesTheLAN`).
    @MainActor
    func connectedHome(guide: Bool = true, wakeable: Bool = false) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel) {
        let bench = try aBench()
        if guide { try await bench.cacheAGuide() }
        if wakeable { bench.keep(mac: WhichRecorderTests.firstsMAC) }
        let recorder = NamedRecorder(1)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        return (bench, recorder, model)
    }

    /// 再接続, as the reader asks for it once silence has lost the recorder. Over when the reads that follow a
    /// connect are.
    @MainActor
    func reconnect(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) async {
        await model.connect()
        let why = model.problem(for: .recorder) ?? "no reason given"
        XCTAssertTrue(model.connected, "the recorder did not come back: \(why)", file: file, line: line)
    }
}

/// A client of the test's own asking `recorder`, with no pause before a 503 is sent again: the recorder's own
/// screen, or a look at what the recorder really holds.
@MainActor
func aClient(of recorder: any HTTPTransport) -> RecorderClient {
    RecorderClient(host: Bench.host, transport: recorder, busyRetryDelay: 0...0)
}

// MARK: - what the app says

/// What the app says about the recorder, in the words the reader sees: literals, so that a sentence moved from
/// one type to another is still the same sentence, and one changed by a character is caught.
enum Said {
    static let notConnected = "レコーダーに接続していません。「再接続」を押してから、もう一度お試しください。"
    static let mayHaveArrived = "送信の途中でレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。再接続してから一覧で確かめてください。"
    static let anotherAnswered = "別のレコーダーが応答したため、この操作は行っていません。"
        + "一覧を読み直しますので、確かめてからもう一度お試しください。"
    static let cacheNotMadeOver = "端末内のデータベースに書き込めなかったため、接続を中断しました。"
        + "少し待ってから、もう一度お試しください。"
    /// Written on the rows of the phone's queue, and counted by being equal to this.
    static let heldForAnotherRecorder = "別のレコーダーに切り替わったため、送らずに残しています。"
        + "「もう一度送る」を選ぶと、いまのレコーダーに送ります。"
    /// Written on a row of the phone's queue whose create met silence, which holds it for the reader.
    static let heldAfterSilence = "予約の登録中にレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "自動では送り直しません。予約一覧で確かめ、届いていなければ「もう一度送る」を選んでください。"
    static func heldBack(_ count: Int) -> String {
        "別のレコーダーに切り替わったため、送信待ちの予約 \(count) 件は送らずに残しています。予約タブから送り直せます"
    }
    static let anotherAnsweredWithNoScreen = "これまでとは別のレコーダーが応答したため、"
        + "送信待ちの予約はそのまま残しています。アプリを開いて確かめてください。"
    /// Said of a reservation kept on the phone because the recorder was not there.
    static let keptForTheRecorder = "レコーダーに届かなかったので、予約を端末に保存しました。"
        + "次にレコーダーにつながったときに登録します。予約タブで削除できます。"
    static let gone = "この予約はレコーダーの予約一覧に見つかりませんでした。一覧を更新しました。"
    static let couldNotBeConfirmed = "予約を登録できたか確かめられませんでした。予約タブで確かめてください。"
    static let foundThere = "レコーダーにはこの番組の予約がすでにありました。"
    static let notKnownThere = "レコーダーの予約が多いため、この予約が届いているか一覧で確かめられませんでした。送っていません。"
        + "レコーダー本体の予約一覧で確かめ、届いていなければ、この送信待ちの予約を削除してから番組表で予約し直してください。"
    static let notKnownThereUnread = "レコーダーの予約一覧を読めなかったため、この予約が届いているか確かめられませんでした。"
        + "送っていません。少し待ってから、もう一度送ってください。"
    static let renumbered = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"
    static let stillRecording = "録画中のため削除できません。番組が終わるまでお待ちください。"
    /// The keyword conditions' screen's reason when its read failed and nothing says why.
    static let conditionsNotAsked = "レコーダーに接続していません"
    static let notInTheTables = "この録画モードと毎回録画の組み合わせは、レコーダーに送れません。"
    static let slotWaitGivenUp = "録画先のディスクの確認を中断したため、送っていません。"
    static let changeRecording = "録画中の予約は変更できません。"
    static let changeEnded = "放送が終わった予約は変更できません。"
    static let changeNotReflected = "変更がレコーダーの予約一覧に反映されていません。一覧を更新しました。"
    static let goneAfterAChange = "レコーダーは変更を受け付けたと答えましたが、この予約が一覧に見つかりません。"
        + "レコーダー本体の予約一覧で確かめてください。"

    // What became of the queue (`PendingQueue.Outcome.summary`), a sentence for each way a reservation went:
    // about the first by its title, and how many more went that way. Here, and not in the tests that look at
    // them, so that a rewording is one edit. `naming` is the device's word, for a home with a television saved
    // beside the recorder, where each sentence says which device it is about (`says(naming:)`); with none the
    // sentence is the one a home with a recorder alone reads.
    static func sent(_ title: String, andOthers others: Int = 0, naming device: String? = nil) -> String {
        device.map { "送信待ちだった\(naming(title, others))を\($0)に登録しました" }
            ?? "送信待ちだった\(naming(title, others))を登録しました"
    }
    static func alreadyThere(_ title: String, andOthers others: Int = 0, naming device: String? = nil) -> String {
        device.map { "\(naming(title, others))は\($0)にすでに予約がありました" }
            ?? "\(naming(title, others))はすでに予約されていました"
    }
    static func expired(_ title: String, andOthers others: Int = 0, naming device: String? = nil) -> String {
        device.map { "\($0)宛の\(naming(title, others))は放送が終わっていたため、送らずに削除しました" }
            ?? "\(naming(title, others))は放送が終わっていたため、送らずに削除しました"
    }
    static func refused(_ title: String, andOthers others: Int = 0, naming device: String? = nil) -> String {
        device.map { "\(naming(title, others))は\($0)に登録できませんでした。理由は予約タブにあります" }
            ?? "\(naming(title, others))はレコーダーが受け付けませんでした。理由は予約タブにあります"
    }
    static func deferred(_ title: String, andOthers others: Int = 0, naming device: String? = nil) -> String {
        device.map { "\(naming(title, others))は\($0)に送れなかったため、次の機会にもう一度送ります" }
            ?? "\(naming(title, others))は送れなかったため、次の機会にもう一度送ります"
    }
    // As a home with a recorder alone reads it. No test has a named device go silent yet, so no form names one.
    static let interrupted = "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります"
    private static func naming(_ title: String, _ others: Int) -> String {
        others == 0 ? "「\(title)」" : "「\(title)」ほか \(others) 件"
    }

    // The package's own, which do not move: by what they are called there.
    static let noAnswer = RecorderError.transport("").explanation
    static func fault(_ code: Int, _ action: String) -> String {
        RecorderError.soap(action: action, status: 500, code: "\(code)", body: "").explanation
    }
    static func busy(_ action: String) -> String { RecorderError.busy(action: action).explanation }
}

/// A line an earlier operation left, for a test that looks at whether it was cleared or written over.
let lineLeft = "前の操作が残した文"

/// Leaves it on the recorder's line of what went wrong.
@MainActor
func leaveALine(on model: AppModel) { model.problem = lineLeft }

/// Leaves nothing there, for a test that looks at what is said over an empty line.
@MainActor
func clearTheLine(on model: AppModel) { model.problem = nil }

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

// MARK: - what the tests ask of the recorder's reservations
//
// As the screens ask for it, through the entries they use, and by what each does rather than by the model's name
// for the recorder's own operation: where that operation lives can change, and only the bodies here change with it.

/// A reservation of `program` on the recorder, as the programme's sheet asks for it: whether it was made or kept.
@MainActor
func reserveOnTheRecorder(_ model: AppModel, _ program: GuideProgramRow, quality: String, repeating: String,
                          disk: String = RecorderDisk.internalID) async -> Bool {
    let came = await model.reserve(program, on: .recorder, quality: quality, repeating: repeating, disk: disk)
    var kept: PendingReservation?
    if case .waiting(let row, _) = came { kept = row }
    keptRows.removeAll { $0.model == nil || $0.model === model }
    keptRows.append(KeptRow(model: model, row: kept))
    var why: String?
    if case .notDone(let said) = came { why = said }
    note(why, of: model)
    switch came {
    case .made, .waiting: return true
    case .wouldStop, .notDone: return false
    }
}

/// The row the last reservation on the recorder kept on the phone; nil when it was made or not done.
@MainActor
func keptJustNow(_ model: AppModel) -> PendingReservation? {
    keptRows.first { $0.model === model }?.row
}

/// A change of a reservation as the recorder's own change takes it: whether it went through. A row of another
/// device is put to the recorder's door, which turns it away with nothing asked.
@MainActor
func changeOnTheRecorder(_ model: AppModel, _ row: Reservation, quality: String, repeating: String,
                         disk: String? = nil) async -> Bool {
    guard row.device == .recorder else {
        let turnedAway = await model.recorderDriver?.update(row, quality: quality, repeating: repeating, disk: disk)
        // Noted too, so that what is read after it is this call's reason, and not the one before it.
        var why: String?
        if case .notDone(let said)? = turnedAway?.altered { why = said }
        note(why, of: model)
        if case .done? = turnedAway?.altered { return true }
        return false
    }
    let altered = await model.change(row, quality: quality, repeating: repeating, disk: disk)
    var why: String?
    if case .notDone(let said) = altered { why = said }
    note(why, of: model)
    if case .done = altered { return true }
    return false
}

/// Why the last reservation or change on the recorder asked through the two above was not done, as its result
/// said it, or the last of the recordings' and the keyword conditions' writes asked through the helpers below;
/// nil when it was made, kept or done.
@MainActor
func whyNotJustNow(_ model: AppModel) -> String? {
    reasons.first { $0.model === model }?.why
}

/// A delete of a reservation as a screen asks for it, whichever device holds the row: whether it went through.
@MainActor
func deleteAReservation(_ model: AppModel, _ row: Reservation) async -> Bool {
    if case .done = await model.cancel(row) { return true }
    return false
}

/// A delete of a television's reservation asked of its host itself, as no screen asks it: whether it went
/// through.
@MainActor
func deleteThroughTheHost(_ host: TVHost, _ row: Reservation) async -> Bool {
    if case .done? = await host.cancel(row) { return true }
    return false
}

// MARK: - what the tests ask of the recordings and the keyword conditions
//
// As the screens ask for it, through the entries they use, and by what each does rather than by the model's name
// for it: where these operations live can change, and only the bodies here change with it.

/// A recording protected, or its protection taken off, as its sheet and the list's swipe ask for it: whether it
/// went through. Why not, as its result said it, is noted for `whyNotJustNow`, as for each of the five below.
@MainActor
func protectARecording(_ model: AppModel, _ title: RecordedTitle, _ on: Bool) async -> Bool {
    noted(await model.setProtected(title, on), of: model)
}

/// A recording deleted, as its sheet, the list's swipe and the group's sheet ask for it: whether it went through.
@MainActor
func deleteARecording(_ model: AppModel, _ title: RecordedTitle) async -> Bool {
    noted(await model.delete(title), of: model)
}

/// A recording played, paused or stopped on the television the recorder is attached to, as its sheet asks for
/// it: `operation` is the recorder's own word for it (`play`, `pause`, `stop`).
@MainActor
func playARecording(_ model: AppModel, _ title: RecordedTitle, _ operation: String) async {
    _ = noted(await model.play(title, operation), of: model)
}

/// The recorder turned on, as a recording's sheet offers once the recorder has said it is in standby.
@MainActor
func turnTheRecorderOn(_ model: AppModel) async {
    _ = noted(await model.powerOn(), of: model)
}

/// A keyword condition registered on the recorder, as its sheet asks for it: whether it went through.
@MainActor
func addACondition(_ model: AppModel, _ request: RecorderRuleRequest) async -> Bool {
    noted(await model.addRecorderRule(request), of: model)
}

/// A keyword condition deleted from the recorder, as its screen's swipe asks for it: whether it went through.
@MainActor
func removeACondition(_ model: AppModel, _ rule: RecorderRule) async -> Bool {
    noted(await model.removeRecorderRule(rule), of: model)
}

/// Whether `altered` was done, with why not noted for `whyNotJustNow`.
@MainActor
private func noted(_ altered: Altered, of model: AppModel) -> Bool {
    var why: String?
    if case .notDone(let said) = altered { why = said }
    note(why, of: model)
    if case .done = altered { return true }
    return false
}

/// What the last reservation on the recorder of each model kept on the phone (`keptJustNow`): the result hands
/// the row back once, and the model keeps nothing of it after. Held weakly, so that a model a test is done with is
/// not kept, and one made later is never taken for it.
private struct KeptRow {
    weak var model: AppModel?
    var row: PendingReservation?
}

@MainActor private var keptRows: [KeptRow] = []

/// Why the last reservation or change of each model was not done (`whyNotJustNow`), held as `KeptRow` is.
private struct Reason {
    weak var model: AppModel?
    var why: String?
}

@MainActor private var reasons: [Reason] = []

@MainActor private func note(_ why: String?, of model: AppModel) {
    reasons.removeAll { $0.model == nil || $0.model === model }
    reasons.append(Reason(model: model, why: why))
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
