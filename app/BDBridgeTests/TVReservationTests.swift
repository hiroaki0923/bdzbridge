import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The television's reservations beside the recorder's: each row is sent to the device that holds it and to no
/// other, the two lists and the two lines of what went wrong are kept apart, and a television the app has let go
/// of leaves nothing on the screens. How a television's list is read and a reservation taken off it, step by
/// step and sentence by sentence, is RecorderKit's to hold (`TVDriverTests`).
@MainActor
final class TVReservationTests: XCTestCase {
    /// A home with both devices, each connected: a recorder that counts what it is asked, a television the app
    /// is registered with, and what stands between the app and that television, for a test that holds one of
    /// its answers.
    private struct Home {
        let recorder: NamedRecorder
        let television: DemoTV
        let door: HeldTelevision
        let credentials: MemoryTVCredentials
        let model: AppModel
    }

    /// The home, with `schedules` on the television from before the app connected: its list has been read.
    /// The television is in standby, unless a test brings one of its own.
    private func atHome(_ schedules: [DemoTV.Schedule] = [], television: DemoTV = DemoTV()) async throws -> Home {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        await television.put(schedules)
        let door = HeldTelevision(television, holding: false)
        let credentials = await registered(with: television)
        let model = bench.model(recorder: recorder, television: door, credentials: credentials)
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        return Home(recorder: recorder, television: television, door: door, credentials: credentials, model: model)
    }

