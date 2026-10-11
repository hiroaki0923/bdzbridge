import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder on the bench by itself, asked by a client with no model in between.
///
/// The gates tell it what to answer and look at what the app made of that. One of them passing because the fake
/// said something other than it was told would hold nothing, so what the fake does with what it is told is held
/// here: how often, after how many, to which kind, and beside its being held or silent. What a client takes a
/// fault, a 503 or a missing file for is the package's to say and is tested there (`DeviceFailureTests`,
/// `RecorderClientTests`); here each is looked at only for being the one the test asked for.
///
/// Two more of the bench's own are held here for the same reason, though neither is the recorder: the cache's
/// table put out of reach, and the record of what a run with no screen told.
@MainActor
final class BenchRecorderTests: XCTestCase {
    func testTheRecorderOnTheBenchAnswersAsItIsToldAndIsReadSo() async throws {
        let list = "X_GetRecordScheduleList", delete = "X_DeleteRecordSchedule", create = "X_CreateRecordSchedule"
        // A number the demo has given to nothing. It takes a delete of it for done, as it takes any.
        let nothing = "0x00000000000fffff"
        let recorder = NamedRecorder(1)
        let client = aClient(of: recorder)
        let first = try await client.reservations()
        let rows = Array(first.filter { !$0.recording }.prefix(3))
        guard rows.count == 3 else { return XCTFail("the demo was meant to hold three reservations to delete") }

        // A fault, each code on the action a recorder gives it for: once, to that kind alone, and then as ever.
        let programme = ReservationRequest(title: "サンプル番組", start: Date().addingTimeInterval(7200),
                                           durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                           qualityCode: 100, eventID: 4321)
        func ask(_ kind: String) async throws {
            switch kind {
            case delete: try await client.deleteReservation(id: rows[0].id)
            case create: try await client.create(programme)
            case "X_DeleteTitle": try await client.deleteTitle(id: nothing)
            default: try await client.playControl(titleID: nothing, operation: "pause")
            }
        }
        let unreceivable = RecorderError.soap(action: create, status: 500, code: "831", body: "").explanation
        let faults: [(kind: String, code: Int, readAs: DeviceFailure)] = [
            (delete, 804, .unknownItem), ("X_DeleteTitle", 820, .unknownItem),
            (create, 831, .refused(reason: unreceivable)), ("X_PlayControlTitle", 880, .needsPower),
        ]
        for (kind, code, readAs) in faults {
            let count = await recorder.heard.count
            await recorder.answer(kind, with: .fault(code))
            expectEqual(await failure { try await ask(kind) }, readAs, "\(code) to \(kind)")
            expectNil(await failure { _ = try await client.reservations() }, "told of \(kind), it answered a read so")
            expectNil(await failure { try await ask(kind) }, "told to answer one \(kind) so, it answered two")
            expectEqual(await recorder.heard(since: count), [kind, list, kind])
        }
        let afterwards = try await client.reservations()
        XCTAssertFalse(afterwards.contains { $0.id == rows[0].id }, "the delete after the fault never got to the demo")
        XCTAssertTrue(afterwards.contains { $0.eventID == 4321 }, "the reservation after the fault never got there")

        // A 503 is sent again twice by the client, so a call that fails as busy is three of them, and two are
        // a call that goes through late. `after` lets so many of the kind through first.
        var count = await recorder.heard.count
        let before = await recorder.asked
        await recorder.beBusy(with: list)
        expectEqual(await failure { _ = try await client.reservations() }, .busy)
        expectEqual(await recorder.heard(since: count), [list, list, list])
        expectEqual(await recorder.asked(list, since: before), 3, "what it answered itself was not counted")
        expectNil(await failure { _ = try await client.reservations() }, "busy for one call, it was for the next")
        count = await recorder.heard.count
        await recorder.answer(list, with: .status(503), times: 2)
        expectNil(await failure { _ = try await client.reservations() }, "busy twice, and the call did not go through")
        expectEqual(await recorder.heard(since: count), [list, list, list])
        await recorder.beBusy(with: list, after: 1)
        expectNil(await failure { _ = try await client.reservations() }, "the first was to be let through")
        expectEqual(await failure { _ = try await client.reservations() }, .busy)

        // A file is a kind by its name. The demo's own answer is that it has no such file.
        let file = "EPG_BSEPG_FILE.dat"
        await recorder.answer(file, with: .status(500))
        expectEqual(await failure { _ = try await client.epgFile("bs") },
                    RecorderError.guideFileMissing(name: file, status: 500).failure)
        expectNil(try await client.epgFile("bs"))
        expectEqual(await recorder.asked(file), 2)

        // A `Result` of the test's own is read as the recorder's, and one that is no XML is an error that is
        // not a device's: the only one these fakes can raise.
        await recorder.answer("X_GetPlayStatus", with: .result("<status><powerstatus>PowerOn</powerstatus></status>"))
        expectEqual(try await client.playStatus()["powerstatus"], "PowerOn")
        expectNil(try await client.playStatus()["powerstatus"], "the demo's own answer says nothing of the power")
        await recorder.answer(list, with: .result("一覧ではない文字列"))
        do {
            _ = try await client.reservations()
            XCTFail("a list that is no XML was read")
        } catch {
            XCTAssertFalse(error is any DeviceError, "\(error)")
        }

        // A request held and then let go meets what the recorder was told meanwhile. One that silence took is
        // not among those it was told to answer.
        await recorder.hold(only: delete)
        count = await recorder.heard.count
        let held = Task { await failure { try await client.deleteReservation(id: nothing) } }
        try await until("the delete never got to the recorder") { await recorder.heard(since: count) == [delete] }
        await recorder.answer(delete, with: .fault(804))
        await recorder.letGo()
        expectEqual(await held.value, .unknownItem, "what was held got past what the recorder was told meanwhile")
        await recorder.answer(delete, with: .fault(804))
        await recorder.goQuiet(on: delete)
        expectEqual(await failure { try await client.deleteReservation(id: nothing) }, .silent)
        expectEqual(await failure { try await client.deleteReservation(id: nothing) }, .unknownItem,
                    "the one silence took was counted as answered")
        expectNil(await failure { try await client.deleteReservation(id: nothing) })

        // A moment behind itself, once: the list after the next delete is the one from before it, and what is
        // deleted after that has gone from the next list.
        _ = try await client.reservations()
        await recorder.beAMomentBehind()
        try await client.deleteReservation(id: rows[1].id)
        expectTrue(try await client.reservations().contains { $0.id == rows[1].id }, "the list was not behind")
        expectFalse(try await client.reservations().contains { $0.id == rows[1].id }, "behind for a second list")
        try await client.deleteReservation(id: rows[2].id)
        expectFalse(try await client.reservations().contains { $0.id == rows[2].id }, "behind after a second delete")
        // And never with another recorder's list: the one that takes its place answers with its own.
        await recorder.beAMomentBehind()
        try await client.deleteReservation(id: nothing)
        await recorder.become(2)
        expectEqual(try await client.reservations().map(\.id), first.map(\.id),
                    "the list the first recorder was behind with was given as the second's")
    }

