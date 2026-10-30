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
        let driver = TVDriver(credentials: credentials, nickname: "BD Bridge", inFront: { true }, titlesWait: wait)
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

    /// The list after a restart: empty with the disk full. It is said to be still coming, read again until rows
    /// come, each read handed over, and the wait ends there.
    func testAListThatMayStillBeComingIsReadAgainUntilItComes() async throws {
        let rows = [Self.recording(1), Self.recording(2)]
        let bench = await attached(rows, wait: TVTitlesWait(every: .milliseconds(5), for: 30))
        await bench.television.leavesOutOfItsList(Set(rows.map(\.uri)))
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .mayStillBeComing))

        let television = bench.television
        let reads = await bench.gate.asked.filter { $0 == Self.read }.count
        await bench.gate.before(Self.read) {
            guard await bench.gate.asked.filter({ $0 == Self.read }).count == reads + 3 else { return }
            await television.leavesOutOfItsList([rows[1].uri])
        }
        await bench.driver.waitForTitles { kept.lists.append($0) }

        XCTAssertEqual(kept.last?.rows.map(\.id), [rows[0].uri], "rows that come are shown as they come")
        XCTAssertEqual(kept.last?.account, .someAreMissing, "the rows that came are short of the disk")
        expectEqual(await bench.gate.asked.filter { $0 == Self.read }.count, reads + 3)
        XCTAssertFalse(bench.world.begun.contains(TVDriver.titlesComingLine), "the wait is the host's to say")
    }

    /// The wait is bounded: a list that does not come within it is said to be short of what the disk holds, and
    /// the wait does not begin again for as long as it stays so, a read after it included.
    func testAListThatNeverComesIsSaidToBeShortOnceTheWaitIsOver() async throws {
        let bench = await attached([Self.recording(1)])
        await bench.television.leavesOutOfItsList([Self.recording(1).uri])
        let kept = Kept()
        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last?.account, .mayStillBeComing)

        await bench.driver.waitForTitles { kept.lists.append($0) }
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .someAreMissing))

        _ = await bench.driver.titles { kept.lists.append($0) }
        XCTAssertEqual(kept.last, TVTitles(rows: [], account: .someAreMissing), "the wait began again")
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
}
