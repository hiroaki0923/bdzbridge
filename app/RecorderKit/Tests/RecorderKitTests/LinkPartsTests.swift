import Foundation
import XCTest
@testable import RecorderKit

/// The parts an operation asked of a device is made of, on its link. The check before it says why the device
/// is not to be asked, and not only that it is not: held here for each way a check can end, with what the
/// host was told on the way and the line it was left with. And an operation run through the link says how it
/// failed, having put the failure on the line and left the link where that failure leaves it. The host is the
/// world's (`LinkWorld`), which only puts down what it is told, so that what the check answers is seen not to
/// lean on what a host does about it.
@MainActor
final class LinkPartsTests: XCTestCase {
    /// The recorder that takes the place of the one known, in the tests where one does.
    static let another = "uuid:00000000-0000-0000-0000-f84e17000002"
    /// A line an earlier failure left on the screen.
    static let left = "left by the request before"
    /// What an operation gives to be said if what it sends meets silence.
    static let mayHaveArrived = "it may have arrived"

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

    /// Whatever is asked for while a check is out waits for that check and is given its reason: not one of
    /// its own making, and not a bare no. The probe is held while two more checks and the Bool are asked for
    /// -- each of which, asked alone, would find a recorder that answered a moment ago -- and is then answered
    /// by another device. One ask went out for the four, and the host was told once.
    func testWhateverJoinsACheckIsGivenItsReason() async throws {
        let (world, recorder, link) = try await connected()
        await recorder.hold()
        let first = Task { await link.check(evenIfRecent: true) }
        await recorder.whenHeld()
        XCTAssertNotNil(link.wakeCheck)

        let joined = Begun()
        let second = Task {
            joined.note()
            return await link.check()
        }
        let third = Task {
            joined.note()
            return await link.check()
        }
        let asBool = Task {
            joined.note()
            return await link.ensureUp()
        }
        await joined.wait(for: 3)
        await recorder.become(Self.another)
        await recorder.letGo()

        expectEqual(await first.value.whyNot, .anotherAnswered)
        expectEqual(await second.value.whyNot, .anotherAnswered)
        expectEqual(await third.value.whyNot, .anotherAnswered)
        expectFalse(await asBool.value)
        XCTAssertEqual(world.count("ask description.xml"), 1)
        XCTAssertEqual(world.count("another device on the check"), 1)
        XCTAssertNil(link.wakeCheck)
    }

    /// A check asked for from inside a connect -- by the host, as it reads its lists once the device has been
    /// reached -- answers at once that the device is up, with the connect's client, and asks nothing: the
    /// connect is the making sure. Whatever the time since the last answer is to count for.
    func testACheckAskedFromInsideAConnectAsksNothing() async throws {
        let world = LinkWorld()
        _ = try place(in: world)
        let link = makeLink(world)
        var inside: (client: (any LinkClient)?, found: LinkCheck?, connecting: Bool)?
        world.onReached = {
            inside = (link.client, await link.check(evenIfRecent: true), link.session.connecting)
        }

        await link.connect()

        let seen = try XCTUnwrap(inside, "the host was not told the connect reached the recorder")
        XCTAssertTrue(seen.connecting)
        XCTAssertNotNil(seen.client)
        XCTAssertTrue(seen.found?.client === seen.client)
        XCTAssertEqual(world.count("ask description.xml"), 1)
    }

    // MARK: - an operation through the link