    /// Silence is told as any other answer is: to the requests of one kind, after as many of them as the test
    /// lets through, and counted among those it was asked. `goQuiet(on:)` is the next of a kind alone.
    func testSilenceIsGivenToTheRequestsItWasToldAndToNoOther() async throws {
        let delete = Ask.deleteRecording, list = Ask.recordings
        let recorder = NamedRecorder(1)
        let client = aClient(of: recorder)

        await recorder.answer(delete, with: .silence, after: 1)
        expectNil(await failure { try await client.deleteTitle(id: nothing) }, "the first was to be let through")
        expectNil(await failure { _ = try await client.allTitles() }, "told of a delete, it said nothing to a read")
        expectEqual(await failure { try await client.deleteTitle(id: nothing) }, .silent)
        expectNil(await failure { try await client.deleteTitle(id: nothing) }, "silent to one, it was to the next")
        expectEqual(await recorder.heard, [delete, list, delete, delete])
        expectEqual(await recorder.asked(delete), 3, "the one it said nothing to was not counted")

        await recorder.answer(list, with: .silence, times: 2)
        expectEqual(await failure { _ = try await client.allTitles() }, .silent)
        expectEqual(await failure { _ = try await client.allTitles() }, .silent)
        expectNil(await failure { _ = try await client.allTitles() }, "silent to two, it was to a third")
    }

