import Foundation
import XCTest
@testable import RecorderKit

/// The parts an operation asked of a device is made of, on its link. The check before it says why the device
/// is not to be asked, and not only that it is not: held here for each way a check can end, with what the
/// host was told on the way and the line it was left with. The host is the world's (`LinkWorld`), which only
/// puts down what it is told, so that what the check answers is seen not to lean on what a host does about it.
@MainActor
final class LinkPartsTests: XCTestCase {
    /// The recorder that takes the place of the one known, in the tests where one does.
    static let another = "uuid:00000000-0000-0000-0000-f84e17000002"
    /// A line an earlier failure left on the screen.
    static let left = "left by the request before"

    /// A link to the recorder at `Stub.host`, woken by `mac` when there is one, whose waking gives up after a
    /// twentieth of a second and whose client sends again at once what was answered 503.
    private func makeLink(mac: String? = nil, _ world: LinkWorld) -> DeviceLink {
        let link = DeviceLink(host: Stub.host, session: SessionState(mac: mac),
                              driver: RecorderDriver(holdingTheQueueWith: "held", wakingLimit: 0.05,
                                                     wakingInterval: .milliseconds(10), busyRetryDelay: 0...0),
                              environment: world.environment)
        link.owner = world
        return link
    }

    /// Puts a recorder that can be told what to answer at `Stub.host`.
    private func place(in world: LinkWorld) throws -> ScriptedRecorder {
        let recorder = try ScriptedRecorder(at: Stub.host, udn: DeviceLinkTests.udn, world: world)
        world.devices[Stub.host] = recorder
        return recorder
    }

    /// A link connected to such a recorder a moment ago, with what the connect put down taken away.
    private func connected(mac: String? = nil) async throws -> (LinkWorld, ScriptedRecorder, DeviceLink) {
        let world = LinkWorld()
        let recorder = try place(in: world)
        let link = makeLink(mac: mac, world)
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        world.events = []
        return (world, recorder, link)
    }

    // MARK: - the check, and why

    /// A device that answers the check, or is not asked at all. With no client there is nothing to ask with,
    /// and the host says that the app is not connected. One that answered a moment ago is up without being
    /// asked, and is asked when its last answer is to count for nothing. Busy is an answer: the device is up,
    /// and what is wrong is for the request itself to say, so the line is left alone. Another device where
    /// the one known was is not up for what was asked: the host is told, once for each check, and the reason
    /// is what the check heard -- this host does nothing about it, and the client is still in hand. The Bool
    /// says the same each time.
    func testTheCheckSaysWhetherADeviceThatAnswersIsToBeAsked() async throws {
        let world = LinkWorld()
        let recorder = try place(in: world)
        let link = makeLink(world)

        expectEqual(await link.check().whyNot, .notConnected)
        XCTAssertEqual(world.problem, LinkWorld.notConnected)
        world.problem = nil
        expectFalse(await link.ensureUp())
        XCTAssertEqual(world.problem, LinkWorld.notConnected)
        XCTAssertEqual(world.count("ask"), 0, "asked with no client")

        await link.connect()
        let client = try XCTUnwrap(link.client)
        world.events = []
        expectTrue(await link.check().client === client)
        expectTrue(await link.ensureUp())
        XCTAssertEqual(world.count("ask"), 0, "a recorder that has just answered was made sure of")

        expectTrue(await link.check(evenIfRecent: true).client === client)
        XCTAssertEqual(world.count("ask description.xml"), 1)
        expectTrue(await link.ensureUp(evenIfRecent: true))
        XCTAssertEqual(world.count("ask description.xml"), 2)

        await recorder.answer(.busy)
        world.problem = Self.left
        expectTrue(await link.check(evenIfRecent: true).client === client, "a busy recorder is not up")
        expectTrue(await link.ensureUp(evenIfRecent: true))
        XCTAssertEqual(world.problem, Self.left)
        XCTAssertFalse(link.session.unreachable)

        await recorder.answer(.itself)
        await recorder.become(Self.another)
        expectEqual(await link.check(evenIfRecent: true).whyNot, .anotherAnswered)
        XCTAssertEqual(world.count("another device on the check"), 1)
        XCTAssertTrue(link.client === client, "this host lets go of nothing")
        expectFalse(await link.ensureUp(evenIfRecent: true))
        XCTAssertEqual(world.count("another device on the check"), 2)
    }