    /// One thing asked through the link, the work a closure of the test's. Going through, it hands back what
    /// the work returned: the work ran under the line with its token and with the client made sure of, the
    /// line an earlier failure left was still up while it ran and is cleared afterwards. A device that
    /// answers, if only that it is busy, is kept and said in its own words, whatever was given to say for
    /// silence; an error that is no device's is said as Swift describes it. Silence on a read loses the
    /// device and says that error's own sentence, which for an answer that was not HTTP is not the driver's
    /// line for no answer; silence on what changes the device says the sentence the operation gave. Not
    /// connected, the work is not run and nothing is written but the host's sentence.
    ///
    /// Whether a read's silence is taken at all is the device's rule. A recorder's always is: one that
    /// answered a connect without saying which it is is not connected, and its silence still loses it and is
    /// said. A television's is while its session is connected; once another device has answered there, a
    /// read still out that meets silence touches neither the link nor the line. The rule is for reads only:
    /// what was sent to that television and met silence may have arrived, and is said and loses it.
    func testAnOperationThroughTheLinkSaysHowItFailed() async throws {
        var (world, recorder, link) = try await connected()
        let client = try XCTUnwrap(link.client)
        world.problem = Self.left
        let went = await link.run(line: "reading") { asked in
            XCTAssertTrue(asked === client)
            world.put("under \(world.line ?? "no line"), \(world.problem ?? "nothing wrong")")
            return 7
        }
        XCTAssertEqual(went, .success(7))
        XCTAssertEqual(world.events, ["under reading, \(Self.left)"])
        XCTAssertNil(world.line)
        XCTAssertNil(world.problem)

        let busy = RecorderError.busy(action: "X_DeleteTitle")
        var failed = await link.run(sending: Self.mayHaveArrived) { _ -> Int in
            XCTAssertNil(world.line, "a line of its own, though none was asked for")
            throw busy
        }
        XCTAssertEqual(failed, .failure(.refused(.busy, sentence: busy.explanation)))
        XCTAssertEqual(world.problem, busy.explanation)
        XCTAssertTrue(link.session.connected)
        XCTAssertFalse(link.session.gaveUp)

        failed = await link.run { _ -> Int in throw NotADevices() }
        XCTAssertEqual(failed, .failure(.refused(nil, sentence: "NotADevices()")))
        XCTAssertEqual(world.problem, "NotADevices()")
        XCTAssertTrue(link.session.connected)

        for silence in [RecorderError.transport("The request timed out."), .notHTTP] {
            await link.connect()
            XCTAssertTrue(link.session.connected)
            failed = await link.run { _ -> Int in throw silence }
            XCTAssertEqual(failed, .failure(.silentOnARead(sentence: silence.explanation)))
            XCTAssertEqual(world.problem, silence.explanation)
            XCTAssertTrue(link.session.unreachable, "\(silence)")
            XCTAssertTrue(link.session.gaveUp, "\(silence)")
        }
        XCTAssertNotEqual(RecorderError.notHTTP.explanation, link.driver.noAnswerLine, "the two sentences are one")

        await link.connect()
        failed = await link.run(sending: Self.mayHaveArrived) { _ -> Int in throw RecorderError.notHTTP }
        XCTAssertEqual(failed, .failure(.silentAfterSending(sentence: Self.mayHaveArrived)))
        XCTAssertEqual(world.problem, Self.mayHaveArrived)
        XCTAssertTrue(link.session.gaveUp)

        var ran = false
        failed = await link.run(line: "reading") { _ -> Int in
            ran = true
            return 0
        }
        XCTAssertEqual(failed, .failure(.notSent(.notConnected)))
        XCTAssertFalse(ran, "the work was run after a check that said no")
        XCTAssertEqual(world.problem, LinkWorld.notConnected)
        XCTAssertNil(world.line)

        world = LinkWorld()
        recorder = try place(in: world)
        await recorder.answer(.busy)
        link = makeLink(world)
        await link.connect()
        XCTAssertFalse(link.session.connected)
        XCTAssertFalse(link.session.unreachable)
        failed = await link.run { _ -> Int in throw RecorderError.notHTTP }
        XCTAssertEqual(failed, .failure(.silentOnARead(sentence: RecorderError.notHTTP.explanation)))
        XCTAssertTrue(link.session.gaveUp, "a recorder's silence was not taken for want of a description")
        XCTAssertEqual(world.problem, RecorderError.notHTTP.explanation)

        let noAnswer = ScalarError.transport("The request timed out.")
        (world, link) = await attachedToATelevision()
        failed = await link.run { _ -> Int in throw noAnswer }
        XCTAssertEqual(failed, .failure(.silentOnARead(sentence: noAnswer.explanation)))
        XCTAssertEqual(world.problem, noAnswer.explanation)
        XCTAssertTrue(link.session.gaveUp)

        (world, link) = await attachedToATelevision()
        link.session.strangerAnswered()
        world.problem = Self.left
        failed = await link.run { _ -> Int in throw noAnswer }
        XCTAssertEqual(failed, .failure(.silentOnARead(sentence: noAnswer.explanation)))
        XCTAssertFalse(link.session.unreachable)
        XCTAssertFalse(link.session.gaveUp)
        XCTAssertEqual(world.problem, Self.left)

        failed = await link.run(sending: Self.mayHaveArrived) { _ -> Int in throw noAnswer }
        XCTAssertEqual(failed, .failure(.silentAfterSending(sentence: Self.mayHaveArrived)))
        XCTAssertTrue(link.session.gaveUp, "silence on what was sent was left to the rule for a read")
        XCTAssertEqual(world.problem, Self.mayHaveArrived)
    }