    /// A test that holds one request of a kind and then the next lets the first go alone. The hold stays as it
    /// was set, so the next of the kind is held as it arrives; and of the requests held, only the one of that
    /// kind that has waited longest goes.
    func testTheRequestHeldLongestIsLetGoAloneAndTheNextOfItsKindIsHeld() async throws {
        let delete = Ask.deleteRecording, list = Ask.recordings
        let recorder = NamedRecorder(1)
        let client = aClient(of: recorder)
        // A delete asked for and waited for until it has arrived, which is where it is held if anything holds it.
        func aDelete(by client: RecorderClient, arrivingAs count: Int) async throws -> Task<DeviceFailure?, Never> {
            let asking = Task { await failure { try await client.deleteTitle(id: nothing) } }
            try await until("delete \(count) never got to the recorder") { await recorder.asked(delete) == count }
            return asking
        }
        // What a request that has arrived comes to once it is let go says whether it was held: one that was
        // meets what the recorder was told after it arrived, and one that was not has been answered already.
        func heldUntilLetGo(_ asking: Task<DeviceFailure?, Never>, _ what: String) async throws {
            await recorder.answer(delete, with: .fault(820))
            await recorder.letTheFirstGo(of: delete)
            let came = try await within(5, what) { await asking.value }
            XCTAssertEqual(came, .unknownItem, "\(what) was not held: it was answered before it was let go")
        }

        // Every request of the kind held: the first, then the second, then the third.
        await recorder.hold(only: delete)
        try await heldUntilLetGo(try await aDelete(by: client, arrivingAs: 1), "the first delete")
        try await heldUntilLetGo(try await aDelete(by: client, arrivingAs: 2), "the delete after the one let go")
        // With none held it lets nothing go, and the hold is still as it was.
        await recorder.letTheFirstGo(of: delete)
        try await heldUntilLetGo(try await aDelete(by: client, arrivingAs: 3), "the delete after nothing was let go")
        await recorder.letGo()
        expectNil(await failure { try await client.deleteTitle(id: nothing) }, "held after everything was let go")

        // The next of the kind held, and asked for again before the first is let go: the one after it is held too,
        // and the one after that is not.
        await recorder.holdTheNext(delete)
        let next = try await aDelete(by: client, arrivingAs: 5)
        await recorder.holdTheNext(delete)
        await recorder.letTheFirstGo(of: delete)
        expectNil(try await within(5, "the delete held as the next") { await next.value })
        try await heldUntilLetGo(try await aDelete(by: client, arrivingAs: 6), "the next delete, asked for again")
        expectNil(await failure { try await client.deleteTitle(id: nothing) }, "a third was held after two nexts")

        // Three held at once, by three clients, as one client asks one thing at a time: the delete that has
        // waited longest goes, and neither the read nor the later delete goes with it.
        let (second, third) = (aClient(of: recorder), aClient(of: recorder))
        await recorder.hold()
        let earlier = try await aDelete(by: client, arrivingAs: 8)
        let before = await recorder.asked
        let read = Task { await failure { _ = try await second.allTitles() } }
        try await until("the read never got to the recorder") { await recorder.asked(list, since: before) == 1 }
        let later = try await aDelete(by: third, arrivingAs: 9)
        let back = Back()
        for (name, asking) in [("the earlier delete", earlier), ("the read", read), ("the later delete", later)] {
            Task {
                _ = await asking.value
                back.came.append(name)
            }
        }
        await recorder.letTheFirstGo(of: delete)
        try await until("nothing that was held was let go") { !back.came.isEmpty }
        guard back.came == ["the earlier delete"] else {
            await recorder.letGo()
            return XCTFail("what was let go was not the delete that had waited longest alone: \(back.came)")
        }
        expectNil(await earlier.value)
        await recorder.answer(list, with: .silence)
        try await heldUntilLetGo(later, "the later delete")
        await recorder.letGo()
        expectEqual(await read.value, .silent, "the read went with a delete: it was answered before it was let go")
    }

