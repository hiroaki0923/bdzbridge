import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The demo's television: found by the demo's search, registered with the number the sheet says, reserved on,
/// changed and deleted from, sent to and taken away, in memory alone. Each test but the last two starts in a home
/// with a real television saved beside the recorder -- its address and MAC, a registration it knows, and a record
/// of what the runs with no screen told of it, with rows -- so that what the demo is to leave alone is there to
/// be touched: with nothing saved, "as it was" would hold whatever the demo did. The real television's
/// registration is kept in a store that writes down each call made to it, which in the app is the Keychain item
/// and its key file: nothing in the demo reaches it, a read included. Nor does anything in the demo take the
/// bench's way to a television for any address, or look at the local network permission, so nothing goes on
/// the LAN; and the real television hears nothing.
@MainActor
final class DemoTelevisionTests: XCTestCase {
    /// In the demo the demo's television is found at its address, asks for its number, turns a wrong one down
    /// and is registered with the one the sheet says: its link is made and connected as the demo's, it says
    /// what it is, a found television can no longer be tapped, and a reservation can go to both devices. An
    /// address of the real television's, typed in the demo, says nothing at once, with nothing asked of the
    /// permission and nothing sent to the television there.
    func testTheDemosTelevisionIsRegisteredByItsNumberAndNothingRealIsReached() async throws {
        let home = try await atHome()
        let model = home.model
        let before = kept(home)
        let then = try await intoTheDemo(home)

        let typed = try await within(2, "an address typed in the demo was waited on") {
            await model.findTV(at: Bench.tvHost)
        }
        XCTAssertEqual(typed, .nothing, "the real television answered in the demo")

        expectEqual(await model.findTV(at: DemoData.tvHost), .on(model: DemoTV.model))
        expectEqual(await model.registerTV(at: DemoData.tvHost, pin: nil), .pinNeeded)
        expectEqual(await model.registerTV(at: DemoData.tvHost, pin: "0000"), .pinNeeded)
        XCTAssertNil(model.tv, "a wrong number registered the demo's television")
        expectEqual(await model.registerTV(at: DemoData.tvHost, pin: DemoTV.pin), .registered)

        XCTAssertTrue(model.demo)
        XCTAssertEqual(model.tv?.host, DemoData.tvHost)
        XCTAssertEqual(model.tv?.session.connected, true, "the demo's television was not connected")
        XCTAssertEqual(model.tvDriver?.facts.model, DemoTV.model)
        XCTAssertNotNil(model.demoTVCredentials?.load(), "the demo's registration was kept nowhere")
        XCTAssertFalse(model.canAddAFoundTelevision, "a found television could be tapped with the demo's added")
        XCTAssertTrue(model.inUse(TVSighting(host: DemoData.tvHost, model: DemoTV.model)))
        XCTAssertEqual(model.destinations, [.recorder, .tv])
        await expectNothingReal(home, since: then, keeping: before)
    }