    /// An error that is no device's.
    private struct NotADevices: Error {}

    /// A link to an invented television at `Stub.host`, registered with it and attached a moment ago.
    private func attachedToATelevision() async -> (LinkWorld, DeviceLink) {
        let world = LinkWorld()
        let television = DemoTV()
        await television.knows("BDBridge:test", cookie: "kept")
        world.devices[Stub.host] = television
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date(), cookieMaxAge: 1_209_600))
        let link = DeviceLink(host: Stub.host, session: SessionState(),
                              driver: TVDriver(credentials: credentials, nickname: "BD Bridge", inFront: { false }),
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(link.session.connected, world.problem ?? "no reason given")
        return (world, link)
    }
}

/// Counts the tasks a test set going that have begun, for the test to wait on rather than on a clock. A task
/// notes itself and goes on in the same turn, so by the time the test is back what was counted has got as far
/// as its first wait.
@MainActor
private final class Begun {
    private var count = 0
    private var waiting: (for: Int, test: CheckedContinuation<Void, Never>)?

    func note() {
        count += 1
        guard let waiting, count >= waiting.for else { return }
        self.waiting = nil
        waiting.test.resume()
    }

    func wait(for count: Int) async {
        guard self.count < count else { return }
        await withCheckedContinuation { waiting = (count, $0) }
    }
}

private extension LinkCheck {
    /// The client to ask, or nil when the device is not up.
    var client: (any LinkClient)? {
        if case .up(let client) = self { client } else { nil }
    }

    /// Why not, or nil when the device is up.
    var whyNot: NotUp? {
        if case .notUp(let why) = self { why } else { nil }
    }
}

/// A recorder at one address that says who it is as the test tells it to, an ask at a time: under a UDN that
/// can be changed, with nothing or with a 503 in place of its description, or not until the test lets the ask
/// go. It says who it is as the recorder of the vectors does and refuses the rest, which an attach does
/// without -- unless it has been given reservations to keep (`keep`), which then answer what is asked of them
/// and of the guide. Each ask is put down in the world.
actor ScriptedRecorder: HTTPTransport {
    /// What an ask of who it is gets: its description, nothing at all, or a 503.
    enum Answer: Sendable {
        case itself, silence, busy
    }

    private let host: String
    private var description: String
    private var always = Answer.itself
    private var next: [Answer] = []
    private var holdsTheNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var watching: CheckedContinuation<Void, Never>?
    private weak var world: LinkWorld?
    /// The reservations it keeps, and the guide it serves beside them, once a test has given it some.
    private var reservations: RecorderReservations?

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

    /// The next ask of who it is gets no answer until `letGo`, and then whatever it would get by then.
    func hold() { holdsTheNext = true }

    /// Returns once an ask is being held.
    func whenHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { watching = $0 }
    }

    func letGo() {
        held?.resume()
        held = nil
    }

    /// Answers from `reservations` from now on whatever is not an ask of who it is.
    func keep(_ reservations: RecorderReservations) {
        self.reservations = reservations
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let asked = request.url.lastPathComponent
        await world?.put("ask \(asked) at \(host)")
        guard asked == "description.xml" else {
            return try await reservations?.answer(request) ?? HTTPResponse(statusCode: 500)
        }
        if holdsTheNext {
            holdsTheNext = false
            await withCheckedContinuation { ask in
                held = ask
                watching?.resume()
                watching = nil
            }
        }
        switch next.isEmpty ? always : next.removeFirst() {
        case .itself: return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        case .silence: throw RecorderError.transport("The request timed out.")
        case .busy: return HTTPResponse(statusCode: 503)
        }
    }
}