    /// Two hours from when the tests began, to the second, as a television writes a start: one moment for
    /// every row made here, so that a row made twice is the same row.
    private static let soon = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 7200).rounded())

    /// A reservation on the invented television, numbered as a television numbers its own: made by its times,
    /// or following `program` -- the same kind of broadcast, service and programme as the guide has it, which
    /// is what makes it the same programme as a recorder's reservation of it.
    private static func row(_ number: Int, following program: GuideProgramRow? = nil) -> DemoTV.Schedule {
        guard let program else { return DemoTV.Schedule(id: "recording.\(number)", start: soon) }
        return DemoTV.Schedule(id: "recording.\(number)", scheme: program.broadcasting == "bs" ? "isdbbs" : "isdbt",
                               serviceID: program.serviceID, station: program.serviceName, title: program.title,
                               start: program.start, durationSec: program.durationSec, eventId: program.eventID)
    }

    /// A line an earlier operation left, for a test that looks at whether it was written over.
    private static let left = "前の操作が残した文"

    /// A recorder's own reservation, one that follows a programme of the guide and is not being recorded.
    private func aRecordersReservation(_ model: AppModel) throws -> Reservation {
        try XCTUnwrap(model.reservations.first { $0.eventID != nil && !$0.createdByRecorder && !$0.recording })
    }

    // MARK: - each row to its own device

    /// One programme is set to record on both devices, each under a number of its own. A change or a delete of
    /// the television's row -- picked from the television's list, or found by the programme -- sends the
    /// recorder nothing at all, not the read its own delete begins with: the delete goes to the television,
    /// once, and the change, which nothing makes yet, goes nowhere and is said on the television's line. A
    /// change turned down hands back no list, and the one the television gave stands, with its time. The
    /// recorder's reservation and the guide's mark stay. The recorder's row, changed and deleted, is the
    /// recorder's alone, and the television's reservation of the programme then keeps the guide's mark.
    func testARowGoesToTheDeviceThatHoldsItAndToNoOther() async throws {
        let home = try await atHome()
        let (recorder, television, model) = (home.recorder, home.television, home.model)
        let host = try XCTUnwrap(model.tvHost)
        let recorders = try aRecordersReservation(model)
        let found = await model.program(for: recorders)
        let program = try XCTUnwrap(found, "the recorder's reservation follows no programme of the guide")
        let same = Self.row(41, following: program), other = Self.row(42)
        model.problem = Self.left

        let ways: [(String, @MainActor () -> Reservation?)] = [
            ("picked from the television's list", { host.reservations.first { $0.id == same.id } }),
            ("found by its programme", { model.reservations(for: program).first { $0.device == .tv } }),
        ]
        for (way, pick) in ways {
            await television.put([same, other])
            await host.loadReservations()
            XCTAssertEqual(model.reservations(for: program).map(\.device), [.recorder, .tv], way)
            XCTAssertEqual(model.reservation(for: program), recorders, "the guide's mark is not the recorder's, \(way)")
            let row = try XCTUnwrap(pick(), way)
            XCTAssertEqual(row.device, .tv, way)
            let asked = await recorder.asked, calls = await television.calls
            let listed = host.reservations, read = host.reservationsRead

            expectFalse(await model.update(row, quality: "DR", repeating: "none"), way)

            expectEqual(await recorder.asked, asked, "a change of the television's row reached the recorder, \(way)")
            expectEqual(await television.calls, calls, "a change nothing makes yet was sent, \(way)")
            XCTAssertEqual(model.problem(for: .tv), TVDriver.changesNotYet, way)
            XCTAssertEqual(model.problem, Self.left, "the television's refusal is on the recorder's line, \(way)")
            XCTAssertEqual(host.reservations, listed, "a change turned down took the television's list, \(way)")
            XCTAssertEqual(host.reservationsRead, read, "a change turned down counts as a read, \(way)")

            expectTrue(await model.cancel(row), model.problem(for: .tv) ?? way)

            expectEqual(await recorder.asked, asked, "a delete of the television's row reached the recorder, \(way)")
            let sent = Array(await television.calls.dropFirst(calls.count))
            XCTAssertEqual(sent.filter { $0.hasPrefix("deleteSchedule") }.count, 1, way)
            expectEqual(await television.schedules.map(\.id), [other.id], way)
            XCTAssertEqual(host.reservations.map(\.id), [other.id], way)
            XCTAssertNil(model.problem(for: .tv), way)
            XCTAssertEqual(model.problem(for: .recorder), Self.left, way)
            XCTAssertEqual(model.reservation(for: program), recorders, "the guide's mark went with the television's")
            XCTAssertTrue(model.reservations.contains(recorders), "the recorder's reservation went with it, \(way)")
        }

        await television.put([same, other])
        await host.loadReservations()
        host.problem = Self.left
        let asked = await recorder.asked, calls = await television.calls

        expectTrue(await model.update(recorders, quality: "DR", repeating: "none"), model.problem ?? "no reason given")
        let changed = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(changed.device, .recorder)
        expectTrue(await model.cancel(changed), model.problem ?? "no reason given")

        expectEqual(await recorder.asked("X_UpdateRecordSchedule", since: asked), 1)
        expectEqual(await recorder.asked("X_DeleteRecordSchedule", since: asked), 1)
        expectEqual(await television.calls, calls, "the recorder's row reached the television")
        expectEqual(await television.schedules.map(\.id), [same.id, other.id])
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.problem(for: .tv), Self.left, "the recorder's work cleared the television's line")
        XCTAssertEqual(model.reservations(for: program).map(\.device), [.tv])
        XCTAssertEqual(model.reservation(for: program)?.device, .tv, "the television's reservation has no mark")
    }

    // MARK: - two lists, two lines

    /// Each device numbers its own, so a row of each can carry the same id. In the list of both they are told
    /// apart by their keys, and the television's is found by its own and deleted without a word to the
    /// recorder. The television's rows are among 通常の予約 and never among おまかせ; what overlaps a
    /// reservation is looked for among its own device's; and a channel the guide does not have goes by the
    /// name the television gave. A delete the television turns down is said on the television's line, the
    /// recorder's left as it was, and the list read on the way is the one kept.
    func testTheTwoDevicesListsAndLinesAreKeptApart() async throws {
        let home = try await atHome()
        let (recorder, television, model) = (home.recorder, home.television, home.model)
        let host = try XCTUnwrap(model.tvHost)
        let recorders = try aRecordersReservation(model)
        let alone = model.overlapping(recorders)
        // The television's, at the recorder's reservation's own hours: one under the same id, on a channel the
        // guide does not have, and one on a channel it has, under another name than the guide's.
        let twin = DemoTV.Schedule(id: recorders.id, serviceID: 1999, station: "みほん放送", title: "サンプル特番",
                                   start: recorders.start, durationSec: recorders.durationSec)
        let beside = DemoTV.Schedule(id: "recording.42", serviceID: recorders.serviceID, station: "サンプルＴＶ",
                                     start: recorders.start, durationSec: recorders.durationSec)
        await television.put([twin, beside])
        await host.loadReservations()
        let twinRow = try XCTUnwrap(host.reservations.first { $0.id == recorders.id })
        let besideRow = try XCTUnwrap(host.reservations.first { $0.id == beside.id })

        XCTAssertNotEqual(twinRow.listKey, recorders.listKey)
        XCTAssertEqual(model.reservation(listKey: twinRow.listKey), twinRow)
        XCTAssertEqual(model.reservation(listKey: recorders.listKey), recorders)
        XCTAssertEqual(model.shownReservations, model.reservations + host.reservations)
        XCTAssertEqual(model.shownReservations.filter { $0.id == recorders.id }.map(\.device), [.recorder, .tv])
        model.reservationKind = .automatic
        XCTAssertFalse(model.shownReservations.isEmpty, "the recorder has none of its own to tell them from")
        XCTAssertFalse(model.shownReservations.contains { $0.device == .tv }, "a television's row among おまかせ")
        XCTAssertNotNil(model.reservation(listKey: twinRow.listKey), "found only among the kind shown")
        model.reservationKind = .mine
        XCTAssertEqual(model.shownReservations.filter { $0.device == .tv }, host.reservations)
        model.reservationKind = .all

        XCTAssertEqual(model.overlapping(recorders), alone, "a television's row overlaps the recorder's")
        XCTAssertEqual(model.overlapping(twinRow), [besideRow])
        XCTAssertEqual(model.channelName(for: twinRow), "みほん放送")
        XCTAssertEqual(model.channelName(for: besideRow), model.channelName(for: recorders))

        var asked = await recorder.asked
        expectTrue(await model.cancel(twinRow), model.problem(for: .tv) ?? "no reason given")

        expectEqual(await recorder.asked, asked, "the television's row took the recorder's of the same id with it")
        expectEqual(await television.schedules.map(\.id), [beside.id])
        XCTAssertNil(model.reservation(listKey: twinRow.listKey))
        XCTAssertEqual(model.reservation(listKey: recorders.listKey), recorders)

        // Behind the app's back the television lets go of the row the app still shows, and has another.
        await television.put([Self.row(43)])
        let read = try XCTUnwrap(host.reservationsRead)
        model.problem = Self.left
        asked = await recorder.asked

        expectFalse(await model.cancel(besideRow))

        XCTAssertEqual(model.problem(for: .tv), TVDriver.notInList)
        XCTAssertEqual(model.problem, Self.left, "the television's failure is on the recorder's line")
        XCTAssertEqual(host.reservations.map(\.id), ["recording.43"], "the list read on the way was not kept")
        XCTAssertGreaterThan(try XCTUnwrap(host.reservationsRead), read)
        expectEqual(await recorder.asked, asked)
    }

    // MARK: - a television let go of

    /// The television's list is its host's, and goes with it. Registered again over the one saved, the
    /// television is on a host of its own that has read nothing yet. The host before is then not the model's,
    /// though the model has one: with its link still standing, as it does while something asked earlier is
    /// carried through, it writes nothing over what the registration saved, puts no line up and asks the
    /// television nothing. Taken away while a read of its list is out, the television leaves no host and no
    /// row behind, the screens are told, and the read's line comes down there and then, not when the read
    /// ends. A row held from before is then nobody's: asked to delete or change it, the app sends neither
    /// device anything and says nothing.
    func testATelevisionLetGoOfTakesItsListWithIt() async throws {
        let home = try await atHome([Self.row(41), Self.row(42)])
        let (recorder, television, door, model) = (home.recorder, home.television, home.door, home.model)
        let first = try XCTUnwrap(model.tvHost), firstLink = try XCTUnwrap(model.tv)
        let held = try XCTUnwrap(first.reservations.first)
        var told = model.tvTimesForgotten

        await door.hold(only: "getScheduleList")
        let registering = Task { await model.registerTV(at: Bench.tvHost, pin: nil) }
        try await until("the television registered again was never read") { await door.isHolding }
        let second = try XCTUnwrap(model.tvHost)
        XCTAssertFalse(second === first, "the host of the last registration was kept, and its list with it")
        XCTAssertTrue(second.reservations.isEmpty)
        XCTAssertNil(second.reservationsRead)
        XCTAssertFalse(model.shownReservations.contains { $0.device == .tv })
        XCTAssertNil(model.reservation(listKey: held.listKey))
        XCTAssertEqual(model.tvTimesForgotten, told + 1)
        await door.letGo()
        expectEqual(await registering.value, .registered)
        XCTAssertEqual(second.reservations.map(\.id), ["recording.42", "recording.41"])
        XCTAssertNotNil(second.reservationsRead)

        // As an attach still out on the first link writes down what it found: here another address and another
        // MAC than the registration saved, so that a write would show.
        first.keepAddress(Bench.otherHost)
        first.keepMAC("f8:4e:17:00:00:0b")
        XCTAssertEqual(model.defaults.string(forKey: DefaultsKey.tvHost), Bench.tvHost)
        XCTAssertEqual(model.defaults.string(forKey: DefaultsKey.tvMac), DemoTV.mac)
        let line = first.beginActivity(TVDriver.deletingLine)
        XCTAssertNil(model.busy, "a host that is no longer the model's put a line on the screens")
        XCTAssertTrue(model.televisionLines.isEmpty)
        first.endActivity(line)
        let heard = await television.calls
        await first.reached()
        await first.loadReservations()
        await first.refreshReservations()
        expectFalse(await first.cancel(held))
        expectEqual(await television.calls, heard, "a host that is no longer the model's asked the television")
        XCTAssertTrue(firstLink.session.connected, "the first link is not one the television would still answer")

        told = model.tvTimesForgotten
        await door.hold(only: "getScheduleList")
        let reading = Task { await second.loadReservations() }
        try await until("the read of the television's list was never out") { await door.isHolding }
        XCTAssertEqual(model.busy, TVDriver.readingLine)
        model.problem = Self.left

        model.removeTV()

        XCTAssertNil(model.tvHost)
        XCTAssertEqual(model.tvTimesForgotten, told + 1)
        XCTAssertFalse(model.shownReservations.contains { $0.device == .tv })
        XCTAssertNil(model.busy, "the line of a read still out on a television taken away was left up")
        XCTAssertTrue(model.televisionLines.isEmpty)
        await door.letGo()
        await reading.value
        XCTAssertNil(model.tvHost)
        XCTAssertFalse(model.shownReservations.contains { $0.device == .tv }, "the read brought the list back")
        XCTAssertNil(model.busy, "the line of the read that was out was left up")

        let asked = await recorder.asked, calls = await television.calls
        expectFalse(await model.cancel(held))
        expectFalse(await model.update(held, quality: "DR", repeating: "none"))

        expectEqual(await recorder.asked, asked, "a row of a television taken away reached the recorder")
        expectEqual(await television.calls, calls, "a television taken away was asked")
        XCTAssertEqual(model.problem, Self.left)
        model.removeTV()
        XCTAssertEqual(model.tvTimesForgotten, told + 1, "told of a television that was not there to let go of")
    }

    /// A registration that does not go through lets go of nothing. To the television saved the app is no
    /// longer on its list, and asked to register it again the television wants its PIN; and at another
    /// address, typed for it, nothing answers. After either the television saved is as it was: the same link
    /// and the same host, the list it gave still shown, and the screens told of nothing let go of.
    func testARegistrationThatDoesNotGoThroughLeavesTheSavedTelevisionAsItWas() async throws {
        let home = try await atHome([Self.row(41), Self.row(42)], television: DemoTV(power: "active"))
        let model = home.model
        let host = try XCTUnwrap(model.tvHost), link = try XCTUnwrap(model.tv)
        let listed = host.reservations, told = model.tvTimesForgotten
        XCTAssertEqual(listed.count, 2)
        XCTAssertTrue(link.session.connected)
        // From here neither the cookie nor the client id in the store is one the television knows, as when it
        // has taken the app off its list: it registers such a client only by its PIN.
        home.credentials.save(TVCredentials(clientID: "BDBridge:unlisted", cookie: "run out"))

        let attempts: [(address: String, ends: AppModel.TVRegistered)] = [
            (Bench.tvHost, .pinNeeded),
            (Bench.otherHost, .failed(ScalarError.transport("no answer").explanation)),
        ]
        for (address, ends) in attempts {
            expectEqual(await model.registerTV(at: address, pin: nil), ends)

            XCTAssertTrue(model.tv === link, "a registration that ended \(ends) let go of the link")
            XCTAssertTrue(model.tvHost === host, "a registration that ended \(ends) let go of the host")
            XCTAssertEqual(model.shownReservations.filter { $0.device == .tv }, listed,
                           "a registration that ended \(ends) took the television's list")
            XCTAssertEqual(model.tvTimesForgotten, told, "the screens were told of a television let go of, \(ends)")
        }
    }

    /// The demo lets go of the real television, and of its list with it: the invented recorder's list has no
    /// row of the television's, though a read of them was out as the demo began. A row held from before
    /// reaches neither the invented recorder nor the television. Nor does the host the app let go of ask the
    /// television anything more, or put a line on the screens, though its link still stands -- as it does
    /// while something asked before the demo is carried through -- and the television would answer.
    func testTheDemoLetsGoOfTheTelevisionsListToo() async throws {
        let home = try await atHome([Self.row(41)])
        let (television, door, model) = (home.television, home.door, home.model)
        let host = try XCTUnwrap(model.tvHost), link = try XCTUnwrap(model.tv)
        let held = try XCTUnwrap(host.reservations.first)
        let told = model.tvTimesForgotten
        await door.hold(only: "getScheduleList")
        let reading = Task { await host.loadReservations() }
        try await until("the read of the television's list was never out") { await door.isHolding }

        await model.enterDemo()
        await door.letGo()
        await reading.value

        XCTAssertTrue(model.demo)
        XCTAssertNil(model.tvHost)
        XCTAssertEqual(model.tvTimesForgotten, told + 1)
        try await untilConnected(model)
        let listed = model.reservations
        XCTAssertFalse(listed.isEmpty, "the invented recorder's reservations were not read")
        XCTAssertEqual(model.shownReservations, listed)
        model.problem = Self.left
        let calls = await television.calls

        expectFalse(await model.cancel(held))
        expectFalse(await model.update(held, quality: "DR", repeating: "none"))

        XCTAssertEqual(model.reservations, listed, "the television's row reached the invented recorder")
        XCTAssertEqual(model.problem, Self.left)
        expectEqual(await television.calls, calls, "the real television was asked from inside the demo")

        XCTAssertTrue(link.session.connected, "the link let go of is not one the television would still answer")
        await host.reached()
        await host.loadReservations()
        await host.refreshReservations()
        expectFalse(await host.cancel(held))
        expectFalse(await host.update(held, quality: "DR", repeating: "none"))
        let line = host.beginActivity(TVDriver.deletingLine)
        XCTAssertNil(model.busy, "a host the app let go of put a line on the screens")
        XCTAssertTrue(model.televisionLines.isEmpty)
        host.endActivity(line)

        expectEqual(await television.calls, calls, "a host the app let go of asked the television")
        expectEqual(await television.schedules.map(\.id), ["recording.41"])
    }

    /// A host the app has let go of numbers its lines on a list of its own, from one, as the model numbers
    /// the lines on its list: a line of the host's can carry the number of a line the model has up. It is not
    /// that line. Changed and ended on the host, it leaves the model's standing with the words it had.
    func testALineOfAHostLetGoOfIsNoLineOfTheModels() async throws {
        let bench = try aBench()
        let model = bench.model(recorder: SilentRecorder(), television: DemoTV(), credentials: MemoryTVCredentials())
        let host = try XCTUnwrap(model.tvHost)
        // The first line of a model that has not been started, so the first number its list gives out.
        let mine = model.beginActivity("録画一覧を取得中")
        model.removeTV()

        let line = host.beginActivity(TVDriver.deletingLine)
        XCTAssertEqual(line, mine, "the two lines carry different numbers, and nothing is tried by this test")
        host.updateActivity(line, to: TVDriver.readingLine)
        XCTAssertEqual(model.busy, "録画一覧を取得中", "a host the app let go of changed a line of the model's")
        host.endActivity(line)
        XCTAssertEqual(model.busy, "録画一覧を取得中", "a host the app let go of took a line of the model's down")

        model.endActivity(mine)
        XCTAssertNil(model.busy)
    }

    // MARK: - neither device's state is the other's

    /// What becomes of the recorder is nothing to the television's list. Another recorder answering where the
    /// first was takes the recorder's lists and leaves the television's as it was, on the host it was on. And
    /// with the recorder gone quiet and given up on, the television's list is read and a row deleted from it,
    /// with nothing asked of the recorder and its line left alone.
    func testWhatBecomesOfTheRecorderLeavesTheTelevisionsListAlone() async throws {
        let home = try await atHome([Self.row(41), Self.row(42)])
        let (recorder, television, model) = (home.recorder, home.television, home.model)
        let host = try XCTUnwrap(model.tvHost)
        let listed = host.reservations, read = host.reservationsRead
        let told = (recorder: model.timesForgotten, television: model.tvTimesForgotten)
        XCTAssertEqual(listed.count, 2)

        await recorder.become(2)
        await model.connect()
        try await untilIdle(model)

        XCTAssertGreaterThan(model.timesForgotten, told.recorder, "the recorder's lists were never let go of")
        XCTAssertEqual(model.tvTimesForgotten, told.television)
        XCTAssertTrue(model.tvHost === host)
        XCTAssertEqual(host.reservations, listed)
        XCTAssertEqual(host.reservationsRead, read)
        XCTAssertEqual(model.shownReservations.filter { $0.device == .tv }, listed)

        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.offline)
        let asked = await recorder.asked, said = model.problem
        await television.put([Self.row(41), Self.row(42), Self.row(43)])

        await host.loadReservations()
        XCTAssertEqual(host.reservations.map(\.id), ["recording.43", "recording.42", "recording.41"])
        expectTrue(await model.cancel(try XCTUnwrap(host.reservations.last)), model.problem(for: .tv) ?? "no reason")

        expectEqual(await television.schedules.map(\.id), ["recording.42", "recording.43"])
        XCTAssertEqual(host.reservations.map(\.id), ["recording.43", "recording.42"])
        expectEqual(await recorder.asked, asked, "the television's work asked a recorder that was given up on")
        XCTAssertEqual(model.problem, said)
        XCTAssertTrue(model.offline)
    }

    /// A home with a television and no recorder: nothing is saved for a recorder and no client is ever made
    /// for one, and the television's reservations are read as it connects, shown, and deleted from.
    func testATelevisionWithNoRecorderBesideItIsReadAndDeletedFrom() async throws {
        let bench = try aBench()
        let television = DemoTV()
        await television.put([Self.row(41), Self.row(42)])
        let model = bench.modelWithNoRecorder(television: television, credentials: await registered(with: television))
        await model.start()
        try await untilTheTelevisionIsConnected(model)
        let host = try XCTUnwrap(model.tvHost)

        XCTAssertNil(model.client)
        XCTAssertEqual(model.shownReservations.map(\.listKey), ["tv|recording.42", "tv|recording.41"])
        let row = try XCTUnwrap(model.reservation(listKey: "tv|recording.42"))
        expectFalse(await model.update(row, quality: "DR", repeating: "none"))
        XCTAssertEqual(model.problem(for: .tv), TVDriver.changesNotYet)
        expectTrue(await model.cancel(row), model.problem(for: .tv) ?? "no reason given")

        expectEqual(await television.schedules.map(\.id), ["recording.41"])
        XCTAssertEqual(host.reservations.map(\.id), ["recording.41"])
        XCTAssertNil(model.problem)
        XCTAssertEqual(bench.clientsMade, 0, "a client was made for a recorder nobody saved")
    }

    /// Reading the television's list is the television's work alone: while a read is out the recorder is not
    /// busy and may be changed, and has been asked nothing -- not made sure of, which is where it would be
    /// woken. A television that cannot be asked, its cookie no longer taken, is not sent the read a screen asks
    /// for as it appears, and the line and the list it left are not written over.
    func testReadingTheTelevisionsListIsNoWorkOfTheRecorders() async throws {
        let home = try await atHome([Self.row(41)])
        let (recorder, television, door, model) = (home.recorder, home.television, home.door, home.model)
        let host = try XCTUnwrap(model.tvHost)
        let asked = await recorder.asked

        await door.hold(only: "getScheduleList")
        let reading = Task { await host.loadReservations() }
        try await until("the read of the television's list was never out") { await door.isHolding }

        XCTAssertEqual(model.busy, TVDriver.readingLine, "the television's line is not on the strip")
        XCTAssertTrue(host.isBusy)
        XCTAssertFalse(model.isBusy, "the television's read made the recorder busy")
        XCTAssertTrue(model.canChangeRecorder, "the television's read held the recorder's choice back")
        expectEqual(await recorder.asked, asked, "the television's read asked the recorder")
        await door.letGo()
        await reading.value
        XCTAssertNil(model.busy)
        expectEqual(await recorder.asked, asked)

        home.credentials.save(TVCredentials(clientID: "BDBridge:test", cookie: "run out"))
        await host.loadReservations()
        XCTAssertEqual(model.tvDriver?.facts.needsPairing, true)
        XCTAssertEqual(model.problem(for: .tv), ScalarError.notRegistered.explanation)
        host.problem = Self.left
        let calls = await television.calls, read = host.reservationsRead

        await host.loadReservations()

        expectEqual(await television.calls, calls, "a television that cannot be asked was sent the read")
        XCTAssertEqual(model.problem(for: .tv), Self.left)
        XCTAssertEqual(host.reservations.map(\.id), ["recording.41"])
        XCTAssertEqual(host.reservationsRead, read)
    }

    // MARK: - pulling the list down

    /// Pulling the list down reads it from a television that is connected: one request, and no connect. From
    /// one given up on after silence it is the reader asking for it to be tried again: the television is
    /// connected to, and its list read as that connect reaches it. A delete asked for while it is given up on
    /// is turned down with nothing read, which the line says, and the list it gave stands with its time.
    func testPullingDownReadsTheListOrConnectsAndReadsIt() async throws {
        let home = try await atHome([Self.row(41)])
        let (television, model) = (home.television, home.model)
        let host = try XCTUnwrap(model.tvHost), link = try XCTUnwrap(model.tv)
        await television.put([Self.row(41), Self.row(42)])
        var calls = await television.calls

        await host.refreshReservations()

        expectEqual(Array(await television.calls.dropFirst(calls.count)), ["getScheduleList cookie=yes pin=no"])
        XCTAssertEqual(host.reservations.map(\.id), ["recording.42", "recording.41"])

        await television.goSilent()
        _ = await link.ensureUp(evenIfRecent: true)
        XCTAssertTrue(link.session.gaveUp)
        let listed = host.reservations, read = host.reservationsRead
        let row = try XCTUnwrap(listed.first)

        expectFalse(await model.cancel(row))

        XCTAssertEqual(model.problem(for: .tv), TVDriver.notConnected)
        XCTAssertEqual(host.reservations, listed, "a delete turned down unread took the television's list")
        XCTAssertEqual(host.reservationsRead, read, "a delete turned down unread counts as a read")

        await television.goSilent(false)
        await television.put([Self.row(41), Self.row(42), Self.row(43)])
        calls = await television.calls

        await host.refreshReservations()

        XCTAssertTrue(link.session.connected, model.problem(for: .tv) ?? "no reason given")
        expectEqual(Array(await television.calls.dropFirst(calls.count)).map { $0.components(separatedBy: " ")[0] },
                    ["getSystemSupportedFunction", "getInterfaceInformation", "getStorageList", "getScheduleList"])
        XCTAssertEqual(host.reservations.map(\.id), ["recording.43", "recording.42", "recording.41"])
        XCTAssertNil(model.problem(for: .tv))
    }
}