    /// On the demo's television, once added: what it holds from the start is listed under its guide's title and
    /// marked in the guide; a programme of the guide reserved on it is made and listed under the guide's title,
    /// its repeat is changed and the change listed, and it is deleted; and a reservation waiting for it is sent
    /// as a pull-down sends one. What the runs with no screen told of the real television stays as it was,
    /// though a sending of the app's own takes the warning of reservations not yet sent away from a real one.
    func testTheDemosTelevisionIsReservedOnChangedDeletedFromAndSentTo() async throws {
        let home = try await atHome()
        let model = home.model
        let before = kept(home)
        let then = try await intoTheDemo(home)
        try await register(model)
        let host = try XCTUnwrap(model.tvHost)

        XCTAssertEqual(host.reservations.count, 1, "the demo's television did not hold one reservation of its own")
        let held = try XCTUnwrap(host.reservations.first)
        let programme = await model.program(for: held)
        let heldProgramme = try XCTUnwrap(programme, "what it holds is no programme of the guide")
        XCTAssertEqual(held.title, heldProgramme.title)
        XCTAssertEqual(model.reservation(for: heldProgramme)?.device, .tv, "the guide did not mark what it holds")

        let wanted = try await programmesNotReserved(model, 2)
        XCTAssertEqual(model.destinations(for: wanted[0]), [.recorder, .tv])
        expectEqual(await model.reserve(wanted[0], on: .tv, quality: "DR", repeating: "none"), .made(saying: nil))
        let made = try XCTUnwrap(model.reservations(for: wanted[0]).first { $0.device == .tv })
        XCTAssertEqual(made.title, wanted[0].title, "made under another title than the guide's")
        expectEqual(await model.change(made, quality: "DR", repeating: "daily"), .done(saying: nil))
        let changed = try XCTUnwrap(model.reservations(for: wanted[0]).first { $0.device == .tv })
        XCTAssertEqual(changed.repeatName, "daily")
        expectTrue(await deleteAReservation(model, changed), "the reservation was not deleted")
        XCTAssertEqual(model.reservations(for: wanted[0]), [], "the demo's television still holds it")

        let store = try XCTUnwrap(model.store)
        try await store.queue(try waiting(wanted[1]))
        await host.refreshReservations()
        expectEqual(try await store.pendingReservations(), [], "what waited for the demo's television was not sent")
        XCTAssertEqual(model.reservations(for: wanted[1]).map(\.title), [wanted[1].title])
        await expectNothingReal(home, since: then, keeping: before)
    }

    /// テレビを外す in the demo takes the demo's television away as it takes a real one: what waits for it is
    /// deleted unsent, and its link and its registration go, in memory. The demo goes on, and the real
    /// television's address, MAC, registration and what was told of it stay as they were.
    func testTakingTheDemosTelevisionAwayTakesItsRowsAndRegistrationAndNothingReal() async throws {
        let home = try await atHome()
        let model = home.model
        let before = kept(home)
        let then = try await intoTheDemo(home)
        try await register(model)
        try await XCTUnwrap(model.store).queue(try waiting(try await programmesNotReserved(model, 1)[0]))
        expectEqual(await model.waitingForTheTelevision(), 1)

        expectTrue(await model.takeTheTelevisionAway(counted: 1), "the demo's television was not taken away")

        XCTAssertTrue(model.demo)
        XCTAssertNil(model.tv)
        XCTAssertNil(model.demoTVHost)
        XCTAssertNil(model.demoTVCredentials?.load(), "the demo's registration stayed")
        expectEqual(await model.waitingForTheTelevision(), 0, "what waited for it stayed")
        await expectNothingReal(home, since: then, keeping: before)
    }

