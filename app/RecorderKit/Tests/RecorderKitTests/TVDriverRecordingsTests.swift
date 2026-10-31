import Foundation
import XCTest
@testable import RecorderKit

/// What a television's driver does with its recordings: whether a list adds up beside what the disk says it
/// holds, the read of the list as one operation, one at a time for everyone asking, the wait for a list that may
/// still be coming, one protected or deleted, and a run over many. Against the invented television, which answers
/// as a real one was measured to (`TVRecordingsTests`).
@MainActor
final class TVDriverRecordingsTests: XCTestCase {
    /// Nine in the evening in Japan on Sunday 1 November 2026.
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_534_400)
    private static let left = "前の操作の失敗"
    private nonisolated static let read = "getContentList"

    /// A wait of moments rather than of minutes, unless a test gives another.
    private nonisolated static let quick = TVTitlesWait(every: .milliseconds(5), for: 0.1)

    private nonisolated static func recording(_ number: Int, sizeMB: Int = 3000, protected: Bool = false,
                                              recording: Bool = false) -> DemoTV.Recording {
        DemoTV.Recording(contentID: number, title: "サンプル番組\(number)", start: start, sizeMB: sizeMB,
                         protected: protected, recording: recording)
    }

    private struct Bench: Sendable {
        let link: DeviceLink, driver: TVDriver, world: LinkWorld, television: DemoTV, gate: TVGate
        let credentials: MemoryTVCredentials
    }

    /// Connected to a television holding `recordings` on a disk of `diskMB`, with a gate between them.
    private func attached(_ recordings: [DemoTV.Recording] = [], diskMB: Int = 100_000,
                          wait: TVTitlesWait = quick) async -> Bench {
        let television = DemoTV(recordings: recordings, diskMB: diskMB)
        await television.knows("BDBridge:test", cookie: "kept")
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept",
                                                            cookieReceived: Date().addingTimeInterval(-86_400),
                                                            cookieMaxAge: 1_209_600))
        let gate = TVGate(television)
        let world = LinkWorld()
        world.devices[Stub.host] = gate
        let driver = TVDriver(credentials: credentials, nickname: "RecBridge", inFront: { true }, titlesWait: wait)
        let link = DeviceLink(host: Stub.host, session: SessionState(device: nil), driver: driver,
                              environment: world.environment)
        link.owner = world
        await link.connect()
        XCTAssertTrue(driver.canBeAsked)
        return Bench(link: link, driver: driver, world: world, television: television, gate: gate,
                     credentials: credentials)
    }

    /// What a `keep` was handed, in order.
    private final class Kept {
        var lists: [TVTitles] = []
        var last: TVTitles? { lists.last }
    }

    private func title(_ sizeMB: Int?, recording: Bool = false) -> RecordedTitle {
        var row = RecordedTitle(id: "x", title: "", start: Self.start, durationSec: 60, broadcastingType: 0,
                                serviceID: 0, qualityCode: 0, protected: false, isNew: true, recording: recording,
                                destination: TVDriver.recordsTo, sizeMB: sizeMB)
        row.device = .tv
        return row
    }

    // MARK: - whether a list adds up

    /// Nothing is said of a list whose rows come to what the disk has used, within the margin: a disk with
    /// nothing on it used about 72 MB, and a real one's four recordings were 72 MB short of it too. So it is for
    /// a list with no rows on a disk with next to nothing on it, which says what an empty list says.
    func testAListThatAddsUpSaysNothing() {
        func storage(used: Int) -> TVStorage { TVStorage(mounted: true, freeMB: 500_000 - used, totalMB: 500_000) }
        expectEqual(TVDriver.account(of: [], on: storage(used: 72)), .addsUp, "an empty disk")
        expectEqual(TVDriver.account(of: [], on: storage(used: 1000)), .addsUp, "up to the margin")
        expectEqual(TVDriver.account(of: [title(11_643)], on: storage(used: 11_715)), .addsUp, "as a real one read")
        expectEqual(TVDriver.account(of: [title(5000), title(5000)], on: storage(used: 11_000)), .addsUp,
                    "short by the margin")
        expectEqual(TVDriver.account(of: [title(9000)], on: storage(used: 5000)), .addsUp, "more listed than used")
    }

    /// No rows, and more on the disk than the margin: it may be just after a start. Rows, and their sum short by
    /// more than the margin: rows are out of the list.
    func testAListThatDoesNotAddUpSaysSo() {
        func storage(used: Int) -> TVStorage { TVStorage(mounted: true, freeMB: 500_000 - used, totalMB: 500_000) }
        expectEqual(TVDriver.account(of: [], on: storage(used: 1001)), .mayStillBeComing)
        expectEqual(TVDriver.account(of: [title(5000)], on: storage(used: 6001)), .someAreMissing)
        expectEqual(TVDriver.account(of: [title(nil)], on: storage(used: 6001)), .someAreMissing, "a row of no size")
    }

    /// A row being recorded fills the disk while it says nought: nothing can be compared, and nothing is said. Nor
    /// of a disk that does not say its sizes.
    func testNothingIsComparedBesideARecordingOrWithoutTheSizes() {
        let full = TVStorage(mounted: true, freeMB: 100, totalMB: 500_000)
        expectEqual(TVDriver.account(of: [title(nil, recording: true)], on: full), .addsUp)
        expectEqual(TVDriver.account(of: [title(100), title(nil, recording: true)], on: full), .addsUp)
        expectEqual(TVDriver.account(of: [], on: TVStorage(mounted: true, freeMB: nil, totalMB: nil)), .addsUp)
        expectEqual(TVDriver.account(of: [], on: TVStorage(mounted: true, freeMB: 100, totalMB: nil)), .addsUp)
    }

    // MARK: - the list

    /// One operation under a line of its own: the disk and then the list, each once, the row handed over as it
    /// came, in the television's order, what is known of the disk brought up to date, and the line of what went
    /// wrong cleared. In standby: nothing asks for it to be on.
    func testTheListIsReadUnderItsLine() async throws {
        let rows = [Self.recording(2), Self.recording(1)]
        let bench = await attached(rows, diskMB: 20_000)
        bench.world.problem = Self.left
        let kept = Kept()
        let before = await bench.gate.asked.count

        expectTrue(await bench.driver.titles { kept.lists.append($0) })

        XCTAssertEqual(kept.lists.count, 1)
        XCTAssertEqual(kept.last?.rows.map(\.id), rows.map(\.uri))
        XCTAssertEqual(kept.last?.rows.first?.device, .tv)
        XCTAssertEqual(kept.last?.account, .addsUp)
        XCTAssertEqual(bench.driver.facts.storage, TVStorage(mounted: true, freeMB: 13_400, totalMB: 20_000))
        XCTAssertEqual(bench.world.begun.last, TVDriver.titlesLine)
        XCTAssertNil(bench.world.problem, "a read that went through left the line")
        expectEqual(Array(await bench.gate.asked.dropFirst(before)), ["getStorageList", Self.read])
    }

    /// Rows short of the disk with no wait under way are said at once, and no wait begins: only an empty list may
    /// be a start.
    func testRowsShortOfTheDiskAreSaidAtOnce() async throws {
        let rows = [Self.recording(1), Self.recording(2)]
        let bench = await attached(rows, wait: TVTitlesWait(every: .seconds(60), for: 600))
        await bench.television.leavesOutOfItsList([rows[1].uri])
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .someAreMissing)
    }

    /// A television that cannot be asked is sent nothing and nothing is said of it: the screens ask this as they
    /// appear, as for its reservations.
    func testATelevisionThatCannotBeAskedIsSentNothing() async throws {
        let bench = await attached([Self.recording(1)])
        bench.credentials.save(TVCredentials(clientID: "BDBridge:test", cookie: "stale"))
        await bench.television.goSilent()
        _ = await bench.link.ensureUp(evenIfRecent: true)
        await bench.television.goSilent(false)
        XCTAssertFalse(bench.driver.canBeAsked)
        bench.world.problem = Self.left
        let before = await bench.gate.asked.count

        expectFalse(await bench.driver.titles { _ in XCTFail("kept") })

        expectEqual(await bench.gate.asked.count, before)
        XCTAssertEqual(bench.world.problem, Self.left)
    }

    /// Silence is said as any read's and loses the television, a refusal of the cookie asks for the registration,
    /// and any other failure is said in the television's words; nothing is handed over for any of them, so what
    /// the app holds stays.
    func testAReadThatFailsHandsNothingOver() async throws {
        let silent = await attached([Self.recording(1)])
        await silent.gate.silence(Self.read)
        expectFalse(await silent.driver.titles { _ in XCTFail("kept") })
        XCTAssertEqual(silent.world.problem, ScalarError.transport("no answer").explanation)
        XCTAssertTrue(silent.link.session.unreachable)

        let stale = await attached([Self.recording(1)])
        stale.credentials.save(TVCredentials(clientID: "BDBridge:test", cookie: "stale"))
        expectFalse(await stale.driver.titles { _ in XCTFail("kept") })
        XCTAssertTrue(stale.driver.facts.needsPairing)

        let refused = await attached([Self.recording(1)])
        await refused.gate.answer(Self.read, with: HTTPResponse(statusCode: 200, body: Data(
            #"{"error":[12,"getContentList"],"id":1}"#.utf8)))
        expectFalse(await refused.driver.titles { _ in XCTFail("kept") })
        XCTAssertEqual(refused.world.problem, ScalarError.rpc(method: Self.read, version: "1.5", code: 12,
                                                              message: "").explanation)
        XCTAssertFalse(refused.link.session.unreachable, "a refusal lost the television")
    }

    /// A disk that is away has no recordings to show: the list is empty and nothing is said, and what is known of
    /// the disk says so. So it is when it goes between the two requests, which the list answers with 41020.
    func testADiskAwayIsAnEmptyList() async throws {
        let away = await attached([Self.recording(1)])
        await away.television.unmount()
        let kept = Kept()
        expectTrue(await away.driver.titles { kept.lists.append($0) })
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .addsUp))
        XCTAssertEqual(away.driver.facts.storage?.mounted, false)
        expectFalse(await away.gate.asked.contains(Self.read), "the list was asked of a disk that is away")

        let going = await attached([Self.recording(1)])
        let television = going.television
        await going.gate.before(Self.read) { await television.unmount() }
        expectTrue(await going.driver.titles { kept.lists.append($0) })
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .addsUp))
        XCTAssertEqual(going.driver.facts.storage?.mounted, false)
        XCTAssertNil(going.world.problem)
    }

    /// One read at a time, however many ask: whoever asks while one is out has its answer, and nothing is sent
    /// again. The next one asked after it is a read of its own.
    func testOneReadAtATime() async throws {
        let bench = await attached([Self.recording(1)])
        let (reached, reach) = AsyncStream.makeStream(of: Void.self)
        let (going, go) = AsyncStream.makeStream(of: Void.self)
        await bench.gate.before(Self.read) {
            reach.yield()
            for await _ in going { break }
        }
        let kept = Kept(), alsoKept = Kept()
        let first = Task { await bench.driver.titles { kept.lists.append($0) } }
        for await _ in reached { break }
        let second = Task { await bench.driver.titles { alsoKept.lists.append($0) } }
        await Task.yield()
        go.yield()
        expectTrue(await first.value)
        expectTrue(await second.value)

        XCTAssertEqual(kept.lists.count, 1)
        XCTAssertEqual(alsoKept.lists, kept.lists, "whoever asked meanwhile was given another answer")
        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, 1)

        go.finish()
        _ = await bench.driver.titles { _ in }
        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, 2)
    }

    /// The answer of a television let go of is thrown away: nothing is handed over, and nothing is said.
    func testAnAnswerOfATelevisionLetGoOfIsThrownAway() async throws {
        let bench = await attached([Self.recording(1)])
        let link = bench.link
        await bench.gate.before(Self.read) { await MainActor.run { link.forgetTheDevice() } }
        bench.world.problem = Self.left

        expectFalse(await bench.driver.titles { _ in XCTFail("kept") })
        XCTAssertEqual(bench.world.problem, Self.left)
    }

    /// Pulling the list down reads it now; with a television that cannot be asked it is the reader asking for
    /// another go, which is a connect, and nothing is read here.
    func testPullingDownReadsOrConnects() async throws {
        let bench = await attached([Self.recording(1)])
        let kept = Kept()
        await bench.driver.refreshTitles { kept.lists.append($0) }
        XCTAssertEqual(kept.lists.count, 1)

        await bench.television.goSilent()
        _ = await bench.link.ensureUp(evenIfRecent: true)
        XCTAssertFalse(bench.driver.canBeAsked)
        await bench.television.goSilent(false)
        await bench.driver.refreshTitles { kept.lists.append($0) }
        XCTAssertEqual(kept.lists.count, 1, "read inside the pull-down's connect")
        XCTAssertTrue(bench.driver.canBeAsked, "no connect was made")
    }

    // MARK: - the wait

    /// The list after a restart: empty with the disk full. It is said to be still coming and read again, rows
    /// that come being shown as they come, some of them no end to it, until they add up.
    func testAListThatMayStillBeComingIsReadAgainUntilItComes() async throws {
        let rows = [Self.recording(1), Self.recording(2)]
        let bench = await attached(rows, wait: TVTitlesWait(every: .milliseconds(5), for: 30))
        await bench.television.leavesOutOfItsList(Set(rows.map(\.uri)))
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .mayStillBeComing))

        let television = bench.television
        let gate = bench.gate
        let reads = await bench.gate.asked.filter { $0 == Self.read }.count
        await bench.gate.before(Self.read) {
            let read = await gate.asked.filter({ $0 == Self.read }).count
            if read == reads + 3 { await television.leavesOutOfItsList([rows[1].uri]) }
            if read == reads + 5 { await television.leavesOutOfItsList([]) }
        }
        await bench.driver.waitForTitles { kept.lists.append($0) }

        XCTAssertEqual(kept.last?.rows.map(\.id), rows.map(\.uri))
        XCTAssertEqual(kept.last?.account, .addsUp)
        XCTAssertEqual(kept.lists.map(\.rows.count), [0, 0, 0, 1, 1, 2], "rows were not shown as they came")
        XCTAssertEqual(kept.lists.map(\.account), Array(repeating: .mayStillBeComing, count: 5) + [.addsUp],
                       "a list with some of its rows ended the wait")
        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, reads + 5)
        XCTAssertFalse(bench.world.begun.contains(TVDriver.titlesComingLine), "the wait is the host's to say")
    }

    /// The wait is bounded: a list that does not come within it is said to be short of what the disk holds, and
    /// the wait does not begin again for as long as it stays so, a read after it included. So too a list some of
    /// whose rows came.
    func testAListThatNeverComesIsSaidToBeShortOnceTheWaitIsOver() async throws {
        let rows = [Self.recording(1), Self.recording(2)]
        let bench = await attached([rows[0]])
        await bench.television.leavesOutOfItsList([rows[0].uri])
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .mayStillBeComing)

        await bench.driver.waitForTitles { kept.lists.append($0) }
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .someAreMissing))

        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .someAreMissing), "the wait began again")

        let some = await attached(rows)
        await some.television.leavesOutOfItsList(Set(rows.map(\.uri)))
        _ = await some.driver.titles { kept.lists.append($0) }
        await some.television.leavesOutOfItsList([rows[1].uri])
        await some.driver.waitForTitles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.rows.map(\.id), [rows[0].uri])
        XCTAssertEqual(kept.last?.account, .someAreMissing)
    }

    /// The wait is counted from when the list was first read empty, so a screen left and come back to goes on
    /// with what was left of it; and a list that comes back whole puts that behind it.
    func testTheWaitIsCountedAcrossAScreenLeft() async throws {
        let row = Self.recording(1)
        let bench = await attached([row], wait: TVTitlesWait(every: .milliseconds(5), for: 0.2))
        await bench.television.leavesOutOfItsList([row.uri])
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        try await Task.sleep(for: .milliseconds(250))
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .someAreMissing)

        await bench.television.leavesOutOfItsList([])
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .addsUp)

        await bench.television.leavesOutOfItsList([row.uri])
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .mayStillBeComing, "a list gone again is a restart again")
    }

    /// An attach starts the count again: the television may be just back from a restart.
    func testAnAttachStartsTheWaitAgain() async throws {
        let row = Self.recording(1)
        let bench = await attached([row], wait: TVTitlesWait(every: .milliseconds(5), for: 0.05))
        await bench.television.leavesOutOfItsList([row.uri])
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        try await Task.sleep(for: .milliseconds(80))
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .someAreMissing)

        await bench.link.connect()
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .mayStillBeComing)
    }

    /// The screen's task ends the wait, in the turn it is cancelled and with nothing more sent.
    func testTheScreensTaskEndsTheWait() async throws {
        let row = Self.recording(1)
        let bench = await attached([row], wait: TVTitlesWait(every: .seconds(60), for: 600))
        await bench.television.leavesOutOfItsList([row.uri])
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        let reads = await bench.gate.asked.filter { $0 == Self.read }.count

        let wait = Task { await bench.driver.waitForTitles { kept.lists.append($0) } }
        await Task.yield()
        wait.cancel()
        await wait.value

        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, reads)
        XCTAssertEqual(kept.lists.count, 1)
    }

    /// A television let go of ends the wait, and so does one that stops answering, which is said as any read's.
    func testATelevisionLetGoOfOrSilentEndsTheWait() async throws {
        let row = Self.recording(1)
        let letGo = await attached([row], wait: TVTitlesWait(every: .milliseconds(5), for: 30))
        await letGo.television.leavesOutOfItsList([row.uri])
        _ = await letGo.driver.titles { _ in }
        letGo.link.forgetTheDevice()
        await letGo.driver.waitForTitles { _ in XCTFail("kept") }

        let silent = await attached([row], wait: TVTitlesWait(every: .milliseconds(5), for: 30))
        await silent.television.leavesOutOfItsList([row.uri])
        _ = await silent.driver.titles { _ in }
        await silent.gate.silence(Self.read)
        await silent.driver.waitForTitles { _ in XCTFail("kept") }
        XCTAssertEqual(silent.world.problem, ScalarError.transport("no answer").explanation)
    }

    // MARK: - one recording

    /// A row being recorded is written to in no way, and one protected is not to be deleted: the rules the doors
    /// and the screens both ask. The protected sentence is the recorder's, which the screens tell by.
    func testWhatKeepsARowFromBeingWrittenTo() throws {
        func row(protected: Bool = false, recording: Bool = false) throws -> RecordedTitle {
            var row = title(100, recording: recording)
            row.protected = protected
            return row
        }
        XCTAssertNil(TVDriver.whyNot(altering: try row()))
        XCTAssertNil(TVDriver.whyNot(altering: try row(protected: true)))
        XCTAssertEqual(TVDriver.whyNot(altering: try row(recording: true)), TVDriver.stillRecording)

        XCTAssertNil(TVDriver.whyNot(deleting: try row()))
        XCTAssertEqual(TVDriver.whyNot(deleting: try row(protected: true)), RecorderDriver.protectedCannotBeDeleted)
        XCTAssertEqual(TVDriver.whyNot(deleting: try row(recording: true)), TVDriver.stillRecording)
        XCTAssertEqual(TVDriver.whyNot(deleting: try row(protected: true, recording: true)), TVDriver.stillRecording)

        XCTAssertNil(TVDriver.whyNot(protecting: try row(), true))
        XCTAssertNil(TVDriver.whyNot(protecting: try row(protected: true), false))
        XCTAssertEqual(TVDriver.whyNot(protecting: try row(protected: true), true), "すでに保護されています")
        XCTAssertEqual(TVDriver.whyNot(protecting: try row(), false), "保護されていません")
        XCTAssertEqual(TVDriver.whyNot(protecting: try row(recording: true), true), TVDriver.stillRecording)
    }

    /// The row of `recording` as a read gives it.
    private func row(of recording: DemoTV.Recording, on bench: Bench) async throws -> RecordedTitle {
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        return try XCTUnwrap(kept.last?.rows.first { $0.id == recording.uri })
    }

    /// A protect goes under a line of its own, and an answer has the row changed and the line of what went wrong
    /// cleared. Taken off, the same.
    func testAProtectGoesThroughUnderItsLine() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        bench.world.problem = Self.left
        var kept = 0

        let on = await bench.driver.protect(title, true) { kept += 1 }

        XCTAssertEqual(on.altered, .done(saying: nil))
        XCTAssertFalse(on.readAgain)
        XCTAssertEqual(kept, 1)
        XCTAssertEqual(bench.world.begun.last, TVDriver.protectingTitleLine)
        XCTAssertNil(bench.world.problem)
        expectEqual(await bench.television.recordings.map(\.protected), [true])

        let off = await bench.driver.protect(title, false) { kept += 1 }
        XCTAssertEqual(off.altered, .done(saying: nil))
        XCTAssertEqual(kept, 2)
        XCTAssertEqual(bench.world.begun.last, TVDriver.unprotectingTitleLine)
        expectEqual(await bench.television.recordings.map(\.protected), [false])
    }

    /// Turned away at the door, with nothing sent, nothing kept and the line left, the result saying why: a row
    /// being recorded, a television that wants the registration, and one not connected. The same for a delete,
    /// which has the protected row besides.
    func testAWriteTurnedAwayAtTheDoorSendsNothing() async throws {
        let rows = [Self.recording(1), Self.recording(2, recording: true), Self.recording(3, protected: true)]
        let bench = await attached(rows)
        let idle = try await row(of: rows[0], on: bench)
        let being = try await row(of: rows[1], on: bench)
        let protected = try await row(of: rows[2], on: bench)
        bench.world.problem = Self.left
        let before = await bench.gate.asked.count

        let protecting = await bench.driver.protect(being, true) { XCTFail("kept") }
        XCTAssertEqual(protecting.altered, .notDone(TVDriver.stillRecording))
        let deletingThat = await bench.driver.delete(being) { XCTFail("kept") }
        XCTAssertEqual(deletingThat.altered, .notDone(TVDriver.stillRecording))
        let deleting = await bench.driver.delete(protected) { XCTFail("kept") }
        XCTAssertEqual(deleting.altered, .notDone(RecorderDriver.protectedCannotBeDeleted))

        bench.driver.facts.needsPairing = true
        let unregistered = await bench.driver.protect(idle, true) { XCTFail("kept") }
        XCTAssertEqual(unregistered.altered, .notDone(ScalarError.notRegistered.explanation))
        bench.driver.facts.needsPairing = false
        XCTAssertEqual(bench.world.problem, Self.left)
        expectEqual(await bench.gate.asked.count, before)

        await bench.television.goSilent()
        _ = await bench.link.ensureUp(evenIfRecent: true)
        await bench.television.goSilent(false)
        let afterTheLook = await bench.gate.asked.count
        bench.world.problem = Self.left
        let away = await bench.driver.delete(idle) { XCTFail("kept") }
        XCTAssertEqual(away.altered, .notDone(TVDriver.notConnected))
        XCTAssertEqual(bench.world.problem, Self.left)
        expectEqual(await bench.gate.asked.count, afterTheLook)
    }

    /// Silence on a write may be one that arrived: it is said so, on the line and in the result, the television is
    /// lost, the row stays, and nothing is sent again.
    func testSilenceOnAWriteMayBeOneThatArrived() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        await bench.gate.silence("deleteContent")

        let came = await bench.driver.delete(title) { XCTFail("kept") }

        XCTAssertEqual(came.altered, .notDone(TVDriver.mayHaveArrived))
        XCTAssertEqual(bench.world.problem, TVDriver.mayHaveArrived)
        XCTAssertTrue(bench.link.session.unreachable)
        expectEqual(await bench.gate.asked.filter { $0 == "deleteContent" }.count, 1)
    }

    /// A refusal is said in the television's words, on the line and in the result, and it is kept; a cookie it
    /// does not take asks for the registration. Off, it says so as any method's 40005.
    func testAWriteRefusedIsSaidInTheTelevisionsWords() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        await bench.gate.answer("setDeleteProtection", with: HTTPResponse(statusCode: 200, body: Data(
            #"{"error":[40005,"display off"],"id":1}"#.utf8)))

        let off = await bench.driver.protect(title, true) { XCTFail("kept") }

        let said = ScalarError.rpc(method: "setDeleteProtection", version: "1.0", code: 40005, message: "").explanation
        XCTAssertEqual(off.altered, .notDone(said))
        XCTAssertEqual(bench.world.problem, said)
        XCTAssertFalse(bench.link.session.unreachable)

        await bench.gate.stopAnswering("setDeleteProtection")
        bench.credentials.save(TVCredentials(clientID: "BDBridge:test", cookie: "stale"))
        let stale = await bench.driver.protect(title, true) { XCTFail("kept") }
        XCTAssertEqual(stale.altered, .notDone(ScalarError.http(status: 403, method: "setDeleteProtection").explanation))
        XCTAssertTrue(bench.driver.facts.needsPairing)
    }

    /// A disk gone since the list was read is said so, and the list is to be read again, which empties it; a run
    /// stops at the first of its rows, the others being on that disk.
    func testAWriteToADiskThatHasGoneSaysSo() async throws {
        let rows = [Self.recording(1), Self.recording(2)]
        let bench = await attached(rows)
        let title = try await row(of: rows[0], on: bench)
        guard case .success(let run) = bench.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        await bench.television.unmount()

        let came = await bench.driver.delete(title) { XCTFail("kept") }

        XCTAssertEqual(came.altered, .notDone("録画用の USB HDD が見つかりません"))
        XCTAssertTrue(came.readAgain)
        XCTAssertEqual(bench.world.problem, "録画用の USB HDD が見つかりません")
        expectEqual(await bench.driver.delete(title, in: run), .stopped(.said("録画用の USB HDD が見つかりません")))
    }

    /// A check that heard something else than the television saying which it is has nothing sent, and what it
    /// heard is said.
    func testAWriteIsNotSentAfterACheckThatHeardSomethingElse() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        await bench.gate.answer("getSystemSupportedFunction", with: HTTPResponse(statusCode: 503))
        _ = await bench.link.ensureUp(evenIfRecent: true)
        XCTAssertNotNil(bench.link.heardInstead)

        let came = await bench.driver.delete(title) { XCTFail("kept") }

        let heard = ScalarError.http(status: 503, method: "getSystemSupportedFunction").explanation
        XCTAssertEqual(came.altered, .notDone(heard))
        XCTAssertEqual(bench.world.problem, heard)
        expectFalse(await bench.gate.asked.contains("deleteContent"), "sent all the same")
    }

    /// A delete takes the row out, clears the line and reads the disk again, for the free space.
    func testADeleteTakesTheRowOutAndReadsTheDisk() async throws {
        let rows = [Self.recording(1, sizeMB: 2000), Self.recording(2, sizeMB: 2000)]
        let bench = await attached(rows, diskMB: 20_000)
        let title = try await row(of: rows[0], on: bench)
        XCTAssertEqual(bench.driver.facts.storage?.freeMB, 15_400)
        bench.world.problem = Self.left
        var kept = 0

        let came = await bench.driver.delete(title) { kept += 1 }

        XCTAssertEqual(came.altered, .done(saying: nil))
        XCTAssertFalse(came.readAgain)
        XCTAssertEqual(kept, 1)
        XCTAssertEqual(bench.world.begun.last, TVDriver.deletingTitleLine)
        XCTAssertNil(bench.world.problem)
        XCTAssertEqual(bench.driver.facts.storage?.freeMB, 17_400, "the free space was not read again")
    }

    /// A delete a read cannot fail: the disk that does not answer afterwards leaves the row taken out.
    func testADeleteCountsThoughTheDiskIsNotReadAfterIt() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording], diskMB: 20_000)
        let title = try await row(of: recording, on: bench)
        await bench.gate.silence("getStorageList")
        var kept = 0

        let came = await bench.driver.delete(title) { kept += 1 }

        XCTAssertEqual(came.altered, .done(saying: nil))
        XCTAssertEqual(kept, 1)
    }

    /// The list is read before a write, and the row it holds is the one the write goes by: a row protected there
    /// since it was read is said as the sheet says a protected row, nothing sent, and the list is to be read again.
    func testARowProtectedSinceItWasReadIsNotSent() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        let client = try XCTUnwrap(bench.link.client as? ScalarClient)
        try await client.setDeleteProtection(uri: recording.uri, true)
        bench.world.problem = Self.left

        let refused = await bench.driver.delete(title) { XCTFail("kept") }

        XCTAssertEqual(refused.altered, .notDone(RecorderDriver.protectedCannotBeDeleted))
        XCTAssertTrue(refused.readAgain)
        XCTAssertNil(bench.world.problem, "the read that found it left the line")
        expectFalse(await bench.gate.asked.contains("deleteContent"), "sent all the same")
    }

    /// Past that read a delete has its two refusals still. 41000, a row protected in the moment between, is said
    /// the same. 41001, a uri listed a moment ago and no longer known, is a row gone: it is taken out, and the
    /// result says so.
    func testADeletesTwoRefusalsAreAnswers() async throws {
        func refused(_ code: Int) -> HTTPResponse {
            HTTPResponse(statusCode: 200, body: Data(#"{"error":[\#(code),"refused"],"id":1}"#.utf8))
        }
        let recording = Self.recording(1)
        let protected = await attached([recording])
        let title = try await row(of: recording, on: protected)
        await protected.gate.answer("deleteContent", with: refused(41000))

        let said = await protected.driver.delete(title) { XCTFail("kept") }

        XCTAssertEqual(said.altered, .notDone(RecorderDriver.protectedCannotBeDeleted))
        XCTAssertTrue(said.readAgain)
        expectEqual(await protected.television.recordings.count, 1)

        let gone = await attached([recording])
        let goneRow = try await row(of: recording, on: gone)
        await gone.gate.answer("deleteContent", with: refused(41001))
        var kept = 0
        let already = await gone.driver.delete(goneRow) { kept += 1 }
        XCTAssertEqual(already.altered, .done(saying: ItemCame.gone.reason))
        XCTAssertEqual(kept, 1)
        XCTAssertFalse(already.readAgain)
    }

    /// The same for a protect: the row gone in that moment says so, and the list is to be read again.
    func testAProtectOfARowGoneSaysSo() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        await bench.gate.answer("setDeleteProtection", with: HTTPResponse(statusCode: 200, body: Data(
            #"{"error":[41001,"no such content"],"id":1}"#.utf8)))

        let came = await bench.driver.protect(title, true) { XCTFail("kept") }

        XCTAssertEqual(came.altered, .notDone(ItemCame.gone.reason ?? ""))
        XCTAssertTrue(came.readAgain)
    }

    // MARK: - that it is still the same recording

    /// A row is found again by its uri, and is that row only with the same start and title: whether a uri lasts
    /// through a restart, a disk swapped or a delete and a new recording has not been measured.
    func testARowIsFoundAgainByItsUriItsStartAndItsTitle() throws {
        var row = title(100)
        row.id = "usb:recStorage?contentId=1"
        var sameButFlags = row
        sameButFlags.protected = true
        var anotherTitle = row
        anotherTitle.title = "別の番組"
        var anotherStart = row
        anotherStart.start = row.start.addingTimeInterval(60)
        var anotherURI = row
        anotherURI.id = "usb:recStorage?contentId=2"

        XCTAssertEqual([anotherURI, sameButFlags].tvTarget(of: row), .found(sameButFlags))
        XCTAssertEqual([anotherTitle].tvTarget(of: row), .changed)
        XCTAssertEqual([anotherStart].tvTarget(of: row), .changed)
        XCTAssertEqual([anotherURI].tvTarget(of: row), .notListed)
        XCTAssertEqual([RecordedTitle]().tvTarget(of: row), .notListed)
    }

    /// Before each write the list is read, and a uri that now names another recording is sent nothing: not a
    /// protect, not a delete, not in a run. The result says so, the list is to be read again, a run stops there,
    /// and the row is not taken out.
    func testAWriteIsNotSentToAUriThatNowNamesAnotherRecording() async throws {
        var other = Self.recording(1)
        other.title = "別の番組"
        var moved = Self.recording(1)
        moved.start = Self.start.addingTimeInterval(3600)
        for (name, now) in [("another title", other), ("another start", moved)] {
            let recording = Self.recording(1)
            let bench = await attached([recording])
            let title = try await row(of: recording, on: bench)
            guard case .success(let run) = bench.driver.beginRun(.delete) else { return XCTFail("did not begin") }
            await bench.television.records([now])

            let protecting = await bench.driver.protect(title, true) { XCTFail("kept") }
            XCTAssertEqual(protecting.altered, .notDone(TVDriver.titleChanged), name)
            XCTAssertTrue(protecting.readAgain, name)
            let deleting = await bench.driver.delete(title) { XCTFail("kept") }
            XCTAssertEqual(deleting.altered, .notDone(TVDriver.titleChanged), name)
            XCTAssertTrue(deleting.readAgain, name)
            expectEqual(await bench.driver.delete(title, in: run), .stopped(.said(TVDriver.titleChanged)), name)
            expectEqual(await bench.driver.protect(title, true, in: run), .stopped(.said(TVDriver.titleChanged)), name)

            let asked = await bench.gate.asked
            XCTAssertFalse(asked.contains("deleteContent"), name)
            XCTAssertFalse(asked.contains("setDeleteProtection"), name)
            expectEqual(await bench.television.recordings, [now], name)
        }
    }

    /// A row the list does not hold is sent nothing either, and is never said to be deleted: the list can lack what
    /// the disk holds, as it does for a minute or two after a restart. A run stops, and does not pass over the
    /// rows of a list being put back together.
    func testARowNotInTheListIsNotSaidToBeDeleted() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        guard case .success(let run) = bench.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        await bench.television.leavesOutOfItsList([recording.uri])

        let deleting = await bench.driver.delete(title) { XCTFail("kept") }
        XCTAssertEqual(deleting.altered, .notDone(TVDriver.titleNotInList))
        XCTAssertTrue(deleting.readAgain)
        let protecting = await bench.driver.protect(title, true) { XCTFail("kept") }
        XCTAssertEqual(protecting.altered, .notDone(TVDriver.titleNotInList))
        expectEqual(await bench.driver.delete(title, in: run), .stopped(.said(TVDriver.titleNotInList)))

        let asked = await bench.gate.asked
        XCTAssertFalse(asked.contains("deleteContent"))
        XCTAssertFalse(asked.contains("setDeleteProtection"))
        expectEqual(await bench.television.recordings, [recording], "the recording on the disk was touched")
    }

    /// A row being recorded by the list just read is not written to, though it was over when the row was read: the
    /// rule is asked again of the row as it is now. In a run it is passed over, the row being there.
    func testTheDoorsRuleIsAskedAgainOfTheRowJustRead() async throws {
        let recording = Self.recording(1)
        let bench = await attached([recording])
        let title = try await row(of: recording, on: bench)
        guard case .success(let run) = bench.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        await bench.television.records([Self.recording(1, recording: true)])

        let came = await bench.driver.protect(title, true) { XCTFail("kept") }
        XCTAssertEqual(came.altered, .notDone(TVDriver.stillRecording))
        XCTAssertTrue(came.readAgain)
        expectEqual(await bench.driver.delete(title, in: run), .passedOver(TVDriver.stillRecording))
    }

    /// Silence on the read before a write is a read's: nothing has been sent, so it is not said that something may
    /// have arrived, and a run stops with nothing sent. Any other failure of that read stops a run too, there
    /// being nothing to go by.
    func testSilenceOnTheReadBeforeAWriteIsARead() async throws {
        let recording = Self.recording(1)
        let single = await attached([recording])
        let title = try await row(of: recording, on: single)
        await single.gate.silence(Self.read)

        let came = await single.driver.delete(title) { XCTFail("kept") }

        let silence = ScalarError.transport("no answer").explanation
        XCTAssertEqual(came.altered, .notDone(silence))
        XCTAssertEqual(single.world.problem, silence)
        expectFalse(await single.gate.asked.contains("deleteContent"))

        let running = await attached([recording])
        let row = try await row(of: recording, on: running)
        guard case .success(let run) = running.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        await running.gate.silence(Self.read)
        expectEqual(await running.driver.delete(row, in: run), .stopped(.silent(afterSending: false)))
        XCTAssertEqual(running.world.problem, silence)

        let refusing = await attached([recording])
        let refused = try await self.row(of: recording, on: refusing)
        guard case .success(let again) = refusing.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        await refusing.gate.answer(Self.read, with: HTTPResponse(statusCode: 200, body: Data(
            #"{"error":[12,"getContentList"],"id":1}"#.utf8)))
        let said = ScalarError.rpc(method: Self.read, version: "1.5", code: 12, message: "").explanation
        expectEqual(await refusing.driver.delete(refused, in: again), .stopped(.said(said)))
        expectFalse(await refusing.gate.asked.contains("deleteContent"))
    }

    // MARK: - a run

    /// A run begins while the television can be asked, by the doors of a single write, and neither begins nor
    /// goes on without one: the sentence is why.
    func testARunBeginsOnlyWithATelevisionThatCanBeAsked() async throws {
        let bench = await attached([Self.recording(1)])
        guard case .success(let run) = bench.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        expectNil(await bench.driver.mayGoOn(run))

        func stop(of begun: Result<Run, RunStop>) -> RunStop? {
            if case .failure(let stop) = begun { stop } else { nil }
        }
        bench.driver.facts.needsPairing = true
        XCTAssertEqual(stop(of: bench.driver.beginRun(.delete)), .said(ScalarError.notRegistered.explanation))
        expectEqual(await bench.driver.mayGoOn(run), .said(ScalarError.notRegistered.explanation))
        bench.driver.facts.needsPairing = false

        bench.link.forgetTheDevice()
        expectEqual(await bench.driver.mayGoOn(run), .said(TVDriver.notConnected))
        XCTAssertEqual(stop(of: bench.driver.beginRun(.delete)), .said(TVDriver.notConnected))
    }

    /// A run deletes what can go. A protected row and one being recorded are passed over with their sentences and
    /// nothing asked; a row protected since the list was read with the same sentence, the list read before it
    /// saying so, and so one the television answers 41000 for; a row it answers 41001 for comes back as gone. The
    /// free space is read as it ends.
    func testARunDeletesWhatCanGo() async throws {
        let rows = [Self.recording(1, sizeMB: 2000), Self.recording(2, protected: true), Self.recording(3, recording: true),
                    Self.recording(4), Self.recording(5)]
        let bench = await attached(rows, diskMB: 50_000)
        var titles: [RecordedTitle] = []
        for row in rows { titles.append(try await self.row(of: row, on: bench)) }
        guard case .success(let run) = bench.driver.beginRun(.delete) else { return XCTFail("did not begin") }

        expectEqual(await bench.driver.delete(titles[0], in: run), .done)
        let asked = await bench.gate.asked.filter { $0 == "deleteContent" }.count
        expectEqual(await bench.driver.delete(titles[1], in: run), .passedOver(RecorderDriver.protectedCannotBeDeleted))
        expectEqual(await bench.driver.delete(titles[2], in: run), .passedOver(TVDriver.stillRecording))
        expectEqual(await bench.gate.asked.filter { $0 == "deleteContent" }.count, asked)

        let client = try XCTUnwrap(bench.link.client as? ScalarClient)
        try await client.setDeleteProtection(uri: rows[3].uri, true)
        expectEqual(await bench.driver.delete(titles[3], in: run), .passedOver(RecorderDriver.protectedCannotBeDeleted))

        await bench.gate.answer("deleteContent", with: HTTPResponse(statusCode: 200, body: Data(
            #"{"error":[41001,"no such content"],"id":1}"#.utf8)))
        expectEqual(await bench.driver.delete(titles[4], in: run), .gone)
        await bench.gate.answer("deleteContent", with: HTTPResponse(statusCode: 200, body: Data(
            #"{"error":[41000,"protected"],"id":1}"#.utf8)))
        expectEqual(await bench.driver.delete(titles[4], in: run), .passedOver(RecorderDriver.protectedCannotBeDeleted))

        let free = bench.driver.facts.storage?.freeMB
        await bench.driver.end(run, deleted: 1, stopped: nil)
        XCTAssertNotEqual(bench.driver.facts.storage?.freeMB, free, "the free space was not read again")
    }

    /// Protecting skips what is already so and a row being recorded, and sends the rest.
    func testARunProtectsWhatIsNotYet() async throws {
        let rows = [Self.recording(1), Self.recording(2, protected: true), Self.recording(3, recording: true)]
        let bench = await attached(rows)
        var titles: [RecordedTitle] = []
        for row in rows { titles.append(try await self.row(of: row, on: bench)) }
        guard case .success(let run) = bench.driver.beginRun(.protecting(true)) else { return XCTFail("did not begin") }

        expectEqual(await bench.driver.protect(titles[0], true, in: run), .done)
        expectEqual(await bench.driver.protect(titles[1], true, in: run), .passedOver("すでに保護されています"))
        expectEqual(await bench.driver.protect(titles[2], true, in: run), .passedOver(TVDriver.stillRecording))
        expectEqual(await bench.television.recordings.map(\.protected), [true, true, false])
    }

    /// Silence stops a run at that row, said as a write's, and it is not sent again. A refusal passes the row over
    /// and the run goes on. A television let go of stops it with nothing sent.
    func testWhatARunCameToWithoutAnAnswer() async throws {
        let rows = [Self.recording(1), Self.recording(2)]
        let silent = await attached(rows)
        let first = try await row(of: rows[0], on: silent)
        guard case .success(let run) = silent.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        await silent.gate.silence("deleteContent")
        expectEqual(await silent.driver.delete(first, in: run), .stopped(.silent(afterSending: true)))
        XCTAssertEqual(silent.world.problem, TVDriver.mayHaveArrived)
        XCTAssertTrue(silent.link.session.unreachable)

        let refused = await attached(rows)
        let second = try await row(of: rows[1], on: refused)
        guard case .success(let again) = refused.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        await refused.gate.answer("deleteContent", with: HTTPResponse(statusCode: 200, body: Data(
            #"{"error":[12,"deleteContent"],"id":1}"#.utf8)))
        let said = ScalarError.rpc(method: "deleteContent", version: "1.0", code: 12, message: "").explanation
        expectEqual(await refused.driver.delete(second, in: again), .passedOver(said))
        XCTAssertNil(refused.world.problem, "what a run passes over is said of that row alone")

        refused.link.forgetTheDevice()
        expectEqual(await refused.driver.delete(second, in: again), .stopped(.said(TVDriver.notConnected)))
    }

    /// Nothing is read as a run ends that deleted nothing, or that something stopped.
    func testARunThatFreedNothingReadsNothing() async throws {
        let bench = await attached([Self.recording(1)])
        guard case .success(let run) = bench.driver.beginRun(.delete) else { return XCTFail("did not begin") }
        let before = await bench.gate.asked.count
        await bench.driver.end(run, deleted: 0, stopped: nil)
        await bench.driver.end(run, deleted: 1, stopped: .silent(afterSending: true))
        expectEqual(await bench.gate.asked.count, before)
    }

    /// What a run says it came to names the device that stopped answering.
    func testARunSaysWhichDeviceStoppedAnswering() {
        let silent = RunStop.silent(afterSending: true)
        XCTAssertEqual(RecorderDriver.outcome(of: .delete, done: 2, changed: 2, passedOver: 1, cancelled: false,
                                              stopped: silent, on: .tv),
                       "2 件を削除したところで、テレビの応答がなくなったため中止しました（1 件はスキップ）")
        XCTAssertEqual(RecorderDriver.outcome(of: .protecting(true), done: 2, changed: 2, passedOver: 0, cancelled: false,
                                              stopped: silent),
                       "2 件を保護したところで、レコーダーの応答がなくなったため中止しました")
    }
}
