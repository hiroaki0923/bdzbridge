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
