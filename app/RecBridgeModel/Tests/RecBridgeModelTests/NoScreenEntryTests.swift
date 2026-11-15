import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The entries the system calls with no screen -- the overnight run (`BackgroundWork.refreshNow(in:)`), its
/// television's part, which the Shortcuts action runs too (`sendToTheTelevisionNow(in:)`), and the action's sending
/// to the recorder (`sendWaiting(in:)`) -- each handed what it reaches of its platform (`NoScreenSurroundings`) as
/// the app hands in its own: what they read of what the screens saved, what they open and ask, what they post and
/// in which order against what they keep, and what the settings then say of the last overnight refresh.
///
/// What each run does once it has its client and its cache is held in `NoScreenGateTests`, `QueueWithATelevisionTests`
/// and the others; here it is what the entry adds to it. The app's own hand-in -- the standard defaults, its folder,
/// the real sessions, the Keychain and `Notify` -- is reached by no test.
///
/// No MAC is saved for the recorder when an entry runs: the entries send their packet themselves, not through the
/// model, and one saved would put a packet on the network this is run on (`handedIn`).
@MainActor
final class NoScreenEntryTests: XCTestCase {
    // MARK: - nothing to do

    /// In the demo neither entry does anything, with a recorder and a television saved: nothing is opened, no
    /// device is asked, nothing is posted and nothing is written. The Shortcuts action says it is the demo.
    func testInTheDemoTheEntriesOpenAskPostAndWriteNothing() async throws {
        let bench = try aBench()
        bench.defaults.set(Bench.host, forKey: DefaultsKey.recorderHost)
        bench.defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        bench.defaults.set(true, forKey: DefaultsKey.demoData)
        let recorder = NamedRecorder(1), television = DemoTV()
        let (surroundings, reached, posted) = handedIn(bench, recorder: recorder, television: television)

        let refreshed = await BackgroundWork.refreshNow(in: surroundings)
        let televisions = await BackgroundWork.sendToTheTelevisionNow(in: surroundings)
        let sending = await BackgroundWork.sendWaiting(in: surroundings)

        XCTAssertFalse(refreshed)
        XCTAssertNil(televisions)
        XCTAssertEqual(sending, .demo)
        XCTAssertEqual(reached.all, [], "something was opened or asked for in the demo")
        expectEqual(await recorder.heard, [])
        expectEqual(await television.calls, [])
        XCTAssertEqual(posted.all, [])
        assertNothingWritten(in: bench)
        for demo in [false, true] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: Storage.guidePath(demo: demo, in: bench.folder)),
                           "a cache was made in the demo")
        }
    }

    /// With no recorder saved, and no television, nothing is opened or asked: the overnight run has nothing to
    /// do, the television's part nobody to ask, and the Shortcuts action says there is no recorder. An address
    /// saved empty is none saved. With a television saved and no recorder, the television's part goes all the
    /// same (`testTheTelevisionsPartPostsWhatItFoundAndThenKeepsWhatWasTold`).
    func testWithNoRecorderSavedNothingIsOpenedOrAsked() async throws {
        let bench = try aBench()
        for saved in [nil, ""] as [String?] {
            for key in [DefaultsKey.recorderHost, DefaultsKey.tvHost] { bench.defaults.set(saved, forKey: key) }
            let recorder = NamedRecorder(1)
            let (surroundings, reached, posted) = handedIn(bench, recorder: recorder)

            let refreshed = await BackgroundWork.refreshNow(in: surroundings)
            let televisions = await BackgroundWork.sendToTheTelevisionNow(in: surroundings)
            let sending = await BackgroundWork.sendWaiting(in: surroundings)

            let which = saved == nil ? "none saved" : "saved empty"
            XCTAssertFalse(refreshed, which)
            XCTAssertNil(televisions, which)
            XCTAssertEqual(sending, .noRecorder, which)
            XCTAssertEqual(reached.all, [], which)
            expectEqual(await recorder.heard, [], which)
            XCTAssertEqual(posted.all, [], which)
            assertNothingWritten(in: bench)
        }
    }

    // MARK: - the overnight run

    /// With a recorder saved, the overnight run goes through as the driver has it go, through what was handed
    /// in: the cache in the folder handed in, the recorder asked through the way handed in for it -- who it is,
    /// what waits sent, its slot and its free space read, and every type of the guide asked for. What became of
    /// the queue is posted, then that nothing is told once of it, then the free space; and the time a guide was
    /// fetched is written where the settings read it, which then say it (`AppModel.lastOvernightRefresh`). With
    /// no television saved, the television's part opens nothing and asks nobody.
    func testWithARecorderSavedTheNightGoesThroughAndWritesTheTimeTheSettingsShow() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await store.queue(morning)
        let (surroundings, reached, posted) = handedIn(bench, recorder: recorder)
        let count = await recorder.heard.count
        let began = Date()

        _ = await BackgroundWork.refreshNow(in: surroundings)

        expectEqual(await recorder.heard(since: count), [Ask.description, Ask.reservations, Ask.create, Ask.slot,
                                                         Ask.freeSpace, Ask.portOfTheGuide] + Ask.guide)
        XCTAssertEqual(reached.all, ["folder", "recorder \(Bench.host)"])
        XCTAssertEqual(posted.names, ["queueFlushed", "recorder", "freeSpace"])
        guard case .queueFlushed(let round) = posted.all.first?.post else { return XCTFail("\(posted.all)") }
        XCTAssertEqual(round.sent.map(\.id), [morning.id])
        XCTAssertEqual(posted.all.dropFirst().first?.post, .recorder(notYet: nil, withdraws: false))
        expectEqual(try await store.pendingReservations(), [], "what was sent still waits")
        let written = try XCTUnwrap(bench.defaults.string(forKey: DefaultsKey.lastBackgroundRefresh),
                                    "the time a guide was fetched was not written")
        let fetched = try XCTUnwrap(RecorderTime.parse(written))
        // Written to the second.
        XCTAssertTrue(fetched >= began.addingTimeInterval(-1) && fetched <= Date(), "\(written)")
        XCTAssertEqual(model.lastOvernightRefresh, Format.when(fetched))
    }

    /// What a night tells once is posted before it is kept, and kept where the next night reads it, as the
    /// app's notifications rely on. With another recorder at the address than the cache is of, and a
    /// reservation waiting that starts after the next night whatever the hour: that the queue was held back is
    /// posted, then the recorder's notice -- none, and none taken away -- each with nothing kept yet, and then
    /// that another recorder answered is kept. The next night, reading that, posts no holding back.
    func testWhatANightTellsOnceIsPostedBeforeItIsKept() async throws {
        let (bench, recorder, _) = try await connectedHome()
        try await GuideStore(path: bench.guidePath).queue(waiting("翌日の番組", startingIn: 30 * 60, programme: 4332))
        await recorder.become(2)
        let another = ToldOnce(stop: .another)

        var (surroundings, _, posted) = handedIn(bench, recorder: recorder)
        _ = await BackgroundWork.refreshNow(in: surroundings)
        XCTAssertEqual(posted.all, [Posted.Posting(post: .queueHeldBack, kept: nil),
                                    Posted.Posting(post: .recorder(notYet: nil, withdraws: false), kept: nil)])
        XCTAssertEqual(KeptOnce.recorder(in: bench.defaults).read(), another)

        (surroundings, _, posted) = handedIn(bench, recorder: recorder)
        _ = await BackgroundWork.refreshNow(in: surroundings)
        XCTAssertEqual(posted.all, [Posted.Posting(post: .recorder(notYet: nil, withdraws: false), kept: another)],
                       "told a second night")
        XCTAssertEqual(KeptOnce.recorder(in: bench.defaults).read(), another)
    }

    // MARK: - the Shortcuts action's sending

    /// The Shortcuts action's sending posts in the order the app's notifications rely on, and keeps after it:
    /// what became of the queue, that it was held back, the recorder's notice, then what was told. Another
    /// recorder at the address: held back, then the notice, then that it answered kept. The recorder the cache
    /// is of back: what waited goes and is posted, then the notice, each with that still kept, and then what
    /// is told of now.
    func testTheActionsSendingPostsBeforeItKeeps() async throws {
        let (bench, recorder, _) = try await connectedHome()
        let later = waiting("翌日の番組", startingIn: 30 * 60, programme: 4332)
        try await GuideStore(path: bench.guidePath).queue(later)
        await recorder.become(2)
        let another = ToldOnce(stop: .another)

        let stranger = handedIn(bench, recorder: recorder)
        let held = await BackgroundWork.sendWaiting(in: stranger.surroundings)
        XCTAssertEqual(held, .anotherRecorder)
        XCTAssertEqual(stranger.reached.all, ["folder", "recorder \(Bench.host)"])
        XCTAssertEqual(stranger.posted.all,
                       [Posted.Posting(post: .queueHeldBack, kept: nil),
                        Posted.Posting(post: .recorder(notYet: nil, withdraws: false), kept: nil)])
        XCTAssertEqual(KeptOnce.recorder(in: bench.defaults).read(), another)

        await recorder.become(1)
        let (surroundings, _, posted) = handedIn(bench, recorder: recorder)
        let sending = await BackgroundWork.sendWaiting(in: surroundings)
        guard case .sent(let round) = sending else { return XCTFail("not sent: \(sending)") }
        XCTAssertEqual(round.sent.map(\.id), [later.id])
        XCTAssertEqual(posted.all, [Posted.Posting(post: .queueFlushed(round), kept: another),
                                    Posted.Posting(post: .recorder(notYet: nil, withdraws: false), kept: another)])
        XCTAssertEqual(KeptOnce.recorder(in: bench.defaults).read(), ToldOnce())
    }

    // MARK: - the television's part

    /// The television's part, with a television saved and no recorder, as the overnight run has it: what waits
    /// for it is sent through the way and the registration handed in, what became of it is posted, and only
    /// then is what was told kept, where the next run reads it. The recorder's part opens nothing.
    func testTheTelevisionsPartPostsWhatItFoundAndThenKeepsWhatWasTold() async throws {
        let bench = try aBench()
        let television = DemoTV()
        await television.receives([DemoTV.Station()])
        bench.defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        try await GuideStore(path: bench.guidePath)
            .queue(forTheTelevision(waiting("サンプル劇場", startingIn: 120, programme: 4401)))
        let (surroundings, reached, posted) = handedIn(bench, television: television,
                                                      credentials: await registered(with: television))

        let refreshed = await BackgroundWork.refreshNow(in: surroundings)

        XCTAssertFalse(refreshed, "a guide was said to be stored with no recorder saved")
        XCTAssertEqual(reached.all, ["folder", "television \(Bench.tvHost)"])
        expectEqual(await television.schedules.map(\.eventId), [4401])
        XCTAssertEqual(posted.all, [Posted.Posting(post: .television(NoScreenNotices(
            queue: Said.sent("サンプル劇場", naming: "テレビ"))), kept: nil)])
        XCTAssertNotNil(KeptOnce.television(in: bench.defaults).read(), "what was told was not kept")
        XCTAssertNil(KeptOnce.recorder(in: bench.defaults).read())
        XCTAssertNil(bench.defaults.object(forKey: DefaultsKey.lastBackgroundRefresh))
    }

    /// A television taken away while the run was out: what the run found is no longer anybody's to be told, and
    /// nothing is posted or kept of it. The reservation it was making is made.
    func testATelevisionTakenAwayWhileTheRunWasOutIsToldNothing() async throws {
        let (bench, television, door, surroundings, posted) = try await aTelevisionHeldAtItsCreate(
            waiting: [waiting("サンプル劇場", startingIn: 120, programme: 4401)])
        let run = Task { await BackgroundWork.sendToTheTelevisionNow(in: surroundings) }
        try await until("the run never reached the create") { await door.isHolding }
        bench.defaults.removeObject(forKey: DefaultsKey.tvHost)
        await door.letGo()
        let sending = await run.value

        guard case .sent(let round)? = sending else { return XCTFail("no round: \(String(describing: sending))") }
        XCTAssertEqual(round.sent.map(\.request.title), ["サンプル劇場"])
        expectEqual(await television.schedules.map(\.eventId), [4401])
        XCTAssertEqual(posted.all, [], "a television taken away was told of")
        XCTAssertNil(KeptOnce.television(in: bench.defaults).read(), "kept of a television taken away")
    }

    /// A run whose time ran out while it was out -- its task cancelled, as the system's expiry cancels it --
    /// posts only what the queue says of its rows and keeps nothing. Here the first of two reservations is made
    /// as the task is cancelled and the television falls silent at the second's create: the round was cut short
    /// by silence, which the suspension may be what caused, so what the queue says is posted without its
    /// sentence for that.
    func testATelevisionRunWhoseTimeRanOutPostsOnlyWhatTheQueueSaysAndKeepsNothing() async throws {
        let (bench, television, door, surroundings, posted) = try await aTelevisionHeldAtItsCreate(
            waiting: [waiting("サンプル劇場", startingIn: 120, programme: 4401),
                      waiting("サンプル紀行", startingIn: 180, programme: 4402)])
        let run = Task { await BackgroundWork.sendToTheTelevisionNow(in: surroundings) }
        try await until("the run never reached the first create") { await door.isHolding }
        run.cancel()
        await door.letGoFirst()
        try await until("the run never reached the second create") { await door.isHolding }
        await television.goSilent()
        await door.letGo()
        let sending = await run.value

        guard case .sent(let round)? = sending else { return XCTFail("no round: \(String(describing: sending))") }
        XCTAssertTrue(round.interrupted, "the round was not cut short by silence: \(round)")
        XCTAssertEqual(round.sent.map(\.request.title), ["サンプル劇場"])
        var told = round
        told.stopped = nil
        let said = try XCTUnwrap(told.says(naming: "テレビ"))
        XCTAssertEqual(said, Said.sent("サンプル劇場", naming: "テレビ"))
        XCTAssertNotEqual(round.says(naming: "テレビ"), said, "the round has no sentence for being cut short")
        XCTAssertEqual(posted.all, [Posted.Posting(post: .television(NoScreenNotices(queue: said)), kept: nil)])
        XCTAssertNil(KeptOnce.television(in: bench.defaults).read(), "kept once the run's time was up")
    }

    // MARK: - what the settings say

    /// What the settings say of the last overnight refresh (最終自動更新): nothing until a run has written its
    /// time, then that time as the guide's own last refresh is said -- here one long past, with its date -- and
    /// what does not read as such a time as it was written.
    func testTheSettingsSayWhenTheOvernightRunLastFetchedAGuide() throws {
        let bench = try aBench()
        let model = bench.modelWithNoRecorder()
        XCTAssertNil(model.lastOvernightRefresh)

        bench.defaults.set(RecorderTime.format(Date(timeIntervalSince1970: 1_700_000_000)),
                           forKey: DefaultsKey.lastBackgroundRefresh)
        XCTAssertEqual(model.lastOvernightRefresh, "11/15(水) 07:13")

        bench.defaults.set("昨夜", forKey: DefaultsKey.lastBackgroundRefresh)
        XCTAssertEqual(model.lastOvernightRefresh, "昨夜")
    }

    // MARK: - what the tests start from

    /// What the entries are handed on the bench: its defaults and folder, `recorder` and `television` at whatever
    /// address is asked for, the television's registration in `credentials`, and the notifications of a record of
    /// what was posted (`Posted`). What an entry reached of these is noted in order (`Reached`).
    ///
    /// The recorder's MAC is taken out first: a connect the test made may have written down the one its recorder
    /// reported, and a run with no screen sends its packet to it itself.
    private func handedIn(_ bench: Bench, recorder: any HTTPTransport = SilentRecorder(),
                          television: any HTTPTransport = NoTelevision(),
                          credentials: any TVCredentialStore = MemoryTVCredentials())
        -> (surroundings: NoScreenSurroundings, reached: Reached, posted: Posted) {
        bench.defaults.removeObject(forKey: DefaultsKey.recorderMac)
        let reached = Reached(), posted = Posted()
        let folder = bench.folder
        let surroundings = NoScreenSurroundings(
            defaults: bench.defaults,
            folder: {
                reached.note("folder")
                return folder
            },
            transport: { host in
                reached.note("recorder \(host)")
                return recorder
            },
            tvTransport: { host in
                reached.note("television \(host)")
                return television
            },
            tvCredentials: credentials, notifications: posted.notifications(keptIn: bench.defaults))
        return (surroundings, reached, posted)
    }

    /// A television saved and registered, with `rows` waiting for it and its creates held, through a door a test
    /// lets go (`HeldTelevision`), and what the entries are handed to reach it.
    private func aTelevisionHeldAtItsCreate(waiting rows: [PendingReservation]) async throws
        -> (bench: Bench, television: DemoTV, door: HeldTelevision, surroundings: NoScreenSurroundings,
            posted: Posted) {
        let bench = try aBench()
        let television = DemoTV()
        await television.receives([DemoTV.Station()])
        let door = HeldTelevision(television, holding: false)
        // A sending left held by a test that failed would keep every later test's from its turn.
        addTeardownBlock { await door.letGo() }
        await door.hold(only: "addSchedule")
        bench.defaults.set(Bench.tvHost, forKey: DefaultsKey.tvHost)
        let store = try GuideStore(path: bench.guidePath)
        for row in rows { try await store.queue(forTheTelevision(row)) }
        let (surroundings, _, posted) = handedIn(bench, television: door,
                                                credentials: await registered(with: television))
        return (bench, television, door, surroundings, posted)
    }

    /// Nothing an entry writes is there: what was told once of either device, and the time of the last guide.
    private func assertNothingWritten(in bench: Bench, file: StaticString = #filePath, line: UInt = #line) {
        for key in [DefaultsKey.recorderTold, DefaultsKey.tvTold, DefaultsKey.lastBackgroundRefresh] {
            XCTAssertNil(bench.defaults.object(forKey: key), "\(key) was written", file: file, line: line)
        }
    }

    /// A reservation of the test's own making: half an hour on the demo's first channel, in DR and not
    /// repeated, starting so many minutes from now.
    private func waiting(_ title: String, startingIn minutes: Double, programme: Int) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Date().addingTimeInterval(minutes * 60),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ")
    }

    /// The same reservation waiting for the television, on the station the invented television receives.
    private func forTheTelevision(_ row: PendingReservation) -> PendingReservation {
        var row = row
        row.target = .tv
        return row
    }
}