    /// A body of the test's own is given as it is. A file of the conformance vectors is a guide a client decodes
    /// and a refresh stores; a SOAP answer written out with its own element is read as the recorder's, where
    /// `.result` can only say something in `Result`.
    func testABodyOfTheTestsOwnIsGivenAsItIs() async throws {
        let recorder = NamedRecorder(1)
        let client = aClient(of: recorder)

        let noSize = "<recordDestinationInfo totalCapacity=\"0\" availableCapacity=\"0\" />"
        await recorder.answer(Ask.freeSpace, with: .text(noSize, in: "RecordDestinationInfo"))
        let disk = try await client.recordDestinationInfo()
        XCTAssertEqual(disk.totalBytes, 0)
        XCTAssertEqual(disk.freeBytes, 0)
        expectEqual(try await client.recordDestinationInfo().totalBytes, DemoData.totalBytes,
                    "told to answer once, it answered so twice")

        let guide = try vectorFile("epg-sample.dat")
        await recorder.answer(Ask.guide[0], with: .body(guide))
        expectEqual(try await client.epgFile("td"), guide)
        expectNil(try await client.epgFile("td"), "the demo's own answer is that it has no such file")
        await recorder.answer(Ask.guide[1], with: .body(guide))
        expectFalse(try await client.guide("bs")?.flatMap(\.programs).isEmpty ?? true, "the file was not read")
        await recorder.answer(Ask.logos[0], with: .body(try vectorFile("logo-sample.dat")))
        expectFalse(try await client.logos("td")?.isEmpty ?? true, "the logos were not read")

        // And into a cache: one type given the file, the rest answered as the demo answers, with no file.
        await recorder.answer(Ask.guide[0], with: .body(guide))
        let store = try GuideStore(path: ":memory:")
        let fetched = await GuideRefresh.run(client: client, store: store)
        XCTAssertEqual(fetched.answered, GuideRefresh.broadcastingTypes)
        XCTAssertTrue(fetched.stored > 0, "nothing of the sample guide was stored")
        expectTrue(try await store.counts()["td"]?.programs ?? 0 > 0, "the cache holds none of its programmes")
    }

    /// Told to, it has one broadcast on its disk twice, as `RecorderWithACopy` has, and goes on being held,
    /// told what to answer and silent as a test has it, which that one cannot be.
    func testARecorderToldToHaveACopyHasOneAndIsStillToldWhatToAnswer() async throws {
        let recorder = NamedRecorder(1)
        let client = aClient(of: recorder)
        // The numbers of the recordings that share their title with another. Numbers and titles are all that is
        // compared between one recorder and another, here and below: each of the demo's recorders is recording
        // something that began twenty minutes before the recorder itself was made, to the second.
        func copies() async throws -> [String] {
            let titles = try await client.allTitles()
            return titles.filter { one in titles.filter { $0.title == one.title }.count > 1 }.map(\.id)
        }
        let before = try await client.allTitles()
        expectEqual(try await copies(), [], "the demo was meant to hold no broadcast twice")

        await recorder.haveACopy()
        let pair = try await copies()
        guard pair.count == 2 else {
            return XCTFail("one broadcast was to be there twice, and nothing else more than once: \(pair)")
        }
        expectEqual(try await client.allTitles().map(\.id), before.map(\.id), "the copy changed a number")
        expectEqual(try await client.allTitles().map(\.title),
                    try await aClient(of: RecorderWithACopy()).allTitles().map(\.title))

        await recorder.answer(Ask.details, with: .fault(820))
        expectEqual(await failure { _ = try await client.titleDetail(id: pair[0]) }, .unknownItem)
        expectNil(await failure { _ = try await client.titleDetail(id: pair[0]) })
        await recorder.answer(Ask.recordings, with: .silence)
        expectEqual(await failure { _ = try await client.allTitles() }, .silent)
        expectEqual(try await copies(), pair, "the copy went with what the recorder was told")
        // The recorder that takes its place numbers its recordings as the first did, the copy among them.
        await recorder.become(2)
        expectEqual(try await copies(), pair)
    }

