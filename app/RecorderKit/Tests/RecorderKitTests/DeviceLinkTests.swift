import Foundation
import XCTest
@testable import RecorderKit

/// A link at work on the local network: the packet before the first ask, the wait for the local network
/// permission instead of a waking, the waking that gets no answer, and the search for a recorder the router has
/// moved. The app's own tests run with nothing on the LAN, where none of this happens; here the link is handed a
/// world of the test's own, which puts down what it was asked to do and answers as the test says. Also one rule
/// whose moment the app's tests cannot reach: silence met after another network sets the looks going again. And
/// one of a link's own life: let go of, it goes, though its driver is kept.
@MainActor
final class DeviceLinkTests: XCTestCase {
    /// The recorder's MAC and the UDN that ends with it: Sony's OUI and the rest zeroed, as everywhere in this
    /// repository, with a last digit of its own.
    static let mac = "f8:4e:17:00:00:01"
    static let udn = "uuid:00000000-0000-0000-0000-f84e17000001"
    /// Where the router moves the recorder to, in the tests that move it.
    static let moved = "192.0.2.20"
    static let noAnswer = "レコーダーが応答しません。電源とネットワーク接続を確認してください。"

    /// A recorder at one address: it says who it is as the recorder of the vectors does, under the UDN it is
    /// given, and refuses the rest, which an attach does without. Each ask is put down in the world.
    actor Recorder: HTTPTransport {
        private let host: String
        private let description: String
        private var silent: Bool
        private var busy = false
        private weak var world: LinkWorld?

        init(at host: String, udn: String, silent: Bool = false, world: LinkWorld? = nil) {
            self.host = host
            self.silent = silent
            self.world = world
            let xml = (try? Vectors.load("description.json"))?.string("description_xml") ?? ""
            description = xml.replacingOccurrences(of: "uuid:00000000-0000-0000-0000-000000000000", with: udn)
        }

        func goSilent(_ value: Bool = true) { silent = value }
        /// Busy with somebody else's request, which it says to every ask, the client's tries again included.
        func goBusy() { busy = true }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let asked = request.url.lastPathComponent
            await world?.put("ask \(asked) at \(host)")
            if silent { throw RecorderError.transport("The request timed out.") }
            if busy { return HTTPResponse(statusCode: 503) }
            guard asked == "description.xml" else { return HTTPResponse(statusCode: 500) }
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
    }

