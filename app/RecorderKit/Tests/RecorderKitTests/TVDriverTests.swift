import Foundation
import XCTest
@testable import RecorderKit

/// A television on a link: attached without being woken, told from another by the MAC it wakes on, asked for a
/// registration when it has none that works, and given a new cookie when the one in hand is past half its life.
/// And what is asked of it after the attach, through its driver: its reservations read, and one deleted.
@MainActor
final class TVDriverTests: XCTestCase {
    /// A link to `television` at `Stub.host`, its driver keeping `credentials`, with the MAC `saved` at the last
    /// launch and the app in front unless `inFront` is false.
    private func makeLink(_ television: DemoTV, _ credentials: MemoryTVCredentials, saved: String? = nil,
                          inFront: Bool = true) -> (DeviceLink, TVDriver, LinkWorld) {
        let world = LinkWorld()
        world.devices[Stub.host] = television
        let driver = TVDriver(credentials: credentials, nickname: "BD Bridge", inFront: { inFront })
        let link = DeviceLink(host: Stub.host, session: SessionState(device: saved), driver: driver,
                              environment: world.environment)
        link.owner = world
        return (link, driver, world)
    }

    /// Credentials the television knows, with a cookie received `daysAgo`.
    private func registered(with television: DemoTV, daysAgo: Double = 1) async -> MemoryTVCredentials {
        await television.knows("BDBridge:test", cookie: "kept")
        return MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                 cookieReceived: Date().addingTimeInterval(-daysAgo * 86_400),
                                                 cookieMaxAge: 1_209_600))
    }

    /// A registered television is attached as it is, in standby: it says which one it is, its model and its disk,
    /// what waits is sent, and nothing wakes it. A cookie a day old is not renewed. The address and the MAC are
    /// written down.
    func testARegisteredTelevisionIsAttachedWithoutBeingWoken() async {
        let television = DemoTV()
        let (link, driver, world) = makeLink(television, await registered(with: television))

        await link.connect()

        XCTAssertTrue(link.session.connected)
        XCTAssertEqual(link.session.timesAttached, 1)
        XCTAssertEqual(driver.facts.model, DemoTV.model)
        XCTAssertEqual(driver.facts.storage, TVStorage(mounted: true, freeMB: 400, totalMB: 1000))
        XCTAssertFalse(driver.facts.needsPairing)
        XCTAssertEqual(world.events, ["address \(Stub.host)", "MAC \(DemoTV.mac)", "send what waits", "reached"])
        let calls = await television.calls
        XCTAssertEqual(calls, ["getSystemSupportedFunction cookie=no pin=no", "getInterfaceInformation cookie=no pin=no",
                               "getStorageList cookie=yes pin=no"])
    }

    /// Without a registration it answers, so it is there and not given up on; but nothing that needs one is sent,
    /// and the screens are told a PIN is wanted.
    func testWithNoRegistrationItIsThereButAsksForOne() async {
        let television = DemoTV()
        let (link, driver, world) = makeLink(television, MemoryTVCredentials())

        await link.connect()

        XCTAssertTrue(driver.facts.needsPairing)
        XCTAssertEqual(link.session.timesAttached, 0)
        XCTAssertFalse(link.session.gaveUp)
        XCTAssertFalse(link.session.unreachable)
        XCTAssertEqual(world.problem, ScalarError.notRegistered.explanation)
        XCTAssertFalse(world.events.contains("send what waits"))
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("getStorageList") }, "asked without a registration")
    }

    /// A cookie the television no longer takes wants the registration again: the same, after one ask.
    func testARefusedCookieAsksForTheRegistrationAgain() async {
        let television = DemoTV()
        let (link, driver, _) = makeLink(television, MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "stale")))

        await link.connect()

        XCTAssertTrue(driver.facts.needsPairing)
        XCTAssertFalse(link.session.gaveUp)
        let calls = await television.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("getStorageList") }.count, 1)
        XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") }, "the app registered by itself")
    }

    /// A request refused for want of a registration after the attach puts that down at once, so that the
    /// screens ask for the registration without waiting for a connect; the next attach that goes through takes
    /// it back.
    func testARefusalAfterTheAttachAsksForTheRegistrationAtOnce() async {
        let bench = await attached()
        let known = try? XCTUnwrap(bench.credentials.load())
        XCTAssertFalse(bench.driver.facts.needsPairing)

        bench.credentials.save(Self.stale)
        _ = await bench.driver.reservations(on: bench.link)
        XCTAssertTrue(bench.driver.facts.needsPairing)

        if let known { bench.credentials.save(known) }
        await bench.link.connect()
        XCTAssertFalse(bench.driver.facts.needsPairing)
    }

    /// Nothing that needs the registration is asked while a connect is under way: the client it made has yet to
    /// hear which television answers and whether the cookie is taken, though the session still says what the
    /// last connect found -- and the last client is still about, for whatever holds it. A read asked for
    /// meanwhile returns in silence, so another television at the address is sent no cookie and is not said to
    /// want a registration; and it is not asked afterwards either.
    func testNothingIsAskedOnTheStrengthOfTheLastConnect() async {
        let bench = await attached()
        let last = bench.link.client
        XCTAssertTrue(bench.driver.canBeAsked(bench.link))
        await bench.television.becomeAnother(mac: "f8:4e:17:00:00:0b")
        let before = await bench.gate.asked.count
        await bench.gate.before("getSystemSupportedFunction") { @MainActor in
            bench.world.put(bench.driver.canBeAsked(bench.link) ? "asked meanwhile" : "not asked meanwhile")
        }

        await bench.link.connect()
        let list = await bench.driver.reservations(on: bench.link)

        XCTAssertEqual(bench.world.events.last, "not asked meanwhile")
        XCTAssertNil(list)
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), ["getSystemSupportedFunction"])
        XCTAssertFalse(bench.driver.facts.needsPairing)
        XCTAssertEqual(bench.world.problem, TVDriver.anotherAnswered)
        withExtendedLifetime(last) {}
    }

    /// The list is read from inside the connect that reached the television, where the host is told so: the
    /// read asks at once, without making sure of a television that has just answered.
    func testTheListIsReadFromInsideTheConnectThatReachedIt() async {
        let television = DemoTV()
        await television.put([Self.drama, Self.weather])
        let (link, driver, world) = makeLink(television, await registered(with: television))
        world.onReached = {
            let list = await driver.reservations(on: link)
            world.put("read \(list?.count ?? -1)")
        }

        await link.connect()

        XCTAssertEqual(world.events.last, "read 2")
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("getPowerStatus") }, "made sure of inside its own connect")
    }

    /// A cookie past half its life is renewed by a connect, after the read that shows the registration is
    /// there, with nothing on the request: the cookie in hand stays good, and the new one is kept. Only with the
    /// app in front.
    func testACookiePastHalfItsLifeIsRenewedWithNothingOnIt() async throws {
        let television = DemoTV()
        let credentials = await registered(with: television, daysAgo: 8)
        let (behind, _, _) = makeLink(television, credentials, inFront: false)
        await behind.connect()
        XCTAssertTrue(behind.session.connected)
        let asked = await television.calls
        XCTAssertFalse(asked.contains { $0.hasPrefix("actRegister") }, "renewed with the app behind")

        let (link, _, _) = makeLink(television, credentials)
        await link.connect()

        XCTAssertTrue(link.session.connected)
        let calls = await television.calls
        XCTAssertEqual(Array(calls.suffix(2)), ["getStorageList cookie=yes pin=no", "actRegister cookie=no pin=no"])
        let kept = try XCTUnwrap(credentials.load())
        XCTAssertNotEqual(kept.cookie, "kept")
        XCTAssertFalse(kept.renewalDue(now: Date()))
    }

    /// Another television at the address is not taken up: its cookie would not do, and what waits was made for
    /// the one registered. Nothing that needs a registration is sent to it, and its MAC is not written down --
    /// after the one registered has answered, and from the first answer after a launch, by the MAC saved.
    func testAnotherTelevisionAtTheAddressIsNotTakenUp() async {
        let television = DemoTV()
        let (link, _, world) = makeLink(television, await registered(with: television))
        await link.connect()
        XCTAssertTrue(link.session.connected)

        await television.becomeAnother(mac: "f8:4e:17:00:00:0b")
        let before = await television.calls.count
        await link.connect()

        XCTAssertFalse(link.session.connected)
        XCTAssertEqual(world.problem, TVDriver.anotherAnswered)
        let after = await television.calls.dropFirst(before)
        XCTAssertEqual(Array(after), ["getSystemSupportedFunction cookie=no pin=no"])

        let (launched, _, fresh) = makeLink(television, await registered(with: television), saved: DemoTV.mac)
        let beforeLaunch = await television.calls.count
        await launched.connect()

        XCTAssertFalse(launched.session.connected)
        XCTAssertEqual(fresh.problem, TVDriver.anotherAnswered)
        XCTAssertFalse(fresh.events.contains { $0.hasPrefix("MAC") }, "the other television's MAC was written down")
        let afterLaunch = await television.calls.dropFirst(beforeLaunch)
        XCTAssertEqual(Array(afterLaunch), ["getSystemSupportedFunction cookie=no pin=no"])
    }

    /// Silence is given up on at once: a television is not woken, nor looked for elsewhere.
    func testASilentTelevisionIsGivenUpWithoutWaking() async {
        let television = DemoTV()
        await television.goSilent()
        let (link, _, world) = makeLink(television, await registered(with: television))

        await link.connect()

        XCTAssertTrue(link.session.gaveUp)
        XCTAssertFalse(link.session.connected)
        XCTAssertEqual(world.count("packet"), 0, "a packet was sent to a television")
        XCTAssertEqual(world.count("search"), 0)
        let calls = await television.calls
        XCTAssertEqual(calls.count, 1, "asked again after silence")
    }

    /// The check before an operation asks whether it is on, and silence there is given up on as well.
    func testTheCheckBeforeAnOperationAsksWhetherItIsOn() async {
        let television = DemoTV()
        let (link, _, world) = makeLink(television, await registered(with: television))
        await link.connect()

        let up = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(up)
        let calls = await television.calls
        XCTAssertEqual(calls.last, "getPowerStatus cookie=no pin=no")

        await television.goSilent()
        let down = await link.ensureUp(evenIfRecent: true)
        XCTAssertFalse(down)
        XCTAssertTrue(link.session.gaveUp)
        XCTAssertEqual(world.count("packet"), 0)
    }

    // MARK: - its reservations, after the attach

    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_534_400)
    /// What the invented television holds here: a reservation that follows its programme, a reminder to watch
    /// that programme, and a newer reservation made by its times on another station.
    private nonisolated static let drama = DemoTV.Schedule(id: "recording.41", title: "サンプル劇場", start: start,
                                                           eventId: 12345)
    private nonisolated static let reminder = DemoTV.Schedule(id: "reminder.23", type: "reminder",
                                                              start: start.addingTimeInterval(-1), eventId: 12345)
    private nonisolated static let weather = DemoTV.Schedule(id: "recording.42", serviceID: 1032,
                                                             station: "サンプル放送", title: "サンプル天気",
                                                             start: start.addingTimeInterval(3600))
    /// A cookie the television never gave.
    private nonisolated static let stale = TVCredentials(clientID: "BDBridge:test", cookie: "stale")
    private static let read = "getScheduleList", delete = "deleteSchedule"
    private static let left = "前の操作の失敗"

    /// A television holding the three, a link connected to it, and between them a gate for what a test has
    /// happen on the way.
    private struct Bench: Sendable {
        let link: DeviceLink, driver: TVDriver, world: LinkWorld
        let television: DemoTV, gate: TVGate, credentials: MemoryTVCredentials
    }

    /// Connected with the cookie the television knows, or with `credentials`.
    private func attached(with credentials: MemoryTVCredentials? = nil) async -> Bench {
        let television = DemoTV()
        await television.put([Self.drama, Self.reminder, Self.weather])
        let known = await registered(with: television)
        let (link, driver, world) = makeLink(television, credentials ?? known)
        let gate = TVGate(television)
        world.devices[Stub.host] = gate
        await link.connect()
        return Bench(link: link, driver: driver, world: world, television: television, gate: gate,
                     credentials: credentials ?? known)
    }

    /// The drama as the app holds it, read before the television moved it a quarter of an hour and gave it
    /// another title: the row a cancel sends is to be the one it has just read, and not this.
    private func held() throws -> Reservation {
        var earlier = Self.drama
        earlier.start -= 900
        earlier.title = "サンプル劇場（仮）"
        return try XCTUnwrap(earlier.row.reservation())
    }

    /// Puts down which line is up as `method` reaches the television.
    private func noteTheLine(at method: String, on bench: Bench) async {
        await bench.gate.before(method) { @MainActor in
            bench.world.put("under \(bench.world.line ?? "no line")")
        }
    }

    /// The list as it is handed over: the television's rows as reservations in its order, the reminder left
    /// out. It is read under a line of its own, gone afterwards, and what an earlier failure left is cleared.
    func testTheReservationsAreReadThroughTheDriver() async {
        let bench = await attached()
        bench.world.problem = Self.left
        await noteTheLine(at: Self.read, on: bench)

        let list = await bench.driver.reservations(on: bench.link)

        XCTAssertEqual(list?.map(\.id), ["recording.42", "recording.41"])
        XCTAssertEqual(list, [Self.weather, Self.drama].compactMap { $0.row.reservation() })
        XCTAssertNil(bench.world.problem)
        XCTAssertEqual(bench.world.events.last, "under \(TVDriver.readingLine)")
        XCTAssertNil(bench.world.line)
    }

    /// Two reads asked for at once are one request: the second waits for the first and is given its answer.
    /// One asked for afterwards is a request of its own.
    func testAReadUnderWayIsWaitedForAndNotSentAgain() async {
        let bench = await attached()

        let first = Task { await bench.driver.reservations(on: bench.link) }
        let second = Task { await bench.driver.reservations(on: bench.link) }
        let lists = await [first.value, second.value]

        XCTAssertEqual(lists[0]?.count, 2)
        XCTAssertEqual(lists[0], lists[1])
        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, 1)
        _ = await bench.driver.reservations(on: bench.link)
        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, 2)
    }

    /// A television that cannot be asked -- its cookie refused at the attach, or silent since -- is sent
    /// nothing. A read says nothing either, so that what an earlier operation left on the line stays; a cancel
    /// says why: the registration that is wanted, or that the app is not connected.
    func testATelevisionThatCannotBeAskedIsSentNothing() async throws {
        let refused = await attached(with: MemoryTVCredentials(Self.stale))
        XCTAssertTrue(refused.link.session.connected)
        XCTAssertTrue(refused.driver.facts.needsPairing)
        let silent = await attached()
        XCTAssertTrue(silent.driver.canBeAsked(silent.link))
        await silent.television.goSilent()
        _ = await silent.link.ensureUp(evenIfRecent: true)
        await silent.television.goSilent(false)

        for (bench, why) in [(refused, ScalarError.notRegistered.explanation), (silent, LinkWorld.notConnected)] {
            XCTAssertFalse(bench.driver.canBeAsked(bench.link), why)
            bench.world.problem = Self.left
            let asked = await bench.gate.asked

            expectNil(await bench.driver.reservations(on: bench.link), why)
            XCTAssertEqual(bench.world.problem, Self.left, "a read that was not sent wrote over the line")
            let cancelled = await bench.driver.cancel(try held(), on: bench.link)

            XCTAssertFalse(cancelled.deleted, why)
            XCTAssertNil(cancelled.list, why)
            XCTAssertEqual(bench.world.problem, why)
            XCTAssertNil(bench.world.line)
            expectEqual(await bench.gate.asked, asked, "sent to a television that cannot be asked")
        }
    }

    /// A read that fails hands nothing back and says why. Refused for its cookie -- the app taken off the
    /// television's list since the attach -- it puts down that the registration is wanted, and the television
    /// is still there. Met with silence, it leaves the link as any silence does.
    func testAReadThatFailsSaysWhy() async {
        let refused = await attached()
        refused.credentials.save(Self.stale)
        expectNil(await refused.driver.reservations(on: refused.link))
        XCTAssertTrue(refused.driver.facts.needsPairing)
        XCTAssertTrue(refused.link.session.connected)
        XCTAssertEqual(refused.world.problem, ScalarError.notRegistered.explanation)
        XCTAssertNil(refused.world.line)

        let silent = await attached()
        await silent.gate.silence(Self.read)
        expectNil(await silent.driver.reservations(on: silent.link))
        XCTAssertFalse(silent.link.session.connected)
        XCTAssertTrue(silent.link.session.gaveUp)
        XCTAssertFalse(silent.driver.facts.needsPairing)
        XCTAssertEqual(silent.world.problem, silent.driver.noAnswerLine)
        XCTAssertNil(silent.world.line)
    }

    /// What a cancel came to: what it handed back, the line of what went wrong, what the television was sent
    /// for it in order, and where it left the link.
    private struct Outcome: Equatable {
        var deleted: Bool
        /// The ids in the list handed back, or nil when none was.
        var list: [String]?
        var problem: String?
        var sent: [String]
        var connected = true
        var needsPairing = false
    }

    /// Cancels the drama held on a bench of its own, once `arrange` has set up what happens on the way.
    private func cancel(after arrange: @MainActor (Bench) async -> Void) async throws -> (Outcome, Bench) {
        let bench = await attached()
        bench.world.problem = Self.left
        await arrange(bench)
        let before = await bench.gate.asked.count

        let cancelled = await bench.driver.cancel(try held(), on: bench.link)

        XCTAssertNil(bench.world.line, "a line was left up")
        let sent = Array(await bench.gate.asked.dropFirst(before))
        return (Outcome(deleted: cancelled.deleted, list: cancelled.list?.map(\.id), problem: bench.world.problem,
                        sent: sent, connected: bench.link.session.connected,
                        needsPairing: bench.driver.facts.needsPairing), bench)
    }

    /// A cancel reads the list, sends the row it has just read, once, and reads again: the reservation is off
    /// the television and out of the list handed back, and the line of what went wrong is cleared. The delete
    /// goes under its own line.
    func testACancelTakesTheReservationOffTheTelevision() async throws {
        let (outcome, bench) = try await cancel {
            await self.noteTheLine(at: Self.delete, on: $0)
            await self.noteTheLine(at: Self.read, on: $0)
        }

        XCTAssertEqual(outcome, Outcome(deleted: true, list: ["recording.42"], problem: nil,
                                        sent: [Self.read, Self.delete, Self.read]))
        XCTAssertEqual(bench.world.events.suffix(3), Array(repeating: "under \(TVDriver.deletingLine)", count: 3),
                       "the reads of a delete went under a line of their own")
        expectEqual(await bench.television.schedules, [Self.reminder, Self.weather])
    }

    /// Silence is said once. A read asked for while a delete is out waits its turn behind it, and when the
    /// delete has met silence that read meets it too: it leaves what the delete said -- that the delete may
    /// have arrived, which is all the reader has to go by -- where it is.
    func testARequestBehindTheOneThatMetSilenceAddsNothing() async throws {
        let bench = await attached()
        let behind = Behind()
        await bench.gate.before(Self.delete) { @MainActor in
            behind.read = Task { await bench.driver.reservations(on: bench.link) }
            await bench.gate.silence(Self.delete)
            await bench.gate.silence(Self.read)
        }
        let before = await bench.gate.asked.count

        let cancelled = await bench.driver.cancel(try held(), on: bench.link)
        let list = await behind.read?.value

        XCTAssertFalse(cancelled.deleted)
        XCTAssertNil(list)
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), [Self.read, Self.delete, Self.read])
        XCTAssertEqual(bench.world.problem, TVDriver.mayHaveArrived)
        XCTAssertFalse(bench.link.session.connected)
    }

    /// Holds the read a test sets going from inside a request, to be waited for afterwards.
    @MainActor
    private final class Behind {
        var read: Task<[Reservation]?, Never>?
    }

    /// What a cancel comes to with something in its way, each on a television of its own.
    ///
    /// A reservation no longer listed, or whose id is now another programme's, is not written to. Silence at
    /// the read before sends no delete, and is not said to be a delete that may have arrived; silence at the
    /// delete is, with nothing sent after it and the row kept in the list; silence at the read after a delete
    /// that went through still counts the delete, and the row is out of the list read before. A television
    /// that answers it has no such reservation is read again, and what is said goes by whether the row is
    /// still listed. A delete refused for its cookie puts down that the registration is wanted.
    func testWhatACancelComesToWithSomethingInItsWay() async throws {
        let read = Self.read, delete = Self.delete
        let both = ["recording.42", "recording.41"], later = ["recording.42"]
        let noAnswer = ScalarError.transport("no answer").explanation
        XCTAssertFalse(noAnswer.contains("届いている"))
        let another = DemoTV.Schedule(id: "recording.41", title: "サンプル劇場", start: Self.start, eventId: 12346)
        let retitled = DemoTV.Schedule(id: "recording.41", title: "サンプル劇場　拡大版", start: Self.start,
                                       eventId: 12345)
        func expect(_ name: String, _ expected: Outcome, line: UInt = #line,
                    after arrange: @MainActor (Bench) async -> Void) async throws {
            let (outcome, _) = try await cancel(after: arrange)
            XCTAssertEqual(outcome, expected, name, line: line)
        }

        try await expect("gone", .init(deleted: false, list: later, problem: TVDriver.notInList, sent: [read])) {
            await $0.television.put([Self.weather])
        }
        try await expect("changed", .init(deleted: false, list: both, problem: TVDriver.listChanged, sent: [read])) {
            await $0.television.put([another, Self.weather])
        }
        try await expect("silence at the read before",
                         .init(deleted: false, list: nil, problem: noAnswer, sent: [read], connected: false)) {
            await $0.gate.silence(read)
        }
        try await expect("silence at the delete", .init(deleted: false, list: both, problem: TVDriver.mayHaveArrived,
                                                        sent: [read, delete], connected: false)) {
            await $0.gate.silence(delete)
        }
        try await expect("silence at the read after", .init(deleted: true, list: later, problem: noAnswer,
                                                            sent: [read, delete, read], connected: false)) { bench in
            await bench.gate.before(delete) { await bench.gate.silence(read) }
        }
        try await expect("41200, the row gone", .init(deleted: false, list: later, problem: TVDriver.notInList,
                                                      sent: [read, delete, read])) { bench in
            await bench.gate.before(delete) { await bench.television.put([Self.weather]) }
        }
        try await expect("41200, the row still there", .init(deleted: false, list: both,
                                                             problem: TVDriver.deleteRefused,
                                                             sent: [read, delete, read])) { bench in
            await bench.gate.before(delete) { await bench.television.put([retitled, Self.weather]) }
        }
        // A television a moment behind itself still lists the row at the read after: it is taken out all the same.
        try await expect("a delete the list does not show yet",
                         .init(deleted: true, list: later, problem: nil, sent: [read, delete, read])) { bench in
            await bench.gate.before(delete) {
                await bench.gate.before(read) { await bench.television.put([Self.drama, Self.weather]) }
            }
        }
        try await expect("41200, and silence at the read after it",
                         .init(deleted: false, list: both, problem: noAnswer, sent: [read, delete, read],
                               connected: false)) { bench in
            await bench.gate.before(delete) {
                await bench.television.put([Self.weather])
                await bench.gate.silence(read)
            }
        }
        let off = ScalarError.rpc(method: delete, version: "1.1", code: 40005, message: "").explanation
        try await expect("a refusal of the television's own",
                         .init(deleted: false, list: both, problem: off, sent: [read, delete])) {
            await $0.gate.answer(delete, with: HTTPResponse(
                statusCode: 200, body: Data(#"{"error":[40005,"display off"],"id":1}"#.utf8)))
        }
        // The cookie goes bad between the read and the delete: handed to the store as the read is on its way.
        try await expect("403 at the delete", .init(deleted: false, list: both,
                                                    problem: ScalarError.notRegistered.explanation,
                                                    sent: [read, delete], needsPairing: true)) { bench in
            await bench.gate.before(read) { bench.credentials.save(Self.stale) }
        }
    }
}

/// Stands between a link and an invented television, for a test that needs something to happen at one method:
/// no answer to it from then on, or something done first -- a row taken off the television between the read and
/// the delete. What was asked is put down by its method, in order, whether or not it was passed on.
actor TVGate: HTTPTransport {
    private let television: DemoTV
    private(set) var asked: [String] = []
    private var silenced: Set<String> = []
    private var first: [String: @Sendable () async -> Void] = [:]
    private var answers: [String: HTTPResponse] = [:]

    init(_ television: DemoTV) {
        self.television = television
    }

    /// Nothing answers `method` from now on.
    func silence(_ method: String) { silenced.insert(method) }

    /// Runs `work` each time `method` is asked, before it is passed on.
    func before(_ method: String, _ work: @escaping @Sendable () async -> Void) { first[method] = work }

    /// Answers `method` itself from now on, the television not asked.
    func answer(_ method: String, with response: HTTPResponse) { answers[method] = response }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let object = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
        let method = object?["method"] as? String ?? ""
        asked.append(method)
        await first[method]?()
        if silenced.contains(method) { throw RecorderError.transport("The request timed out.") }
        if let answer = answers[method] { return answer }
        return try await television.send(request)
    }
}