    /// With the cache's `meta` table out of reach, whose cache it is cannot be read, by a store opened before or
    /// by the rule the runs with no screen ask (`RecorderDriver.isTheOneKnown`), which takes that for a recorder
    /// it does not know; the queue is read as ever. Put back, the cache is the recorder's it was.
    func testWhoseCacheItIsCannotBeReadWhileItsTableIsOutOfReach() async throws {
        let (bench, recorder, _) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        let client = aClient(of: recorder)
        try await client.describe()
        expectEqual(try await store.owner(), NamedRecorder.udn(1))
        expectTrue(await RecorderDriver.isTheOneKnown(client, to: store))

        let meta = MetaOutOfReach(in: bench.guidePath)
        do {
            let owner = try await store.owner()
            XCTFail("the owner was read from a table out of reach: \(owner ?? "none")")
        } catch {}
        expectFalse(await RecorderDriver.isTheOneKnown(client, to: store))
        expectEqual(try await store.pendingReservations(), [], "the queue went out of reach with it")

        meta.putBack()
        expectEqual(try await store.owner(), NamedRecorder.udn(1))
        expectTrue(await RecorderDriver.isTheOneKnown(client, to: store))
    }

    /// What a run with no screen tells is on the bench's record by the time each telling returns, as it was told
    /// and in that order: the one that is told with no wait as well, which a record kept by a task of its own
    /// would hold a moment late or out of its place.
    func testWhatARunWithNoScreenTellsIsOnRecordAsItIsToldAndInItsOrder() async throws {
        let told = Tellings()
        let tell = telling(told)
        XCTAssertEqual(told.said, [])
        tell.fetched(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(told.said, [.fetched], "what is told with no wait was not on record when its telling returned")
        let disk = RecorderDisk(destination: RecorderDisk.usbID, name: "録画用ディスク", mounted: true, freeMB: 1,
                                totalMB: 2, registered: "2026-01-01T00:00:00+09:00")
        await tell.heldBack()
        await tell.freeSpace(1, 2, "HDD")
        await tell.usbSpace(disk)
        tell.fetched(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(told.said, [.fetched, .heldBack, .freeSpace(free: 1, total: 2, naming: "HDD"), .usbSpace(disk),
                                   .fetched])
        XCTAssertEqual(told.names, ["fetched", "heldBack", "freeSpace", "usbSpace", "fetched"])
        XCTAssertEqual(told.rounds, [])

        // A night of the demo's recorder with nothing waiting, which tells of the queue all the same.
        let (bench, recorder, _) = try await connectedHome()
        let night = Tellings()
        _ = await BackgroundWork.refresh(client: aClient(of: recorder), store: try GuideStore(path: bench.guidePath),
                                         mac: nil, telling: telling(night))
        XCTAssertEqual(night.names, ["flushed", "freeSpace", "fetched"])
        XCTAssertEqual(night.rounds.map(\.slot), [.recorder])
        guard case .freeSpace(_, let total, let naming)? = night.said.dropFirst().first else {
            return XCTFail("the second thing told was not the free space: \(night.said)")
        }
        XCTAssertEqual(total, DemoData.totalBytes)
        XCTAssertNil(naming, "the demo's recorder has no USB disk for its own to be told from")
    }
}

/// A number the demo has given to nothing. It takes a delete of it for done, as it takes any.
private let nothing = "0x00000000000fffff"

/// Which of the requests a test set going have come back, in the order they did, for a test that is not to wait
/// for one that may never.
@MainActor
private final class Back {
    var came: [String] = []
}

/// What the recorder's answer to `ask` was read as: nil when it went through.
@MainActor
private func failure(_ ask: @MainActor () async throws -> Void) async -> DeviceFailure? {
    do {
        try await ask()
        return nil
    } catch {
        return (error as? any DeviceError)?.failure ?? .unexpected(String(describing: error))
    }
}
