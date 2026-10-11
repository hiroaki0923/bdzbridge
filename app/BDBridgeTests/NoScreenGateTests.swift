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
/// Gates, as `RunGateTests` is: each pins what the app does today, so that the order of a run can move into
/// RecorderKit with the test's body unchanged, and where a test holds something that is still to be changed on
/// purpose it says so, and that change rewrites it. What a night told is read from the bench's record
/// (`Tellings`), which has each telling by the time it returns.
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
    /// guide, as it is today. With one type's file a guide, its logos are asked for after it, and the run hands
    /// back that something was stored.
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
    /// reads once more after the guide while the disk known does not answer, is not read again. That a guide was
    /// fetched is told all the same, a type having answered, as it is today: a later change has a night tell
    /// nothing of the guide once its time is up, and rewrites that.
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
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"])
        XCTAssertFalse(ran.stored)
    }

    /// A night that comes to its guide while another refresh is out waits its turn: one refresh at a time, the
    /// screens' and the night's. And a night whose time runs out while it waits asks for no file once the turn
    /// is its own: the guide is fetched in the night's own task, also behind that wait, and looks for the
    /// cancellation before its first type. Here the refresh that is out is one as the screens make it, on a
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

    /// Silence part-way through a night ends it at the USB slot and in the guide, and nowhere else, as it is
    /// today.
    ///
    /// At a reservation's create alone, the recorder answering again after it: the row is held for the reader
    /// with its reason, what became of the queue is told, and the night goes on -- the slot is read, the free
    /// space told, the guide fetched. From the create on: the round is told, the slot is asked, and its silence
    /// ends the night. On the free space alone: nothing is told of it, and the guide is still asked for. In the
    /// guide: the night ends there, and the slot is not read again after it; that a guide was fetched is told,
    /// a type having answered before the silence, and what the night hands back is whether a programme was
    /// stored before it -- none where the type that answered had no file to give, and one where it gave a guide.
    ///
    /// A later change ends a night at its first silence, which rewrites the first three.
    func testSilencePartWayThroughANightEndsItAtTheSlotAndInTheGuideAndNowhereElse() async throws {
        let (recorder, store, _) = try await home()
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)
        await recorder.goQuiet(on: Ask.create)
        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create, Ask.slot, Ask.freeSpace,
                                   Ask.portOfTheGuide] + Ask.guide, "silence at the create alone")
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"], "silence at the create alone")
        XCTAssertEqual(ran.told.rounds.map(\.interrupted), [true])
        expectEqual(try await rows(in: store), ["朝の番組: " + Said.heldAfterSilence])

        // The row above is held now, and is not sent again: another, and silence from its create on.
        let noon = waiting("昼の番組", startingIn: 150, programme: 4322)
        try await store.queue(noon)
        await recorder.answer(Ask.create, with: .silence)
        await recorder.answer(Ask.slot, with: .silence)
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, [Ask.description, Ask.reservations, Ask.create, Ask.slot],
                       "silence from the create on")
        XCTAssertEqual(ran.told.names, ["flushed"], "silence from the create on")
        XCTAssertEqual(ran.told.rounds.map(\.interrupted), [true])
        XCTAssertFalse(ran.stored)
        expectEqual(try await rows(in: store),
                    ["朝の番組: " + Said.heldAfterSilence, "昼の番組: " + Said.heldAfterSilence])

        // Both rows are held, so nothing is read or sent for the queue from here on.
        await recorder.goQuiet(on: Ask.freeSpace)
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + Ask.guide, "silence on the free space alone")
        XCTAssertEqual(ran.told.names, ["flushed", "fetched"], "silence on the free space alone")

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

    /// A recorder that will not say how much room it has: refused, nothing is told of the free space and the
    /// guide is fetched as ever. A disk of no size is told as it was answered, a total of nought and nought free,
    /// as it is today: the notice the app makes of it drops it, where no test sees. A later change reads the
    /// night's free space through the rule the screens use, by which a disk of no size has not said, and
    /// rewrites that half.
    func testANightTellsNothingOfSpaceTheRecorderWillNotSayAndTellsADiskOfNoSizeAsItIs() async throws {
        let (recorder, store, _) = try await home()
        await recorder.answer(Ask.freeSpace, with: .fault(402))
        var ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.names, ["flushed", "fetched"])
        XCTAssertEqual(ran.heard, Self.beforeTheGuide + Ask.guide)

        await recorder.answer(Ask.freeSpace,
                              with: .text("<recordDestinationInfo totalCapacity=\"0\" availableCapacity=\"0\" />",
                                          in: "RecordDestinationInfo"))
        ran = await night(of: recorder, store)
        XCTAssertEqual(ran.told.names, ["flushed", "freeSpace", "fetched"])
        XCTAssertEqual(ran.told.said.dropFirst().first, .freeSpace(free: 0, total: 0, naming: nil),
                       "a disk of no size was not told as the recorder answered it")
    }

    /// A night that finds nobody at the address, and one answered by a recorder it cannot take for the cache's
    /// own, send nothing and fetch nothing, and say so only where the reader would otherwise miss something.
    ///
    /// Nobody there, with a reservation waiting that could be sent: nothing is told, and the queue is as it was.
    /// Another recorder than the cache's, with only a reservation held for the reader and one whose programme
    /// is over waiting: nothing is told either, there being nothing that would have gone, and neither row is
    /// touched. A recorder whose cache does not say whose it is -- the owner cannot be read -- with a
    /// reservation waiting that could be sent: it is told as a recorder the cache is not of is, that the queue
    /// was held back, as it is today. A later change tells nothing of a recorder that merely could not be told
    /// apart, and rewrites that row.
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
        XCTAssertEqual(ran.told.names, ["heldBack"], "with the cache's owner out of reach")
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
    /// nothing is sent, and the action says that another recorder answered, though none did, as it is today: a
    /// later change takes that for a recorder not reached, with that sentence, and rewrites the row.
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
        let meta = MetaOutOfReach(in: path)
        let unread = await action(on: recorder, store)
        meta.putBack()
        XCTAssertEqual(unread.sending, .anotherRecorder)
        XCTAssertEqual(unread.heard, [Ask.description], "something was sent with the cache's owner out of reach")
        XCTAssertEqual(SendWaitingIntent.saying(unread.sending), Said.anotherAnsweredWithNoScreen)
        expectEqual(try await rows(in: store), ["朝の番組"], "the queue is not as it was")

        let sent = await action(on: recorder, store).sending
        let nothingToSay = BackgroundWork.Sending.sent(await PendingQueue.flush(client: aClient(of: recorder),
                                                                                 store: store))
        let nothing = "送信待ちの予約はありません。"
        let words: [(BackgroundWork.Sending, alone: String, withATelevision: String)] = [
            (.demo, "サンプルデータの表示中は送りません。", "サンプルデータの表示中は送りません。"),
            (.noRecorder, "レコーダーが設定されていません。", "レコーダーが設定されていません。"),
            (.nothingWaiting, nothing, nothing),
            (.unreachable, "レコーダーに接続できませんでした。送信待ちの予約はそのまま残しています。",
             "レコーダーに接続できませんでした。送信待ちの予約はそのまま残しています。"),
            (.anotherRecorder, Said.anotherAnsweredWithNoScreen, Said.anotherAnsweredWithNoScreen),
            (sent, Said.sent("朝の番組"), Said.sent("朝の番組", naming: "レコーダー")),
            (nothingToSay, nothing, nothing),
        ]
        for (sending, alone, withATelevision) in words {
            XCTAssertEqual(SendWaitingIntent.saying(sending), alone, "\(sending)")
            XCTAssertEqual(SendWaitingIntent.saying(sending, televisionSaved: true), withATelevision, "\(sending)")
        }
    }

    /// The action's round meets silence. At the read of the recorder's list that opens it, nothing was sent: the
    /// action says the recorder stopped answering part-way and that what waits is left as it is, and the row is
    /// as it was. At a reservation's create the row is held for the reader with its reason, which says it may
    /// have arrived and is not sent again by itself -- and the action says the same sentence, that it is left as
    /// it is, as it does today. A later change has the action say of such a row that it is held, and rewrites
    /// that.
    func testTheActionWhoseRoundMeetsSilenceSaysWhatWaitsIsLeftAtTheReadAndAtACreateAlike() async throws {
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
        XCTAssertEqual(SendWaitingIntent.saying(came.sending), left, "silence at the create")
        expectEqual(try await rows(in: store), ["朝の番組: " + Said.heldAfterSilence])
    }
}