    /// Silence, and nothing to ask afterwards. With nothing to wake the device with, the link is lost and the
    /// line is the driver's own, there having been no waking to say one. With a MAC the waking runs out and
    /// says so itself, and that sentence is not written over. When the local network permission is why, the
    /// device is not woken behind it: the host waits for the permission, and the line an earlier failure left
    /// is taken away, since the screens say this one from the session.
    func testTheCheckSaysWhySilenceLeftNothingToAsk() async throws {
        var (world, recorder, link) = try await connected()
        await recorder.answer(.silence)
        expectEqual(await link.check(evenIfRecent: true).whyNot, .silent)
        XCTAssertTrue(link.session.unreachable)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertEqual(world.problem, link.driver.noAnswerLine)

        (world, recorder, link) = try await connected(mac: DeviceLinkTests.mac)
        await recorder.answer(.silence)
        expectEqual(await link.check(evenIfRecent: true).whyNot, .silent)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertGreaterThan(world.count("ask description.xml"), 1, "not woken")
        XCTAssertEqual(world.problem, DeviceLinkTests.noAnswer)
        XCTAssertNotEqual(link.driver.noAnswerLine, DeviceLinkTests.noAnswer, "the two sentences are one")

        (world, recorder, link) = try await connected(mac: DeviceLinkTests.mac)
        await recorder.answer(.silence)
        world.blocked = true
        world.problem = Self.left
        expectEqual(await link.check(evenIfRecent: true).whyNot, .waitingForPermission)
        XCTAssertEqual(world.count("ask description.xml"), 1, "woken behind a permission that stops every ask")
        XCTAssertEqual(world.waitingAt, Stub.host)
        XCTAssertTrue(link.session.connectBlocked)
        XCTAssertNil(world.problem)
    }

    /// Silent to the probe, and woken. The same device is up, to be asked with the client the check began
    /// with. Another one has described itself in the waking's attach, so the host hears that first and then
    /// that it answered the check, and it is not up for what was asked. One that answers the waking and is
    /// busy when the attach asks who it is has turned the attach away: it is there -- neither connected nor
    /// unreachable, and not given up on -- and the line is the attach's.
    func testTheCheckSaysWhatAWakingCameTo() async throws {
        var (world, recorder, link) = try await connected(mac: DeviceLinkTests.mac)
        let began = try XCTUnwrap(link.client)
        await recorder.answerNext(.silence)
        expectTrue(await link.check(evenIfRecent: true).client === began)
        XCTAssertGreaterThan(world.count("packet"), 1, "not woken")
        XCTAssertTrue(link.session.connected)
        XCTAssertFalse(link.session.unreachable)

        (world, recorder, link) = try await connected(mac: DeviceLinkTests.mac)
        await recorder.become(Self.another)
        await recorder.answerNext(.silence)
        expectEqual(await link.check(evenIfRecent: true).whyNot, .anotherAnswered)
        XCTAssertEqual(world.events.filter { $0.hasPrefix("another device") },
                       ["another device", "another device on the check"])

        (world, recorder, link) = try await connected(mac: DeviceLinkTests.mac)
        // The probe, the waking's ask, and the attach's with the two tries a client makes after a 503.
        await recorder.answerNext(.silence, .itself, .busy, .busy, .busy)
        expectEqual(await link.check(evenIfRecent: true).whyNot, .turnedAway)
        XCTAssertEqual(world.count("ask description.xml"), 5)
        XCTAssertFalse(link.session.connected)
        XCTAssertFalse(link.session.unreachable)
        XCTAssertFalse(link.session.gaveUp)
        XCTAssertEqual(world.problem, RecorderError.busy(action: "description.xml").explanation)
    }
}

private extension LinkCheck {
    /// The client to ask, or nil when the device is not up.
    var client: (any LinkClient)? {
        if case .up(let client) = self { client } else { nil }
    }
}

/// A recorder at one address that says who it is as the test tells it to, an ask at a time: under a UDN that
/// can be changed, with nothing or with a 503 in place of its description. It says who it is as the recorder
/// of the vectors does and refuses the rest, which an attach does without. Each ask is put down in the world.
actor ScriptedRecorder: HTTPTransport {
    /// What an ask of who it is gets: its description, nothing at all, or a 503.
    enum Answer: Sendable {
        case itself, silence, busy
    }

    private let host: String
    private var description: String
    private var always = Answer.itself
    private var next: [Answer] = []
    private weak var world: LinkWorld?

    init(at host: String, udn: String, world: LinkWorld) throws {
        self.host = host
        self.world = world
        description = try Vectors.descriptionXML(udn: udn)
    }

    /// Says from now on that it is the recorder with this UDN.
    func become(_ udn: String) {
        description = (try? Vectors.descriptionXML(udn: udn)) ?? ""
    }

    /// What every ask of who it is gets from now on.
    func answer(_ answer: Answer) {
        always = answer
        next = []
    }

    /// What the next asks of who it is get, one each and in this order, before the rest get what they did.
    func answerNext(_ answers: Answer...) { next = answers }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let asked = request.url.lastPathComponent
        await world?.put("ask \(asked) at \(host)")
        guard asked == "description.xml" else { return HTTPResponse(statusCode: 500) }
        switch next.isEmpty ? always : next.removeFirst() {
        case .itself: return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        case .silence: throw RecorderError.transport("The request timed out.")
        case .busy: return HTTPResponse(statusCode: 503)
        }
    }
}