    /// A link to the recorder at `Stub.host`, woken by `mac` when there is one, whose waking gives up after a
    /// twentieth of a second rather than half a minute.
    private func makeLink(mac: String? = nil, _ world: LinkWorld) -> DeviceLink {
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: mac),
                              driver: RecorderDriver(holdingTheQueueWith: "held", wakingLimit: 0.05,
                                                     wakingInterval: .milliseconds(10), busyRetryDelay: 0...0),
                              environment: world.environment)
        link.owner = world
        return link
    }

    /// Puts the recorder at `host`, and hands it back for the test to silence or keep busy.
    @discardableResult
    private func place(at host: String = Stub.host, silent: Bool = false, in world: LinkWorld) -> Recorder {
        let recorder = Recorder(at: host, udn: Self.udn, silent: silent, world: world)
        world.devices[host] = recorder
        return recorder
    }

    /// The recorder at `host`, as a search of the subnet finds it.
    private func foundAt(_ host: String) -> RecorderDescription {
        RecorderDescription(host: host, port: 64220, friendlyName: "サンプルレコーダー", product: "BDZ",
                            model: "BDZ-SAMPLE", udn: Self.udn, epgCapable: true,
                            location: "http://\(host):64220/description.xml", via: "scan")
    }

    /// Waits for `condition`, a few seconds at most: for what the link's own tasks get round to.
    private func until(_ what: String, within seconds: Double = 3, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail(what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - the packet

    /// The packet goes before the first ask, from a connect and from the check before an operation: a recorder
    /// asleep is on its way up while the ask waits, and one awake ignores it. One that answered a moment ago is
    /// not made sure of at all.
    func testThePacketGoesBeforeTheFirstAsk() async {
        let world = LinkWorld()
        place(in: world)
        let link = makeLink(mac: Self.mac, world)
        let packetThenAsk = ["packet \(Self.mac) for \(Stub.host)", "ask description.xml at \(Stub.host)"]

        await link.connect()
        XCTAssertTrue(link.session.connected)
        XCTAssertEqual(world.onTheNetwork, packetThenAsk)

        world.events = []
        let up = await link.ensureUp()
        XCTAssertTrue(up)
        XCTAssertEqual(world.onTheNetwork, [], "a recorder that has just answered was made sure of")

        let madeSure = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(madeSure)
        XCTAssertEqual(world.onTheNetwork, packetThenAsk)
    }

    /// With no MAC there is nothing to send a packet to.
    func testWithNoMACNoPacketIsSent() async {
        let world = LinkWorld()
        place(in: world)
        let link = makeLink(world)

        await link.connect()

        XCTAssertTrue(link.session.connected)
        XCTAssertEqual(world.count("packet"), 0)
    }

    // MARK: - the local network permission

    /// After a silent first ask the permission is asked about, and when it is what is in the way the app waits
    /// for it: no waking, which would be half a minute of nothing, and no search. The attempt stays given up until
    /// the permission comes, and then it connects.
    func testSilenceThatIsThePermissionWaitsForItInsteadOfWaking() async {
        let world = LinkWorld()
        let recorder = place(silent: true, in: world)
        world.blocked = true
        world.near = [Self.moved]
        world.found = foundAt(Self.moved)
        let link = makeLink(mac: Self.mac, world)

        await link.connect()

        XCTAssertEqual(world.count("permission at \(Stub.host)"), 1)
        XCTAssertTrue(link.session.connectBlocked)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertEqual(world.waitingAt, Stub.host)
        XCTAssertEqual(world.count("ask description.xml"), 1, "woken behind a permission that stops every ask")
        XCTAssertEqual(world.count("search"), 0)
        XCTAssertNil(world.problem)

        await recorder.goSilent(false)
        world.blocked = false
        await link.permissionArrived(true, at: Stub.host)

        XCTAssertTrue(link.session.connected)
        XCTAssertFalse(link.session.connectBlocked)
        XCTAssertFalse(link.session.gaveUp)
    }

    /// The permission that comes for an address the link has left connects nothing.
    func testThePermissionForAnAddressLeftConnectsNothing() async {
        let world = LinkWorld()
        place(silent: true, in: world)
        place(at: Self.moved, in: world)
        world.blocked = true
        let link = makeLink(world)
        await link.connect()
        XCTAssertTrue(link.session.connectBlocked)

        link.host = Self.moved
        await link.permissionArrived(true, at: Stub.host)

        XCTAssertEqual(world.count("ask description.xml at \(Self.moved)"), 0)
        XCTAssertFalse(link.session.connected)
        XCTAssertFalse(link.session.connectBlocked)
    }

    /// The check before an operation asks about the permission too, and waits for it rather than wake.
    func testTheCheckBeforeAnOperationAsksAboutThePermissionToo() async {
        let world = LinkWorld()
        let recorder = place(in: world)
        let link = makeLink(mac: Self.mac, world)
        await link.connect()
        XCTAssertTrue(link.session.connected)

        await recorder.goSilent()
        world.blocked = true
        world.events = []
        let up = await link.ensureUp(evenIfRecent: true)

        XCTAssertFalse(up)
        XCTAssertTrue(link.session.connectBlocked)
        XCTAssertEqual(world.waitingAt, Stub.host)
        XCTAssertEqual(world.count("packet"), 1, "woken behind the permission")
        XCTAssertEqual(world.count("ask description.xml"), 1, "woken behind the permission")
    }

    /// A connect is what the wait was waiting to find out, one way or the other: it ends the wait.
    func testAConnectEndsTheWaitForThePermission() async {
        let world = LinkWorld()
        let recorder = place(silent: true, in: world)
        world.blocked = true
        let link = makeLink(world)
        await link.connect()
        XCTAssertEqual(world.waitingAt, Stub.host)

        await recorder.goSilent(false)
        world.blocked = false
        await link.connect()

        XCTAssertNil(world.waitingAt, "the wait for the permission went on beside a connect")
        XCTAssertTrue(link.session.connected)
    }

    /// So does letting go of the device: the permission that came would connect to a device the app has left.
    func testForgettingTheDeviceEndsTheWaitForThePermission() async {
        let world = LinkWorld()
        place(silent: true, in: world)
        world.blocked = true
        let link = makeLink(world)
        await link.connect()
        XCTAssertEqual(world.waitingAt, Stub.host)

        link.forgetTheDevice()

        XCTAssertNil(world.waitingAt)
        XCTAssertFalse(link.session.connectBlocked)
    }

    // MARK: - silence

    /// Silence met after the phone was on another network for a while -- the Wi-Fi went and came back while a
    /// request was out -- is no reason to stay given up at home, where the phone is the same as before and after:
    /// the looks at the network start again, and the first finds that it moved since the last attempt. Without
    /// them the app stayed given up whenever the looks set going by the reports had run out first.
    func testSilenceAfterAnotherNetworkLooksAtTheNetworkAgain() async throws {
        let world = LinkWorld()
        place(in: world)
        let link = makeLink(world)
        await link.connect()
        XCTAssertTrue(link.session.connected)

        // A look while the phone was elsewhere, as a report of the Wi-Fi going leaves it.
        link.session.noted(network: "elsewhere")
        link.lost()
        XCTAssertTrue(link.session.gaveUp)

        try await until("the app stayed given up at home") { link.session.connected && !link.session.gaveUp }
    }

    // MARK: - waking, and a recorder that has moved

    /// A recorder that answered, if only to say it is busy, is there: it is neither woken nor looked for, and not
    /// given up on.
    func testARecorderThatAnswersBusyIsNeitherWokenNorLookedFor() async {
        let world = LinkWorld()
        await place(in: world).goBusy()
        world.near = [Self.moved]
        world.found = foundAt(Self.moved)
        let link = makeLink(mac: Self.mac, world)

        await link.connect()

        XCTAssertEqual(world.count("packet"), 1, "a recorder that answered was woken")
        XCTAssertEqual(world.count("search"), 0)
        XCTAssertFalse(link.session.gaveUp)
        XCTAssertFalse(link.session.connected)
    }

    /// A waking that gets no answer, and a search that finds nothing after it, give up and say why: the waking's
    /// line, put back after the search.
    func testAWakingThatGetsNoAnswerGivesUpAndSaysSo() async {
        let world = LinkWorld()
        place(silent: true, in: world)
        world.near = [Self.moved]
        let link = makeLink(mac: Self.mac, world)

        await link.connect()

        XCTAssertGreaterThan(world.count("ask description.xml"), 1, "not asked again after the packet")
        XCTAssertEqual(world.count("search"), 1)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertEqual(world.problem, Self.noAnswer)
    }

    /// A recorder silent where it was, and not woken there, is looked for once on the subnet by the MAC its UDN
    /// ends with. Found, it is the recorder the app had and nothing of it is forgotten: the address moves --
    /// written down, then where the MAC was read -- and it is attached there with a client of its own.
    func testARecorderThatMovedIsFoundByItsMACAndFollowed() async {
        let world = LinkWorld()
        let recorder = place(in: world)
        let link = makeLink(mac: Self.mac, world)
        await link.connect()
        XCTAssertTrue(link.session.connected)

        await recorder.goSilent()
        place(at: Self.moved, in: world)
        world.near = [Self.moved]
        world.found = foundAt(Self.moved)
        world.events = []
        await link.connect()

        XCTAssertEqual(link.host, Self.moved)
        XCTAssertEqual(link.client?.host, Self.moved)
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        XCTAssertFalse(link.session.gaveUp)
        XCTAssertEqual(link.session.mac, Self.mac)
        XCTAssertEqual(world.macReadAt, Self.moved)
        XCTAssertEqual(world.count("search"), 1)
        XCTAssertEqual(world.count("another device"), 0, "the recorder that moved was taken for another")
        let saves = world.events.filter { $0.hasPrefix("address") || $0.hasPrefix("MAC read at") }
        XCTAssertEqual(Array(saves.prefix(2)), ["address \(Self.moved)", "MAC read at \(Self.moved)"])
        let search = world.events.firstIndex { $0.hasPrefix("search") } ?? 0
        let lastAskWhereItWas = world.events.lastIndex { $0 == "ask description.xml at \(Stub.host)" } ?? .max
        XCTAssertLessThan(lastAskWhereItWas, search, "looked for before the waking was over")
    }

    /// Not looked for while the MAC kept was read at another address: after the reader types another recorder's
    /// address the MAC is still the last one's, and the search would go back to the recorder just left.
    func testNoSearchWhileTheMACWasReadAtAnotherAddress() async {
        let world = LinkWorld()
        place(silent: true, in: world)
        world.near = [Self.moved]
        world.found = foundAt(Self.moved)
        world.macReadAt = "192.0.2.99"
        let link = makeLink(mac: Self.mac, world)

        await link.connect()

        XCTAssertEqual(world.count("search"), 0)
        XCTAssertEqual(link.host, Stub.host)
        XCTAssertTrue(link.session.gaveUp)
    }

    /// Nor where the app gives nowhere to look: in the demo, in the background, on a Wi-Fi the address is not on.
    func testNoSearchWithNowhereToLook() async {
        let world = LinkWorld()
        place(silent: true, in: world)
        world.found = foundAt(Self.moved)
        let link = makeLink(mac: Self.mac, world)

        await link.connect()

        XCTAssertEqual(world.count("search"), 0)
        XCTAssertTrue(link.session.gaveUp)
    }

    /// The check before an operation wakes the recorder but does not look for it elsewhere: silence after the
    /// waking leaves the app offline, given up, where it was.
    func testTheCheckBeforeAnOperationDoesNotLookElsewhere() async {
        let world = LinkWorld()
        let recorder = place(in: world)
        let link = makeLink(mac: Self.mac, world)
        await link.connect()

        await recorder.goSilent()
        place(at: Self.moved, in: world)
        world.near = [Self.moved]
        world.found = foundAt(Self.moved)
        world.events = []
        let up = await link.ensureUp(evenIfRecent: true)

        XCTAssertFalse(up)
        XCTAssertGreaterThan(world.count("packet"), 1, "not woken")
        XCTAssertEqual(world.count("search"), 0)
        XCTAssertEqual(link.host, Stub.host)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertTrue(link.offline)
    }

    // MARK: - a television that has moved

    /// Another television's MAC: Sony's OUI and the rest zeroed, with a last digit of its own.
    static let otherTV = "f8:4e:17:00:00:0b"
    /// An address of the subnet where nothing answers, beside the one the television moves to.
    static let nobodyHere = "192.0.2.19"

    /// The television, saved by its MAC as a launch has it, registered with a cookie it gave out a moment ago:
    /// no renewal is due, so a registration sent to anything is a wrong one.
    private func registeredTelevision(at host: String? = Stub.host, in world: LinkWorld) async -> DemoTV {
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        if let host { world.devices[host] = television }
        return television
    }

    /// A link to the television saved at `Stub.host`, known by the MAC saved with it unless `saved` is nil.
    private func makeTVLink(saved: String? = DemoTV.mac, _ world: LinkWorld) -> DeviceLink {
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let link = DeviceLink(host: Stub.host, session: SessionState(device: saved),
                              driver: TVDriver(credentials: credentials, nickname: "BD Bridge", inFront: { true }),
                              environment: world.environment)
        link.owner = world
        return link
    }

    /// What a device that is not the television heard, as long as it asked nothing but which television it is:
    /// a request of the one method that needs no registration, with no cookie and no PIN.
    private func onlyAskedWhichItIs(_ heard: [HTTPRequest]) -> Bool {
        heard.allSatisfy { request in
            request.headers["Cookie"] == nil && request.headers["Authorization"] == nil
                && String(decoding: request.body ?? Data(), as: UTF8.self).contains(#""getSystemSupportedFunction""#)
        }
    }

    private static let askedWhich = "getSystemSupportedFunction cookie=no pin=no"

    /// A television silent where it was saved is looked for once on its subnet, by the MAC it wakes on, with the
    /// strip saying so while the look is out and the line of what went wrong taken down until the look is over;
    /// found, it is the television the app had: the address moves -- written down -- and a client of its own
    /// attaches there, asking which television it is before anything carries the cookie. Nothing is woken and
    /// nothing registers.
    func testATelevisionSilentWhereItWasIsFoundByItsMACAndFollowed() async {
        let world = LinkWorld()
        let television = await registeredTelevision(in: world)
        let link = makeTVLink(world)
        await link.connect()
        XCTAssertTrue(link.session.connected)
        let before = link.client

        world.devices[Stub.host] = nil
        world.devices[Self.moved] = television
        world.devices[Self.nobodyHere] = StubTransport { _, _ in
            let line = await world.line
            let problem = await world.problem
            await world.put("line while looking: \(line ?? "none")")
            await world.put("problem while looking: \(problem ?? "none")")
            throw RecorderError.transport("Nothing is here.")
        }
        world.near = [Self.nobodyHere, Self.moved]
        world.events = []
        let calls = await television.calls.count
        await link.connect()

        XCTAssertEqual(link.host, Self.moved)
        XCTAssertEqual(link.client?.host, Self.moved)
        XCTAssertFalse(link.client === before, "the last client was kept")
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        XCTAssertFalse(link.session.gaveUp)
        XCTAssertNil(world.problem)
        XCTAssertEqual(world.count("search for television"), 1)
        XCTAssertTrue(world.events.contains("address \(Self.moved)"), "the new address was not written down")
        XCTAssertTrue(world.events.contains("line while looking: \(TVDriver.lookingLine)"), "the strip said nothing")
        XCTAssertTrue(world.events.contains("problem while looking: none"), "the silence was said while looking")
        XCTAssertNil(world.line, "a line was left up")
        XCTAssertEqual(world.count("packet"), 0)
        let heard = Array(await television.calls.dropFirst(calls))
        XCTAssertEqual(Array(heard.prefix(2)), [Self.askedWhich, Self.askedWhich], "the look, then the attach")
        XCTAssertEqual(heard.dropFirst(2).first, "getInterfaceInformation cookie=no pin=no")
        XCTAssertFalse(heard.contains { $0.hasPrefix("actRegister") || $0.hasPrefix("setPowerStatus") })
    }

    /// Another television on the subnet, and only that, is not the one saved: nothing is taken, the app gives up
    /// as on silence, and the line the attach left is put back. It was asked which television it is, and
    /// nothing else.
    func testAnotherTelevisionOnTheSubnetIsNotTakenForTheOneSaved() async {
        let world = LinkWorld()
        let other = DemoTV(mac: Self.otherTV)
        await other.knows("BDBridge:test", cookie: "kept")
        world.devices[Self.moved] = other
        world.near = [Self.moved]
        let link = makeTVLink(world)

        await link.connect()

        XCTAssertEqual(link.host, Stub.host)
        XCTAssertFalse(link.session.connected)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertEqual(world.count("search for television"), 1)
        XCTAssertEqual(world.problem, ScalarError.transport("no answer").explanation)
        XCTAssertEqual(world.count("address"), 0, "an address was written down")
        expectEqual(await other.calls, [Self.askedWhich])
    }

    /// Something that is not the television saved, answering at its address, is the television not being there:
    /// another television, by its MAC, or a device that is no television -- a printer, a router's page --
    /// which answers on port 80 with a status no television gives. The television is looked for past it and
    /// followed, and what answered at the old address was asked which television it is and nothing else: no
    /// cookie, no PIN, at most twice (the attach, and the look).
    func testATelevisionIsFollowedPastWhateverAnswersWhereItWas() async {
        let strangers: [(String, any HTTPTransport)] = [
            ("another television", DemoTV(mac: Self.otherTV)),
            ("a page on port 80", StubTransport(always: HTTPResponse(statusCode: 404))),
        ]
        for (what, stranger) in strangers {
            let world = LinkWorld()
            let television = await registeredTelevision(at: Self.moved, in: world)
            let heard = StubTransport { request, _ in try await stranger.send(request) }
            world.devices[Stub.host] = heard
            world.near = [Stub.host, Self.nobodyHere, Self.moved]
            let link = makeTVLink(world)

            await link.connect()

            XCTAssertEqual(link.host, Self.moved, what)
            XCTAssertTrue(link.session.connected, "\(what): \(world.problem ?? "no reason given")")
            XCTAssertNil(world.problem, what)
            XCTAssertEqual(world.count("search for television"), 1, what)
            let asked = await heard.requests
            XCTAssertTrue(onlyAskedWhichItIs(asked), "\(what) was asked more than which television it is")
            XCTAssertLessThanOrEqual(asked.count, 2, what)
            let calls = await television.calls
            XCTAssertEqual(calls.first, Self.askedWhich, what)
            XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") }, what)
            XCTAssertEqual(world.count("packet"), 0, what)
        }
    }

    /// With the television nowhere on the subnet, what answered at its address is not taken up and the app gives
    /// up as on silence, saying what answered: another television, or the status of a device that is no
    /// television. A television that refuses its first ask as a television does -- asking for the registration,
    /// busy, in standby with its display off -- is the television, and is neither looked past nor given up on.
    func testWhatAnswersWhereTheTelevisionWasIsSaidWhenItIsNotFound() async {
        let page = ScalarError.http(status: 404, method: "getSystemSupportedFunction").explanation
        let strangers: [(String, any HTTPTransport, String)] = [
            ("another television", DemoTV(mac: Self.otherTV), TVDriver.anotherAnswered),
            ("a page on port 80", StubTransport(always: HTTPResponse(statusCode: 404)), page),
        ]
        for (what, stranger, line) in strangers {
            let world = LinkWorld()
            world.devices[Stub.host] = stranger
            world.near = [Stub.host, Self.nobodyHere]
            let link = makeTVLink(world)

            await link.connect()

            XCTAssertFalse(link.session.connected, what)
            XCTAssertTrue(link.session.gaveUp, what)
            XCTAssertEqual(world.count("search for television"), 1, what)
            XCTAssertEqual(world.problem, line, what)
        }

        let method = "getSystemSupportedFunction"
        let displayOff = HTTPResponse(statusCode: 200, body: Data(#"{"error":[40005,"display off"],"id":1}"#.utf8))
        let refusals: [(String, HTTPResponse, ScalarError)] = [
            ("asking for the registration", HTTPResponse(statusCode: 401), .http(status: 401, method: method)),
            ("busy", HTTPResponse(statusCode: 503), .http(status: 503, method: method)),
            ("its display off", displayOff, .rpc(method: method, version: "1.0", code: 40005, message: "display off")),
        ]
        for (what, answer, error) in refusals {
            let world = LinkWorld()
            world.devices[Stub.host] = StubTransport(always: answer)
            world.near = [Stub.host, Self.nobodyHere]
            let link = makeTVLink(world)

            await link.connect()

            XCTAssertFalse(link.session.gaveUp, "a television \(what) was given up on")
            XCTAssertFalse(link.session.unreachable, what)
            XCTAssertEqual((link.driver as? TVDriver)?.facts.needsPairing, error.failure == .needsPairing, what)
            XCTAssertEqual(world.problem, error.explanation, what)
            XCTAssertEqual(world.count("search for television"), 0, "a television \(what) was looked past")
        }
    }

    /// Nothing is looked for while the session does not know which television this is: one that gave no MAC
    /// when it was registered.
    func testNoLookForATelevisionNotKnownByItsMAC() async {
        let world = LinkWorld()
        let television = await registeredTelevision(at: Self.moved, in: world)
        world.near = [Self.moved]
        let link = makeTVLink(saved: nil, world)

        await link.connect()

        XCTAssertEqual(world.count("search for television"), 0)
        XCTAssertEqual(link.host, Stub.host)
        XCTAssertTrue(link.session.gaveUp)
        expectEqual(await television.calls, [])
    }

    /// Nor where the app gives nowhere to look: in the demo, in the background, on a Wi-Fi the address is not on.
    func testNoLookForATelevisionWithNowhereToLook() async {
        let world = LinkWorld()
        let television = await registeredTelevision(at: Self.moved, in: world)
        let link = makeTVLink(world)

        await link.connect()

        XCTAssertEqual(world.count("search for television"), 0)
        XCTAssertNil(world.line, "the strip said it was looking")
        XCTAssertEqual(link.host, Stub.host)
        XCTAssertTrue(link.session.gaveUp)
        expectEqual(await television.calls, [])
    }

    /// A connect looks once, and a second time only when the network changed under its first attempt, which it
    /// then makes again; the check before an operation never looks elsewhere.
    func testATelevisionIsLookedForOncePerAttemptAndNeverByTheCheck() async {
        let world = LinkWorld()
        world.devices[Self.nobodyHere] = StubTransport { _, _ in
            await MainActor.run { world.network = "another" }
            throw RecorderError.transport("Nothing is here.")
        }
        world.near = [Self.nobodyHere]
        let link = makeTVLink(world)

        await link.connect()

        XCTAssertEqual(world.count("search for television"), 2, "not looked for again on the network it moved to")
        XCTAssertTrue(link.session.gaveUp)

        let checked = LinkWorld()
        let television = await registeredTelevision(in: checked)
        let checking = makeTVLink(checked)
        await checking.connect()
        XCTAssertTrue(checking.session.connected)
        await television.goSilent()
        _ = await registeredTelevision(at: Self.moved, in: checked)
        checked.near = [Self.moved]

        let up = await checking.ensureUp(evenIfRecent: true)

        XCTAssertFalse(up)
        XCTAssertEqual(checked.count("search for television"), 0)
        XCTAssertEqual(checking.host, Stub.host)
        XCTAssertTrue(checking.session.gaveUp)
    }

    /// A look that found nothing is not made again on the same network, whatever brings the next connect, until
    /// the television has said it is the one saved: a television silent in standby would otherwise cost a look
    /// through the subnet at every launch, return and pull. Once it has answered, its next silence is looked
    /// past again; and another network is looked on afresh.
    func testALookThatFoundNothingIsNotMadeAgainOnTheSameNetwork() async {
        let world = LinkWorld()
        let television = await registeredTelevision(in: world)
        await television.goSilent()
        world.near = [Self.nobodyHere]
        let link = makeTVLink(world)

        await link.connect()
        await link.connect()
        XCTAssertEqual(world.count("search for television"), 1, "looked again on a network that had nothing")

        await television.goSilent(false)
        await link.connect()
        XCTAssertTrue(link.session.connected)
        await television.goSilent()
        await link.connect()
        await link.connect()
        XCTAssertEqual(world.count("search for television"), 2, "not looked for after it answered and went silent")

        world.network = "another"
        await link.connect()
        XCTAssertEqual(world.count("search for television"), 3, "not looked for on another network")
        XCTAssertEqual(world.count("packet"), 0)
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") || $0.hasPrefix("setPowerStatus") })
    }

    /// What makes a look worth making again is the television saying it is the one saved, which it does before
    /// anything needs the registration: one that then turns the cookie down has still said it, and its next
    /// silence is looked past.
    func testALookIsMadeAgainOnceTheTelevisionSaidWhichItIsThoughItWantsTheRegistration() async {
        let world = LinkWorld()
        let television = DemoTV()   // knows no cookie of the app's
        world.devices[Stub.host] = television
        await television.goSilent()
        world.near = [Self.nobodyHere]
        let link = makeTVLink(world)
        await link.connect()
        XCTAssertEqual(world.count("search for television"), 1)

        await television.goSilent(false)
        await link.connect()
        XCTAssertEqual((link.driver as? TVDriver)?.facts.needsPairing, true)
        XCTAssertEqual(world.count("search for television"), 1)

        await television.goSilent()
        await link.connect()

        XCTAssertEqual(world.count("search for television"), 2, "not looked for after it said which it is")
    }

    /// An address as a router hands it out: what is behind it now answers each request, to a client made before
    /// the change as well.
    private actor Address: HTTPTransport {
        private var device: any HTTPTransport

        init(_ device: any HTTPTransport) { self.device = device }

        func handTo(_ device: any HTTPTransport) { self.device = device }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse { try await device.send(request) }
    }

    /// The address changing hands while the app is connected, and the phone then joining another Wi-Fi with the
    /// same subnet: the check that follows asks which television answers, and reads another television -- one
    /// that would take the very cookie -- or a device that is no television as something else in its place. The
    /// host is told, the app is not connected to it and not given up on, and nothing that needs the registration
    /// is asked from then on: the next operation is refused, and its check too. What answered heard which
    /// television it is and nothing else, never the cookie.
    func testTheCookieGoesToNothingThatTookTheAddressWhileConnected() async {
        let other = DemoTV(mac: Self.otherTV)
        await other.knows("BDBridge:test", cookie: "kept")
        let strangers: [(String, any HTTPTransport)] = [
            ("another television", other),
            ("a page on port 80", StubTransport(always: HTTPResponse(statusCode: 404))),
        ]
        for (what, stranger) in strangers {
            let world = LinkWorld()
            let address = Address(await registeredTelevision(at: nil, in: world))
            world.devices[Stub.host] = address
            let link = makeTVLink(world)
            let driver = link.driver as? TVDriver
            await link.connect()
            XCTAssertEqual(driver?.canBeAsked, true, what)

            let heard = StubTransport { request, _ in try await stranger.send(request) }
            await address.handTo(heard)
            world.network = "another"
            world.events = []
            await link.networkChangedWhileOpen()

            XCTAssertEqual(world.count("another device on the check"), 1, "\(what): the host was not told")
            XCTAssertEqual(driver?.canBeAsked, false, what)
            XCTAssertFalse(link.session.connected, what)
            XCTAssertFalse(link.session.gaveUp, "\(what) was given up on as silence")
            expectNil(await driver?.reservations(), "\(what): the list was read")
            let up = await link.ensureUp(evenIfRecent: true)
            XCTAssertFalse(up, "\(what): the next check let the operation through")
            let asked = await heard.requests
            XCTAssertFalse(asked.isEmpty, "\(what) was not asked which television it is")
            XCTAssertTrue(onlyAskedWhichItIs(asked), "\(what) was asked more than which television it is")
        }
    }

    // MARK: - letting go

    /// A link goes when the app lets go of it, though its driver is kept: the link holds the driver, and the
    /// driver holds its link only as long as something else does. Held both ways neither would ever go, and a
    /// recorder taken out of the app would leave its link behind with its client and its session.
    func testALinkLetGoOfGoesThoughItsDriverIsKept() async {
        let world = LinkWorld()
        place(in: world)
        let driver: any LinkDriver
        weak var link: DeviceLink?
        do {
            let made = makeLink(world)
            await made.connect()
            XCTAssertTrue(made.session.connected)
            XCTAssertTrue(made.driver is RecorderDriver)
            XCTAssertTrue(made.driver.link === made, "the driver was not told whose it is")
            driver = made.driver
            link = made
        }

        XCTAssertNil(link, "the driver keeps its link")
        XCTAssertNil(driver.link)
    }
}