    /// Ending the demo takes its television with it -- its link, the television, its registration and what
    /// waited for it -- and gives the real television back as it was: its link made from what is saved and
    /// connected, with no number asked of the reader. No client id goes from one to the other: a registration
    /// under way before the demo is not the demo's, and none under way in it outlives it. After the end the
    /// demo's address reaches nothing, and no television's transport is taken for it. Started again, the demo
    /// has no television, nothing waits for one, and its search lists the demo's to be added.
    func testEndingTheDemoTakesItsTelevisionAndGivesTheRealOneBackAsItWas() async throws {
        let home = try await atHome()
        let model = home.model
        // A registration again begun and not gone through: its client id is in hand as the demo begins.
        let attempt = await model.registerTV(at: "192.0.2.31", pin: nil)
        XCTAssertNotEqual(attempt, .registered, "nobody answered there")
        XCTAssertEqual(model.tvClientID, "BDBridge:real")
        let before = kept(home)
        let then = try await intoTheDemo(home)
        XCTAssertNil(model.tvClientID, "the real registration's client id was taken into the demo")
        try await register(model)
        XCTAssertNotEqual(model.demoTVCredentials?.load()?.clientID, "BDBridge:real")
        try await XCTUnwrap(model.store).queue(try waiting(try await programmesNotReserved(model, 1)[0]))
        model.scanForDevices()
        try await until("the demo's search never ended") { model.scanOutcome != nil }
        await expectNothingReal(home, since: then, keeping: before)
        // A registration again begun in the demo and not gone through: its client id is in hand as it ends.
        _ = await model.registerTV(at: "192.0.2.31", pin: nil)
        XCTAssertNotNil(model.tvClientID, "the demo's registration left no client id to outlive it")

        await model.leaveDemo()

        XCTAssertFalse(model.demo)
        XCTAssertEqual(model.tv?.host, Bench.tvHost, "the real television's link was not made again")
        XCTAssertNil(model.demoTV)
        XCTAssertNil(model.demoTVCredentials)
        XCTAssertNil(model.demoTVHost)
        XCTAssertNil(model.tvClientID)
        XCTAssertEqual(model.foundTelevisions, [], "the demo's television was listed after it")
        XCTAssertNil(model.scanOutcome)
        try await untilTheTelevisionIsConnected(model)
        XCTAssertEqual(model.tvDriver?.facts.needsPairing, false, "the real television wanted a number")
        expectFalse(await home.television.calls.contains { $0.hasSuffix("pin=yes") }, "a number was asked")
        XCTAssertEqual(kept(home), before)
        expectEqual(await model.waitingForTheTelevision(), 0, "what waited for the demo's television waits on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Storage.guidePath(demo: true, in: home.bench.folder)),
                       "the demo's cache was left")

        let made = home.bench.televisionTransportsMade
        let found = try await within(2, "the demo's address was waited on after the demo") {
            await model.findTV(at: DemoData.tvHost)
        }
        XCTAssertEqual(found, .nothing, "the demo's address answered after the demo")
        XCTAssertEqual(home.bench.televisionTransportsMade.dropFirst(made.count).filter { $0 == DemoData.tvHost }, [],
                       "a way to the LAN was taken for the demo's address")

        await model.enterDemo()
        try await untilIdle(model)
        XCTAssertNil(model.tv, "the demo's television was kept for the next demo")
        expectEqual(await model.waitingForTheTelevision(), 0, "what waited for it was kept for the next demo")
        model.scanForDevices()
        try await until("the demo's search never ended") { model.scanOutcome != nil }
        XCTAssertEqual(model.foundTelevisions, [TVSighting(host: DemoData.tvHost, model: DemoTV.model)])
        XCTAssertTrue(model.canAddAFoundTelevision)
        XCTAssertFalse(model.foundTelevisions.contains(where: model.inUse), "the demo's television was in use")
        await model.leaveDemo()
    }

    /// The demo's television is in memory alone: a launch with the demo on -- the app ended while it was -- has
    /// none, and what waited for it in the demo's cache is deleted as the cache opens, so nothing waits for a
    /// television that is not there. What waits for the demo's recorder, held for the reader by its reason, is
    /// left.
    func testALaunchWithTheDemoOnHasNoTelevisionAndNothingWaitsForOne() async throws {
        let bench = try aBench()
        DemoData.turnOn(realHost: "", realMac: nil, in: bench.defaults)
        let demoGuide = try GuideStore(path: Storage.guidePath(demo: true, in: bench.folder))
        let later = Date().addingTimeInterval(86_400)
        var forTheTelevision = PendingReservation(
            request: ReservationRequest(title: "みほん自然紀行", start: later, durationSec: 7200, repeatCode: "1",
                                        broadcastingType: 2, serviceID: 1032, qualityCode: 100, eventID: 1110),
            serviceName: "サンプル教育")
        forTheTelevision.target = .tv
        let heldForTheReader = PendingReservation(
            request: ReservationRequest(title: "サンプル古典芸能", start: later, durationSec: 3600, repeatCode: "1",
                                        broadcastingType: 2, serviceID: 1032, qualityCode: 100, eventID: 1111),
            serviceName: "サンプル教育", problem: "サンプルの理由")
        try await demoGuide.queue(forTheTelevision)
        try await demoGuide.queue(heldForTheReader)

        let model = bench.modelWithNoRecorder()
        XCTAssertTrue(model.demo)
        XCTAssertNil(model.tv)
        await model.start()

        expectEqual(try await demoGuide.pendingReservations().map(\.id), [heldForTheReader.id])
        XCTAssertNil(model.tv)
    }

