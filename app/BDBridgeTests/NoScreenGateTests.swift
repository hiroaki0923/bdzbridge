import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder's two runs with no screen, each asked for as the app's own entries ask for it, with its
/// surroundings handed in -- the overnight run (`BackgroundWork.refresh`) and the Shortcuts action
/// (`BackgroundWork.sendWaiting`, and what it says, `SendWaitingIntent.saying`): what a run asks of the recorder
/// and in which order, what it tells and what it leaves untold, and what being cancelled, silence part-way,
/// nobody at the address and a recorder the cache is not of each come to.
///
/// They were written as gates, as `RunGateTests` was: each pinned what the app did, so that the order of a run
/// could move into RecorderKit with the test's body unchanged (`RecorderDriver.refreshWithNoScreen`,
/// `sendWithNoScreen`, `says`), and each change made on purpose afterwards rewrote the tests it changed. They
/// hold the rules a run keeps now: a night ends at its first silence; once its time is up it tells only what
/// became of the waiting reservations, and nothing once the cache is another recorder's; a recorder that
/// cannot be told from the cache's own is not said to be another; a reservation whose create met silence is
/// said to be held, and one still held is counted when a later round has news; a round acts on a reservation
/// only as it read it; and another recorder answering, and a reservation that has not reached the recorder in
/// time, are told once, what has been told being handed over to be kept, and the warning forgotten once a
/// sending of the screens' own leaves none of its reservations waiting. What a night told is read from the
/// bench's record (`Tellings`), which has each telling by the time it returns.
///
/// The entries the system calls -- `BackgroundWork.refreshNow` and the argument-less `sendWaiting()`, which
/// read the app's own settings, send a real packet and post -- are reached by none of these, nor by any other
/// test: what is behind each is tried with its surroundings handed in.
///
/// No MAC is handed to either run, as in `WhichRecorderNoScreenTests`: a run with no screen sends its packet
/// itself, not through the model, and a MAC would put one on the network this is run on.
@MainActor
final class NoScreenGateTests: XCTestCase {
    // MARK: - what the tests start from

    /// At home with the first recorder: the cache its own, with the demo's guide in it, as a model that connected
    /// and is gone left it, and a connection to it of the test's own, as a run with no screen opens one. Every
    /// broadcasting type is marked as answered for a day ahead of now, so that none is behind at any hour.
    private func home() async throws -> (recorder: NamedRecorder, store: GuideStore, path: String) {
        let (bench, recorder, _) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        for type in GuideRefresh.broadcastingTypes {
            try await store.noteNoGuide(broadcasting: type, at: Date().addingTimeInterval(86_400))
        }
        return (recorder, store, bench.guidePath)
    }

    /// The overnight run as the app's entry hands it on, with a client of its own and no MAC: whether it says a
    /// guide was stored, what it told, and what it asked of the recorder, in order.
    private func night(of recorder: NamedRecorder, _ store: GuideStore) async
        -> (stored: Bool, told: Tellings, heard: [String]) {
        let told = Tellings()
        let count = await recorder.heard.count
        let stored = await BackgroundWork.refresh(client: aClient(of: recorder), store: store, mac: nil,
                                                  telling: telling(told))
        return (stored, told, await recorder.heard(since: count))
    }

