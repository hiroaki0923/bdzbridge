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