/// What an entry reached of the surroundings it was handed, in order: the guide's folder, and the way to each
/// device by the address it was asked for.
private final class Reached: @unchecked Sendable {
    private let lock = NSLock()
    private var reached: [String] = []

    var all: [String] { lock.withLock { reached } }

    func note(_ what: String) {
        lock.withLock { reached.append(what) }
    }
}

/// What the entries posted through the notifications handed in, in the order it was posted, each with what was
/// kept of what had been told once of its device as it was posted (`KeptOnce`): whether an entry posts before it
/// keeps. Written by the posting itself, under a lock, so that everything posted is here once the entry returns.
private final class Posted: @unchecked Sendable {
    enum Post: Equatable, Sendable {
        case queueFlushed(PendingQueue.Outcome)
        case queueHeldBack
        case recorder(notYet: String?, withdraws: Bool)
        case freeSpace(free: Int, total: Int, naming: String?)
        case usbSpace(RecorderDisk)
        case television(NoScreenNotices)

        var name: String {
            switch self {
            case .queueFlushed: "queueFlushed"
            case .queueHeldBack: "queueHeldBack"
            case .recorder: "recorder"
            case .freeSpace: "freeSpace"
            case .usbSpace: "usbSpace"
            case .television: "television"
            }
        }
    }

    struct Posting: Equatable, Sendable {
        let post: Post
        /// What was kept of the device it is about as it was posted; nil when nothing was.
        let kept: ToldOnce?
    }

    private let lock = NSLock()
    private var posted: [Posting] = []

    var all: [Posting] { lock.withLock { posted } }
    var names: [String] { all.map(\.post.name) }

    /// The notifications to hand in, each posting put on this record with what `defaults` kept just then.
    func notifications(keptIn defaults: UserDefaults) -> Notifications {
        let recorder = KeptOnce.recorder(in: defaults), television = KeptOnce.television(in: defaults)
        return Notifications(recorder: { self.put(.recorder(notYet: $0, withdraws: $1), recorder) },
                             queueFlushed: { self.put(.queueFlushed($0), recorder) },
                             queueHeldBack: { self.put(.queueHeldBack, recorder) },
                             lowSpace: { self.put(.freeSpace(free: $0, total: $1, naming: $2), recorder) },
                             usbLowSpace: { self.put(.usbSpace($0), recorder) },
                             television: { self.put(.television($0), television) })
    }

    private func put(_ post: Post, _ kept: KeptOnce) {
        let then = kept.read()
        lock.withLock { posted.append(Posting(post: post, kept: then)) }
    }
}