    /// A reservation of the test's own waiting for the recorder: half an hour on the demo's first channel, in DR
    /// and not repeated, starting so many minutes from now, of a programme the demo's guide does not list.
    private func waiting(_ title: String, startingIn minutes: Double, programme: Int,
                         problem: String? = nil) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Date().addingTimeInterval(minutes * 60),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ", problem: problem)
    }

    /// What waits in the queue, in the order it would be sent: each row by its title, with the reason written on
    /// it where it has one. What a run is to have left as it was, or held.
    private func rows(in store: GuideStore) async throws -> [String] {
        try await store.pendingReservations().map { $0.request.title + ($0.problem.map { ": \($0)" } ?? "") }
    }

    /// What a night with nothing waiting asks before the guide's files: who is there, the USB slot, the free
    /// space, and where the guide's files are.
    private static let beforeTheGuide = [Ask.description, Ask.slot, Ask.freeSpace, Ask.portOfTheGuide]

    // MARK: - the overnight run

    /// The order of a night. The recorder is asked who it is; what waits is sent, the list read first; the USB
    /// slot is read, then the free space; and every type of the guide is asked for, in turn, though the cache has
    /// each marked as answered for since the recorder's last rebuild: the night does not go by the marks. It
    /// tells what became of the queue, then the free space, then that a guide was fetched.
    ///
    /// That last is told when a type answered, also with no file to give, which is all the demo's recorder
    /// answers; and what the run hands back is whether a programme was stored, which none was. With every file
    /// answered 500, as a recorder answers that has not built them, no type answered: nothing is told of the
    /// guide. With one type's file a guide, its logos are asked for after it, and the run hands back that
    /// something was stored.
    func testANightSendsWhatWaitsReadsTheSlotAndTheSpaceAndAsksForEveryTypeOfTheGuide() async throws {
        let (recorder, store, _) = try await home()
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)

        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create, Ask.slot, Ask.freeSpace,
                                   Ask.portOfTheGuide] + Ask.guide)
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"])
        XCTAssertEqual(ran.told.rounds.map { $0.sent.map(\.id) }, [[morning.id]])
        XCTAssertEqual(ran.told.rounds.first?.summary, Said.sent("朝の番組"))
        XCTAssertFalse(ran.stored, "the night said a guide was stored, the recorder having given no file")
        expectEqual(try await rows(in: store), [], "what was sent still waits")

        for file in Ask.guide { await recorder.answer(file, with: .status(500)) }
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + Ask.guide)
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace"],
                       "a guide was said to be fetched, no type of it having answered")
        XCTAssertFalse(ran.stored)

        await recorder.answer(Ask.guide[0], with: .body(try vectorFile("epg-sample.dat")))
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + [Ask.guide[0], Ask.logos[0]] + Ask.guide.dropFirst())
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"])
        XCTAssertTrue(ran.stored, "a guide was stored and the night did not say so")
    }

    /// The overnight run as its task is cancelled, which is what the system's expiry does to it, while its next
    /// request of one kind is held: the request is then let go, and the run waited for. What `night` hands back.
    private func nightCancelled(of recorder: NamedRecorder, _ store: GuideStore, at kind: String) async throws
        -> (stored: Bool, told: Tellings, heard: [String]) {
        let told = Tellings()
        let tell = telling(told)
        let client = aClient(of: recorder)
        let before = await recorder.asked
        let count = await recorder.heard.count
        await recorder.holdTheNext(kind)
        addTeardownBlock { await recorder.letGo() }
        let run = Task { await BackgroundWork.refresh(client: client, store: store, mac: nil, telling: tell) }
        try await until("the night never asked for \(kind)") { await recorder.asked(kind, since: before) == 1 }
        run.cancel()
        await recorder.letGo()
        return (await run.value, told, await recorder.heard(since: count))
    }

    /// A night whose time runs out stops between one step and the next: the request under way is waited for,
    /// and nothing is asked after it. Cancelled as it asks who is there, it sends nothing and tells nothing, and
    /// the queue is as it was. Cancelled while a reservation is being made, it tells what became of the queue,
    /// in full, and then nothing: the slot is not read.
    ///
    /// Cancelled from outside while the first file of the guide is out, it asks for no further file: the guide is
    /// fetched in the night's own task, and looks for the cancellation before each type. The slot, which a night
    /// reads once more after the guide while the disk known does not answer, is not read again. And that a guide
    /// was fetched is not told, though a type answered: once its time is up a night tells only what became of
    /// the queue, and the time the settings show is not written by a run the system has ended.
    func testANightWhoseTimeIsUpStopsBetweenItsStepsHavingToldWhatBecameOfTheQueue() async throws {
        let (recorder, store, _) = try await home()
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)

        var ran = try await nightCancelled(of: recorder, store, at: Ask.description)
        XCTAssertEqual(ran.heard, [Ask.description], "a night cancelled as it asked who is there went on")
        XCTAssertEqual(ran.told.names, [])
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store), ["朝の番組"], "the queue is not as it was")

        ran = try await nightCancelled(of: recorder, store, at: Ask.create)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create],
                       "a night cancelled while a reservation was being made went on")
        XCTAssertEqual(ran.told.names, ["flushed"])
        XCTAssertEqual(ran.told.rounds.map { $0.sent.map(\.id) }, [[morning.id]])
        XCTAssertEqual(ran.told.rounds.first?.summary, Said.sent("朝の番組"),
                       "what became of the queue was not told in full")
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store), [])

        // A disk known that takes recordings, which the slot does not answer: the slot is read again after the
        // guide on such a night.
        try await store.keep(knownUSBDisk: USBDiskTests.disk)
        ran = try await nightCancelled(of: recorder, store, at: Ask.guide[0])
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + [Ask.guide[0]],
                       "a further file was asked for, or the slot read again, once the night's time was up")
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace"],
                       "a guide was said to be fetched once the night's time was up")
        XCTAssertFalse(ran.stored)
    }

    /// The overnight run with its next request of one kind held, and what a test does while it is
    /// (`meanwhile`, which is handed the night's task): the request is then let go, with whatever else is held,
    /// and the run waited for. What `night` hands back.
    private func nightHeld(of recorder: NamedRecorder, _ store: GuideStore, at kind: String,
                           _ meanwhile: (Task<Bool, Never>) async throws -> Void) async throws
        -> (stored: Bool, told: Tellings, heard: [String]) {
        let told = Tellings()
        let tell = telling(told)
        let client = aClient(of: recorder)
        let before = await recorder.asked
        let count = await recorder.heard.count
        await recorder.holdTheNext(kind)
        addTeardownBlock { await recorder.letGo() }
        let run = Task { await BackgroundWork.refresh(client: client, store: store, mac: nil, telling: tell) }
        try await until("the night never asked for \(kind)") { await recorder.asked(kind, since: before) == 1 }
        try await meanwhile(run)
        await recorder.letGo()
        return (await run.value, told, await recorder.heard(since: count))
    }

    /// What the notification would say of a round as a night told it. The app posts what the driver says a
    /// round with no screen tells (`Notify.queueFlushed`), where no test sees; nil is nothing posted.
    private func posted(_ round: PendingQueue.Outcome?) -> String? {
        round.flatMap { RecorderDriver.tells($0, naming: nil) }
    }

    /// What a round with news ends with while a reservation held after silence at an earlier create still waits,
    /// passed over: how many such there are, in the notification and in the Shortcuts action's answer.
    private static func stillHeld(_ count: Int) -> String {
        "レコーダーに届いたか確かめていない予約が \(count) 件あります。予約一覧で確かめてください"
    }

    /// Once its time is up a night tells of the reservations that waited only what is news, and says it so that
    /// it holds whatever it was that cut the run short.
    ///
    /// Cancelled while a reservation is being made, the create then meeting silence: the reservation is held
    /// for the reader with its reason, and that is told, in the sentence written on the row and with nothing of
    /// a rest that goes the next time; the night ends there. It is told also now: the row is held on the phone
    /// whatever cut the create.
    ///
    /// Cancelled while the recorder's list is read for the round, the read then meeting silence, with a
    /// reservation whose programme is over ahead of the one to go: the one dropped is told, and not as of a
    /// round cut short. The queue's sentence for that -- the recorder stopped answering, the rest goes the next
    /// time it answers -- is left off, since the system's suspension may be what cut the read. With nothing
    /// dropped ahead of the read there is no news, and nothing is told.
    ///
    /// And a night whose time runs out while what became of the queue is being told -- as the app posts the
    /// notification -- asks nothing after it: here the telling itself cancels the task it is made in, which
    /// is the night's.
    ///
    /// The reservation the first night held is taken out of the queue before the nights after it, as the
    /// reader deletes one from the reservations tab: what those nights tell is of the reservations they are
    /// about alone.
    func testANightWhoseTimeIsUpTellsOfTheQueueOnlyWhatIsNewsAndOfASilentCreateThatTheReservationIsHeld()
        async throws {
        let (recorder, store, _) = try await home()
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)
        await recorder.goQuiet(on: Ask.create)
        var ran = try await nightCancelled(of: recorder, store, at: Ask.create)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create],
                       "a night whose time was up went on after a create that met silence")
        XCTAssertEqual(ran.told.names, ["flushed"], "the reservation held was not told, the night's time being up")
        XCTAssertEqual(posted(ran.told.rounds.first), Said.heldAfterSilence,
                       "the reservation held was not told as held and nothing more")
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store), ["朝の番組: " + Said.heldAfterSilence])

        // The morning's, held now, is taken out. One that is over, and one to go, which the round reads the
        // recorder's list for.
        try await store.removePending(morning.id)
        let over = waiting("終わった番組", startingIn: -120, programme: 4323)
        try await store.queue(over)
        try await store.queue(waiting("昼の番組", startingIn: 150, programme: 4322))
        await recorder.goQuiet(on: Ask.reservations)
        ran = try await nightCancelled(of: recorder, store, at: Ask.reservations)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations],
                       "a night whose time was up went on after a read that met silence")
        XCTAssertEqual(ran.told.names, ["flushed"], "the reservation dropped was not told")
        XCTAssertEqual(ran.told.rounds.map { $0.expired.map(\.id) }, [[over.id]])
        XCTAssertEqual(posted(ran.told.rounds.first), Said.expired("終わった番組"),
                       "a round cut short once the night's time was up was told as cut short")
        expectEqual(try await rows(in: store), ["昼の番組"])

        // Nothing over ahead of the read now.
        await recorder.goQuiet(on: Ask.reservations)
        ran = try await nightCancelled(of: recorder, store, at: Ask.reservations)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations])
        XCTAssertEqual(ran.told.names, [], "a round with no news was told, the night's time being up")
        expectEqual(try await rows(in: store), ["昼の番組"], "the queue is not as it was")

        // The noon's goes now. The night's time is up as that is told.
        let told = Tellings()
        var tell = telling(told)
        let flushed = tell.flushed
        tell.flushed = { outcome in
            await flushed(outcome)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let (client, count, tellingIt) = (aClient(of: recorder), await recorder.heard.count, tell)
        let stored = await Task {
            await BackgroundWork.refresh(client: client, store: store, mac: nil, telling: tellingIt)
        }.value
        XCTAssertEqual(told.names, ["flushed"])
        XCTAssertEqual(posted(told.rounds.first), Said.sent("昼の番組"))
        expectEqual(await recorder.heard(since: count), [Ask.description, Ask.reservations, Ask.create],
                    "a night whose time ran out as it told what became of the queue went on")
        XCTAssertFalse(stored)
    }

    /// Once its time is up a night tells nothing of the room on the recorder's disks, though the request that
    /// asked for it was under way and is answered: the notice made of it writes down that it warned, and
    /// nothing is written by a run the system has ended. The night ends there, and asks for no guide.
    ///
    /// Cancelled while the free space is asked for: nothing is told of it. So with a USB disk in the slot that
    /// takes recordings and a recorder that will not say its own space: the USB disk's space, which the slot
    /// had answered, is not told. And cancelled while the slot is read once more after the guide -- which a
    /// night does while the disk known did not answer the first read -- the disk it then answers is not told
    /// either; that a guide was fetched had been told before the time was up. A telling kept back ends the
    /// night, which then hands back that nothing was stored, though a type of that guide gave programmes:
    /// nothing reads what a night hands back once the system has ended it.
    func testANightWhoseTimeIsUpTellsNothingOfTheSpaceItWasAskingFor() async throws {
        let (recorder, store, _) = try await home()
        var ran = try await nightCancelled(of: recorder, store, at: Ask.freeSpace)
        XCTAssertEqual(ran.told.names, ["flushed"], "the free space was told, the night's time being up")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace])
        XCTAssertFalse(ran.stored)

        await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()))
        await recorder.answer(Ask.freeSpace, with: .fault(402))
        ran = try await nightCancelled(of: recorder, store, at: Ask.freeSpace)
        XCTAssertEqual(ran.told.names, ["flushed"], "the USB disk's space was told, the night's time being up")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace])

        // A disk known that takes recordings, which the slot does not answer at first: read again after the
        // guide, and held then. It answers the disk once the night's time is up.
        try await store.keep(knownUSBDisk: USBDiskTests.disk)
        await recorder.answer(Ask.guide[0], with: .body(try vectorFile("epg-sample.dat")))
        ran = try await nightHeld(of: recorder, store, at: Ask.freeSpace) { run in
            let read = await recorder.asked(Ask.slot)
            await recorder.holdTheNext(Ask.slot)
            await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()))
            await recorder.letGo(only: Ask.freeSpace)
            try await until("the slot was never read again") { await recorder.asked(Ask.slot) == read + 1 }
            run.cancel()
        }
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"],
                       "the USB disk's space, read again after the guide, was told once the night's time was up")
        XCTAssertEqual(ran.heard,
                       Self.beforeTheGuide + [Ask.guide[0], Ask.logos[0]] + Ask.guide.dropFirst() + [Ask.slot])
        XCTAssertFalse(ran.stored, "a guide was handed back as stored by a night that had kept a telling back")
    }

    /// A night whose time is up asks nothing after the request of its own that was out, also where it has
    /// nothing to tell that the time would keep back.
    ///
    /// Cancelled while the USB slot is read: the free space is not asked for. Cancelled while the free space
    /// is asked for, of a recorder that then will not say it, so that there is nothing to tell: the guide's
    /// files are not looked for. And cancelled while the first file of the guide is out, which the recorder
    /// has not built, so that no type has answered and nothing is told of the guide: no further file is asked
    /// for, and the slot, which a night reads once more after its guide while the disk known does not answer,
    /// is not read again. With that file a guide: its programmes are stored, and its logos, which a night asks
    /// for after a type's guide, are not asked for; that a guide was fetched is not told.
    func testANightWhoseTimeIsUpAsksNothingAfterTheRequestThatWasOut() async throws {
        let (recorder, store, _) = try await home()
        var ran = try await nightCancelled(of: recorder, store, at: Ask.slot)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot],
                       "the free space was asked for by a night whose time ran out as it read the slot")
        XCTAssertEqual(ran.told.names, ["flushed"])
        XCTAssertFalse(ran.stored)

        await recorder.answer(Ask.freeSpace, with: .fault(402))
        ran = try await nightCancelled(of: recorder, store, at: Ask.freeSpace)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace],
                       "the guide was looked for by a night whose time ran out as it asked for the free space")
        XCTAssertEqual(ran.told.names, ["flushed"])
        XCTAssertFalse(ran.stored)

        // A disk known that takes recordings, which the slot does not answer: read again after a guide.
        try await store.keep(knownUSBDisk: USBDiskTests.disk)
        await recorder.answer(Ask.guide[0], with: .status(500))
        ran = try await nightCancelled(of: recorder, store, at: Ask.guide[0])
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + [Ask.guide[0]],
                       "a further file was asked for, or the slot read again, once the night's time was up")
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace"],
                       "something was told of a guide of which no type answered")
        XCTAssertFalse(ran.stored)

        await recorder.answer(Ask.guide[0], with: .body(try vectorFile("epg-sample.dat")))
        ran = try await nightCancelled(of: recorder, store, at: Ask.guide[0])
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + [Ask.guide[0]],
                       "the logos of the type that came were asked for once the night's time was up")
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace"],
                       "a guide was said to be fetched once the night's time was up")
        XCTAssertFalse(ran.stored)
        expectEqual(try await store.counts()["td"]?.programs, 4, "the type whose file was out is not in the cache")
    }

    /// A night tells nothing once the cache is another recorder's: made over, as the screens make it over when
    /// they take a recorder up, while a request of the night's was out. What the night found is of a recorder
    /// that is the reader's no longer. Made over here by a connection of the test's own while the request named
    /// is held, and back to the first recorder after each night.
    ///
    /// While a reservation is being made: the reservation goes, its request being out, and what became of the
    /// queue is not told; the night ends there. While what became of the queue is being told, which is where
    /// the app posts its notification -- made over here by the telling itself: the night ends there, and the
    /// slot is not read. While the free space is asked for: nothing is told of it, and no
    /// guide is asked for. So with a USB disk in the slot that takes recordings and a recorder that will not
    /// say its own space: the USB disk's is not told, and no guide is asked for. So with no disk in the slot
    /// and a recorder that will not say its own space, where there is nothing to tell: the guide's files are
    /// not looked for, the cache being asked whose it is before the guide as well. And while the second file of
    /// the guide is out, the first having given a guide: the cache takes nothing of the second, which ends the
    /// guide, and the night neither tells that a guide was fetched nor hands back that one was stored -- the
    /// first type's programmes went with the make-over.
    func testANightTellsNothingOnceTheCacheIsAnotherRecorders() async throws {
        let (recorder, store, path) = try await home()
        func makeOver(to last: Int) async throws {
            let description = try await aClient(of: NamedRecorder(last)).describe()
            expectEqual(try await GuideStore(path: path).claim(for: description), .another,
                        "the cache was meant to be made over")
        }

        try await store.queue(waiting("朝の番組", startingIn: 120, programme: 4321))
        var ran = try await nightHeld(of: recorder, store, at: Ask.create) { _ in try await makeOver(to: 2) }
        XCTAssertEqual(ran.told.names, [], "what became of the queue was told over a cache made over meanwhile")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create],
                       "the night went on over a cache made over while a reservation was being made")
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store), [], "the reservation that was out did not go")
        try await makeOver(to: 1)

        try await store.queue(waiting("昼の番組", startingIn: 150, programme: 4322))
        let told = Tellings()
        var tell = telling(told)
        let flushed = tell.flushed
        tell.flushed = { outcome in
            await flushed(outcome)
            let another = try? await aClient(of: NamedRecorder(2)).describe()
            guard let another, let screens = try? GuideStore(path: path) else { return }
            _ = try? await screens.claim(for: another)
        }
        let (client, count, tellingIt) = (aClient(of: recorder), await recorder.heard.count, tell)
        let stored = await BackgroundWork.refresh(client: client, store: store, mac: nil, telling: tellingIt)
        XCTAssertEqual(told.names, ["flushed"])
        expectEqual(await recorder.heard(since: count), [Ask.description, Ask.reservations, Ask.create],
                    "the night went on over a cache made over as what became of the queue was told")
        XCTAssertFalse(stored)
        try await makeOver(to: 1)

        ran = try await nightHeld(of: recorder, store, at: Ask.freeSpace) { _ in try await makeOver(to: 2) }
        XCTAssertEqual(ran.told.names, ["flushed"], "the free space was told over a cache made over meanwhile")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace],
                       "the night went on over a cache made over while the free space was asked for")
        XCTAssertFalse(ran.stored)
        try await makeOver(to: 1)

        await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()))
        await recorder.answer(Ask.freeSpace, with: .fault(402))
        ran = try await nightHeld(of: recorder, store, at: Ask.freeSpace) { _ in try await makeOver(to: 2) }
        XCTAssertEqual(ran.told.names, ["flushed"], "the USB disk's space was told over a cache made over meanwhile")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace],
                       "the night went on over a cache made over, the USB disk's space untold")
        try await makeOver(to: 1)

        await recorder.answer(Ask.freeSpace, with: .fault(402))
        ran = try await nightHeld(of: recorder, store, at: Ask.freeSpace) { _ in try await makeOver(to: 2) }
        XCTAssertEqual(ran.told.names, ["flushed"])
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace],
                       "the guide was looked for over a cache made over, there having been nothing to tell")
        XCTAssertFalse(ran.stored)
        try await makeOver(to: 1)

        await recorder.answer(Ask.guide[0], with: .body(try vectorFile("epg-sample.dat")))
        ran = try await nightHeld(of: recorder, store, at: Ask.guide[1]) { _ in try await makeOver(to: 2) }
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace"],
                       "a guide was said to be fetched that the cache, made over, had ended")
        XCTAssertFalse(ran.stored, "a guide was handed back as stored whose programmes went with the make-over")
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + [Ask.guide[0], Ask.logos[0], Ask.guide[1]],
                       "a file was asked for after the one the cache would not take")
    }

    /// A night sends a waiting reservation only as its round read it: one given a reason while the round was out
    /// is not sent, nor one the queue cannot say anything of just then.
    ///
    /// Two reservations wait, and while the first is being made the cache is made over to another recorder, as
    /// the screens make it over when they take one up, which writes on every row that waits that it is held for
    /// the recorder before. The first goes, its request being out. The second is not sent to the recorder the
    /// screens have left: it waits, carrying that sentence, for the reader to send again. Nothing is told, the
    /// cache being another's, and the night ends there.
    ///
    /// The cache the first recorder's again, and the queue out of reach while the first of two more is being
    /// made, so that the round cannot read the second again: the second is not sent. The night tells what the
    /// round came to, the first made, and goes on.
    func testANightSendsAWaitingReservationOnlyAsItsRoundReadIt() async throws {
        let (recorder, store, path) = try await home()
        try await store.queue(waiting("朝の番組", startingIn: 120, programme: 4321))
        try await store.queue(waiting("昼の番組", startingIn: 150, programme: 4322))
        var ran = try await nightHeld(of: recorder, store, at: Ask.create) { _ in
            let another = try await aClient(of: NamedRecorder(2)).describe()
            expectEqual(try await GuideStore(path: path)
                .claim(for: another, holdingTheQueueWith: RecorderDriver.heldForAnotherRecorder), .another,
                        "the cache was meant to be made over")
        }
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create],
                       "a reservation held for another recorder meanwhile was sent to the recorder left")
        expectEqual(try await rows(in: store), ["昼の番組: " + Said.heldForAnotherRecorder],
                    "the reservation held meanwhile does not wait with the sentence written on it")
        XCTAssertEqual(ran.told.names, [], "something was told over a cache made over meanwhile")
        XCTAssertFalse(ran.stored)

        let first = try await aClient(of: NamedRecorder(1)).describe()
        expectEqual(try await store.claim(for: first), .another, "the cache was meant to be made over")
        for row in try await store.pendingReservations() { try await store.removePending(row.id) }
        let evening = waiting("夕方の番組", startingIn: 180, programme: 4324)
        try await store.queue(evening)
        try await store.queue(waiting("夜の番組", startingIn: 210, programme: 4325))
        ran = try await nightHeld(of: recorder, store, at: Ask.create) { run in
            let queue = QueueOutOfReach(in: path)
            await recorder.letGo()
            _ = await run.value
            queue.putBack()
        }
        XCTAssertEqual(ran.heard.filter { $0 == Ask.create }.count, 1,
                       "a reservation was sent that the queue could not say anything of")
        XCTAssertEqual(ran.told.rounds.map { $0.sent.map(\.id) }, [[evening.id]])
        expectTrue(try await rows(in: store).contains("夜の番組"), "the reservation not sent does not wait")
    }

    /// Nor does a night take a waiting reservation out as found on the recorder but as its round read it.
    ///
    /// A reservation waits that the recorder holds already, as one does whose create the recorder took and whose
    /// answer was lost: the night's round finds it there, takes it out unsent, and tells that it was reserved
    /// already. Then the same reservation waits again behind another, and while that one is being made the
    /// cache is made over to another recorder, as the screens make it over when they take one up, which writes
    /// on every row that waits that it is held for the recorder before. The first goes, its request being out.
    /// The second, which the round found on the recorder as it opened, is not taken out: it waits, carrying
    /// that sentence, for the reader, who has just been shown it as left for them. Nothing is told, the cache
    /// being another's.
    func testANightTakesAReservationOutAsFoundOnTheRecorderOnlyAsItsRoundReadIt() async throws {
        let (recorder, store, path) = try await home()
        let noon = waiting("昼の番組", startingIn: 150, programme: 4322)
        try await aClient(of: recorder).create(noon.request)
        try await store.queue(noon)
        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.rounds.map { $0.alreadyThere.map(\.id) }, [[noon.id]],
                       "the reservation was meant to be found on the recorder")
        XCTAssertEqual(Array(ran.heard.prefix(3)), [Ask.description, Ask.reservations, Ask.slot])
        expectEqual(try await rows(in: store), [])

        try await store.queue(waiting("朝の番組", startingIn: 120, programme: 4321))
        try await store.queue(noon)
        ran = try await nightHeld(of: recorder, store, at: Ask.create) { _ in
            let another = try await aClient(of: NamedRecorder(2)).describe()
            expectEqual(try await GuideStore(path: path)
                .claim(for: another, holdingTheQueueWith: RecorderDriver.heldForAnotherRecorder), .another,
                        "the cache was meant to be made over")
        }
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create])
        expectEqual(try await rows(in: store), ["昼の番組: " + Said.heldForAnotherRecorder],
                    "a reservation held for another recorder meanwhile was taken out as found on the recorder left")
        XCTAssertEqual(ran.told.names, [], "something was told over a cache made over meanwhile")
    }

    /// A cache whose owner cannot be read just then silences nothing: no other recorder is known to have taken
    /// the cache, and what the night found is still of the recorder it knew as it began. The cache's own table
    /// is put out of reach here while a request of the night's is held, and back once the night is over.
    ///
    /// While a reservation is being made, the create then meeting silence: what became of the queue is told,
    /// the reservation held. While the free space is asked for: it is told, and the night goes on to its guide.
    /// Nothing is told of that guide here, which is the staging's doing and no rule's: each type is asked for,
    /// and none can be marked as answered for, the marks being kept in the table that is out of reach.
    ///
    /// And while a reservation is being made that then goes, so that the table is out of reach as what became
    /// of the queue has been told: the night goes on from there, to the slot, the free space, which it tells,
    /// and its guide.
    func testANightIsNotSilencedByACacheWhoseOwnerCannotBeReadJustThen() async throws {
        let (recorder, store, path) = try await home()
        func untilTheNightIsOver(_ run: Task<Bool, Never>) async {
            let meta = MetaOutOfReach(in: path)
            await recorder.letGo()
            _ = await run.value
            meta.putBack()
        }

        try await store.queue(waiting("朝の番組", startingIn: 120, programme: 4321))
        await recorder.goQuiet(on: Ask.create)
        var ran = try await nightHeld(of: recorder, store, at: Ask.create, untilTheNightIsOver)
        XCTAssertEqual(ran.told.names, ["flushed"], "an owner that could not be read silenced the queue's telling")
        XCTAssertEqual(posted(ran.told.rounds.first), Said.heldAfterSilence)
        expectEqual(try await rows(in: store), ["朝の番組: " + Said.heldAfterSilence])

        // That row is held now, so nothing is read or sent for the queue.
        ran = try await nightHeld(of: recorder, store, at: Ask.freeSpace, untilTheNightIsOver)
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace"],
                       "an owner that could not be read silenced the free space's telling")
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + Ask.guide, "the night did not go on to its guide")
        XCTAssertFalse(ran.stored)

        // One more waits, and goes: the table out of reach from its create on, and so as its round is told.
        let noon = waiting("昼の番組", startingIn: 150, programme: 4322)
        try await store.queue(noon)
        ran = try await nightHeld(of: recorder, store, at: Ask.create, untilTheNightIsOver)
        XCTAssertEqual(ran.told.rounds.map { $0.sent.map(\.id) }, [[noon.id]], "the reservation was meant to go")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create, Ask.slot, Ask.freeSpace,
                                   Ask.portOfTheGuide] + Ask.guide,
                       "an owner that could not be read as the queue was told ended the night there")
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace"],
                       "an owner that could not be read as the queue was told silenced what came after")
    }

    /// A night that comes to its guide while another refresh is out waits its turn: one refresh at a time, the
    /// screens' and the night's. And a night whose time runs out while it waits asks for no file once the turn
    /// is its own: the guide is fetched in the night's own task, also behind that wait, and the night looks at
    /// its task again once the turn has come. Here the refresh that is out is one as the screens make it, on a
    /// recorder and a client of its own, its first file held; the night has told the free space, which is the
    /// last thing before its guide, when its task is cancelled; and the other refresh is then let go. The
    /// night asked the recorder who it is, for the slot and for the free space, and for nothing after.
    func testANightWhoseTimeIsUpWhileItWaitsItsTurnForTheGuideAsksForNoFile() async throws {
        let (recorder, store, _) = try await home()
        let other = NamedRecorder(1)
        await other.holdTheNext(Ask.guide[0])
        addTeardownBlock { await other.letGo() }
        let out = Task { await GuideRefresh.run(client: aClient(of: other), store: store) }
        try await until("the other refresh was never asked for") { await other.asked(Ask.guide[0]) == 1 }

        let told = Tellings()
        let tell = telling(told)
        let client = aClient(of: recorder)
        let count = await recorder.heard.count
        let run = Task { await BackgroundWork.refresh(client: client, store: store, mac: nil, telling: tell) }
        try await until("the night never came to its guide") { told.names.contains("freeSpace") }
        run.cancel()
        await other.letGo()
        let fetched = await out.value
        let stored = await run.value

        XCTAssertEqual(fetched.answered, GuideRefresh.broadcastingTypes, "the refresh that was out did not end")
        XCTAssertFalse(stored)
        expectEqual(await recorder.heard(since: count), [Ask.description, Ask.slot, Ask.freeSpace],
                    "a file was asked for by a night whose time was up as it waited its turn")
        XCTAssertEqual(told.names, ["flushed", "freeSpace"])
    }

    /// A night ends at its first silence, wherever it meets it: whatever it asked next would wait the same silence
    /// out again, of a recorder that has gone.
    ///
    /// At the read of the recorder's list that opens the round of what waits: nothing was sent, the row is as
    /// it was, the round is told as one that met silence, and the night ends there -- the slot is not read.
    /// At a reservation's create alone, the recorder answering again after it: the row is held for the reader
    /// with its reason, what became of the queue is told, and the night ends there -- the slot is not read,
    /// nothing is told of the free space and no guide is asked for. Silent from the create on, the same, and a
    /// recorder that has gone is asked nothing after the create. On the free space alone: nothing is told of
    /// it, and no guide is asked for. (Silent at the slot, which is read between the two, is the USB disk's
    /// own test.) In the guide: the night ends there, and the slot is not read again after it; that a guide was
    /// fetched is told, a type having answered before the silence, and what the night hands back is whether a
    /// programme was stored before it -- none where the type that answered had no file to give, and one where it
    /// gave a guide.
    func testANightEndsAtItsFirstSilenceHavingToldWhatItHadFound() async throws {
        let (recorder, store, _) = try await home()
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)
        await recorder.goQuiet(on: Ask.reservations)
        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations], "silence at the read that opens the round")
        XCTAssertEqual(ran.told.names, ["flushed"], "silence at the read that opens the round")
        XCTAssertEqual(ran.told.rounds.map(\.interrupted), [true], "silence at the read that opens the round")
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store), ["朝の番組"], "the row is not as it was")

        await recorder.goQuiet(on: Ask.create)
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create], "silence at the create alone")
        XCTAssertEqual(ran.told.names, ["flushed"], "silence at the create alone")
        XCTAssertEqual(ran.told.rounds.map(\.interrupted), [true])
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store), ["朝の番組: " + Said.heldAfterSilence])

        // The row above is held now, and is not sent again: another, and silence from its create on -- after
        // the recorder has said who it is and given its list.
        let noon = waiting("昼の番組", startingIn: 150, programme: 4322)
        try await store.queue(noon)
        await recorder.goQuiet(for: 1000, after: 2)
        ran = await night(of: recorder, store)
        await recorder.goQuiet(for: 0)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create], "silence from the create on")
        XCTAssertEqual(ran.told.names, ["flushed"], "silence from the create on")
        XCTAssertEqual(ran.told.rounds.map(\.interrupted), [true])
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store),
                    ["朝の番組: " + Said.heldAfterSilence, "昼の番組: " + Said.heldAfterSilence])

        // Both rows are held, so nothing is read or sent for the queue from here on.
        await recorder.goQuiet(on: Ask.freeSpace)
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace], "silence on the free space alone")
        XCTAssertEqual(ran.told.names, ["flushed"], "silence on the free space alone")
        XCTAssertFalse(ran.stored)

        // With a disk known that the slot does not answer, the slot is read again after a guide that ends.
        try await store.keep(knownUSBDisk: USBDiskTests.disk)
        await recorder.goQuiet(on: Ask.guide[1])
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + [Ask.guide[0], Ask.guide[1]], "silence in the guide")
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"], "silence in the guide")
        XCTAssertFalse(ran.stored)

        await recorder.answer(Ask.guide[0], with: .body(try vectorFile("epg-sample.dat")))
        await recorder.goQuiet(on: Ask.guide[1])
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + [Ask.guide[0], Ask.logos[0], Ask.guide[1]],
                       "silence in the guide, after a type that gave one")
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"])
        XCTAssertTrue(ran.stored, "a guide stored before the silence was not handed back as stored")
    }

    /// A night's guide goes only into the cache of the recorder that answered the night. While its first file is
    /// out, the cache is made over to another recorder, as the screens make it over when they take one up: by
    /// a connection of the test's own. The file then comes with a guide. Nothing of it is stored and no type is
    /// marked as answered for, in a cache that is the other's now; no further file is asked for; nothing is told
    /// of the guide; and the night hands back that nothing was stored.
    func testANightsGuideStaysOutOfACacheMadeOverToAnotherRecorderWhileAFileWasOut() async throws {
        let (recorder, store, path) = try await home()
        let told = Tellings()
        let tell = telling(told)
        let client = aClient(of: recorder)
        let before = await recorder.asked
        let count = await recorder.heard.count
        await recorder.holdTheNext(Ask.guide[0])
        addTeardownBlock { await recorder.letGo() }
        let run = Task { await BackgroundWork.refresh(client: client, store: store, mac: nil, telling: tell) }
        try await until("the night never asked for the guide") {
            await recorder.asked(Ask.guide[0], since: before) == 1
        }

        let another = try await aClient(of: NamedRecorder(2)).describe()
        let screens = try GuideStore(path: path)
        expectEqual(try await screens.claim(for: another), .another, "the cache was meant to be made over")
        await recorder.answer(Ask.guide[0], with: .body(try vectorFile("epg-sample.dat")))
        await recorder.letGo()
        let stored = await run.value

        XCTAssertFalse(stored, "the night said a guide was stored")
        expectEqual(await recorder.heard(since: count), Self.beforeTheGuide + [Ask.guide[0]],
                    "a file was asked for after the one the cache would not take")
        XCTAssertEqual(told.names, ["flushed", "freeSpace"], "a guide was said to be fetched")
        expectEqual(try await screens.owner(), NamedRecorder.udn(2))
        let counts = try await screens.counts()
        for type in GuideRefresh.broadcastingTypes {
            XCTAssertEqual(counts[type]?.programs, 0, "\(type): the night's programmes are in the other's cache")
            XCTAssertNil(counts[type]?.lastAnswered, "\(type) is marked as answered for")
        }
    }

    /// A night tells what is free as the free space and what the disk holds as its size, each as the recorder
    /// answered it and neither for the other: here a disk that holds two terabytes with thirty gigabytes of them
    /// free. The notice the app makes of the two, where no test sees, reads the first against its line: told
    /// the other way round, a disk nearly full would be taken for one with all its room.
    func testANightTellsWhatIsFreeAsFreeAndWhatTheDiskHoldsAsItsSize() async throws {
        let (recorder, store, _) = try await home()
        await recorder.answer(Ask.freeSpace,
                              with: .text("<recordDestinationInfo totalCapacity=\"2000000000000\" "
                                          + "availableCapacity=\"30000000000\" />", in: "RecordDestinationInfo"))
        let ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"])
        XCTAssertEqual(ran.told.said.dropFirst().first,
                       .freeSpace(free: 30_000_000_000, total: 2_000_000_000_000, naming: nil),
                       "what is free and what the disk holds were not each told as the recorder answered them")
    }

    /// A recorder that will not say how much room it has, by the rule the screens read the free space by: one
    /// that refuses, and one that answers a disk of no size, which is a recorder that has not said and not a
    /// disk that is full. Nothing is told of the free space of either, so that no notice is made of it, and the
    /// guide is fetched as ever: it answered, and the night goes on.
    func testANightTellsNothingOfSpaceTheRecorderWillNotSayNorOfADiskOfNoSize() async throws {
        let (recorder, store, _) = try await home()
        await recorder.answer(Ask.freeSpace, with: .fault(402))
        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.names, ["flushed", "fetched"])
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + Ask.guide)

        await recorder.answer(Ask.freeSpace,
                              with: .text("<recordDestinationInfo totalCapacity=\"0\" availableCapacity=\"0\" />",
                                          in: "RecordDestinationInfo"))
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.names, ["flushed", "fetched"], "a disk of no size was told as a disk")
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + Ask.guide, "a disk of no size")
    }

    /// A night that meets silence on the free space, the slot having just answered a USB disk that takes
    /// recordings: the USB disk's space is told all the same -- it was heard before the silence, and telling it
    /// asks nothing -- and the night ends there, with nothing told of the internal disk and no guide asked for.
    func testANightSilentOnTheFreeSpaceTellsTheUSBDisksSpaceItHadHeardAndEnds() async throws {
        let (recorder, store, _) = try await home()
        await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()))
        await recorder.goQuiet(on: Ask.freeSpace)
        let ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.names, ["flushed", "usbSpace"])
        XCTAssertEqual(ran.told.said.last, .usbSpace(USBDiskTests.disk),
                       "the USB disk's space, heard before the silence, was not told")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.slot, Ask.freeSpace],
                       "the night went on after silence on the free space")
        XCTAssertFalse(ran.stored)
    }

    /// A night that finds nobody at the address, and one answered by a recorder it cannot take for the cache's
    /// own, send nothing and fetch nothing, and say so only where the reader would otherwise miss something.
    ///
    /// Nobody there, with a reservation waiting that could be sent: nothing is told, and the queue is as it was.
    /// Another recorder than the cache's, with only a reservation held for the reader and one whose programme
    /// is over waiting: nothing is told either, there being nothing that would have gone, and neither row is
    /// touched. A recorder whose cache does not say whose it is -- the owner cannot be read -- with a
    /// reservation waiting that could be sent: nothing is sent to it, since it cannot be told to be the cache's
    /// own, and nothing is told. That the queue was held back is told of another recorder answering, with such
    /// a reservation waiting (`WhichRecorderTests`), and none is known to have answered here.
    func testANightWithNobodyThereOrARecorderItCannotTakeForItsOwnSendsNothing() async throws {
        let (recorder, store, path) = try await home()
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)
        await recorder.goQuiet(for: 1000)
        var ran = await night(of: recorder, store)
        XCTAssertFalse(ran.stored)
        XCTAssertEqual(ran.told.names, [], "a night that reached nobody told something")
        XCTAssertEqual(ran.heard, [Ask.description])
        expectEqual(try await rows(in: store), ["朝の番組"], "the queue is not as it was")
        await recorder.goQuiet(for: 0)

        // The cache's own recorder still, its owner out of reach.
        let meta = MetaOutOfReach(in: path)
        ran = await night(of: recorder, store)
        meta.putBack()
        XCTAssertFalse(ran.stored)
        XCTAssertEqual(ran.told.names, [], "with the cache's owner out of reach")
        XCTAssertEqual(ran.heard, [Ask.description], "with the cache's owner out of reach")
        expectEqual(try await rows(in: store), ["朝の番組"], "the queue is not as it was")

        // Another recorder, and nothing waiting that would go: one row held, one over an hour and a half ago.
        try await store.removePending(morning.id)
        let held = waiting("昼の番組", startingIn: 150, programme: 4322, problem: "前に断られた理由")
        let over = waiting("終わった番組", startingIn: -120, programme: 4323)
        try await store.queue(held)
        try await store.queue(over)
        await recorder.become(2)
        ran = await night(of: recorder, store)
        XCTAssertFalse(ran.stored)
        XCTAssertEqual(ran.told.names, [], "a stranger was told of with nothing waiting that would have gone")
        XCTAssertEqual(ran.heard, [Ask.description])
        expectEqual(try await rows(in: store), ["終わった番組", "昼の番組: 前に断られた理由"],
                    "a row was dropped or sent with a stranger answering")
    }

    /// The hour of the night: the next two o'clock in the morning in the recorder's own time, which is Japan's.
    /// From a second before it, that same morning's; at it and after it, the next morning's.
    ///
    /// Asked from fixed instants, so what is held is the hour, in Japan's time. That the time is Japan's whatever
    /// zone the phone is in is not held: on a machine in Japan the phone's own would give the same.
    func testTheNextNightIsAtTwoInTheMorningJapanTime() throws {
        func at(_ time: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: time)) }
        let two = try at("2026-10-10T02:00:00+09:00"), nextTwo = try at("2026-10-11T02:00:00+09:00")
        XCTAssertEqual(BackgroundWork.nextNightlyRun(after: try at("2026-10-10T01:59:59+09:00")), two)
        XCTAssertEqual(BackgroundWork.nextNightlyRun(after: two), nextTwo)
        XCTAssertEqual(BackgroundWork.nextNightlyRun(after: try at("2026-10-10T02:00:01+09:00")), nextTwo)
    }

    // MARK: - the Shortcuts action

    /// The Shortcuts action as the app's entry hands it on, with a client of its own and no MAC: what it came
    /// to, and what it asked of the recorder, in order.
    private func action(on recorder: NamedRecorder, _ store: GuideStore) async
        -> (sending: BackgroundWork.Sending, heard: [String]) {
        let count = await recorder.heard.count
        let sending = await BackgroundWork.sendWaiting(client: aClient(of: recorder), store: store, mac: nil)
        return (sending, await recorder.heard(since: count))
    }

    /// The action reads the queue before it asks anything of the recorder, which it would otherwise wake at every
    /// arrival home. A queue that holds only a reservation the recorder refused before, or only one whose
    /// programme is over, has nothing to send: nothing is asked, the row is neither sent nor dropped, and the
    /// action says there is nothing waiting.
    ///
    /// With a reservation to send and a cache that does not say whose it is -- the owner cannot be read --
    /// nothing is sent to a recorder that cannot be told to be the one the queue was made for, and the action
    /// answers as it does of a recorder it did not reach, in that sentence: not that another recorder answered,
    /// which none is known to have.
    ///
    /// And each end of the recorder's sending in the action's own words, letter for letter.
    func testTheActionAsksNothingWithNothingToSendAndSaysEachEndInItsOwnWords() async throws {
        let (recorder, store, path) = try await home()
        let refused = waiting("昼の番組", startingIn: 150, programme: 4322, problem: "前に断られた理由")
        let over = waiting("終わった番組", startingIn: -120, programme: 4323)
        for (row, asItWas) in [(refused, "昼の番組: 前に断られた理由"), (over, "終わった番組")] {
            try await store.queue(row)
            let came = await action(on: recorder, store)
            XCTAssertEqual(came.sending, .nothingWaiting, asItWas)
            XCTAssertEqual(came.heard, [], "the recorder was asked with nothing to send it: \(asItWas)")
            expectEqual(try await rows(in: store), [asItWas], "the row was sent or dropped")
            try await store.removePending(row.id)
        }

        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)
        let notReached = "レコーダーに接続できませんでした。送信待ちの予約はそのまま残しています。"
        let meta = MetaOutOfReach(in: path)
        let unread = await action(on: recorder, store)
        meta.putBack()
        XCTAssertEqual(unread.sending, .unreachable)
        XCTAssertEqual(unread.heard, [Ask.description], "something was sent with the cache's owner out of reach")
        XCTAssertEqual(SendWaitingIntent.saying(unread.sending), notReached)
        expectEqual(try await rows(in: store), ["朝の番組"], "the queue is not as it was")

        let sent = await action(on: recorder, store).sending
        let nothingToSay = BackgroundWork.Sending.sent(await PendingQueue.flush(client: aClient(of: recorder),
                                                                                 store: store))
        let nothing = "送信待ちの予約はありません。"
        let words: [(BackgroundWork.Sending, alone: String, withATelevision: String)] = [
            (.demo, "サンプルデータの表示中は送りません。", "サンプルデータの表示中は送りません。"),
            (.noRecorder, "レコーダーが設定されていません。", "レコーダーが設定されていません。"),
            (.nothingWaiting, nothing, nothing),
            (.unreachable, notReached, notReached),
            (.anotherRecorder, Said.anotherAnsweredWithNoScreen, Said.anotherAnsweredWithNoScreen),
            (sent, Said.sent("朝の番組"), Said.sent("朝の番組", naming: "レコーダー")),
            (nothingToSay, nothing, nothing),
        ]
        for (sending, alone, withATelevision) in words {
            XCTAssertEqual(SendWaitingIntent.saying(sending), alone, "\(sending)")
            XCTAssertEqual(SendWaitingIntent.saying(sending, televisionSaved: true), withATelevision, "\(sending)")
        }
    }

    /// A reservation held after silence at its create is said to be held still by each later round that has
    /// news, for as long as it waits: what is told of a round takes the place of what was told of the one
    /// before, and the row, passed over with its reason, is no news.
    ///
    /// The action's round meets silence at the create, and says the reservation is held. With another
    /// reservation waiting, the action's next round makes that one and passes the first over: it says what it
    /// made, and then that one reservation is still held and where to look -- with a television saved the
    /// same, the line naming the recorder as it always does. A night with nothing to send has no news, and
    /// would post nothing. A night with a third to send posts what it made, and the same line.
    func testARoundWithNewsSaysThatAReservationHeldAfterAnEarlierSilenceIsStillHeld() async throws {
        let (recorder, store, _) = try await home()
        try await store.queue(waiting("朝の番組", startingIn: 120, programme: 4321))
        await recorder.goQuiet(on: Ask.create)
        var came = await action(on: recorder, store)
        XCTAssertEqual(SendWaitingIntent.saying(came.sending), Said.heldAfterSilence, "silence at the create")
        let held = "朝の番組: " + Said.heldAfterSilence

        try await store.queue(waiting("昼の番組", startingIn: 150, programme: 4322))
        came = await action(on: recorder, store)
        XCTAssertEqual(came.heard, [Ask.description, Ask.reservations, Ask.create])
        XCTAssertEqual(SendWaitingIntent.saying(came.sending), Said.sent("昼の番組") + "。" + Self.stillHeld(1),
                       "the reservation held before was not said to be held still")
        XCTAssertEqual(SendWaitingIntent.saying(came.sending, televisionSaved: true),
                       Said.sent("昼の番組", naming: "レコーダー") + "。" + Self.stillHeld(1), "with a television saved")
        expectEqual(try await rows(in: store), [held])

        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.names.first, "flushed")
        XCTAssertNil(posted(ran.told.rounds.first), "a round with no news told of the reservation held before")

        try await store.queue(waiting("夜の番組", startingIn: 180, programme: 4323))
        ran = await night(of: recorder, store)
        XCTAssertEqual(posted(ran.told.rounds.first), Said.sent("夜の番組") + "。" + Self.stillHeld(1),
                       "the night did not say that the reservation held before is held still")
        expectEqual(try await rows(in: store), [held])
    }

    /// So it is said by a round that never came to that reservation: one cut short at a read ahead of it. The
    /// line is counted over the whole of what the round read, and of the rows behind the stop the queue's clause
    /// for a round cut short -- that the rest goes the next time -- is not true of this one.
    ///
    /// Three reservations wait: one whose programme is over, one to go, and one that starts after it, held
    /// after silence at an earlier create. The recorder is silent at the reservations' list, which a round
    /// reads as it opens. A night's round drops the one that is over, which is news, and stops there: it tells
    /// that, that the rest goes the next time the recorder answers, and that one reservation is held still.
    /// The Shortcuts action, with another whose programme is over, answers the same. And a night whose time is
    /// up meanwhile, which tells no round as cut short at a read, tells of the one it dropped and that one is
    /// held still. The two that waited wait as they were.
    func testARoundCutShortAheadOfAReservationHeldAfterAnEarlierSilenceSaysItIsStillHeld() async throws {
        let (recorder, store, _) = try await home()
        let cutShort = "途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります"
        try await store.queue(waiting("終わった番組", startingIn: -120, programme: 4323))
        try await store.queue(waiting("昼の番組", startingIn: 150, programme: 4322))
        try await store.queue(waiting("夜の番組", startingIn: 300, programme: 4324, problem: Said.heldAfterSilence))
        let asTheyWere = ["昼の番組", "夜の番組: " + Said.heldAfterSilence]

        await recorder.goQuiet(on: Ask.reservations)
        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations])
        XCTAssertEqual(posted(ran.told.rounds.first),
                       Said.expired("終わった番組") + "。" + cutShort + "。" + Self.stillHeld(1),
                       "the reservation held behind the read that met silence was not said to be held still")
        expectEqual(try await rows(in: store), asTheyWere)

        try await store.queue(waiting("終わった番組", startingIn: -120, programme: 4325))
        await recorder.goQuiet(on: Ask.reservations)
        let came = await action(on: recorder, store)
        XCTAssertEqual(came.heard, [Ask.description, Ask.reservations])
        XCTAssertEqual(SendWaitingIntent.saying(came.sending),
                       Said.expired("終わった番組") + "。" + cutShort + "。" + Self.stillHeld(1), "the action's answer")
        expectEqual(try await rows(in: store), asTheyWere)

        try await store.queue(waiting("終わった番組", startingIn: -120, programme: 4326))
        await recorder.goQuiet(on: Ask.reservations)
        ran = try await nightCancelled(of: recorder, store, at: Ask.reservations)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations])
        XCTAssertEqual(posted(ran.told.rounds.first), Said.expired("終わった番組") + "。" + Self.stillHeld(1),
                       "a night whose time was up did not say that the reservation is held still")
        expectEqual(try await rows(in: store), asTheyWere)
    }

    /// The action's round meets silence. At the read of the recorder's list that opens it, nothing was sent: the
    /// action says the recorder stopped answering part-way and that what waits is left as it is, and the row is
    /// as it was. At a reservation's create the row is held for the reader with its reason, which says it may
    /// have arrived and is not sent again by itself, and the action says that sentence, the one written on the
    /// row: what waits is not left as it was. So it does with a television saved, the sentence naming no device
    /// but the recorder it is about.
    ///
    /// And after another reservation that went: what the queue says of the one sent, then that sentence, in
    /// place of the queue's own for a round cut short -- that the rest goes the next time the recorder answers,
    /// which the reservation held does not.
    func testTheActionWhoseRoundMeetsSilenceSaysWhatWaitsIsLeftAtTheReadAndThatTheReservationIsHeldAtACreate()
        async throws {
        let (recorder, store, _) = try await home()
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)
        let left = "途中でレコーダーの応答がなくなりました。送信待ちの予約はそのまま残しています。"

        await recorder.goQuiet(on: Ask.reservations)
        var came = await action(on: recorder, store)
        XCTAssertEqual(came.heard, [Ask.description, Ask.reservations])
        XCTAssertEqual(SendWaitingIntent.saying(came.sending), left, "silence at the read that opens the round")
        expectEqual(try await rows(in: store), ["朝の番組"], "the row is not as it was")

        await recorder.goQuiet(on: Ask.create)
        came = await action(on: recorder, store)
        XCTAssertEqual(came.heard, [Ask.description, Ask.reservations, Ask.create])
        XCTAssertEqual(SendWaitingIntent.saying(came.sending), Said.heldAfterSilence, "silence at the create")
        XCTAssertEqual(SendWaitingIntent.saying(came.sending, televisionSaved: true), Said.heldAfterSilence,
                       "silence at the create, with a television saved")
        expectEqual(try await rows(in: store), ["朝の番組: " + Said.heldAfterSilence])

        // The morning's is held now and is not sent again: two more, the second's create meeting silence.
        try await store.queue(waiting("昼の番組", startingIn: 150, programme: 4322))
        try await store.queue(waiting("夜の番組", startingIn: 180, programme: 4323))
        await recorder.answer(Ask.create, with: .silence, after: 1)
        came = await action(on: recorder, store)
        XCTAssertEqual(came.heard, [Ask.description, Ask.reservations, Ask.create, Ask.create])
        XCTAssertEqual(SendWaitingIntent.saying(came.sending), Said.sent("昼の番組") + "。" + Said.heldAfterSilence,
                       "silence at a create, after a reservation that went")
        XCTAssertEqual(SendWaitingIntent.saying(came.sending, televisionSaved: true),
                       Said.sent("昼の番組", naming: "レコーダー") + "。" + Said.heldAfterSilence)
        expectEqual(try await rows(in: store),
                    ["朝の番組: " + Said.heldAfterSilence, "夜の番組: " + Said.heldAfterSilence])
    }

    // MARK: - told once

    /// Half past noon in Japan on 18 May 2033, when the reservations of these tests start unless said, and the
    /// overnight run asked for next, an hour after it: a reservation here is never over at the hour the test is
    /// run, and is due before the next run or not by what the test says.
    private static let dueAt = Date(timeIntervalSince1970: 2_000_000_000)
    private static let nextRun = dueAt + 3600

    /// A reservation waiting for the recorder, half an hour on the demo's first channel, starting at `start`.
    private func due(_ title: String, programme: Int, at start: Date = dueAt) -> PendingReservation {
        let request = ReservationRequest(title: title, start: start, durationSec: 1800, repeatCode: "1",
                                         broadcastingType: 2, serviceID: 1024, qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ")
    }

    /// The notice of reservations that have not reached the recorder in time, of the one that starts at
    /// `dueAt`, as far as what stands in its way.
    private static func notYet(_ title: String) -> String {
        "レコーダーにまだ届いていない予約があります（「\(title)」12:33 から）。"
    }

    private static let notAnswering = "レコーダーが応答しないため送っていません。次にレコーダーが答えたときに送ります"

    /// The overnight run handed what was told before and when the next is asked for, as the app's entry hands
    /// them on: what it told, and what it asked of the recorder. With `kind`, its next request of that kind is
    /// held while `meanwhile` runs, handed the night's task, and then let go with whatever else is held.
    /// `asTheQueueIsTold` is run in the night's own task once what became of the queue has been told, as the app
    /// would be posting its notification.
    private func nightTellingOnce(of recorder: NamedRecorder, _ store: GuideStore, from told: ToldOnce = ToldOnce(),
                                  heldAt kind: String? = nil,
                                  _ meanwhile: (Task<Bool, Never>) async throws -> Void = { _ in },
                                  asTheQueueIsTold: (@Sendable () async -> Void)? = nil) async throws
        -> (told: Tellings, heard: [String]) {
        let record = Tellings()
        var asked = telling(record)
        if let asTheQueueIsTold {
            let flushed = asked.flushed
            asked.flushed = { outcome in
                await flushed(outcome)
                await asTheQueueIsTold()
            }
        }
        let tell = asked
        let client = aClient(of: recorder)
        let before = await recorder.asked
        let count = await recorder.heard.count
        if let kind {
            await recorder.holdTheNext(kind)
            addTeardownBlock { await recorder.letGo() }
        }
        let run = Task {
            await BackgroundWork.refresh(client: client, store: store, mac: nil, telling: tell, told: { told },
                                         nextRun: Self.nextRun)
        }
        if let kind {
            try await until("the night never asked for \(kind)") { await recorder.asked(kind, since: before) == 1 }
            try await meanwhile(run)
            await recorder.letGo()
        }
        _ = await run.value
        return (record, await recorder.heard(since: count))
    }

    /// A night tells once of a reservation that starts before the next night and has not reached the recorder,
    /// and hands that over as its sending ends, whichever way it ends, ahead of the free space and the guide.
    ///
    /// Nobody there: the notice, saying the recorder is not answering, and the reservation kept as told of. The
    /// next such night, handed what the first kept, tells no notice again. So with a recorder that answers and
    /// cannot be told to be the cache's own -- the owner out of reach -- which is told of as one not reached.
    /// A round that meets silence at the read that opens it: what became of the queue, then the notice, and the
    /// night ends. And a round that makes the reservation: what became of the queue, then that the notice is to
    /// be taken away and nothing is told of any more, and only then the free space and the guide.
    func testANightTellsOnceOfAReservationThatHasNotReachedTheRecorderInTimeBeforeTheSpaceAndTheGuide()
        async throws {
        let (recorder, store, path) = try await home()
        let evening = due("夕方の番組", programme: 4331)
        try await store.queue(evening)
        let kept = ToldOnce(rows: [evening.id])
        let notice = Self.notYet("夕方の番組") + Self.notAnswering

        await recorder.goQuiet(for: 1000)
        var ran = try await nightTellingOnce(of: recorder, store)
        XCTAssertEqual(ran.told.said, [.told(notYet: notice, withdraws: false, kept: kept)], "nobody there")
        ran = try await nightTellingOnce(of: recorder, store, from: kept)
        XCTAssertEqual(ran.told.said, [.told(notYet: nil, withdraws: false, kept: kept)], "nobody there, again")
        XCTAssertEqual(ran.heard, [Ask.description])
        await recorder.goQuiet(for: 0)

        let meta = MetaOutOfReach(in: path)
        ran = try await nightTellingOnce(of: recorder, store)
        meta.putBack()
        XCTAssertEqual(ran.told.said, [.told(notYet: notice, withdraws: false, kept: kept)],
                       "with the cache's owner out of reach")
        XCTAssertEqual(ran.heard, [Ask.description], "with the cache's owner out of reach")

        // Nobody there again, and the owner out of reach only once the night has begun: whose cache it is
        // cannot be read as the telling is made, which keeps nothing back.
        await recorder.goQuiet(for: 1000)
        ran = try await nightTellingOnce(of: recorder, store, heldAt: Ask.description) { run in
            let meta = MetaOutOfReach(in: path)
            await recorder.letGo()
            _ = await run.value
            meta.putBack()
        }
        XCTAssertEqual(ran.told.said, [.told(notYet: notice, withdraws: false, kept: kept)],
                       "nobody there, the cache's owner out of reach by the telling")
        await recorder.goQuiet(for: 0)

        await recorder.goQuiet(on: Ask.reservations)
        ran = try await nightTellingOnce(of: recorder, store)
        XCTAssertEqual(ran.told.names, ["flushed", "told"], "silence at the read that opens the round")
        XCTAssertEqual(ran.told.said.last, .told(notYet: notice, withdraws: false, kept: kept),
                       "silence at the read that opens the round")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations])

        ran = try await nightTellingOnce(of: recorder, store, from: kept)
        XCTAssertEqual(ran.told.names, ["flushed", "told", "freeSpace", "fetched"],
                       "what is told once was not handed over ahead of the free space and the guide")
        XCTAssertEqual(ran.told.said.dropFirst().first, .told(notYet: nil, withdraws: true, kept: ToldOnce()))
        expectEqual(try await rows(in: store), [])
    }

    /// That another recorder answered is told once, not every night. With a reservation waiting that starts
    /// after the next night: the queue held back, and what is kept says it was told; the next such night, handed
    /// that, tells nothing of the queue. With one that starts before the next night as well, the notice of it
    /// carries the sentence, and the queue held back is not told beside it. And a stranger with nothing waiting
    /// that would go is told of by nothing, and what was told is forgotten.
    func testANightTellsOnceThatAnotherRecorderAnsweredAndNotWithNothingWaiting() async throws {
        let (recorder, store, _) = try await home()
        let later = due("翌日の番組", programme: 4332, at: Self.nextRun + 3600)
        try await store.queue(later)
        await recorder.become(2)
        let said = ToldOnce(stop: .another)

        var ran = try await nightTellingOnce(of: recorder, store)
        XCTAssertEqual(ran.told.said, [.heldBack, .told(notYet: nil, withdraws: false, kept: said)])
        ran = try await nightTellingOnce(of: recorder, store, from: said)
        XCTAssertEqual(ran.told.said, [.told(notYet: nil, withdraws: false, kept: said)], "told a second night")

        let evening = due("夕方の番組", programme: 4331)
        try await store.queue(evening)
        ran = try await nightTellingOnce(of: recorder, store)
        XCTAssertEqual(ran.told.said, [.told(notYet: Self.notYet("夕方の番組") + Said.anotherAnsweredWithNoScreen,
                                             withdraws: false, kept: ToldOnce(stop: .another, rows: [evening.id]))])

        for row in [later, evening] { try await store.setPendingProblem(row.id, "前に断られた理由") }
        ran = try await nightTellingOnce(of: recorder, store, from: said)
        XCTAssertEqual(ran.told.said, [.told(notYet: nil, withdraws: false, kept: ToldOnce())],
                       "a stranger with nothing waiting that would go")
        XCTAssertEqual(ran.heard, [Ask.description])
    }

    /// A night hands over nothing of what is told once, so that nothing of it is posted or kept, once its time
    /// is up or the cache is another recorder's.
    ///
    /// Its time up while nobody answers: nothing. Nobody answering, and the cache made over to another recorder
    /// while the one at the address is asked who it is, as the screens make it over when they take one up: the
    /// night has heard nothing to hold against the cache, and whose cache it was as the night began is what
    /// keeps the telling back -- nothing, where it would hand over what to keep of the recorder before. Its
    /// time up while the first of two reservations is being made: both go, the round being finished row by
    /// row, what became of the queue is told, and nothing after it. Its time up as what became of the queue is
    /// being told, and the cache made over to another recorder just then: nothing after it, and the night
    /// ends. The cache made over while a reservation is being made: nothing at all.
    func testANightHandsOverNothingOfWhatIsToldOnceWhenItsTimeIsUpOrTheCacheIsAnotherRecorders() async throws {
        let (recorder, store, path) = try await home()
        try await store.queue(due("夕方の番組", programme: 4331))
        await recorder.goQuiet(for: 1000)
        var ran = try await nightTellingOnce(of: recorder, store, heldAt: Ask.description) { $0.cancel() }
        XCTAssertEqual(ran.told.said, [], "nobody there, the night's time up")

        ran = try await nightTellingOnce(of: recorder, store, heldAt: Ask.description) { _ in
            let another = try await aClient(of: NamedRecorder(2)).describe()
            expectEqual(try await GuideStore(path: path).claim(for: another), .another,
                        "the cache was meant to be made over")
        }
        XCTAssertEqual(ran.told.said, [], "nobody there, the cache another recorder's than it was")
        XCTAssertEqual(ran.heard, [Ask.description])
        let itsOwn = try await aClient(of: NamedRecorder(1)).describe()
        expectEqual(try await store.claim(for: itsOwn), .another, "the cache was meant to have been made over")
        await recorder.goQuiet(for: 0)

        try await store.queue(due("夜の番組", programme: 4333, at: Self.dueAt + 1800))
        ran = try await nightTellingOnce(of: recorder, store, heldAt: Ask.create) { $0.cancel() }
        XCTAssertEqual(ran.told.names, ["flushed"], "the night's time up while a reservation was being made")
        expectEqual(try await rows(in: store), [])

        try await store.queue(due("朝の番組", programme: 4336))
        ran = try await nightTellingOnce(of: recorder, store, asTheQueueIsTold: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
        XCTAssertEqual(ran.told.names, ["flushed"], "the night's time up as what became of the queue was told")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create])

        try await store.queue(due("昼の番組", programme: 4337))
        ran = try await nightTellingOnce(of: recorder, store, asTheQueueIsTold: {
            let another = try? await aClient(of: NamedRecorder(2)).describe()
            guard let another, let screens = try? GuideStore(path: path) else { return }
            _ = try? await screens.claim(for: another)
        })
        XCTAssertEqual(ran.told.names, ["flushed"],
                       "the cache another recorder's as what became of the queue was told")
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create])
        let first = try await aClient(of: NamedRecorder(1)).describe()
        expectEqual(try await store.claim(for: first), .another, "the cache was meant to have been made over")

        try await store.queue(due("深夜の番組", programme: 4334))
        ran = try await nightTellingOnce(of: recorder, store, heldAt: Ask.create) { _ in
            let another = try await aClient(of: NamedRecorder(2)).describe()
            expectEqual(try await GuideStore(path: path)
                .claim(for: another, holdingTheQueueWith: RecorderDriver.heldForAnotherRecorder), .another,
                        "the cache was meant to be made over")
        }
        XCTAssertEqual(ran.told.said, [], "the cache another recorder's after the round")
    }

    /// The Shortcuts action hands back, with what its sending came to, what it has to tell once, for its entry
    /// to post and keep: asked as that entry asks, with what was told before and when the next night is.
    ///
    /// Nobody there, a reservation waiting that starts before the next night: the notice, and the reservation
    /// kept as told of; handed that, no notice again. Another recorder: that it answered is news, in the notice
    /// where a reservation is due and by itself where none is, and is not news the next time. The recorder
    /// known: the reservation goes, the notice is to be taken away and nothing is told of any more. And with no
    /// next night handed in, as the action's tests ask it: another recorder answering is news each time, and
    /// there is nothing to post or keep.
    func testTheActionHandsBackWithItsSendingWhatItHasToTellOnce() async throws {
        let (recorder, store, _) = try await home()
        let evening = due("夕方の番組", programme: 4331)
        try await store.queue(evening)
        let kept = ToldOnce(rows: [evening.id])
        func action(from told: ToldOnce = ToldOnce(), before nextRun: Date? = Self.nextRun) async
            -> (sending: BackgroundWork.Sending, news: NoScreenTold) {
            await BackgroundWork.sendWaiting(client: aClient(of: recorder), store: store, mac: nil, told: { told },
                                             nextRun: nextRun, now: Self.dueAt, tell: { _, _ in })
        }

        await recorder.goQuiet(for: 1000)
        var came = await action()
        XCTAssertEqual(came.sending, .unreachable)
        XCTAssertEqual(came.news, NoScreenTold(notYet: Self.notYet("夕方の番組") + Self.notAnswering, kept: kept))
        came = await action(from: kept)
        XCTAssertEqual(came.news, NoScreenTold(kept: kept), "nobody there, again")
        await recorder.goQuiet(for: 0)

        let stranger = NamedRecorder(2)
        func asked(of stranger: NamedRecorder, from told: ToldOnce, before nextRun: Date?) async -> NoScreenTold {
            await BackgroundWork.sendWaiting(client: aClient(of: stranger), store: store, mac: nil, told: { told },
                                             nextRun: nextRun, now: Self.dueAt, tell: { _, _ in }).news
        }
        let late = ToldOnce(stop: .another, rows: [evening.id])
        expectEqual(await asked(of: stranger, from: kept, before: Self.nextRun),
                    NoScreenTold(heldBackIsNews: true, kept: late), "another recorder, the reservation told of before")
        expectEqual(await asked(of: stranger, from: ToldOnce(), before: Self.nextRun),
                    NoScreenTold(notYet: Self.notYet("夕方の番組") + Said.anotherAnsweredWithNoScreen, kept: late))
        expectEqual(await asked(of: stranger, from: ToldOnce(), before: Self.dueAt - 3600),
                    NoScreenTold(heldBackIsNews: true, kept: ToldOnce(stop: .another)),
                    "another recorder, the reservation not due before the next night")
        expectEqual(await asked(of: stranger, from: ToldOnce(stop: .another), before: Self.dueAt - 3600),
                    NoScreenTold(kept: ToldOnce(stop: .another)), "another recorder, told before")
        expectEqual(await asked(of: stranger, from: ToldOnce(stop: .another), before: nil),
                    NoScreenTold(heldBackIsNews: true), "another recorder, with no next night")
        expectEqual(await stranger.asked(Ask.create), 0)

        came = await action(from: late)
        guard case .sent(let outcome) = came.sending else { return XCTFail("not sent: \(came.sending)") }
        XCTAssertEqual(outcome.sent.map(\.id), [evening.id])
        XCTAssertEqual(came.news, NoScreenTold(withdrawsNotYet: true, kept: ToldOnce()))
        came = await action(before: nil)
        XCTAssertEqual(came.sending, .nothingWaiting)
        XCTAssertEqual(came.news, NoScreenTold(), "with no next night")
    }

    /// A sending of the screens' own, or a delete, takes the recorder's late notice away once none of the
    /// reservations it told of waits to go, and they are told of no more: what the runs with no screen kept of
    /// them is written again without them, the stop told left as it was. While one of them still waits, nothing
    /// is written.
    ///
    /// Two told of: a connect's sending makes the first, the recorder being too busy for the second, which
    /// still waits. That one deleted by the reader: none is told of any more. And one told of that the reader
    /// sends again, which goes: the same. So with one told of whose programme the reader reserves by hand
    /// from the guide: that reservation takes the waiting row's place, goes, and none is told of any more.
    func testTheScreensOwnSendingOrADeleteForgetsTheRecordersLateNoticeOnceNoneOfItsReservationsWaits()
        async throws {
        let (bench, recorder, model) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        let evening = due("夕方の番組", programme: 4331), night = due("夜の番組", programme: 4333, at: Self.dueAt + 1800)
        func keep(_ told: ToldOnce) throws {
            bench.defaults.set(try JSONEncoder().encode(told), forKey: DefaultsKey.recorderTold)
        }
        func kept() throws -> ToldOnce? {
            try bench.defaults.data(forKey: DefaultsKey.recorderTold).map {
                try JSONDecoder().decode(ToldOnce.self, from: $0)
            }
        }

        try await store.queue(evening)
        try await store.queue(night)
        let warned = ToldOnce(stop: .another, rows: [evening.id, night.id])
        try keep(warned)
        await recorder.beBusy(with: Ask.create, after: 1)
        await model.connect()
        try await untilIdle(model)
        XCTAssertEqual(model.pending.map(\.id), [night.id], "the second reservation was meant to wait still")
        try await afterTheQueuesTurn()
        XCTAssertEqual(try kept(), warned, "the reservations warned of forgotten while one still waits")

        await model.deleteWaiting(try XCTUnwrap(model.pending.first))
        XCTAssertEqual(model.pending, [])
        try await afterTheQueuesTurn(until: { try kept() == ToldOnce(stop: .another) })
        XCTAssertEqual(try kept(), ToldOnce(stop: .another), "the reservations warned of still told of once deleted")

        let morning = due("朝の番組", programme: 4336)
        try await store.queue(morning)
        try keep(ToldOnce(rows: [morning.id]))
        await model.loadPending()
        await model.resend(try XCTUnwrap(model.pending.first))
        XCTAssertEqual(model.pending, [])
        try await afterTheQueuesTurn(until: { try kept() == ToldOnce() })
        XCTAssertEqual(try kept(), ToldOnce(), "the reservation warned of still told of once sent again")

        try keep(warned)
        try await store.queue(due("昼の番組", programme: 4337))
        await model.connect()
        try await untilIdle(model)
        try await afterTheQueuesTurn(until: { try kept() == ToldOnce(stop: .another) })
        XCTAssertEqual(try kept(), ToldOnce(stop: .another), "the reservations warned of still told of once sent")

        // One waiting that the attach's sending passed over, the recorder too busy, and was told of since.
        let program = try await programmesNotReserved(model, 1)[0]
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        let byHand = PendingReservation(request: request, serviceName: program.serviceName)
        try await store.queue(byHand)
        try keep(ToldOnce(rows: [byHand.id]))
        await model.loadPending()
        let reserved = await model.reserve(program, on: .recorder, quality: "DR", repeating: "none")
        XCTAssertEqual(reserved, .made(saying: nil))
        XCTAssertEqual(model.pending, [], "the reservation made by hand still waits")
        try await afterTheQueuesTurn(until: { try kept() == ToldOnce() })
        XCTAssertEqual(try kept(), ToldOnce(), "the reservation warned of still told of once reserved by hand")
    }

    /// The recorder's warning, the same way: a forgetting of it asked for real -- a reservation made by hand, the
    /// recorder given up on, so that it is kept to go by itself and takes no turn of the queue's -- that waits
    /// for the queue's turn while the demo begins is made all the same, of the real queue, as it was asked. Told
    /// of: another recorder answering, and a reservation no longer in the queue, which is told of no more once
    /// the queue's turn has come round. The test holds the queue's turn while the reservation is made and the
    /// demo begun, and lets it go once the demo's cache has taken the real one's place.
    func testTheRecordersForgettingAskedBeforeTheDemoBeganIsMadeOfTheRealQueue() async throws {
        try await theRecordersForgettingAcrossTheDemo(toldOfTheRowKept: false)
    }

    /// The same with the reservation just kept told of: it still waits in the real queue, and nothing changes,
    /// though the demo's queue, the one in play by the turn, has none of it.
    func testTheRecordersForgettingAskedBeforeTheDemoBeganReadsTheRealQueue() async throws {
        try await theRecordersForgettingAcrossTheDemo(toldOfTheRowKept: true)
    }

    /// The two rows above.
    private func theRecordersForgettingAcrossTheDemo(toldOfTheRowKept: Bool) async throws {
        let (bench, recorder, model) = try await connectedHome()
        let kept = KeptIn(bench.defaults, DefaultsKey.recorderTold)
        let programme = try await theDemosProgramme(model, in: try XCTUnwrap(model.store))
        await recorder.goQuiet(for: 1000)
        await model.connect()
        try await untilGivenUp(model)
        let real = try XCTUnwrap(model.store)
        let turn = Held()
        addTeardownBlock { await turn.letGo() }
        let holding = Task { await PendingQueue.betweenFlushes { await turn.wait() } }
        try await within(10, "the queue's turn was never had") { await turn.untilCome() }

        let reserved = try await within(10, "the reservation never came back while the queue's turn was held") {
            await model.reserve(programme, on: .recorder, quality: "DR", repeating: "none")
        }
        guard case .waiting(let row, _) = reserved else {
            return XCTFail("set up wrong: the reservation was meant to be kept to go by itself: \(reserved)")
        }
        let told = ToldOnce(stop: .another, rows: [toldOfTheRowKept ? row.id : "サンプルの行"])
        kept.value = told
        let entering = Task { await model.enterDemo() }
        try await until("the demo's cache never took the real one's place") { model.store !== real }
        await turn.letGo()
        _ = try await within(10, "the queue's turn held was never over") { await holding.value }
        try await within(10, "the demo was never entered") { await entering.value }

        if toldOfTheRowKept {
            try await afterTheQueuesTurn()
            XCTAssertEqual(kept.value, told, "forgotten while the reservation told of still waits in the real queue")
        } else {
            try await afterTheQueuesTurn(until: { kept.value == ToldOnce(stop: .another) })
            XCTAssertEqual(kept.value, ToldOnce(stop: .another),
                           "a reservation no longer in the queue still told of once the demo began")
        }
    }

    /// The Shortcuts action telling as the app, opened at the same arrival, sends what waits itself: what is
    /// told once is decided, posted and kept inside the queue's turn, and the screens' sending waits for that.
    /// The action, the recorder not answering it, tells of a reservation that has not reached the recorder,
    /// and is held there by the test. The screens' sending -- a pull-down -- is begun meanwhile, its line up,
    /// and its round does not begin while the action is telling. Let go, the action keeps the reservation as
    /// told of; the screens then send it and take it off what is kept. So nothing kept names the reservation,
    /// and the action told of it once, before it was sent; the withdrawal that follows the forgetting is not
    /// seen on the bench, whose notifications are off.
    func testTheScreensSendingWaitsForTheActionsTellingAndTakesItsNoticeAway() async throws {
        let (bench, recorder, model) = try await connectedHome()
        try await afterTheQueuesTurn()
        let store = try GuideStore(path: bench.guidePath)
        let evening = due("夕方の番組", programme: 4331)
        try await store.queue(evening)
        await model.loadPending()
        let kept = KeptIn(bench.defaults, DefaultsKey.recorderTold)
        let held = Held()
        addTeardownBlock { await held.letGo() }
        let notices = Notices()
        let action = Task {
            await BackgroundWork.sendWaiting(client: aClient(of: SilentRecorder()), store: store, mac: nil,
                                             told: { kept.value ?? ToldOnce() }, nextRun: Self.nextRun,
                                             now: Self.dueAt, tell: { _, news in
                notices.note(news.notYet)
                await held.wait()
                if let news = news.kept { kept.value = news }
            })
        }
        try await within(10, "the action never came to tell what it tells once") { await held.untilCome() }
        let count = await recorder.heard.count
        let ended = Flag()
        let sending = Task {
            await model.refreshReservations()
            ended.yes = true
        }
        // Up while the sending waits for its round; over already where nothing held it back.
        try await until("the screens' sending never put its line up") {
            model.busy == RecorderDriver.sendingLine || ended.yes
        }

        var turns = 0
        while turns < 20_000, await recorder.heard(since: count).allSatisfy({ $0 == Ask.description }) {
            turns += 1
            await Task.yield()
        }
        expectEqual(await recorder.heard(since: count).filter { $0 != Ask.description }, [],
                    "the screens' round began while the action was telling")
        await held.letGo()
        let acted = try await within(10, "the action never ended") { await action.value }
        try await within(10, "the screens' sending never ended") { await sending.value }
        try await afterTheQueuesTurn(until: { kept.value == ToldOnce() })

        XCTAssertEqual(acted.sending, .unreachable)
        XCTAssertEqual(model.pending, [], "the screens' sending did not send the reservation")
        XCTAssertEqual(kept.value, ToldOnce(), "the reservation the screens sent is still told of")
        XCTAssertEqual(notices.all, [Self.notYet("夕方の番組") + Self.notAnswering],
                       "the action did not tell of the reservation once, before it was sent")
    }

    /// A pull-down while the Shortcuts action is telling, with nothing to send: what follows the screens'
    /// sending -- what the runs told once of reservations that no longer wait, forgotten -- is made in the
    /// queue's turn, and so not while the action is telling, never from what was kept before it and written
    /// over what it kept. Kept before: another recorder told of, and a reservation told of that has gone since.
    /// What waits is held with a reason, so that the action has nothing to send and the pull-down nothing to
    /// send either. The action is held as it tells; the pull-down is made meanwhile, and what was kept is not
    /// written while the action is telling. Let go, the action keeps that nothing is told of, the stop with it,
    /// which a forgetting made from what was kept before would have kept.
    func testThePullDownForgetsWhatWasToldOnceOnlyAfterARunHasToldIt() async throws {
        let (bench, _, model) = try await connectedHome()
        try await afterTheQueuesTurn()
        let store = try GuideStore(path: bench.guidePath)
        let gone = due("朝の番組", programme: 4336)
        var held = due("夕方の番組", programme: 4331)
        held.problem = "前に断られた理由"
        try await store.queue(held)
        await model.loadPending()
        let kept = KeptIn(bench.defaults, DefaultsKey.recorderTold)
        let before = ToldOnce(stop: .another, rows: [gone.id])
        kept.value = before
        let telling = Held()
        addTeardownBlock { await telling.letGo() }
        let action = Task {
            await BackgroundWork.sendWaiting(client: aClient(of: SilentRecorder()), store: store, mac: nil,
                                             told: { kept.value ?? ToldOnce() }, nextRun: Self.nextRun,
                                             now: Self.dueAt, tell: { _, news in
                await telling.wait()
                if let news = news.kept { kept.value = news }
            })
        }
        try await within(10, "the action never came to tell what it tells once") { await telling.untilCome() }

        try await within(10, "the pull-down never came back") { await model.refreshReservations() }
        for _ in 0..<100_000 where kept.value == before { await Task.yield() }
        XCTAssertEqual(kept.value, before,
                       "what follows the screens' sending was made while the action was telling")
        await telling.letGo()
        let acted = try await within(10, "the action never ended") { await action.value }
        try await afterTheQueuesTurn()

        XCTAssertEqual(acted.sending, .nothingWaiting)
        XCTAssertEqual(kept.value, ToldOnce(), "what the action kept was not what is kept")
    }

    /// The cache made over to another recorder while a night is telling what it tells once of the recorder
    /// before: what the make-over forgets of what was told is forgotten in the queue's turn as well, after the
    /// telling, so that nothing the night kept of the recorder before stays. The night, nobody answering it,
    /// tells of a reservation that has not reached the recorder, and is held as it keeps that; the screens
    /// take up another recorder at the address meanwhile. Once the night has ended and the queue's turn has come
    /// round, nothing is kept.
    func testACacheMadeOverWhileANightIsTellingKeepsNothingOfTheRecorderBefore() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        try await store.queue(due("夕方の番組", programme: 4331))
        let kept = KeptIn(bench.defaults, DefaultsKey.recorderTold)
        let held = Held()
        addTeardownBlock { await held.letGo() }
        var tell = telling(Tellings())
        tell.kept = { _, _, told in
            await held.wait()
            kept.value = told
        }
        let night = Task { [tell] in
            await BackgroundWork.refresh(client: aClient(of: SilentRecorder()), store: store, mac: nil,
                                         telling: tell, told: { kept.value ?? ToldOnce() }, nextRun: Self.nextRun)
        }
        try await within(10, "the night never came to keep what it told once") { await held.untilCome() }

        await recorder.become(2)
        try await within(10, "the connect to the second recorder never came back") { await model.connect() }
        try await untilIdle(model)
        expectEqual(try await store.owner(), NamedRecorder.udn(2), "the cache was meant to be made over")
        await held.letGo()
        _ = try await within(10, "the night never ended") { await night.value }
        try await afterTheQueuesTurn(until: { kept.value == nil })

        XCTAssertNil(kept.value, "what the night told of the recorder before is kept over the cache made over")
    }
}
