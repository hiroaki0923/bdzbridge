import Foundation
import XCTest
@testable import RecorderKit

/// A television on a link: attached without being woken, told from another by the MAC it wakes on, asked for a
/// registration when it has none that works, and given a new cookie when the one in hand is past half its life.
/// And what is asked of it after the attach, of its driver alone: its reservations read, one deleted, a change
/// turned down, the list pulled down, what waits sent, a programme reserved, and a waiting row sent again.
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
        _ = await bench.driver.reservations()
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
        XCTAssertTrue(bench.driver.canBeAsked)
        await bench.television.becomeAnother(mac: "f8:4e:17:00:00:0b")
        let before = await bench.gate.asked.count
        await bench.gate.before("getSystemSupportedFunction") { @MainActor in
            bench.world.put(bench.driver.canBeAsked ? "asked meanwhile" : "not asked meanwhile")
        }

        await bench.link.connect()
        let list = await bench.driver.reservations()

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
            let list = await driver.reservations()
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

        let list = await bench.driver.reservations()

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

        let first = Task { await bench.driver.reservations() }
        let second = Task { await bench.driver.reservations() }
        let lists = await [first.value, second.value]

        XCTAssertEqual(lists[0]?.count, 2)
        XCTAssertEqual(lists[0], lists[1])
        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, 1)
        _ = await bench.driver.reservations()
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
        XCTAssertTrue(silent.driver.canBeAsked)
        await silent.television.goSilent()
        _ = await silent.link.ensureUp(evenIfRecent: true)
        await silent.television.goSilent(false)

        for (bench, why) in [(refused, ScalarError.notRegistered.explanation), (silent, LinkWorld.notConnected)] {
            XCTAssertFalse(bench.driver.canBeAsked, why)
            bench.world.problem = Self.left
            let asked = await bench.gate.asked

            expectNil(await bench.driver.reservations(), why)
            XCTAssertEqual(bench.world.problem, Self.left, "a read that was not sent wrote over the line")
            let cancelled = await bench.driver.cancel(try held())

            XCTAssertFalse(cancelled.deleted, why)
            XCTAssertNil(cancelled.list, why)
            XCTAssertEqual(bench.world.problem, why)
            XCTAssertNil(bench.world.line)
            expectEqual(await bench.gate.asked, asked, "sent to a television that cannot be asked")
        }
    }

    /// A driver is asked without being handed a link, and holds its own only as long as the app does. Once
    /// the link has been let go of -- here it is deallocated -- a television that could be asked a moment
    /// before cannot, and whatever is asked of the driver comes to nothing and is not sent.
    func testADriverWhoseLinkIsGoneSendsNothing() async throws {
        let television = DemoTV()
        await television.put([Self.drama, Self.weather])
        let credentials = await registered(with: television)
        let driver: TVDriver
        weak var link: DeviceLink?
        do {
            let (made, itsDriver, _) = makeLink(television, credentials)
            await made.connect()
            XCTAssertTrue(itsDriver.canBeAsked)
            driver = itsDriver
            link = made
        }
        XCTAssertNil(link, "something still holds the link")
        let asked = await television.calls

        XCTAssertFalse(driver.canBeAsked)
        expectNil(await driver.reservations())
        expectNil(await driver.refreshReservations())
        let cancelled = await driver.cancel(try held())
        XCTAssertFalse(cancelled.deleted)
        XCTAssertNil(cancelled.list)
        expectEqual(await television.calls, asked, "sent by a driver with no link")
        expectEqual(await television.schedules, [Self.drama, Self.weather])
    }

    /// A reservation that is not a television's is refused at the door. The recorder's own reservation of the
    /// drama -- the channel, the start and the programme of a row the television lists -- is not looked for
    /// here: the television is sent nothing at all, not the read a cancel begins with, and the line is left as
    /// it was. A change is refused the same way, without the sentence it has for a television's.
    ///
    /// The door comes before the asking whether the television can be asked. One that cannot -- its cookie
    /// refused at the attach, or given up on after silence -- says why to a cancel of a reservation of its
    /// own; of the recorder's it says nothing, the line staying as it was, and it is sent nothing more.
    func testAReservationOfAnotherDeviceIsRefusedAtTheDoor() async throws {
        let bench = await attached()
        var recorders = try XCTUnwrap(Self.drama.row.reservation())
        recorders.id = "0x29"
        recorders.device = .recorder
        recorders.tvRow = nil
        bench.world.problem = Self.left
        let asked = await bench.gate.asked

        let cancelled = await bench.driver.cancel(recorders)
        let changed = await bench.driver.update(recorders, quality: "DR", repeating: "daily")

        XCTAssertFalse(cancelled.deleted)
        XCTAssertNil(cancelled.list)
        XCTAssertFalse(changed.changed)
        XCTAssertNil(changed.list)
        expectEqual(await bench.gate.asked, asked, "sent for a reservation that is another device's")
        XCTAssertEqual(bench.world.problem, Self.left)
        XCTAssertNil(bench.world.line)
        expectEqual(await bench.television.schedules, [Self.drama, Self.reminder, Self.weather])

        let refused = await attached(with: MemoryTVCredentials(Self.stale))
        XCTAssertTrue(refused.driver.facts.needsPairing)
        let silent = await attached()
        await silent.television.goSilent()
        _ = await silent.link.ensureUp(evenIfRecent: true)
        await silent.television.goSilent(false)
        XCTAssertTrue(silent.link.session.gaveUp)
        for (unasked, which) in [(refused, "its cookie refused"), (silent, "given up on")] {
            XCTAssertFalse(unasked.driver.canBeAsked, which)
            unasked.world.problem = Self.left
            let sentSoFar = await unasked.gate.asked

            let turnedAway = await unasked.driver.cancel(recorders)

            XCTAssertFalse(turnedAway.deleted, which)
            XCTAssertNil(turnedAway.list, which)
            XCTAssertEqual(unasked.world.problem, Self.left, "\(which): said what is said of a television's own")
            expectEqual(await unasked.gate.asked, sentSoFar, "\(which): sent for another device's reservation")
        }
    }

    /// A read that fails hands nothing back and says why. Refused for its cookie -- the app taken off the
    /// television's list since the attach -- it puts down that the registration is wanted, and the television
    /// is still there. Met with silence, it leaves the link as any silence does.
    func testAReadThatFailsSaysWhy() async {
        let refused = await attached()
        refused.credentials.save(Self.stale)
        expectNil(await refused.driver.reservations())
        XCTAssertTrue(refused.driver.facts.needsPairing)
        XCTAssertTrue(refused.link.session.connected)
        XCTAssertEqual(refused.world.problem, ScalarError.notRegistered.explanation)
        XCTAssertNil(refused.world.line)

        let silent = await attached()
        await silent.gate.silence(Self.read)
        expectNil(await silent.driver.reservations())
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

        let cancelled = await bench.driver.cancel(try held())

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
            behind.read = Task { await bench.driver.reservations() }
            await bench.gate.silence(Self.delete)
            await bench.gate.silence(Self.read)
        }
        let before = await bench.gate.asked.count

        let cancelled = await bench.driver.cancel(try held())
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

    /// A delete is carried through on the link it began on. The reader asked for it, and the app lets go of
    /// its link meanwhile -- here as the read before the delete is on its way, the last moment before the
    /// delete is sent, and nothing else holds the link from there. The cancel does not look for its link a
    /// second time and stop for want of one: the delete is sent, the list read after it, and the reservation
    /// is off the television.
    func testADeleteIsCarriedThroughOnTheLinkItBeganOn() async throws {
        let television = DemoTV()
        await television.put([Self.drama, Self.reminder, Self.weather])
        let gate = TVGate(television)
        let kept = Kept()
        let driver: TVDriver, world: LinkWorld
        weak var link: DeviceLink?
        do {
            let (made, itsDriver, itsWorld) = makeLink(television, await registered(with: television))
            itsWorld.devices[Stub.host] = gate
            await made.connect()
            XCTAssertTrue(itsDriver.canBeAsked)
            driver = itsDriver
            world = itsWorld
            link = made
            kept.link = made
        }
        await gate.before(Self.read) { @MainActor in kept.link = nil }
        let before = await gate.asked.count

        let cancelled = await driver.cancel(try held())

        XCTAssertNil(link, "something beside the cancel held the link, which shows nothing of the cancel")
        XCTAssertTrue(cancelled.deleted)
        XCTAssertEqual(cancelled.list?.map(\.id), ["recording.42"])
        expectEqual(Array(await gate.asked.dropFirst(before)), [Self.read, Self.delete, Self.read])
        expectEqual(await television.schedules, [Self.reminder, Self.weather])
        XCTAssertNil(world.problem)
        XCTAssertNil(world.line)
    }

    /// Holds the one reference a test keeps to its link, to be let go of from inside a request.
    @MainActor
    private final class Kept {
        var link: DeviceLink?
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

    /// Nothing changes a television's reservation yet. Asked to, the driver reads nothing and sends nothing,
    /// and says so on the line, over what was there: the reader asked for the change.
    func testAChangeIsNotMadeAndTheLineSaysSo() async throws {
        let bench = await attached()
        bench.world.problem = Self.left
        let asked = await bench.gate.asked

        let changed = await bench.driver.update(try held(), quality: "DR", repeating: "daily")

        XCTAssertFalse(changed.changed)
        XCTAssertNil(changed.list)
        expectEqual(await bench.gate.asked, asked, "sent for a change that is not made")
        XCTAssertEqual(bench.world.problem, TVDriver.changesNotYet)
        XCTAssertNil(bench.world.line)
    }

    // MARK: - pulling the list down

    /// From a television that can be asked, pulling the list down is a read: one request, the list handed
    /// back, and no connect made for it.
    func testPullingDownReadsWhenTheTelevisionCanBeAsked() async {
        let bench = await attached()
        let tries = bench.link.session.link.tries
        let before = await bench.gate.asked.count

        let list = await bench.driver.refreshReservations()

        XCTAssertEqual(list?.map(\.id), ["recording.42", "recording.41"])
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), [Self.read])
        XCTAssertEqual(bench.link.session.link.tries, tries, "connected to a television that could be asked")
        XCTAssertEqual(bench.world.count("reached"), 1)
    }

    /// From a television given up on after silence, pulling down is the reader asking for it to be tried
    /// again: a connect is made, and nothing is handed back. While the television says nothing still, that
    /// is all. When it answers again the host is told so, once, inside the connect, and reads the list from
    /// there.
    func testPullingDownConnectsWhenTheTelevisionCannotBeAsked() async {
        let bench = await attached()
        await bench.television.goSilent()
        _ = await bench.link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(bench.link.session.gaveUp)
        bench.world.onReached = {
            let list = await bench.driver.reservations()
            bench.world.put("told, and read \(list?.count ?? -1)")
        }
        let tries = bench.link.session.link.tries
        var before = await bench.gate.asked.count

        expectNil(await bench.driver.refreshReservations())

        XCTAssertEqual(bench.link.session.link.tries, tries + 1, "no connect was made")
        XCTAssertFalse(bench.link.session.connected)
        XCTAssertEqual(bench.world.count("told"), 0)
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), ["getSystemSupportedFunction"])

        await bench.television.goSilent(false)
        before = await bench.gate.asked.count

        expectNil(await bench.driver.refreshReservations())

        XCTAssertEqual(bench.link.session.link.tries, tries + 2)
        XCTAssertTrue(bench.driver.canBeAsked)
        XCTAssertEqual(bench.world.events.filter { $0.hasPrefix("told") }, ["told, and read 2"])
        expectEqual(Array(await bench.gate.asked.dropFirst(before)),
                    ["getSystemSupportedFunction", "getInterfaceInformation", "getStorageList", Self.read])
    }

    /// From a television that answered and refused the cookie, pulling down is the reader asking for it to be
    /// tried again as well: the session is connected, since the television said which it is, and it still
    /// cannot be asked. So a connect is made -- the only thing that finds out a registration made since --
    /// and nothing is handed back. Refused again, the connect says on the line that the registration is wanted.
    func testPullingDownConnectsToATelevisionThatRefusedTheCookie() async {
        let bench = await attached(with: MemoryTVCredentials(Self.stale))
        XCTAssertTrue(bench.link.session.connected)
        XCTAssertTrue(bench.driver.facts.needsPairing)
        bench.world.problem = Self.left
        let tries = bench.link.session.link.tries
        let before = await bench.gate.asked.count

        expectNil(await bench.driver.refreshReservations())

        XCTAssertEqual(bench.link.session.link.tries, tries + 1, "no connect was made")
        expectEqual(Array(await bench.gate.asked.dropFirst(before)),
                    ["getSystemSupportedFunction", "getInterfaceInformation", "getStorageList"])
        XCTAssertEqual(bench.world.problem, ScalarError.notRegistered.explanation)
    }

    // MARK: - what waits in the queue

    private static let disk = "getStorageList", stations = "getContentList"
    private static let question = "getConflictScheduleList", create = "addSchedule"
    /// What an attach asks, and what a round that makes one reservation asks, by their methods and in order.
    private static let attaching = ["getSystemSupportedFunction", "getInterfaceInformation", disk]
    private static let round = [disk, read, stations, question, create, read]

    /// A television that receives the station the waiting rows are on, a gate before it, and a link whose host
    /// has a cache of the test's own and sends what waits as an app's does: it asks the driver, and keeps what
    /// each sending came to.
    private struct QueueBench: Sendable {
        let link: DeviceLink, driver: TVDriver, world: LinkWorld
        let television: DemoTV, gate: TVGate, credentials: MemoryTVCredentials
        let store: GuideStore, sendings: Sendings
    }

    /// What each sending the host asked for came to, in order.
    @MainActor
    private final class Sendings {
        var came: [PendingQueue.Outcome?] = []
    }

    /// Not connected yet, with `rows` waiting in the cache, and the app in front unless `inFront` is false.
    private func queueBench(_ rows: [PendingReservation] = [], inFront: Bool = true) async throws -> QueueBench {
        let television = DemoTV()
        await television.receives([DemoTV.Station()])
        let credentials = await registered(with: television)
        let (link, driver, world) = makeLink(television, credentials, inFront: inFront)
        let gate = TVGate(television)
        world.devices[Stub.host] = gate
        let store = try temporaryStore()
        for row in rows { try await store.queue(row) }
        world.cache = store
        let sendings = Sendings()
        world.onSendWhatWaits = {
            let outcome = await driver.sendWhatWaits()
            sendings.came.append(outcome)
            world.put("sent \(outcome?.sent.map(\.request.title) ?? [])")
        }
        return QueueBench(link: link, driver: driver, world: world, television: television, gate: gate,
                          credentials: credentials, store: store, sendings: sendings)
    }

    /// A reservation of the programme `programme` on that station, waiting for the television unless said.
    /// It starts two hours from now by the real clock unless said -- a sending takes the clock as it is, and
    /// a start fixed here would one day be over -- and at a whole second, as the cache keeps a start.
    private func waiting(_ title: String, _ programme: Int, in hours: Double = 2, reason: String? = nil,
                         for target: DeviceSlot = .tv) -> PendingReservation {
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + hours * 3600).rounded(.down))
        let station = DemoTV.Station()
        let request = ReservationRequest(title: title, start: start, durationSec: 1800, repeatCode: "1",
                                         broadcastingType: Codes.broadcasting["td"] ?? 0,
                                         serviceID: station.serviceID, qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: station.name,
                                  queuedAt: Date(timeIntervalSince1970: 1_793_000_000), problem: reason,
                                  target: target)
    }

    /// An attach that got as far as the registration sends what waits for the television, before its host is
    /// told the television was reached, and counts. What went out is the attach's three requests and then the
    /// six of a round that makes one reservation, the create among them once: nothing is asked to make sure
    /// of a television that has just answered, nothing registers the app again, and no packet is sent. While
    /// the create is out the line says what is being sent. A row waiting for the recorder is none of the
    /// television's: it is not sent, and stays as it was with nothing written on it.
    ///
    /// A connect made with the app behind sends what waits as well, in the very same requests: the reader
    /// has to be there for a renewal of the cookie and for nothing else.
    func testAnAttachSendsWhatWaitsForTheTelevisionAndNothingElse() async throws {
        let mine = waiting("サンプル劇場", 50101), recorders = waiting("サンプル紀行", 50102, for: .recorder)
        let bench = try await queueBench([mine, recorders])
        await bench.gate.before(Self.create) { @MainActor in
            bench.world.put("under \(bench.world.line ?? "no line")")
        }

        await bench.link.connect()

        expectEqual(await bench.television.calls,
                    Self.attaching.prefix(2).map { "\($0) cookie=no pin=no" }
                        + ([Self.disk] + Self.round).map { "\($0) cookie=yes pin=no" })
        XCTAssertEqual(bench.world.count("packet"), 0, "a packet was sent to a television")
        XCTAssertEqual(bench.world.events, ["address \(Stub.host)", "MAC \(DemoTV.mac)", "send what waits",
                                            "under テレビに送信待ちの予約を登録中", "sent [\"サンプル劇場\"]", "reached"])
        XCTAssertEqual(bench.link.session.timesAttached, 1)
        XCTAssertNil(bench.world.problem)
        XCTAssertNil(bench.world.line)
        expectEqual(try await bench.store.pendingReservations(), [recorders])
        expectEqual(await bench.television.schedules.map(\.eventId), [50101])

        let behind = try await queueBench([mine, recorders], inFront: false)
        await behind.link.connect()
        expectEqual(await behind.television.calls, await bench.television.calls, "with the app behind")
        XCTAssertEqual(behind.link.session.timesAttached, 1, "with the app behind")
        expectEqual(try await behind.store.pendingReservations(), [recorders], "with the app behind")
        expectEqual(await behind.television.schedules.map(\.eventId), [50101], "with the app behind")
    }

    /// With nothing to send, an attach asks the television nothing beyond its own three requests and puts
    /// up no line. No sending is made with no row waiting, with only the recorder's -- one of them over,
    /// which is not the television's to drop -- or with only a row that has a reason on it, which waits for
    /// the reader. A row of the television's whose programme is over is dropped with nothing asked; the row
    /// with a reason beside it is held with its reason as it was, since no consent is handed in for it.
    ///
    /// So is a row held for what it would stop from recording, and that is the row a consent would make:
    /// the reason on it is the very one the television would give were it asked now. Each television here
    /// holds two recordings at one time, and a third at that time, which the row is, would cost the one
    /// made first its recording. The row waits for the reader all the same, and what the television holds
    /// is as it was.
    func testWithNothingToSendTheTelevisionIsAskedNothingAndNoLineGoesUp() async throws {
        let recorders = [waiting("サンプル討論", 50104, in: -2, for: .recorder),
                         waiting("サンプル紀行", 50102, for: .recorder)]
        let held = waiting("サンプル劇場", 50101, reason: "この局は録画できません")
        let over = waiting("サンプル天気", 50103, in: -2)
        var clashing = waiting("サンプル映画", 50105)
        let start = clashing.request.start
        let holding = [
            DemoTV.Schedule(id: "recording.21", serviceID: 1032, station: "サンプル放送", title: "サンプル寄席",
                            start: start),
            DemoTV.Schedule(id: "recording.22", serviceID: 1040, station: "サンプル放送2", title: "サンプル音楽館",
                            start: start),
        ]
        clashing.problem = ScalarClient.wouldStop(naming: [holding[0].row])
        let cases: [(String, queued: [PendingReservation], came: PendingQueue.Outcome?, left: [PendingReservation])] = [
            ("nothing waiting", [], nil, []),
            ("the recorder's rows alone", recorders, nil, recorders),
            ("a row with a reason on it", [held], nil, [held]),
            ("a row that is over, beside one with a reason", [over, held],
             PendingQueue.Outcome(slot: .tv, expired: [over], held: [held]), [held]),
            ("a row that is over, beside one held for what it would stop", [over, clashing],
             PendingQueue.Outcome(slot: .tv, expired: [over], held: [clashing]), [clashing]),
        ]
        for (name, queued, came, left) in cases {
            let bench = try await queueBench(queued)
            await bench.television.put(holding)

            await bench.link.connect()

            XCTAssertEqual(bench.sendings.came, [came], name)
            expectEqual(try await bench.store.pendingReservations(), left, name)
            expectEqual(await bench.gate.asked, Self.attaching, name)
            XCTAssertEqual(bench.world.begun, [TVDriver.connectingLine], name)
            XCTAssertEqual(bench.world.events.last, "reached", name)
            expectEqual(await bench.television.schedules, holding, name)
        }
    }

    /// Asked outside an attach, a television that cannot be asked is sent nothing of what waits, and the row
    /// waits as it was. Given up on after silence, nothing is asked and no line goes up, so that what an
    /// earlier operation left on the line stays. So it is for one that is to be registered again, which a
    /// read since the attach found out: its session is still connected and its client the one attached, and
    /// what the driver put down of the registration is all that says it cannot be asked. With its link let
    /// go of, the driver sends nothing. One that could be asked as the sending set out cannot once the queue
    /// has been read, a connect having begun meanwhile: its client has yet to hear which television answers
    /// it -- here another one, which is sent nothing on the strength of the last attach. And one that is
    /// being made sure of is waited for: when that check meets silence, the television is sent nothing
    /// after it.
    func testATelevisionThatCannotBeAskedIsSentNothingOfWhatWaits() async throws {
        let row = waiting("サンプル劇場", 50101)
        func attachedThenQueued() async throws -> QueueBench {
            let bench = try await queueBench()
            await bench.link.connect()
            try await bench.store.queue(row)
            XCTAssertTrue(bench.driver.canBeAsked)
            return bench
        }

        let silent = try await attachedThenQueued()
        await silent.television.goSilent()
        _ = await silent.link.ensureUp(evenIfRecent: true)
        await silent.television.goSilent(false)
        silent.world.problem = Self.left
        var asked = await silent.gate.asked
        expectNil(await silent.driver.sendWhatWaits(), "given up on")
        expectEqual(await silent.gate.asked, asked, "sent to a television given up on")
        XCTAssertEqual(silent.world.problem, Self.left, "a sending that was not made wrote over the line")
        XCTAssertFalse(silent.world.begun.contains(TVDriver.sendingLine))
        expectEqual(try await silent.store.pendingReservations(), [row])

        let unregistered = try await attachedThenQueued()
        unregistered.credentials.save(Self.stale)
        _ = await unregistered.driver.reservations()
        XCTAssertTrue(unregistered.driver.facts.needsPairing)
        XCTAssertTrue(unregistered.link.session.connected, "the refusal lost the television, as silence does")
        unregistered.world.problem = Self.left
        asked = await unregistered.gate.asked
        expectNil(await unregistered.driver.sendWhatWaits(), "to be registered")
        expectEqual(await unregistered.gate.asked, asked, "sent to a television that is to be registered")
        XCTAssertEqual(unregistered.world.problem, Self.left, "a sending that was not made wrote over the line")
        XCTAssertFalse(unregistered.world.begun.contains(TVDriver.sendingLine), "a line went up for nothing sent")
        expectEqual(try await unregistered.store.pendingReservations(), [row])

        let driver: TVDriver, gate: TVGate
        do {
            let gone = try await attachedThenQueued()
            (driver, gate) = (gone.driver, gone.gate)
        }
        XCTAssertFalse(driver.canBeAsked, "something still holds the link")
        asked = await gate.asked
        expectNil(await driver.sendWhatWaits(), "its link gone")
        expectEqual(await gate.asked, asked, "sent by a driver with no link")

        let meanwhile = try await attachedThenQueued()
        await meanwhile.television.becomeAnother(mac: "f8:4e:17:00:00:0b")
        asked = await meanwhile.gate.asked
        let sending = Task { await meanwhile.driver.sendWhatWaits() }
        let connecting = Task { await meanwhile.link.connect() }
        let outcome = await sending.value
        await connecting.value
        XCTAssertNil(outcome, "a connect begun meanwhile")
        XCTAssertTrue(meanwhile.world.begun.contains(TVDriver.sendingLine), "the connect began before the sending")
        expectEqual(Array(await meanwhile.gate.asked.dropFirst(asked.count)), [Self.attaching[0]])
        expectEqual(try await meanwhile.store.pendingReservations(), [row])

        // The check's ask is kept from failing until the sending has come back from reading the queue, which
        // its line going up shows.
        let unsure = try await attachedThenQueued()
        await unsure.television.goSilent()
        await unsure.gate.before("getPowerStatus") { @MainActor in
            for _ in 0..<100_000 where !unsure.world.begun.contains(TVDriver.sendingLine) { await Task.yield() }
        }
        asked = await unsure.gate.asked
        let checking = Task { await unsure.link.ensureUp(evenIfRecent: true) }
        expectNil(await unsure.driver.sendWhatWaits(), "being made sure of")
        expectFalse(await checking.value)
        expectEqual(Array(await unsure.gate.asked.dropFirst(asked.count)), ["getPowerStatus"])
    }

    /// What an attach's sending left when its round stopped: what stopped it, the reason on each row still
    /// waiting, the line of what went wrong, the last request the television was sent, and where the link
    /// and the attach were left.
    private struct Stopped: Equatable {
        var stop: SendingStop?
        var reasons: [String?]
        var problem: String?
        var last: String
        var connected = true, attached = true, reached = true, needsPairing = false
    }

    /// Connects with `rows` waiting, on a bench of its own, once `arrange` has set up what stops the round.
    private func connect(with rows: [PendingReservation],
                         after arrange: @MainActor (QueueBench) async -> Void) async throws -> (Stopped, QueueBench) {
        let bench = try await queueBench(rows)
        await arrange(bench)
        await bench.link.connect()
        XCTAssertNil(bench.world.line, "a line was left up")
        let reasons = try await bench.store.pendingReservations().map(\.problem)
        let session = bench.link.session
        return (Stopped(stop: bench.sendings.came.last??.stopped, reasons: reasons, problem: bench.world.problem,
                        last: await bench.gate.asked.last ?? "", connected: session.connected,
                        attached: session.timesAttached == 1, reached: bench.world.events.contains("reached"),
                        needsPairing: bench.driver.facts.needsPairing), bench)
    }

    /// What a round that stopped leaves and says, sent from inside an attach, each on a television of its own.
    /// No row has a reason written on it for any of them.
    ///
    /// With the disk away nothing is asked past it and nothing is said: the attach counts, and what is known
    /// of the disk is what the attach read. Silence at one of the round's reads is said as any read's and
    /// loses the television: the attach does not count, and its host is not told the television was reached.
    /// Silence at the create is said in the sentence for that and nothing is sent after it; the next connect
    /// finds the reservation in the television's list and sends no create. A cookie that is no longer taken
    /// is said in the registration's words and put down at once, the television kept. And a second row
    /// running answered with nothing that says anything stops the round with neither the link nor the line
    /// touched, both rows handed back as passed over.
    func testWhatARoundThatStoppedLeavesAndSays() async throws {
        let one = [waiting("サンプル劇場", 50101)], two = one + [waiting("サンプル紀行", 50102, in: 3)]
        let noAnswer = ScalarError.transport("no answer").explanation
        let metSilence = "送信の途中でテレビの応答がなくなりました。届いている場合もあるため、送り直していません。"
            + "次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"
        let nothingSaid = HTTPResponse(
            statusCode: 200, body: Data(#"{"error":[\#(DemoTV.inventedError),"invented"],"id":1}"#.utf8))
        @discardableResult
        func expect(_ name: String, _ rows: [PendingReservation], _ expected: Stopped, line: UInt = #line,
                    after arrange: @MainActor (QueueBench) async -> Void) async throws -> QueueBench {
            let (stopped, bench) = try await connect(with: rows, after: arrange)
            XCTAssertEqual(stopped, expected, name, line: line)
            return bench
        }

        let away = try await expect("the disk away", one, .init(
            stop: .cannotRecord(reason: ScalarClient.diskNotFound), reasons: [nil], problem: nil, last: Self.disk)) {
            await $0.television.unmount()
        }
        expectEqual(await away.gate.asked, Self.attaching + [Self.disk])
        XCTAssertEqual(away.driver.facts.storage, TVStorage(mounted: false, freeMB: nil, totalMB: nil))

        try await expect("silence at the round's list", two, .init(
            stop: .silent(afterSending: false), reasons: [nil, nil], problem: noAnswer, last: Self.read,
            connected: false, attached: false, reached: false)) {
            await $0.gate.silence(Self.read)
        }

        let met = try await expect("silence at the create", one, .init(
            stop: .silent(afterSending: true), reasons: [nil], problem: metSilence, last: Self.create,
            connected: false, attached: false, reached: false)) {
            await $0.television.atTheNextCreate(.carriedOutAndNotAnswered)
        }
        let before = await met.gate.asked.count
        await met.link.connect()
        expectEqual(Array(await met.gate.asked.dropFirst(before)), Self.attaching + [Self.disk, Self.read])
        XCTAssertEqual(met.sendings.came.last??.alreadyThere, one)
        expectEqual(try await met.store.pendingReservations(), [])
        expectEqual(await met.television.schedules.map(\.eventId), [50101])
        XCTAssertEqual(met.link.session.timesAttached, 1)

        try await expect("a cookie that is no longer taken", one, .init(
            stop: .needsPairing, reasons: [nil], problem: ScalarError.notRegistered.explanation,
            last: Self.stations, needsPairing: true)) { bench in
            await bench.gate.before(Self.read) { bench.credentials.save(Self.stale) }
        }

        let unsaid = try await expect("a second row running that says nothing", two, .init(
            stop: .saysNothing, reasons: [nil, nil], problem: nil, last: Self.question)) {
            await $0.gate.answer(Self.question, with: nothingSaid)
        }
        XCTAssertEqual(unsaid.sendings.came.last??.deferred, two)
    }

    /// Silence is said once, at an attach as well. A create that met silence left on the line that it may
    /// have arrived, and a delete says the same of itself: all the reader has to go by until the television
    /// answers. A connect that meets silence after either leaves that sentence where it is. One that goes
    /// through clears it, and here finds the reservation in the television's list.
    ///
    /// Only silence, and only over those two sentences. A connect the television refuses for its cookie
    /// says so over the create's sentence, and one that meets silence over anything else on the line says
    /// that the television did not answer, as it always has.
    func testAnAttachThatMeetsSilenceLeavesWhatAWriteThatMetSilenceSaid() async throws {
        let noAnswer = "テレビに接続できませんでした。テレビの電源とネットワーク接続を確認してください"
        let toBeRegistered = "テレビへの登録が必要です。設定の「テレビ」から登録してください"
        let row = waiting("サンプル劇場", 50101)
        func metAtTheCreate() async throws -> QueueBench {
            let (_, bench) = try await connect(with: [row]) {
                await $0.television.atTheNextCreate(.carriedOutAndNotAnswered)
            }
            XCTAssertEqual(bench.world.problem, Self.metSilence)
            return bench
        }

        let created = try await metAtTheCreate()
        await created.television.goSilent()
        await created.link.connect()
        XCTAssertEqual(created.world.problem, Self.metSilence, "a connect that met silence wrote over the create's")
        XCTAssertTrue(created.link.session.gaveUp)
        await created.television.goSilent(false)
        await created.link.connect()
        XCTAssertNil(created.world.problem, "a connect that went through left the line as it was")
        XCTAssertEqual(created.sendings.came.last??.alreadyThere, [row])

        let deleted = await attached()
        await deleted.gate.silence(Self.delete)
        _ = await deleted.driver.cancel(try held())
        XCTAssertEqual(deleted.world.problem, TVDriver.mayHaveArrived)
        await deleted.television.goSilent()
        await deleted.link.connect()
        XCTAssertEqual(deleted.world.problem, TVDriver.mayHaveArrived,
                       "a connect that met silence wrote over the delete's")

        let refused = try await metAtTheCreate()
        refused.credentials.save(Self.stale)
        await refused.link.connect()
        XCTAssertEqual(refused.world.problem, toBeRegistered, "a refusal was kept off the line")

        let other = try await metAtTheCreate()
        other.world.problem = Self.left
        await other.television.goSilent()
        await other.link.connect()
        XCTAssertEqual(other.world.problem, noAnswer, "silence over another line went unsaid")
    }

    /// What a sending saw of the disk is written into what is known of the television, both ways: the
    /// screens say the disk from there, and the television stays attached while its disk is pulled out or
    /// put back. A sending that stopped for want of the disk leaves it away, in the sentence the screens
    /// say for it, and still writes nothing on the line of what went wrong, nor on the row. One whose
    /// round made the row got past its opening, which reads the disk before anything else, and leaves the
    /// disk there, its sizes unknown until an attach reads them. A round that stopped at its opening for
    /// silence never read the disk, and leaves what was known of it as it was, though the disk is back.
    ///
    /// A disk known to be there is left as the attach read it, with its sizes, by a round that made a row.
    ///
    /// Making the row is not what says the disk is back: any round past its opening has read it there.
    /// One whose row the television turns down, one that finds the reservation in the television's list,
    /// and one that passes its row over each leave the disk there, each on a television of its own whose
    /// disk was away at the attach. And a sending that asks the television nothing -- here it drops a row
    /// that is over and holds one with a reason -- has not read the disk, and leaves it away as it was
    /// known.
    func testWhatASendingSawOfTheDiskIsWrittenIntoWhatIsKnownOfTheTelevision() async throws {
        let notFound = "録画用の USB HDD が見つからないため、テレビへの予約は送っていません"
        let away = TVStorage(mounted: false, freeMB: nil, totalMB: nil)
        let first = waiting("サンプル天気", 50100, in: 1)
        let bench = try await queueBench([first])
        await bench.link.connect()
        XCTAssertEqual(bench.sendings.came.last??.sent, [first])
        XCTAssertEqual(bench.driver.facts.storage, TVStorage(mounted: true, freeMB: 400, totalMB: 1000),
                       "a round that found the disk where the attach had read it took its sizes away")
        let row = waiting("サンプル劇場", 50101)
        try await bench.store.queue(row)
        await bench.television.unmount()
        bench.world.problem = Self.left

        let stopped = await bench.driver.sendWhatWaits()

        XCTAssertEqual(stopped?.stopped, .cannotRecord(reason: notFound))
        XCTAssertEqual(TVDriver.diskNotFound, notFound)
        XCTAssertEqual(bench.driver.facts.storage, away, "a sending that stopped for want of the disk left it there")
        XCTAssertEqual(bench.world.problem, Self.left, "a disk that is away went on the line of what went wrong")
        expectEqual(try await bench.store.pendingReservations(), [row], "a reason was written, or the row went")

        await bench.television.unmount(false)
        let sent = await bench.driver.sendWhatWaits()

        XCTAssertEqual(sent?.sent, [row])
        XCTAssertEqual(bench.driver.facts.storage, TVStorage(mounted: true, freeMB: nil, totalMB: nil),
                       "a round that got past its opening left the disk away")

        try await bench.store.queue(waiting("サンプル紀行", 50102, in: 3))
        await bench.television.unmount()
        _ = await bench.driver.sendWhatWaits()
        XCTAssertEqual(bench.driver.facts.storage, away)
        await bench.television.unmount(false)
        await bench.gate.silence(Self.disk)

        let silent = await bench.driver.sendWhatWaits()

        XCTAssertEqual(silent?.stopped, .silent(afterSending: false))
        XCTAssertEqual(bench.driver.facts.storage, away, "a round that never read the disk said it was back")

        // Attached with the disk away, which the attach's own sending stops at; then the disk is back.
        func back(with row: PendingReservation) async throws -> QueueBench {
            let (_, fresh) = try await connect(with: [row]) { await $0.television.unmount() }
            XCTAssertEqual(fresh.driver.facts.storage, away)
            await fresh.television.unmount(false)
            return fresh
        }
        let there = TVStorage(mounted: true, freeMB: nil, totalMB: nil)
        var unlisted = waiting("サンプル討論", 50104)
        unlisted.request.serviceID = 1040

        let turnedDown = try await back(with: unlisted)
        let refused = await turnedDown.driver.sendWhatWaits()
        XCTAssertEqual(refused?.refused.map(\.id), [unlisted.id])
        XCTAssertEqual(turnedDown.driver.facts.storage, there, "a round that turned its row down left the disk away")

        let listed = try await back(with: row)
        await listed.television.put([DemoTV.Schedule(id: "recording.31", title: "サンプル劇場",
                                                     start: row.request.start, eventId: 50101)])
        let found = await listed.driver.sendWhatWaits()
        XCTAssertEqual(found?.alreadyThere, [row])
        XCTAssertEqual(listed.driver.facts.storage, there, "a round that found its row there left the disk away")

        let unsaid = try await back(with: row)
        await unsaid.gate.answer(Self.question, with: HTTPResponse(
            statusCode: 200, body: Data(#"{"error":[\#(DemoTV.inventedError),"invented"],"id":1}"#.utf8)))
        let passedOver = await unsaid.driver.sendWhatWaits()
        XCTAssertEqual(passedOver?.deferred, [row])
        XCTAssertEqual(unsaid.driver.facts.storage, there, "a round that passed its row over left the disk away")

        let over = waiting("サンプル寄席", 50106, in: -2)
        let held = waiting("サンプル映画", 50105, reason: "この局は録画できません")
        let (_, unasked) = try await connect(with: [over, held]) { await $0.television.unmount() }
        XCTAssertEqual(unasked.sendings.came, [PendingQueue.Outcome(slot: .tv, expired: [over], held: [held])])
        expectEqual(await unasked.gate.asked, Self.attaching, "a sending with nothing to send asked the television")
        XCTAssertEqual(unasked.driver.facts.storage, away, "a sending that never read the disk said it was back")
    }

    /// Pulling the list down sends what waits and then reads the list, in that order and with no connect
    /// made: the six requests of a round and then the read, which hands back the reservation just made. The
    /// sending is asked for through the host, as an attach asks for it, and not made by the driver past it:
    /// the host is what says what became of the rows. When the sending lost the television -- here its
    /// create met silence -- no read follows it: nothing is asked after the create, nothing is handed back,
    /// and the line keeps the sentence for that silence. Nor does a read follow a sending that lost the
    /// registration, the television still there: the cookie stops being taken part way through the round,
    /// and nothing is asked after the request that was refused.
    func testPullingDownSendsWhatWaitsAndThenReadsTheList() async throws {
        let bench = try await queueBench()
        await bench.link.connect()
        try await bench.store.queue(waiting("サンプル劇場", 50101))
        let tries = bench.link.session.link.tries
        var before = await bench.gate.asked.count

        let list = await bench.driver.refreshReservations()

        XCTAssertEqual(list?.map(\.eventID), [50101])
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), Self.round + [Self.read])
        XCTAssertNil(bench.world.problem)
        XCTAssertEqual(bench.world.events.suffix(2), ["send what waits", "sent [\"サンプル劇場\"]"],
                       "the host was not asked for the sending, or not once")

        try await bench.store.queue(waiting("サンプル紀行", 50102, in: 3))
        await bench.gate.silence(Self.create)
        before = await bench.gate.asked.count

        expectNil(await bench.driver.refreshReservations())

        expectEqual(Array(await bench.gate.asked.dropFirst(before)), Self.round.dropLast(), "asked after the create")
        XCTAssertEqual(bench.world.problem, TVDriver.createMetSilence)
        XCTAssertEqual(bench.link.session.link.tries, tries, "a connect was made")

        // The cookie goes bad as the round's list is on its way: the stations are the first asked with it.
        let refused = try await queueBench()
        await refused.link.connect()
        try await refused.store.queue(waiting("サンプル劇場", 50101))
        await refused.gate.before(Self.read) { refused.credentials.save(Self.stale) }
        before = await refused.gate.asked.count

        expectNil(await refused.driver.refreshReservations())

        expectEqual(Array(await refused.gate.asked.dropFirst(before)), [Self.disk, Self.read, Self.stations],
                    "asked after the cookie was refused")
        XCTAssertEqual(refused.world.problem, ScalarError.notRegistered.explanation)
        XCTAssertTrue(refused.driver.facts.needsPairing)
        XCTAssertTrue(refused.link.session.connected, "the refusal lost the television, as silence does")
    }

    // MARK: - reserving a programme

    private static let waitsNotConnected = "テレビに接続していないため、予約を端末に保存しました。"
        + "次にテレビが答えたときに登録します。予約タブで削除できます。"
    private static let waitsForTheRegistration = "テレビの登録が必要なため、予約を端末に保存しました。"
        + "登録すると送ります。"
    private static let metSilence = "送信の途中でテレビの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"
    private static let programmeIsOver = "この番組は放送が終わっているため、予約していません。"

    /// A programme of the guide on the station the invented television receives, numbered `number`. It starts
    /// two hours from now by the real clock unless said, at a whole second: a reservation takes the clock as
    /// it is, as a sending does.
    private func programme(_ title: String, _ number: Int, in hours: Double = 2,
                           at start: Date? = nil) -> GuideProgramRow {
        let station = DemoTV.Station()
        let start = start ?? Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + hours * 3600).rounded(.down))
        return GuideProgramRow(broadcasting: "td", serviceID: station.serviceID, serviceName: station.name,
                               eventID: number, start: start, end: start.addingTimeInterval(1800), title: title,
                               summary: "", extended: "", genres: [], copyControl: 0, parental: 0,
                               isReference: false, referenceServiceID: nil, referenceEventID: nil)
    }

    /// Connected to a television that can be asked, with nothing waiting.
    private func attachedQueueBench() async throws -> QueueBench {
        let bench = try await queueBench()
        await bench.link.connect()
        XCTAssertTrue(bench.driver.canBeAsked)
        return bench
    }

    /// A reservation the reader asks for is written to the phone's queue first -- for the television, in DR,
    /// with no reason on it -- and then made by a round for that one row: when the round's first request
    /// reaches the television the row is kept already. What goes out is the six requests of a round and the
    /// read of the list after it, each with the cookie and nothing else on it: one create, nothing to make
    /// sure of a television that has just answered, nothing that registers the app, no packet, no connect.
    /// The line says what is being made while the create is out and is gone afterwards. Made, the
    /// reservation clears the line of what went wrong, and the list handed back has it. Another row waiting
    /// for the television is not sent with it and waits as it was, and the host is not asked to send what
    /// waits.
    ///
    /// A programme the television's list holds already is not made a second time: the round ends at its
    /// list, and the result says the reservation was there.
    func testAReservationIsKeptFirstAndThenMadeByARoundForThatOneRow() async throws {
        let bench = try await attachedQueueBench()
        let other = waiting("サンプル紀行", 50102, in: 3)
        try await bench.store.queue(other)
        bench.world.problem = Self.left
        await bench.gate.before(Self.disk) { @MainActor in
            let kept = try? await bench.store.pendingReservations().first { $0.request.eventID == 50101 }
            bench.world.put("kept for \(kept?.target.rawValue ?? "nobody") in \(kept?.request.qualityCode ?? 0), "
                + (kept?.problem ?? "no reason"))
        }
        await bench.gate.before(Self.create) { @MainActor in
            bench.world.put("under \(bench.world.line ?? "no line")")
        }
        let tries = bench.link.session.link.tries, events = bench.world.events.count
        var before = await bench.television.calls.count

        let made = await bench.driver.reserve(programme("サンプル劇場", 50101), repeating: "none")

        XCTAssertEqual(made.reserved, .made(saying: nil))
        XCTAssertEqual(made.list?.map(\.eventID), [50101])
        expectEqual(Array(await bench.television.calls.dropFirst(before)),
                    (Self.round + [Self.read]).map { "\($0) cookie=yes pin=no" })
        XCTAssertEqual(Array(bench.world.events.dropFirst(events)),
                       ["kept for tv in 100, no reason", "under テレビに予約を登録中"])
        XCTAssertNil(bench.world.line)
        XCTAssertNil(bench.world.problem)
        expectEqual(try await bench.store.pendingReservations(), [other])
        expectEqual(await bench.television.schedules.map(\.eventId), [50101])

        let weather = programme("サンプル天気", 50103, in: 4)
        let holds = await bench.television.schedules
        await bench.television.put(holds + [DemoTV.Schedule(id: "recording.61", start: weather.start, eventId: 50103)])
        before = await bench.television.calls.count

        let found = await bench.driver.reserve(weather, repeating: "none")

        XCTAssertEqual(found.reserved, .made(saying: "テレビにはこの番組の予約がすでにありました。"))
        XCTAssertEqual(found.list?.map(\.eventID), [50103, 50101])
        expectEqual(Array(await bench.television.calls.dropFirst(before)),
                    [Self.disk, Self.read, Self.read].map { "\($0) cookie=yes pin=no" })
        expectEqual(try await bench.store.pendingReservations(), [other])
        XCTAssertEqual(bench.world.count("packet"), 0, "a packet was sent to a television")
        XCTAssertEqual(bench.world.count("send what waits"), 1, "the host was asked to send what waits")
        XCTAssertEqual(bench.link.session.link.tries, tries, "a connect was made")
    }

    /// A reservation asked for while a sending of what waits has the programme's row in hand is not made a
    /// second time, and is not left unanswered. The row waited already, and the sending had read it and
    /// was at its create when the reservation replaced the row and took its turn behind the sending. The
    /// sending makes the reservation and takes the row out of the queue, the reservation's own with it. The
    /// round for the reservation then finds no row, and has it in none of its lists. The television's list
    /// is read all the same and has the programme, so the result is made, with that list handed back. One
    /// create went out in all, and nothing waits.
    func testAReservationASendingMadeFirstIsAnsweredFromTheListAndNotMadeAgain() async throws {
        let bench = try await attachedQueueBench()
        let older = waiting("サンプル劇場", 50101)
        try await bench.store.queue(older)
        let film = programme("サンプル劇場", 50101, at: older.request.start)
        // The sending's create is kept back until the reservation has been kept and its line is up.
        let behind = Reserving()
        await bench.gate.before(Self.create) { @MainActor in
            behind.reservation = Task { await bench.driver.reserve(film, repeating: "none") }
            for _ in 0..<100_000 where !bench.world.begun.contains(TVDriver.reservingLine) { await Task.yield() }
        }
        let before = await bench.gate.asked.count

        let sending = await bench.driver.sendWhatWaits()
        let made = await behind.reservation?.value

        XCTAssertEqual(sending?.sent, [older], "the sending did not have the row in hand")
        XCTAssertEqual(made?.reserved, .made(saying: nil))
        XCTAssertEqual(made?.list?.map(\.eventID), [50101])
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), Self.round + [Self.read])
        expectEqual(try await bench.store.pendingReservations(), [])
        expectEqual(await bench.television.schedules.map(\.eventId), [50101])
    }

    /// Holds the reservation a test sets going from inside a request, to be waited for afterwards.
    @MainActor
    private final class Reserving {
        var reservation: Task<(reserved: Reserved, list: [Reservation]?), Never>?
    }

    /// A round that could not read the phone's queue comes back as one does whose row has gone: with the row
    /// in none of its lists and nothing stopped. The row waits still, though, and the result says so. It is
    /// not answered as neither made nor kept on the strength of a list that has no such recording, when the
    /// next sending of what waits goes on to make it. Here the queue cannot be read from the moment the
    /// reservation is kept until the list after its round is asked for. The round asks the television
    /// nothing, the list is read, and the row is in the queue as it was written, with no reason on it.
    func testAReservationWhoseRoundCouldNotReadTheQueueIsSaidToWait() async throws {
        let unanswered = "テレビの応答を読み取れなかったため、予約を端末に保存しました。"
            + "次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"
        let bench = try await attachedQueueBench()
        let path = temporaryPath()
        let store = try GuideStore(path: path)
        bench.world.cache = store
        // The queue's table is put out of reach from another connection, on purpose: a read of it then fails.
        // A check is in flight as the reservation is asked for, and its ask is held until the reservation has
        // been kept and its line is up, so that the first read to fail is the round's.
        let other = try Sqlite(path: path)
        await bench.gate.before("getPowerStatus") { @MainActor in
            for _ in 0..<100_000 where !bench.world.begun.contains(TVDriver.reservingLine) { await Task.yield() }
            try? other.execute("ALTER TABLE pending_reservations RENAME TO out_of_reach")
        }
        await bench.gate.before(Self.read) { @MainActor in
            try? other.execute("ALTER TABLE out_of_reach RENAME TO pending_reservations")
        }
        let before = await bench.gate.asked.count
        let checking = Task { await bench.link.ensureUp(evenIfRecent: true) }

        let (reserved, list) = await bench.driver.reserve(programme("サンプル劇場", 50101), repeating: "none")

        expectTrue(await checking.value)
        let kept = try await store.pendingReservations()
        XCTAssertEqual(kept.map(\.id), ["tv|2/1024/50101"])
        XCTAssertEqual(kept.map(\.problem), [nil])
        XCTAssertEqual(reserved, kept.first.map { Reserved.waiting($0, saying: unanswered) })
        XCTAssertEqual(list?.map(\.eventID), [])
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), ["getPowerStatus", Self.read])
        expectEqual(await bench.television.schedules, [])
    }

    /// What the door turns away, each on a television of its own that could be asked, with something left on
    /// the line by an earlier operation: a weekly repeat of another weekday than the programme's; a repeat no
    /// table has; a programme whose end has passed; no cache; a cache that cannot be written to, another
    /// connection holding a write on it; and the link let go of. Each is answered as not done with its
    /// sentence, in the result and nowhere else: nothing is kept, nothing is asked of the television, no line
    /// goes up, and the line of what went wrong is as it was.
    func testWhatTheDoorTurnsAwayIsNeitherKeptNorSentAndIsSaidInTheResult() async throws {
        let repeatNotTaken = "この番組には、選んだ毎回録画の設定でテレビに予約できません。"
        let soon = programme("サンプル劇場", 50101)
        func turnedAway(_ name: String, _ programme: GuideProgramRow, repeating: String = "none", by driver: TVDriver,
                        _ gate: TVGate, _ world: LinkWorld, _ store: GuideStore) async throws -> Reserved {
            world.problem = Self.left
            let asked = await gate.asked, begun = world.begun
            let (reserved, list) = await driver.reserve(programme, repeating: repeating)
            XCTAssertNil(list, name)
            expectEqual(await gate.asked, asked, "\(name): the television was asked")
            expectEqual(try await store.pendingReservations(), [], "\(name): a row was kept")
            XCTAssertEqual(world.problem, Self.left, "\(name): the door wrote on the line")
            XCTAssertEqual(world.begun, begun, "\(name): a line went up")
            return reserved
        }
        func turnedAway(_ name: String, _ programme: GuideProgramRow, repeating: String = "none",
                        on bench: QueueBench, keptIn store: GuideStore? = nil) async throws -> Reserved {
            try await turnedAway(name, programme, repeating: repeating, by: bench.driver, bench.gate, bench.world,
                                 store ?? bench.store)
        }

        // A Sunday evening in Japan: a repeat is settled before the clock is read, whenever this is run.
        let sunday = programme("サンプル劇場", 50101, at: Self.start), over = programme("サンプル劇場", 50101, in: -2)
        let cases = [("a weekly repeat of another weekday", sunday, "mon", repeatNotTaken),
                     ("a repeat no table has", soon, "なし", repeatNotTaken),
                     ("a programme that is over", over, "none", Self.programmeIsOver)]
        for (name, programme, repeating, says) in cases {
            let bench = try await attachedQueueBench()
            expectEqual(try await turnedAway(name, programme, repeating: repeating, on: bench), .notDone(says), name)
        }

        let without = try await attachedQueueBench()
        without.world.cache = nil
        expectEqual(try await turnedAway("no cache", soon, on: without),
                    .notDone("予約を端末に保存できませんでした（端末内のデータベースを開けませんでした）"))

        // The lock is held on purpose and the wait for it cut short: what is tested is giving up.
        let locked = try await attachedQueueBench()
        let path = temporaryPath()
        let impatient = try GuideStore(path: path, busyTimeoutMilliseconds: 200)
        locked.world.cache = impatient
        let writer = try Sqlite(path: path)
        try writer.execute("BEGIN IMMEDIATE")
        let unkept = try await turnedAway("a cache that cannot be written to", soon, on: locked, keptIn: impatient)
        try writer.execute("ROLLBACK")
        guard case .notDone(let said) = unkept else { return XCTFail("not turned away: \(unkept)") }
        XCTAssertTrue(said.hasPrefix("予約を端末に保存できませんでした: "), "what is said instead: \(said)")

        let driver: TVDriver, gate: TVGate, world: LinkWorld, store: GuideStore
        do {
            let gone = try await attachedQueueBench()
            (driver, gate, world, store) = (gone.driver, gone.gate, gone.world, gone.store)
        }
        XCTAssertFalse(driver.canBeAsked, "something still holds the link")
        expectEqual(try await turnedAway("the link gone", soon, by: driver, gate, world, store),
                    .notDone("テレビに接続していません。テレビの電源とネットワーク接続を確認してください。"))
    }

    /// A television that cannot be asked is sent nothing of a reservation and is not connected to for it. The
    /// reservation is kept on the phone, for the television and with no reason on it, to go with the next
    /// sending of what waits, and the result says which wait it is: for the registration, where the
    /// television refused the cookie at the attach, and otherwise for the television to answer -- here one
    /// given up on after silence. No line goes up for either, and what an earlier operation left on the line
    /// stays.
    ///
    /// One that is being made sure of as the reservation is asked for is waited for, the line up meanwhile.
    /// When that check meets silence the reservation is kept the same way: nothing is asked after the
    /// check's own ask, and the line of what went wrong is the check's.
    func testAReservationForATelevisionThatCannotBeAskedIsKeptAndNotSent() async throws {
        let film = programme("サンプル劇場", 50101)
        let unregistered = try await queueBench()
        unregistered.credentials.save(Self.stale)
        await unregistered.link.connect()
        XCTAssertTrue(unregistered.driver.facts.needsPairing)
        let silent = try await attachedQueueBench()
        await silent.television.goSilent()
        _ = await silent.link.ensureUp(evenIfRecent: true)
        await silent.television.goSilent(false)
        XCTAssertTrue(silent.link.session.gaveUp)

        for (bench, says) in [(unregistered, Self.waitsForTheRegistration), (silent, Self.waitsNotConnected)] {
            bench.world.problem = Self.left
            let asked = await bench.gate.asked, tries = bench.link.session.link.tries

            let (reserved, list) = await bench.driver.reserve(film, repeating: "none")

            let kept = try await bench.store.pendingReservations()
            XCTAssertEqual(kept.map(\.id), ["tv|2/1024/50101"], says)
            XCTAssertEqual(kept.map(\.problem), [nil], says)
            XCTAssertEqual(reserved, kept.first.map { Reserved.waiting($0, saying: says) })
            XCTAssertNil(list, says)
            expectEqual(await bench.gate.asked, asked, "sent to a television that cannot be asked")
            XCTAssertEqual(bench.link.session.link.tries, tries, "a connect was made")
            XCTAssertFalse(bench.world.begun.contains(TVDriver.reservingLine), "a line went up for nothing sent")
            XCTAssertEqual(bench.world.problem, Self.left, "a reservation that was not sent wrote over the line")
        }

        // The check's ask is kept from failing until the reservation has been kept and its line is up.
        let unsure = try await attachedQueueBench()
        await unsure.television.goSilent()
        await unsure.gate.before("getPowerStatus") { @MainActor in
            for _ in 0..<100_000 where !unsure.world.begun.contains(TVDriver.reservingLine) { await Task.yield() }
        }
        let asked = await unsure.gate.asked
        let checking = Task { await unsure.link.ensureUp(evenIfRecent: true) }

        let (reserved, list) = await unsure.driver.reserve(film, repeating: "none")

        expectFalse(await checking.value)
        let kept = try await unsure.store.pendingReservations()
        XCTAssertEqual(kept.map(\.problem), [nil])
        XCTAssertEqual(reserved, kept.first.map { Reserved.waiting($0, saying: Self.waitsNotConnected) })
        XCTAssertNil(list)
        expectEqual(Array(await unsure.gate.asked.dropFirst(asked.count)), ["getPowerStatus"])
        XCTAssertEqual(unsure.world.problem, unsure.driver.noAnswerLine)
    }

    /// A programme whose end has passed is turned away at the door where the television cannot be asked as
    /// well, which is where the door is needed: no round runs there to drop the row, so it would be kept,
    /// and said to go when the television next answers, for a programme no television is sent once it is
    /// over. Here the television was given up on after silence. Nothing is kept, nothing is asked of it, no
    /// connect is made, and the result says the programme is over.
    func testAProgrammeThatIsOverIsNotKeptForATelevisionThatCannotBeAsked() async throws {
        let bench = try await attachedQueueBench()
        await bench.television.goSilent()
        _ = await bench.link.ensureUp(evenIfRecent: true)
        await bench.television.goSilent(false)
        XCTAssertTrue(bench.link.session.gaveUp)
        let asked = await bench.gate.asked, tries = bench.link.session.link.tries

        let (reserved, list) = await bench.driver.reserve(programme("サンプル劇場", 50101, in: -2), repeating: "none")

        XCTAssertEqual(reserved, .notDone(Self.programmeIsOver))
        XCTAssertNil(list)
        expectEqual(try await bench.store.pendingReservations(), [], "kept for a television that is never sent it")
        expectEqual(await bench.gate.asked, asked, "sent to a television that cannot be asked")
        XCTAssertEqual(bench.link.session.link.tries, tries, "a connect was made")
    }

    /// A programme that has begun is not reserved on a television. Why not is said for a screen to go by,
    /// by the moment it is handed: nothing for a programme still ahead, a second before its start as well;
    /// that it has begun, from its start to its end; and that it is over, once its end has passed.
    ///
    /// The door turns such a programme away by the same rule, with the sentence in the result and nowhere
    /// else, on a television that can be asked and on one given up on after silence: nothing is kept,
    /// nothing is asked of the television, no connect is made, no line goes up, and the line of what went
    /// wrong is as it was. With no door the first would keep a row for its round to hold, and the second a
    /// row promised to a television that is never sent it.
    func testAProgrammeThatHasBegunIsNotOfferedAndIsTurnedAwayAtTheDoor() async throws {
        let begun = "放送が始まった番組は、テレビには予約できません。"
        let film = programme("サンプル劇場", 50101, at: Self.start)
        let whys: [(name: String, after: TimeInterval, why: String?)] = [
            ("a day ahead", -86_400, nil), ("a second before its start", -1, nil), ("at its start", 0, begun),
            ("half way through", 900, begun), ("at its end", 1800, begun),
            ("a second after its end", 1801, Self.programmeIsOver),
        ]
        for (name, after, why) in whys {
            XCTAssertEqual(TVDriver.whyNot(film, now: Self.start.addingTimeInterval(after)), why, name)
        }

        // On air by the real clock, which is the door's: begun a quarter of an hour ago, with as long to go.
        let onAir = programme("サンプル劇場", 50101, in: -0.25)
        let attached = try await attachedQueueBench()
        let givenUp = try await attachedQueueBench()
        await givenUp.television.goSilent()
        _ = await givenUp.link.ensureUp(evenIfRecent: true)
        await givenUp.television.goSilent(false)
        XCTAssertTrue(givenUp.link.session.gaveUp)
        for (name, bench) in [("attached", attached), ("given up on", givenUp)] {
            bench.world.problem = Self.left
            let asked = await bench.gate.asked, lines = bench.world.begun, tries = bench.link.session.link.tries

            let (reserved, list) = await bench.driver.reserve(onAir, repeating: "none")

            XCTAssertEqual(reserved, .notDone(begun), name)
            XCTAssertNil(list, name)
            expectEqual(try await bench.store.pendingReservations(), [], "\(name): a row was kept")
            expectEqual(await bench.gate.asked, asked, "\(name): the television was asked")
            XCTAssertEqual(bench.link.session.link.tries, tries, "\(name): a connect was made")
            XCTAssertEqual(bench.world.begun, lines, "\(name): a line went up")
            XCTAssertEqual(bench.world.problem, Self.left, "\(name): the door wrote on the line")
        }
    }

    /// A television is offered DR and, for a programme, exactly the repeats it is sent for it, in the order
    /// a sheet lists them: all six for a Monday evening's; no Monday to Friday for a Saturday's; neither
    /// that nor Monday to Saturday for a Sunday's; and nothing with a weekday in it for one at two in the
    /// morning. Each list is the names the door of `reserve` lets through, of all the names there are: every
    /// other is turned away there for its repeat, and none of these is. With no cache to keep a row in they
    /// get as far as that and no further, so nothing is kept or sent.
    ///
    /// Each programme is the next of its weekday from tomorrow on by the real clock, which is the door's: a
    /// start fixed here would one day be over, and the door would then say that of every repeat it is sent.
    func testATelevisionIsOfferedTheRepeatsItIsSentForAProgrammeAndDR() async throws {
        XCTAssertEqual(TVDriver.recordsIn, "DR")
        XCTAssertEqual(Codes.qualityLabel[TVDriver.recordsIn], "DR(高画質)")
        let repeatNotTaken = "この番組には、選んだ毎回録画の設定でテレビに予約できません。"
        let noCache = "予約を端末に保存できませんでした（端末内のデータベースを開けませんでした）"
        var japan = Calendar(identifier: .gregorian)
        japan.timeZone = RecorderTime.timeZone
        // The calendar counts the days of the week from Sunday, which is 1.
        func next(_ weekday: Int, at hour: Int) throws -> Date {
            try XCTUnwrap(japan.nextDate(after: Date().addingTimeInterval(86_400),
                                         matching: DateComponents(hour: hour, weekday: weekday),
                                         matchingPolicy: .nextTime))
        }
        let offered: [(name: String, start: Date, repeats: [String])] = [
            ("a Monday evening's", try next(2, at: 21), ["none", "title", "daily", "mon", "mon-fri", "mon-sat"]),
            ("a Saturday evening's", try next(7, at: 21), ["none", "title", "daily", "sat", "mon-sat"]),
            ("a Sunday evening's", try next(1, at: 21), ["none", "title", "daily", "sun"]),
            ("one at two on a Monday morning", try next(2, at: 2), ["none", "title", "daily"]),
        ]
        let bench = try await attachedQueueBench()
        bench.world.cache = nil
        let asked = await bench.gate.asked
        for (name, start, repeats) in offered {
            let programme = programme("サンプル劇場", 50101, at: start)
            XCTAssertEqual(TVDriver.repeats(for: programme), repeats, name)
            for repeating in Codes.repeatCodes.keys.sorted() {
                expectEqual(await bench.driver.reserve(programme, repeating: repeating).reserved,
                            .notDone(repeats.contains(repeating) ? noCache : repeatNotTaken),
                            "\(name), \(repeating)")
            }
        }
        expectEqual(await bench.gate.asked, asked, "the television was asked")
    }

    /// What a round for one row is read as, with no television: each way a round can go, and the sentence the
    /// result says for it, to the letter. A round that never ran keeps the reservation, and what the driver
    /// knows of the registration says which wait it is. The reason for what a reservation would stop from
    /// recording is told from every other reason, on a row refused now and on one held from before.
    ///
    /// A row the round has in none of its lists, with nothing stopped, is not taken for made because it has
    /// gone from the queue. Made is said only where the television's list has a recording of the programme
    /// that is all the row asks for; where what it has falls short of the repeat asked, the reason for that
    /// is said; and with nothing of it listed, or no list read, nothing is known to have been made -- or,
    /// its programme being over by then, that is what is said.
    func testWhatARoundForOneRowCameToIsReadAsWhatTheReservationCameTo() {
        let driver = TVDriver(credentials: MemoryTVCredentials(), nickname: "BD Bridge", inFront: { true })
        let row = waiting("サンプル劇場", 50101), other = waiting("サンプル紀行", 50102, in: 3)
        var clashing = row, unlisted = row, daily = row
        clashing.problem = ScalarClient.wouldStop(naming: [Self.weather.row])
        unlisted.problem = "テレビのチャンネル一覧にこの局が見つかりませんでした。"
        daily.request.repeatCode = "d"
        let remark = "「サンプル劇場」はほかの予約と重なっていて、録画されないことがあります"
        let forTheDisk = "録画用の USB HDD が見つからないため、予約を端末に保存しました。"
            + "HDD が見つかったあと、テレビが答えたときに登録します。"
        let unanswered = "テレビの応答を読み取れなかったため、予約を端末に保存しました。"
            + "次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"
        let unconfirmed = "予約を登録できたか確かめられませんでした。予約タブで確かめてください。"
        let once = [DemoTV.Schedule(id: "recording.31", start: row.request.start, eventId: 50101), Self.weather]
            .compactMap { $0.row.reservation() }
        let without = [Self.weather, Self.drama].compactMap { $0.row.reservation() }
        func round(sent: [PendingReservation] = [], remarks: [String] = [], expired: [PendingReservation] = [],
                   refused: [PendingReservation] = [], deferred: [PendingReservation] = [],
                   held: [PendingReservation] = [], alreadyThere: [PendingReservation] = [],
                   stopped: SendingStop? = nil) -> PendingQueue.Outcome {
            PendingQueue.Outcome(slot: .tv, sent: sent, remarks: remarks, expired: expired, refused: refused,
                                 deferred: deferred, held: held, alreadyThere: alreadyThere, stopped: stopped)
        }
        let cases: [(name: String, row: PendingReservation, round: PendingQueue.Outcome?, list: [Reservation]?,
                     comes: Reserved)] = [
            ("no round ran", row, nil, nil, .waiting(row, saying: Self.waitsNotConnected)),
            ("made", row, round(sent: [row]), once, .made(saying: nil)),
            ("made, and something to say", row, round(sent: [row], remarks: [remark]), once, .made(saying: remark)),
            ("found there", row, round(alreadyThere: [row]), once,
             .made(saying: "テレビにはこの番組の予約がすでにありました。")),
            ("refused for what it would stop", row, round(refused: [clashing]), nil, .wouldStop(clashing)),
            ("held for what it would stop", row, round(held: [clashing]), nil, .wouldStop(clashing)),
            ("refused for its station", row, round(refused: [unlisted]), nil,
             .waiting(unlisted, saying: "テレビのチャンネル一覧にこの局が見つかりませんでした。")),
            ("held for its station", row, round(held: [unlisted]), nil,
             .waiting(unlisted, saying: "テレビのチャンネル一覧にこの局が見つかりませんでした。")),
            ("its programme over", row, round(expired: [row]), nil, .notDone(Self.programmeIsOver)),
            ("silence at the create", row, round(stopped: .silent(afterSending: true)), nil,
             .waiting(row, saying: Self.metSilence)),
            ("silence at a read", row, round(stopped: .silent(afterSending: false)), nil,
             .waiting(row, saying: Self.waitsNotConnected)),
            ("the registration wanted", row, round(stopped: .needsPairing), nil,
             .waiting(row, saying: Self.waitsForTheRegistration)),
            ("the disk away", row, round(stopped: .cannotRecord(reason: ScalarClient.diskNotFound)), nil,
             .waiting(row, saying: forTheDisk)),
            ("passed over", row, round(deferred: [row]), nil, .waiting(row, saying: unanswered)),
            ("an opening that says nothing", row, round(stopped: .saysNothing), nil,
             .waiting(row, saying: unanswered)),
            ("gone from the queue, and listed", row, round(), once, .made(saying: nil)),
            ("gone, and listed once where a repeat was asked", daily, round(), once,
             .notDone(ScalarClient.reservedOnceOnly)),
            ("gone, and not listed", row, round(), without, .notDone(unconfirmed)),
            ("gone, and no list read", row, round(), nil, .notDone(unconfirmed)),
            ("gone, another row made", row, round(sent: [other], remarks: [remark]), without, .notDone(unconfirmed)),
        ]
        for (name, row, round, list, comes) in cases {
            XCTAssertEqual(driver.reserved(row, by: round, listing: list), comes, name)
        }
        XCTAssertEqual(driver.reserved(row, by: round(), listing: without, now: row.request.end.addingTimeInterval(1)),
                       .notDone(Self.programmeIsOver), "gone, and over by then")
        driver.facts.needsPairing = true
        XCTAssertEqual(driver.reserved(row, by: nil, listing: nil), .waiting(row, saying: Self.waitsForTheRegistration),
                       "no round ran, the registration wanted")
    }

    /// A reservation that would stop another from recording is not made: nothing hands a consent in with a
    /// reservation just asked for. The television holds two recordings at the programme's time, so a third
    /// would cost the one made first its recording. The television is asked up to that question and no
    /// further; the row is kept and held with the reason that names that recording; and the result says it
    /// is for the reader to answer. No list is read for a reservation that was not made, so what an earlier
    /// operation left on the line stays. The television holds what it held.
    ///
    /// A create that meets silence is followed by nothing: not the list, not a second create. It may have
    /// been made, so the row waits with no reason on it, the result and the line both say so in the sentence
    /// for that, and the television is lost. The next connect finds the reservation in the television's
    /// list and sends no create.
    func testAReservationThatWouldStopAnotherIsHeldAndOneWhoseCreateMetSilenceWaits() async throws {
        let film = programme("サンプル映画", 50105)
        let holding = [
            DemoTV.Schedule(id: "recording.21", serviceID: 1032, station: "サンプル放送", title: "サンプル寄席",
                            start: film.start),
            DemoTV.Schedule(id: "recording.22", serviceID: 1040, station: "サンプル放送2", title: "サンプル音楽館",
                            start: film.start),
        ]
        let clashing = try await attachedQueueBench()
        await clashing.television.put(holding)
        clashing.world.problem = Self.left
        var before = await clashing.gate.asked.count

        let held = await clashing.driver.reserve(film, repeating: "none")

        var kept = try await clashing.store.pendingReservations()
        XCTAssertEqual(kept.map(\.problem), [ScalarClient.wouldStop(naming: [holding[0].row])])
        XCTAssertEqual(held.reserved, kept.first.map { Reserved.wouldStop($0) })
        XCTAssertNil(held.list)
        expectEqual(Array(await clashing.gate.asked.dropFirst(before)), Array(Self.round.prefix(4)))
        XCTAssertEqual(clashing.world.problem, Self.left)
        expectEqual(await clashing.television.schedules, holding)

        let silent = try await attachedQueueBench()
        await silent.television.atTheNextCreate(.carriedOutAndNotAnswered)
        before = await silent.gate.asked.count

        let waits = await silent.driver.reserve(film, repeating: "none")

        kept = try await silent.store.pendingReservations()
        XCTAssertEqual(kept.map(\.problem), [nil])
        XCTAssertEqual(waits.reserved, kept.first.map { Reserved.waiting($0, saying: Self.metSilence) })
        XCTAssertNil(waits.list)
        expectEqual(Array(await silent.gate.asked.dropFirst(before)), Array(Self.round.dropLast()))
        XCTAssertEqual(silent.world.problem, Self.metSilence)
        XCTAssertFalse(silent.link.session.connected)

        before = await silent.gate.asked.count
        await silent.link.connect()
        expectEqual(Array(await silent.gate.asked.dropFirst(before)), Self.attaching + [Self.disk, Self.read])
        XCTAssertEqual(silent.sendings.came.last??.alreadyThere, kept)
        expectEqual(try await silent.store.pendingReservations(), [])
        expectEqual(await silent.television.schedules.map(\.eventId), [50105])
    }

    /// What a screen asks before a reservation held for what it would stop is made all the same is the
    /// reason on the row without its last sentence: the reservations as the television named them, a viewing
    /// reservation as one, and nothing of the button that sends a row again, which the screen that asks does
    /// not have. Only that last sentence goes, from the end: the same words in a title stay. A row held for
    /// anything else, and one with no reason, has nothing to ask. And what a screen says a reservation on
    /// the television will do, before the reader confirms it, to the letter.
    func testWhatIsAskedBeforeAHeldReservationIsMadeIsItsReasonWithoutItsLastSentence() {
        let named = "この予約を入れると、次の予約は録画されません: 「サンプル天気」（サンプル放送 11/1 22:00）、"
            + "視聴予約「サンプル番組」（サンプルテレビ 11/1 21:00）。"
        let tail = "「もう一度送る」を選ぶと、それでも予約します。"
        var held = waiting("サンプル劇場", 50101)
        held.problem = ScalarClient.wouldStop(naming: [Self.weather.row, Self.reminder.row])
        XCTAssertEqual(held.problem, named + tail)
        XCTAssertEqual(TVDriver.asks(of: held), named)

        var titled = Self.weather
        titled.title = tail
        held.problem = ScalarClient.wouldStop(naming: [titled.row])
        XCTAssertEqual(TVDriver.asks(of: held), "この予約を入れると、次の予約は録画されません: "
                       + "「「もう一度送る」を選ぶと、それでも予約します。」（サンプル放送 11/1 22:00）。")

        held.problem = "テレビのチャンネル一覧にこの局が見つかりませんでした。"
        XCTAssertNil(TVDriver.asks(of: held), "a row held for its station")
        held.problem = nil
        XCTAssertNil(TVDriver.asks(of: held), "a row with no reason")

        XCTAssertEqual(TVDriver.confirming, "テレビに予約を登録します。テレビが応答しないときは端末に保存し、"
                       + "次に応答したときに登録します。")
    }

    // MARK: - sending a waiting row again

    /// What sending a row again came to and left: the round and the list handed back, the list by its ids;
    /// what the television was asked for it; what still waits in the queue; what the television holds, each
    /// by its id and its overlap; the lines put up for it; and the connects made.
    private struct Resent: Equatable {
        var round: PendingQueue.Outcome?
        var listed: [String]?
        var asked: [String]
        var left: [PendingReservation]
        var holds: [String]
        var lines: [String] = []
        var connects = 0
    }

    /// A film's row, and the two recordings a television holds at its time, so that a third there, which
    /// the row is, would cost the one made first its recording: what the television holds while nothing is
    /// made, and once the row is. `clashing` is the row held with the reason that names that recording, as
    /// the television would name it now, and `stale` the row held with a reason that names the other.
    private struct Clash {
        let film: PendingReservation, clashing: PendingReservation, stale: PendingReservation
        let holding: [DemoTV.Schedule]
        let untouched = ["recording.21 notOverlapped", "recording.22 notOverlapped"]
        let stopped = ["recording.21 fullyOverlapped", "recording.22 notOverlapped", "recording.23 notOverlapped"]
        let listed = ["recording.23", "recording.22", "recording.21"]
    }

    private func clash() -> Clash {
        let film = waiting("サンプル映画", 50105)
        let holding = [
            DemoTV.Schedule(id: "recording.21", serviceID: 1032, station: "サンプル放送", title: "サンプル寄席",
                            start: film.request.start),
            DemoTV.Schedule(id: "recording.22", serviceID: 1040, station: "サンプル放送2", title: "サンプル音楽館",
                            start: film.request.start),
        ]
        var clashing = film, stale = film
        clashing.problem = ScalarClient.wouldStop(naming: [holding[0].row])
        stale.problem = ScalarClient.wouldStop(naming: [holding[1].row])
        return Clash(film: film, clashing: clashing, stale: stale, holding: holding)
    }

    /// Connected to a television that holds `holding`, and then with `rows` waiting: queued once the attach
    /// is over, whose own sending would have taken them. With `givenUp` it has been silent to a check since,
    /// so it is given up on, and answers again unless `silent`.
    private func resendBench(_ rows: [PendingReservation], holding: [DemoTV.Schedule] = [], givenUp: Bool = false,
                             silent: Bool = false) async throws -> QueueBench {
        let bench = try await attachedQueueBench()
        await bench.television.put(holding)
        for row in rows { try await bench.store.queue(row) }
        guard givenUp else { return bench }
        await bench.television.goSilent()
        _ = await bench.link.ensureUp(evenIfRecent: true)
        await bench.television.goSilent(silent)
        XCTAssertTrue(bench.link.session.gaveUp)
        return bench
    }

    /// Sends `pressed` again on `bench`, and reads what that came to and left. No line is left up by it,
    /// and no packet is sent for it.
    private func resend(_ pressed: PendingReservation, on bench: QueueBench) async throws -> Resent {
        let asked = await bench.gate.asked.count, begun = bench.world.begun.count
        let tries = bench.link.session.link.tries
        let sent = await bench.driver.resend(pressed)
        XCTAssertNil(bench.world.line, "a line was left up")
        XCTAssertEqual(bench.world.count("packet"), 0, "a packet was sent to a television")
        return Resent(round: sent.round, listed: sent.list?.map(\.id),
                      asked: Array(await bench.gate.asked.dropFirst(asked)),
                      left: try await bench.store.pendingReservations(),
                      holds: await bench.television.schedules.map { "\($0.id) \($0.overlapStatus)" },
                      lines: Array(bench.world.begun.dropFirst(begun)), connects: bench.link.session.link.tries - tries)
    }

    /// A row sent again, each on a television of its own.
    ///
    /// A row that waits for the recorder is none of this driver's: nothing is asked, read or written for
    /// it, its reason stays, and the line of what went wrong is as it was. Nor is anything asked for a row
    /// that is no longer in the queue. A row of the television's with a reason the television gave it has
    /// the reason taken off and is made by a round for that one row, under the line for what waits: the six
    /// requests of a round and the read of the list, which is handed back. The rows beside it wait as they
    /// were, the one with a reason and the one without.
    ///
    /// A row held for what it would stop from recording keeps that reason, which is what the reader consents
    /// to by sending it again. The television is asked the question again, and where it names what the
    /// reason names the create goes and the recording named loses. Where it names another recording, nothing
    /// is made: the row is held with the reason that names that one. And where the reason in the queue is no
    /// longer the one on the row the reader pressed, nothing is asked and nothing changes.
    ///
    /// A television given up on is connected to, once. A row whose reason was taken off goes with that
    /// connect's own sending, and nothing follows the connect -- not where that sending found the row would
    /// stop a recording and held it for that, which the reader has not been asked about. A row held for
    /// what it would stop is not sent by an attach: it is sent after the connect, with its consent, when
    /// the television answers again, and stays held with its reason when it does not.
    func testWhatSendingARowAgainSendsAndLeaves() async throws {
        let sending = "テレビに送信待ちの予約を登録中", connecting = TVDriver.connectingLine
        let clash = self.clash(), film = clash.film, clashing = clash.clashing, holding = clash.holding
        var turnedDown = film
        turnedDown.problem = "この局は録画できません"
        let made = ["recording.1 notOverlapped"], question = Array(Self.round.prefix(4))

        let recorders = waiting("サンプル紀行", 50102, reason: turnedDown.problem, for: .recorder)
        let door = try await resendBench([recorders])
        door.world.problem = Self.left
        expectEqual(try await resend(recorders, on: door), Resent(asked: [], left: [recorders], holds: []),
                    "another device's row")
        XCTAssertEqual(door.world.problem, Self.left, "something was said for another device's row")
        expectEqual(try await resend(turnedDown, on: door), Resent(asked: [], left: [recorders], holds: []),
                    "a row that no longer waits")

        let held = waiting("サンプル劇場", 50101, in: 3, reason: turnedDown.problem)
        let unmarked = waiting("サンプル天気", 50103, in: 4)
        let freed = try await resendBench([turnedDown, held, unmarked])
        expectEqual(try await resend(turnedDown, on: freed),
                    Resent(round: .init(slot: .tv, sent: [film]), listed: ["recording.1"],
                           asked: Self.round + [Self.read], left: [held, unmarked], holds: made, lines: [sending]),
                    "a reason the television gave")

        let consented = try await resendBench([clashing], holding: holding)
        expectEqual(try await resend(clashing, on: consented),
                    Resent(round: .init(slot: .tv, sent: [clashing]), listed: clash.listed,
                           asked: Self.round + [Self.read], left: [], holds: clash.stopped, lines: [sending]),
                    "held for what the television names now")

        let renamed = try await resendBench([clash.stale], holding: holding)
        expectEqual(try await resend(clash.stale, on: renamed),
                    Resent(round: .init(slot: .tv, refused: [clashing]), asked: question, left: [clashing],
                           holds: clash.untouched, lines: [sending]),
                    "held for another recording than the television names now")

        let unseen = try await resendBench([clashing], holding: holding)
        expectEqual(try await resend(clash.stale, on: unseen),
                    Resent(asked: [], left: [clashing], holds: clash.untouched),
                    "the reason in the queue is not the one pressed")

        let away = try await resendBench([turnedDown], givenUp: true)
        expectEqual(try await resend(turnedDown, on: away),
                    Resent(asked: Self.attaching + Self.round, left: [], holds: made, lines: [connecting, sending],
                           connects: 1),
                    "a reason the television gave, the television given up on")
        XCTAssertEqual(away.sendings.came.last??.sent, [film], "not made by the connect's own sending")

        let back = try await resendBench([clashing], holding: holding, givenUp: true)
        expectEqual(try await resend(clashing, on: back),
                    Resent(round: .init(slot: .tv, sent: [clashing]), listed: clash.listed,
                           asked: Self.attaching + Self.round + [Self.read], left: [], holds: clash.stopped,
                           lines: [connecting, sending], connects: 1),
                    "held for what it would stop, the television given up on")

        let silent = try await resendBench([clashing], holding: holding, givenUp: true, silent: true)
        expectEqual(try await resend(clashing, on: silent),
                    Resent(asked: [Self.attaching[0]], left: [clashing], holds: clash.untouched, lines: [connecting],
                           connects: 1),
                    "held for what it would stop, the television still silent")

        let found = try await resendBench([turnedDown], holding: holding, givenUp: true)
        expectEqual(try await resend(turnedDown, on: found),
                    Resent(asked: Self.attaching + question, left: [clashing], holds: clash.untouched,
                           lines: [connecting, sending], connects: 1),
                    "a reason the television gave, and the connect's sending finds what the row would stop")
    }

    /// A consent is to one sentence, and for one round.
    ///
    /// Two sendings again begun together on one row, whose reason names a recording the television no
    /// longer names: both set out with the sentence the reader saw, the second while the first is still
    /// asking. The first is answered with another name and holds the row with the reason for that. The
    /// second then finds a reason on the row that is not the one it was handed, and asks nothing: one
    /// question in all, no create, and the television holds what it held. Nothing is made for a sentence no
    /// screen has shown.
    ///
    /// A row sent with a consent and left unsettled does not keep the reason it was held with, which would
    /// keep it from every later sending: passed over for an answer that says nothing, it waits with no
    /// reason. So does one whose create met silence, and what the line then says of it is so: the next
    /// connect looks for it in the television's list, finds it, and sends no second create.
    func testAConsentIsToTheSentencePressedAndForOneRound() async throws {
        let sending = "テレビに送信待ちの予約を登録中"
        let clash = self.clash(), film = clash.film, clashing = clash.clashing, holding = clash.holding
        let question = Array(Self.round.prefix(4))

        // The first's question is kept from being answered until the second has its line up as well.
        let twice = try await resendBench([clash.stale], holding: holding)
        await twice.gate.before(Self.question) { @MainActor in
            for _ in 0..<100_000 where twice.world.begun.filter({ $0 == sending }).count < 2 { await Task.yield() }
        }
        var before = await twice.gate.asked.count
        let first = Task { await twice.driver.resend(clash.stale) }
        let second = Task { await twice.driver.resend(clash.stale) }
        let rounds = [await first.value.round, await second.value.round].compactMap { $0 }
        expectEqual(Array(await twice.gate.asked.dropFirst(before)), question, "asked again, or a create sent")
        XCTAssertEqual([rounds.flatMap(\.refused), rounds.flatMap(\.held), rounds.flatMap(\.sent)],
                       [[clashing], [clashing], []])
        expectEqual(try await twice.store.pendingReservations(), [clashing])
        expectEqual(await twice.television.schedules, holding)

        let unsaid = try await resendBench([clashing], holding: holding)
        await unsaid.gate.answer(Self.question, with: HTTPResponse(
            statusCode: 200, body: Data(#"{"error":[\#(DemoTV.inventedError),"invented"],"id":1}"#.utf8)))
        expectEqual(try await resend(clashing, on: unsaid),
                    Resent(round: .init(slot: .tv, deferred: [clashing]), asked: question, left: [film],
                           holds: clash.untouched, lines: [sending]),
                    "passed over")

        let met = try await resendBench([clashing], holding: holding)
        await met.television.atTheNextCreate(.carriedOutAndNotAnswered)
        expectEqual(try await resend(clashing, on: met),
                    Resent(round: .init(slot: .tv, stopped: .silent(afterSending: true)),
                           asked: Array(Self.round.dropLast()), left: [film], holds: clash.stopped, lines: [sending]),
                    "silence at the create")
        XCTAssertEqual(met.world.problem, Self.metSilence)
        XCTAssertFalse(met.link.session.connected)

        before = await met.gate.asked.count
        await met.link.connect()
        expectEqual(Array(await met.gate.asked.dropFirst(before)), Self.attaching + [Self.disk, Self.read])
        XCTAssertEqual(met.sendings.came.last??.alreadyThere, [film])
        expectEqual(try await met.store.pendingReservations(), [])
        expectEqual(await met.television.schedules.map { "\($0.id) \($0.overlapStatus)" }, clash.stopped)
    }

    /// What a row sent again came to, as it is handed back for the screen the reader asked on, each on a
    /// television of its own. A row the result carries is the row as it waits afterwards, and all that
    /// waits.
    ///
    /// Nothing is handed back for another device's row, nor for one that no longer waits. A row the round
    /// made is made, sent with a consent or without. One for which the television names other recordings
    /// than its reason does would stop those, and carries the reason that names them. So does one whose
    /// reason in the queue is not the one pressed, as the queue has it and with nothing asked.
    ///
    /// A row with a reason the television gave, sent again to a television given up on, is left to the
    /// connect. Nothing is handed back where that connect's sending made the row: the host was asked for
    /// that sending and says it. Where the sending found what the row would stop, that is the answer.
    /// Where the television says nothing still, the row waits for it to answer. And where the connect got
    /// through and its sending left the row all the same, the row waits for the disk, or for answers that
    /// read: it is not said to wait for a connection there is.
    ///
    /// Where that sending turned the row down for a reason of its own -- a station the television's list
    /// does not have -- the answer is that reason on the row, and no question about what it would stop.
    /// Where its create met silence the row may be on the television: it is answered in the sentence for
    /// that, and not as one kept for a television that is not connected. Silence at what the sending reads
    /// before its create is not this, and nor is that sentence left on the line by an earlier create, under
    /// a connect that met silence itself: the row was sent nowhere, and waits for the television to answer.
    ///
    /// A row held for what it would stop that could not be sent keeps its reason, and is said not to have
    /// been sent: in the sentence for a television that is not connected, or for one that is to be
    /// registered. So is one whose round could not read the phone's queue, and so asked nothing about it.
    /// None of them is said to go by itself. A row that went with its consent and was left unsettled --
    /// passed over, or its create met by silence -- waits with no reason, and is handed back with none; so
    /// is one whose reason was taken off before a round that stopped at the disk.
    func testWhatARowSentAgainCameToIsHandedBack() async throws {
        let notConnected = "テレビに接続していません。テレビの電源とネットワーク接続を確認してください。"
        let toBeRegistered = "テレビへの登録が必要です。設定の「テレビ」から登録してください"
        let forTheDisk = "録画用の USB HDD が見つからないため、予約を端末に保存しました。"
            + "HDD が見つかったあと、テレビが答えたときに登録します。"
        let unanswered = "テレビの応答を読み取れなかったため、予約を端末に保存しました。"
            + "次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"
        let nothingSaid = HTTPResponse(
            statusCode: 200, body: Data(#"{"error":[\#(DemoTV.inventedError),"invented"],"id":1}"#.utf8))
        let clash = self.clash(), film = clash.film, clashing = clash.clashing, holding = clash.holding
        var turnedDown = film
        turnedDown.problem = "この局は録画できません"
        func expect(_ name: String, _ pressed: PendingReservation, on bench: QueueBench, _ expected: Reserved?,
                    line: UInt = #line) async throws {
            let came = await bench.driver.resend(pressed).came
            XCTAssertEqual(came, expected, name, line: line)
            let left = try await bench.store.pendingReservations().filter { $0.target == .tv }
            switch expected {
            case .wouldStop(let row)?, .waiting(let row, _)?: XCTAssertEqual(left, [row], name, line: line)
            default: XCTAssertEqual(left, [], name, line: line)
            }
        }

        let recorders = waiting("サンプル紀行", 50102, reason: turnedDown.problem, for: .recorder)
        let door = try await resendBench([recorders])
        try await expect("another device's row", recorders, on: door, nil)
        try await expect("a row that no longer waits", turnedDown, on: door, nil)

        try await expect("a reason the television gave", turnedDown, on: resendBench([turnedDown]),
                         .made(saying: nil))
        try await expect("held for what the television names now", clashing,
                         on: resendBench([clashing], holding: holding), .made(saying: nil))
        try await expect("held for another recording than the television names now", clash.stale,
                         on: resendBench([clash.stale], holding: holding), .wouldStop(clashing))
        let unseen = try await resendBench([clashing], holding: holding)
        let asked = await unseen.gate.asked
        try await expect("the reason in the queue is not the one pressed", clash.stale, on: unseen,
                         .wouldStop(clashing))
        expectEqual(await unseen.gate.asked, asked, "asked about a reason nobody pressed on")

        let away = try await resendBench([turnedDown], givenUp: true)
        try await expect("left to a connect whose sending made it", turnedDown, on: away, nil)
        XCTAssertEqual(away.sendings.came.last??.sent, [film], "not made by the connect's own sending")
        XCTAssertEqual(away.world.count("send what waits"), 2, "the host was not asked to send what waits")
        try await expect("left to a connect whose sending found what it would stop", turnedDown,
                         on: resendBench([turnedDown], holding: holding, givenUp: true), .wouldStop(clashing))
        try await expect("left to a connect that met silence", turnedDown,
                         on: resendBench([turnedDown], givenUp: true, silent: true),
                         .waiting(film, saying: Self.waitsNotConnected))
        let noDisk = try await resendBench([turnedDown], givenUp: true)
        await noDisk.television.unmount()
        try await expect("left to a connect that got through, the disk away", turnedDown, on: noDisk,
                         .waiting(film, saying: forTheDisk))
        let unread = try await resendBench([turnedDown], givenUp: true)
        await unread.gate.answer(Self.question, with: nothingSaid)
        try await expect("left to a connect that got through, its answers saying nothing", turnedDown, on: unread,
                         .waiting(film, saying: unanswered))
        var unlisted = waiting("サンプル紀行", 50102, reason: turnedDown.problem)
        unlisted.request.serviceID = 1040
        var notListed = unlisted
        notListed.problem = "テレビのチャンネル一覧にこの局が見つかりませんでした。"
        try await expect("left to a connect whose sending turned it down", unlisted,
                         on: resendBench([unlisted], givenUp: true),
                         .waiting(notListed, saying: "テレビのチャンネル一覧にこの局が見つかりませんでした。"))
        let metAtTheCreate = try await resendBench([turnedDown], givenUp: true)
        await metAtTheCreate.television.atTheNextCreate(.carriedOutAndNotAnswered)
        try await expect("left to a connect whose create met silence", turnedDown, on: metAtTheCreate,
                         .waiting(film, saying: Self.metSilence))
        XCTAssertEqual(metAtTheCreate.world.problem, Self.metSilence)
        let metAtARead = try await resendBench([turnedDown], givenUp: true)
        await metAtARead.gate.silence(Self.stations)
        try await expect("left to a connect whose sending met silence before its create", turnedDown, on: metAtARead,
                         .waiting(film, saying: Self.waitsNotConnected))
        let saidBefore = try await resendBench([turnedDown], givenUp: true, silent: true)
        saidBefore.world.problem = Self.metSilence
        try await expect("left to a connect that met silence, an earlier create's sentence on the line", turnedDown,
                         on: saidBefore, .waiting(film, saying: Self.waitsNotConnected))
        XCTAssertEqual(saidBefore.world.problem, Self.metSilence, "the connect wrote over what the create said")

        try await expect("held for what it would stop, the television still silent", clashing,
                         on: resendBench([clashing], holding: holding, givenUp: true, silent: true),
                         .waiting(clashing, saying: notConnected))
        let unregistered = try await resendBench([clashing], holding: holding)
        unregistered.credentials.save(Self.stale)
        _ = await unregistered.driver.reservations()
        XCTAssertTrue(unregistered.driver.facts.needsPairing)
        try await expect("held for what it would stop, the television to be registered", clashing,
                         on: unregistered, .waiting(clashing, saying: toBeRegistered))

        let passedOver = try await resendBench([clashing], holding: holding)
        await passedOver.gate.answer(Self.question, with: nothingSaid)
        try await expect("sent with its consent and passed over", clashing, on: passedOver,
                         .waiting(film, saying: unanswered))
        let met = try await resendBench([clashing], holding: holding)
        await met.television.atTheNextCreate(.carriedOutAndNotAnswered)
        try await expect("sent with its consent, its create met by silence", clashing, on: met,
                         .waiting(film, saying: Self.metSilence))
        let diskAway = try await resendBench([turnedDown])
        await diskAway.television.unmount()
        try await expect("its reason taken off, the disk away", turnedDown, on: diskAway,
                         .waiting(film, saying: forTheDisk))

        // The queue's table is put out of reach from another connection, on purpose, from the check before
        // the round until the list after it, as for a reservation whose round could not read the queue: the
        // round comes back empty, and the row is in the queue as it was, held with the reason pressed.
        let unreadable = try await resendBench([], holding: holding)
        let path = temporaryPath()
        let store = try GuideStore(path: path)
        try await store.queue(clashing)
        unreadable.world.cache = store
        let other = try Sqlite(path: path)
        await unreadable.gate.before("getPowerStatus") { @MainActor in
            for _ in 0..<100_000 where !unreadable.world.begun.contains(TVDriver.sendingLine) { await Task.yield() }
            try? other.execute("ALTER TABLE pending_reservations RENAME TO out_of_reach")
        }
        await unreadable.gate.before(Self.read) { @MainActor in
            try? other.execute("ALTER TABLE out_of_reach RENAME TO pending_reservations")
        }
        let before = await unreadable.gate.asked.count
        let checking = Task { await unreadable.link.ensureUp(evenIfRecent: true) }
        let came = await unreadable.driver.resend(clashing).came
        expectTrue(await checking.value)
        XCTAssertEqual(came, .waiting(clashing, saying: notConnected), "a round that could not read the queue")
        expectEqual(Array(await unreadable.gate.asked.dropFirst(before)), ["getPowerStatus", Self.read])
        expectEqual(try await store.pendingReservations(), [clashing])
    }

    /// What is left to say beside a waiting row once it has been sent again, with no television: the row
    /// is on the screen with its reason, so a result that says only that reason leaves nothing. A row that
    /// was made has left what waits, whatever was said of making it. One held for what it would stop is
    /// said by its reason, whole, down to how the reader says to make it all the same. One that waits is
    /// said by whatever is not its own reason: why it was not sent, where it keeps one, and how it goes by
    /// itself, where it has none. What was neither made nor kept is said as it is.
    func testWhatIsLeftToSayBesideAWaitingRowIsWhatTheRowDoesNotSay() throws {
        let notConnected = "テレビに接続していません。テレビの電源とネットワーク接続を確認してください。"
        let clash = self.clash(), film = clash.film, clashing = clash.clashing
        var unlisted = film
        unlisted.problem = "テレビのチャンネル一覧にこの局が見つかりませんでした。"
        let names = try XCTUnwrap(clashing.problem)
        XCTAssertTrue(names.hasSuffix("「もう一度送る」を選ぶと、それでも予約します。"), names)
        let cases: [(name: String, came: Reserved, says: String?)] = [
            ("made", .made(saying: nil), nil),
            ("made, and found there", .made(saying: "テレビにはこの番組の予約がすでにありました。"), nil),
            ("held for what it would stop", .wouldStop(clashing), names),
            ("turned down, with the reason on the row", .waiting(unlisted, saying: unlisted.problem ?? ""), nil),
            ("held, and not sent", .waiting(clashing, saying: notConnected), notConnected),
            ("waiting with no reason", .waiting(film, saying: Self.waitsNotConnected), Self.waitsNotConnected),
            ("neither made nor kept", .notDone(Self.programmeIsOver), Self.programmeIsOver),
        ]
        for (name, came, says) in cases {
            XCTAssertEqual(came.besideItsRow, says, name)
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