    /// The demo's television receives every station of the demo's guide, by its kind of broadcast and its service
    /// id and under the guide's name, subscribed: any programme of the guide can be reserved on it.
    func testTheDemosTelevisionReceivesEveryStationOfTheDemosGuide() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let guide = try GuideStore(path: bench.guidePath)
        var listed: [String] = []
        for (broadcasting, scheme) in [("td", "isdbt"), ("bs", "isdbbs"), ("cs", "isdbcs"), ("bs4k", "isdbs3bs")] {
            listed += try await guide.channels(broadcasting: broadcasting, includeHidden: true)
                .map { "\(scheme) \($0.serviceID) \($0.name)" }
        }

        let received = await DemoData.television().stations
        XCTAssertEqual(received.map { "\($0.scheme) \($0.serviceID) \($0.name)" }.sorted(), listed.sorted())
        XCTAssertTrue(received.allSatisfy { $0.subscribed && $0.programMediaType == "tv" })
    }

    /// テレビを外す pressed on the demo's television while a sending of a run with no screen has the queue's
    /// turn, and the demo ended before that turn comes: what goes through then would be about the real
    /// television, which the reader was not asked about. It goes through not at all, and the real television,
    /// its registration and what the app keeps of it are as they were.
    func testTakingTheDemosTelevisionAwayHeldOverTheDemosEndTakesNothingReal() async throws {
        let home = try await atHome()
        let model = home.model
        let before = kept(home)
        _ = try await intoTheDemo(home)
        try await register(model)
        expectEqual(await model.waitingForTheTelevision(), 0)

        let (released, release) = AsyncStream<Void>.makeStream()
        let holding = Task { await PendingQueue.betweenFlushes { for await _ in released { break }; return true } }
        try await Task.sleep(for: .milliseconds(300))
        let away = Task { await model.takeTheTelevisionAway(counted: 0) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.tv?.host, DemoData.tvHost, "外す did not wait for the queue's turn")
        let leaving = Task { await model.leaveDemo() }
        try await until("the demo never ended") { !model.demo }
        XCTAssertEqual(model.tv?.host, Bench.tvHost, "the real television's link was not made again")

        release.yield()
        release.finish()
        _ = await holding.value
        let tookAway = await away.value
        await leaving.value
        XCTAssertFalse(tookAway, "外す of the demo's television went through after the demo")
        XCTAssertEqual(model.tv?.host, Bench.tvHost, "the real television was taken away by the demo's 外す")
        XCTAssertNotNil(home.credentials.held, "the real television's registration was removed")
        XCTAssertEqual(kept(home), before, "what the app keeps of the real television changed")
    }

    // MARK: - what the tests set up

    /// The real television's MAC: another than the demo's own (`DemoTV.mac`), so that the demo's written in its
    /// place would be seen.
    private static let realMac = "f8:4e:17:00:00:0b"

    /// A home with the recorder and a real television saved, and the model started and connected to both.
    private struct Home {
        let bench: Bench
        let model: AppModel
        let television: DemoTV
        let credentials: WatchedCredentials
    }

    private func atHome() async throws -> Home {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV(mac: Self.realMac)
        await television.knows("BDBridge:real", cookie: "kept")
        let credentials = WatchedCredentials(TVCredentials(clientID: "BDBridge:real", cookie: "kept",
                                                           cookieReceived: Date().addingTimeInterval(-86_400),
                                                           cookieMaxAge: 1_209_600))
        bench.defaults.set(Self.realMac, forKey: DefaultsKey.tvMac)
        bench.defaults.set(try JSONEncoder().encode(TVTold(stop: .registration, rows: ["サンプルの行"])),
                           forKey: DefaultsKey.tvTold)
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials)
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        return Home(bench: bench, model: model, television: television, credentials: credentials)
    }

    /// What the app keeps of the real television: what the demo is to leave as it was.
    private struct Kept: Equatable {
        var host: String?
        var mac: String?
        var told: Data?
        var registration: TVCredentials?
    }

    private func kept(_ home: Home) -> Kept {
        Kept(host: home.bench.defaults.string(forKey: DefaultsKey.tvHost),
             mac: home.bench.defaults.string(forKey: DefaultsKey.tvMac),
             told: home.bench.defaults.data(forKey: DefaultsKey.tvTold),
             registration: home.credentials.held)
    }

    /// What had reached the real television, its registration and the way to the LAN as the demo began.
    private struct Reached {
        let calls: [String]
        let heard: [String]
        let transports: [String]
    }

    /// Turns to the demo and waits for its connect: the real television is let go of, and whatever reaches it,
    /// its registration or the LAN from here on is the demo's doing.
    private func intoTheDemo(_ home: Home) async throws -> Reached {
        await home.model.enterDemo()
        try await untilIdle(home.model)
        XCTAssertTrue(home.model.demo)
        XCTAssertNil(home.model.tv, "the real television was not let go of")
        return Reached(calls: home.credentials.calls, heard: await home.television.calls,
                       transports: home.bench.televisionTransportsMade)
    }

    /// Holds that nothing in the demo has reached the real television since it began: no call to its
    /// registration's store, no request to it, no way to a television on the LAN taken for any address, no look
    /// at the local network permission; and that what the app keeps of it is as it was before the demo.
    private func expectNothingReal(_ home: Home, since then: Reached, keeping before: Kept,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(home.credentials.calls, then.calls, "the real registration was reached from the demo",
                       file: file, line: line)
        expectEqual(await home.television.calls, then.heard, "the real television was asked from the demo",
                    file: file, line: line)
        XCTAssertEqual(home.bench.televisionTransportsMade, then.transports, "a way to the LAN was taken in the demo",
                       file: file, line: line)
        XCTAssertEqual(home.bench.permissionLooks, [], "the permission was looked at in the demo", file: file, line: line)
        XCTAssertEqual(kept(home), before, "what the app keeps of the real television changed", file: file, line: line)
    }

    /// Registers the demo's television as the sheet does: found at its address, asked for its number, and
    /// given the one the sheet says.
    private func register(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        expectEqual(await model.findTV(at: DemoData.tvHost), .on(model: DemoTV.model), file: file, line: line)
        expectEqual(await model.registerTV(at: DemoData.tvHost, pin: nil), .pinNeeded, file: file, line: line)
        expectEqual(await model.registerTV(at: DemoData.tvHost, pin: DemoTV.pin), .registered, file: file, line: line)
        try await untilTheTelevisionIsConnected(model)
    }

    /// A reservation of `program` waiting for the television, in DR and not repeated, as one the television did
    /// not answer for would be kept.
    private func waiting(_ program: GuideProgramRow) throws -> PendingReservation {
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        return PendingReservation(request: request, serviceName: program.serviceName, target: .tv)
    }
}

/// The real television's registration as the app keeps it, with each call the app makes to it written down: in
/// the app it is the Keychain item and its key file (`KeychainTVCredentials`).
private final class WatchedCredentials: TVCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: TVCredentials?
    private var made: [String] = []

    init(_ credentials: TVCredentials?) {
        kept = credentials
    }

    /// Each call made to it, `load`, `save` or `remove`, in order.
    var calls: [String] { lock.withLock { made } }
    /// What it holds, as the test looks at it: not written down among the calls.
    var held: TVCredentials? { lock.withLock { kept } }

    func load() -> TVCredentials? {
        lock.withLock {
            made.append("load")
            return kept
        }
    }

    func save(_ credentials: TVCredentials) {
        lock.withLock {
            made.append("save")
            kept = credentials
        }
    }

    func remove() {
        lock.withLock {
            made.append("remove")
            kept = nil
        }
    }
}
