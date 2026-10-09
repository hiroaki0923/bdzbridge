import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder's reservations, each thing asked for as a screen asks for it: a delete and a change of one it
/// holds, the question of what a new one would clash with, and a new one made. What is read before a write and
/// after it and in which order, which reservation the write goes to, what a refusal, silence and not being
/// connected each leave behind, and what does and does not go to the queue.
///
/// Gates, as `FunnelGateTests` are and for the same move: each pins what the app does today, with what nobody
/// would choose among it, and where a later change is to rewrite a test it says so, with that change's name in
/// the plan in brackets. A test asks only what a screen asks and reads only what a screen reads.
///
/// A delete and a change are written out in the model by hand, each with a read of the list before it and one
/// after, rather than run through the funnel, so what is held of one is held of the other (`ReservationWrite`).
/// What the recorder was asked is compared whole and in order (`NamedRecorder.heard`): a recorder that answered
/// within the last minute and a half is not made sure of first, so an operation asks only what it asks itself.
@MainActor
final class ReservationGateTests: XCTestCase {
    // MARK: - a delete and a change

    /// A delete or a change that goes through. The list is read again first, so that the reservation is found
    /// as the recorder holds it now. The write goes once, under a line of its own, and while it is out the
    /// recorder in play cannot be changed. The list is read after it, which is what puts a change on screen.
    ///
    /// A deleted reservation stays out of the list whatever that last read says: a recorder a moment behind
    /// itself, whose next list still has it, does not bring it back; and a read the recorder turns down takes
    /// nothing back -- the delete is done, and the read's refusal is what is left on screen.
    ///
    /// The line is looked at here only while the write itself is out; while the lists are read, by the test
    /// after this one.
    func testADeleteOrAChangeThatGoesThroughIsReadBack() async throws {
        let (_, recorder, model) = try await connectedHome()
        // The change to one that can still be changed; the three deletes to any other the app put in.
        let changed = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let deleted = try ReservationWrite.rows(of: model, atLeast: 4, toDelete: true).filter { $0.id != changed.id }
        let rows = [deleted[0], changed, deleted[1], deleted[2]]

        for (write, row) in zip(ReservationWrite.allCases, rows) {
            let found = await model.program(for: row)
            let program = try XCTUnwrap(found, "the reservation follows no programme of the guide")
            let count = await recorder.heard.count
            await recorder.hold(only: write.rawValue)
            let asking = Task { await write.ask(model, row) }
            try await until("\(write.name) never got to the recorder") {
                await recorder.heard(since: count).contains(write.rawValue)
            }

            expectEqual(await recorder.heard(since: count), [Kind.list, write.rawValue],
                        "the list was not read before \(write.name), or something else was asked")
            XCTAssertEqual(model.busy, write.line)
            XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with \(write.name) out")
            // Only once that is so: where it is not, the choice would go through, and what follows would wait
            // out its ten seconds on a recorder the model had left.
            if !model.canChangeRecorder {
                await model.adopt(host: Bench.otherHost)
                XCTAssertEqual(model.host, Bench.host, "another address was taken with \(write.name) out")
            }

            await recorder.letGo()
            expectTrue(await asking.value, "\(write.name): \(model.problem(for: .recorder) ?? "no reason given")")
            expectEqual(await recorder.heard(since: count), [Kind.list, write.rawValue, Kind.list],
                        "\(write.name) was sent again, or the list was not read after it")
            XCTAssertNil(model.problem(for: .recorder), write.name)
            XCTAssertNil(model.busy, write.name)
            let listed = model.reservations.first { $0.id == row.id }
            switch write {
            case .delete:
                XCTAssertNil(listed, "the deleted reservation is still listed")
                XCTAssertNil(model.reservation(for: program), "the guide still marks the programme as reserved")
            case .change:
                XCTAssertEqual(listed?.qualityCode, Codes.quality["ER"], "the change is not on screen")
            }
        }

        // A moment behind itself: the list it gives after the delete is the one from before it.
        await recorder.beAMomentBehind()
        expectTrue(await deleteAReservation(model, rows[2]), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertFalse(model.reservations.contains { $0.id == rows[2].id },
                       "a recorder a moment behind itself brought the deleted reservation back")

        // The read after the delete turned down. The read before it is let through first.
        await recorder.answer(Kind.list, with: .fault(402), after: 1)
        expectTrue(await deleteAReservation(model, rows[3]), "a read that failed took back the delete it followed")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.list))
        XCTAssertFalse(model.reservations.contains { $0.id == rows[3].id })
        XCTAssertTrue(model.connected)
    }

    /// One line for each thing the reader asks of the recorder, up from before its first read to after its last,
    /// as a television's: the reads a delete, a change and a reservation make on the way have none of their own,
    /// so 予約一覧を取得中 does not come up in the middle of one, and the recorder in play cannot be changed
    /// under it. The read before a delete and before a change is held; for a reservation, the read after the
    /// create, held only once the create has been heard, so that it is that read and no other.
    func testADeleteAChangeOrAReservationShowsItsOwnLineThroughItsReads() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let rows = try ReservationWrite.rows(of: model, atLeast: 2)

        for (write, row) in zip(ReservationWrite.allCases, rows) {
            let count = await recorder.heard.count
            await recorder.holdTheNext(Kind.list)
            let asking = Task { await write.ask(model, row) }
            try await until("the list was never read before \(write.name)") {
                await recorder.heard(since: count).contains(Kind.list)
            }
            XCTAssertEqual(model.busy, write.line, "the read before \(write.name) showed a line of its own")
            XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with \(write.name) under way")
            await recorder.letGo()
            expectTrue(await asking.value, "\(write.name): \(model.problem(for: .recorder) ?? "no reason given")")
            XCTAssertNil(model.busy, write.name)
        }

        let program = try await programmesNotReserved(model, 1)[0]
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.create)
        let reserving = Task { await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none") }
        try await until("the reservation never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.list)
        await recorder.letGo(only: Kind.create)
        try await until("the list was never read after the reservation") {
            await recorder.asked(Kind.list, since: before) == 1
        }
        XCTAssertEqual(model.busy, "予約を登録中", "the read after the reservation showed a line of its own, or none")
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with the reservation under way")
        await recorder.letGo()
        expectTrue(await reserving.value, model.problem(for: .recorder) ?? "no reason given")
        XCTAssertNotNil(model.reservation(for: program), "the programme is not marked as reserved")
        XCTAssertNil(model.busy)
    }

    /// A change the recorder answered as made, whose read after it is turned down: the change is done, the
    /// read's sentence is on the line, and the row on screen shows what was sent -- the mode and the repeat --
    /// in the list read before it, as a television's change shows what it sent.
    func testAChangeWhoseReadAfterFailsShowsWhatWasSent() async throws {
        let (_, recorder, model) = try await connectedHome()
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        XCTAssertNotEqual(row.repeatName, "daily", "the row was meant to be changed to a repeat it has not")
        let count = await recorder.heard.count
        // The read before the change is let through first.
        await recorder.answer(Kind.list, with: .fault(402), after: 1)

        expectEqual(await model.change(row, quality: "ER", repeating: "daily"), .done(saying: nil))
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.change, Kind.list])
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.list))
        let shown = try XCTUnwrap(model.reservations.first { $0.id == row.id }, "the row left the list")
        XCTAssertEqual(shown.qualityCode, Codes.quality["ER"], "the row on screen does not show the mode sent")
        XCTAssertEqual(shown.repeatName, "daily", "the row on screen does not show the repeat sent")
        XCTAssertEqual(shown.destination, row.destination)
    }

    /// A change the recorder answers as made is looked for in the list read after it, as a television's is. A
    /// recorder a moment behind itself, whose list after the change still has the reservation in the mode it had,
    /// has the change said not to show there, and the list on screen is the one read. A change of the repeat
    /// alone, the list after it a moment behind in the same way, is done: the repeat is not compared. A list after
    /// a change that no longer has the reservation has the reader sent to look at the recorder itself. Nothing is
    /// sent but the change and the reads either side of it.
    func testAChangeTheListAfterItDoesNotShowIsSaidSo() async throws {
        let (_, recorder, model) = try await connectedHome()
        let rows = try ReservationWrite.rows(of: model, atLeast: 2)
        let row = rows[0]
        let mode = try XCTUnwrap(row.qualityName), repeating = try XCTUnwrap(row.repeatName)
        let otherMode = mode == "ER" ? "SR" : "ER", otherRepeat = repeating == "daily" ? "none" : "daily"

        var count = await recorder.heard.count
        await recorder.beAMomentBehind()
        expectEqual(await model.change(row, quality: otherMode, repeating: repeating),
                    .notDone(Said.changeNotReflected))
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.change, Kind.list])
        XCTAssertEqual(model.reservations.first { $0.id == row.id }?.qualityCode, row.qualityCode,
                       "the list on screen is not the one read after the change")

        // The change went through all the same: the next list has it.
        await model.loadReservations()
        let changed = try XCTUnwrap(model.reservations.first { $0.id == row.id })
        XCTAssertEqual(changed.qualityName, otherMode)
        count = await recorder.heard.count
        await recorder.beAMomentBehind()
        expectEqual(await model.change(changed, quality: otherMode, repeating: otherRepeat), .done(saying: nil))
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.change, Kind.list])

        // The read before the change is let through first.
        count = await recorder.heard.count
        await recorder.answer(Kind.list, with: .result(""), after: 1)
        expectEqual(await model.change(rows[1], quality: rows[1].qualityName == "ER" ? "SR" : "ER",
                                       repeating: try XCTUnwrap(rows[1].repeatName)),
                    .notDone(Said.goneAfterAChange))
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.change, Kind.list])
        XCTAssertTrue(model.reservations.isEmpty, "the list on screen is not the one read after the change")
        XCTAssertNil(model.problem(for: .recorder))
    }

    /// What keeps a delete or a change from being sent, and what is said of each. A reservation that is not in
    /// the list just read has gone -- deleted on the recorder's own screen -- and the list on screen is the new
    /// one. A read before it that meets silence ends it there, under the read's sentence. Known to be away after
    /// that, not even the list is asked for, and the app says it is not connected. A change to a mode the tables
    /// do not know reads the list, and then sends nothing and says nothing.
    ///
    /// Each says it in its result alone, and leaves the line as the read before it or an earlier operation left
    /// it; with no recorder in hand each says that the app is not connected.
    func testADeleteOrAChangeThatCannotBeSentSaysWhyAndSendsNothing() async throws {
        let (_, recorder, model) = try await connectedHome()
        let rows = try ReservationWrite.rows(of: model, atLeast: 3)
        let kept = rows[2]

        for (write, gone) in zip(ReservationWrite.allCases, rows) {
            // Deleted on the recorder's own screen since the app read its list.
            try await aClient(of: recorder).deleteReservation(id: gone.id)
            var count = await recorder.heard.count
            expectEqual(await write.result(model, gone), .notDone(Said.gone), write.name)
            XCTAssertNil(model.problem(for: .recorder), write.name)
            expectEqual(await recorder.heard(since: count), [Kind.list],
                        "\(write.name) was sent for a reservation the recorder no longer lists")
            XCTAssertFalse(model.reservations.contains { $0.id == gone.id },
                           "the list on screen is not the one just read")

            // Silence on the read before it.
            count = await recorder.heard.count
            await recorder.goQuiet(on: Kind.list)
            expectFalse(await write.ask(model, kept), write.name)
            XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, write.name)
            expectEqual(await recorder.heard(since: count), [Kind.list],
                        "\(write.name) was sent after a read that met silence")
            XCTAssertTrue(model.gaveUp, write.name)

            // And from then on the recorder is known to be away.
            leaveALine(on: model)
            count = await recorder.heard.count
            expectEqual(await write.result(model, kept), .notDone(Said.notConnected), write.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, write.name)
            expectEqual(await recorder.heard(since: count), [], "a recorder known to be away was asked")
            XCTAssertTrue(model.reservations.contains(kept), write.name)
            await reconnect(model)
        }

        var count = await recorder.heard.count
        expectFalse(await changeOnTheRecorder(model, kept, quality: "知らない画質", repeating: "none"))
        expectEqual(await recorder.heard(since: count), [Kind.list], "a change to a mode nobody knows was sent")
        XCTAssertNil(model.problem(for: .recorder))

        // No recorder in hand: the address is taken away, which lets go of the recorder and connects to nothing.
        await model.adopt(host: "")
        leaveALine(on: model)
        count = await recorder.heard.count
        for write in ReservationWrite.allCases {
            expectEqual(await write.result(model, kept), .notDone(Said.notConnected), write.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(write.name) said something, with no recorder")
        }
        expectEqual(await recorder.heard(since: count), [], "a recorder the app had let go of was asked")
    }

    /// A change of a reservation the recorder is recording, or whose end has passed, is turned away at its door
    /// with nothing asked, and its result says why; the line stays as an earlier operation left it. The demo's
    /// one being recorded, as the list read it; one of the app's moved, on the phone, to have ended an hour ago.
    /// And the rule is asked again of the row the read before the change finds: the one being recorded, held
    /// on the phone as though it were not, reads the list, which says it is, and goes no further, its result
    /// saying so and the read having cleared the line.
    func testAChangeOfAReservationBeingRecordedOrOverIsTurnedAwayAndNothingIsAsked() async throws {
        let (_, recorder, model) = try await connectedHome()
        let recording = try XCTUnwrap(model.reservations.first { $0.recording }, "the demo records nothing")
        var over = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        over.start = Date() - TimeInterval(over.durationSec) - 3_600

        let turnedAway = [("being recorded", recording, Said.changeRecording), ("over", over, Said.changeEnded)]
        for (name, row, why) in turnedAway {
            leaveALine(on: model)
            let count = await recorder.heard.count
            expectEqual(await model.change(row, quality: "ER", repeating: "none"), .notDone(why), name)
            expectEqual(await recorder.heard(since: count), [], "a change of a reservation \(name) asked something")
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a change of a reservation \(name) wrote the line")
        }

        var heldAsNotRecording = recording
        heldAsNotRecording.recording = false
        leaveALine(on: model)
        let count = await recorder.heard.count
        expectEqual(await model.change(heldAsNotRecording, quality: "ER", repeating: "none"),
                    .notDone(Said.changeRecording))
        expectEqual(await recorder.heard(since: count), [Kind.list],
                    "a change of a reservation the list says is being recorded was sent")
        XCTAssertNil(model.problem(for: .recorder), "the read before the change did not clear the line")
        XCTAssertTrue(model.reservations.contains { $0.id == recording.id && $0.recording },
                      "the list on screen is not the one just read")
    }

    /// The recorder renumbers the reservations its own automatic recording made, so a number read a while ago
    /// can be dead. A row whose number the recorder no longer has is found by its channel and its start in the
    /// list just read; the change is built from the row read and not from the one the screen held; and both
    /// writes go out under the number the recorder has now.
    ///
    /// The delete is looked for on the recorder itself as well as in the model's list. The bench's recorder
    /// takes a delete of a number it does not know for done, and the model takes the row out of its own list by
    /// hand, so a delete sent under the dead number would show in neither the answer nor the model.
    ///
    /// A number that still stands on another channel and another programme is not the row held: nothing is sent
    /// to it, the change is not done and says that the list has been updated, and the row of that number is as
    /// it was.
    ///
    /// The rows are the recorder's own, which are the ones it renumbers: two, since a change sent from here makes
    /// a row an app's on the demo's recorder, and the delete is asked of the other.
    func testAReservationTheRecorderHasRenumberedIsFoundByItsChannelAndStart() async throws {
        let (_, recorder, model) = try await connectedHome()
        // The one changed is one whose programme has not ended. The lists are looked at with the reservation being
        // recorded left out: the demo's began twenty minutes before the bench was made, and so at one second of
        // the day it stands at the channel and start of one of the recorder's own.
        let itsOwn = model.reservations.filter { $0.createdByRecorder && $0.eventID != nil && !$0.recording }
        let row = try XCTUnwrap(itsOwn.first { $0.end > Date() },
                                "the demo was meant to hold a reservation of the recorder's own still to end")
        let other = try XCTUnwrap(itsOwn.first { $0.id != row.id },
                                  "the demo was meant to hold two of the recorder's own")
        // What a list has at the row's channel and start, which is where a renumbered reservation is found.
        func there(_ list: [Reservation]) -> [Reservation] {
            list.filter {
                $0.broadcastingType == row.broadcastingType && $0.serviceID == row.serviceID && $0.start == row.start
                    && !$0.recording
            }
        }
        // The row as a screen holds it from an earlier read: under a number the recorder no longer has, and
        // with a title of its own, which tells what was built from this row from what was built from the one
        // just read.
        var stale = row
        stale.id = "0x00000000000fffff"
        stale.title = "読んだときの題名"

        var count = await recorder.heard.count
        expectTrue(await changeOnTheRecorder(model, stale, quality: "ER", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.change, Kind.list])
        var held = there(model.reservations)
        XCTAssertEqual(held.map(\.id), [row.id], "the change went out under the number the screen held")
        XCTAssertEqual(held.first?.qualityCode, Codes.quality["ER"])
        XCTAssertEqual(held.first?.title, row.title, "the change was built from the row the screen held")
        XCTAssertEqual(held.first?.eventID, row.eventID)

        // A number that still stands, on a row that is otherwise another's.
        var odd = try XCTUnwrap(held.first)
        odd.serviceID += 1
        odd.eventID = odd.eventID.map { $0 + 1 }
        count = await recorder.heard.count
        expectEqual(await model.change(odd, quality: "SR", repeating: "none"), .notDone(Said.renumbered),
                    "a change went to a number that now stands on another programme")
        expectEqual(await recorder.heard(since: count), [Kind.list])
        XCTAssertNil(model.problem(for: .recorder), "the change wrote its result on the line")
        held = there(model.reservations)
        XCTAssertEqual(held.map(\.id), [row.id])
        XCTAssertEqual(held.first?.qualityCode, Codes.quality["ER"], "the row of that number was changed")

        // The other, as a screen holds it from an earlier read, and what a list has at its channel and start.
        var otherStale = other
        otherStale.id = "0x00000000000ffffe"
        func whereTheOtherIs(_ list: [Reservation]) -> [Reservation] {
            list.filter {
                $0.broadcastingType == other.broadcastingType && $0.serviceID == other.serviceID
                    && $0.start == other.start && !$0.recording
            }
        }
        count = await recorder.heard.count
        expectTrue(await deleteAReservation(model, otherStale), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.delete, Kind.list])
        XCTAssertTrue(whereTheOtherIs(model.reservations).isEmpty)
        let onTheRecorder = try await aClient(of: recorder).reservations()
        XCTAssertTrue(whereTheOtherIs(onTheRecorder).isEmpty,
                      "the delete went out under the number the screen held, and the recorder still records it")
    }

    /// The reader's own reservation, made by an app, deleted on the recorder's own screen since the app read its
    /// list; and in the list read before a delete or a change, the recorder's own reservation of the same
    /// programme at the same start, under a number of its own. The recorder has not been seen to renumber what an
    /// app made, so the reader's has gone: nothing is sent to the recorder's own, and the result says the
    /// reservation was not found in the list just read, and the line, which the read cleared, does not.
    func testAReservationDeletedOnTheRecorderIsNotTakenForTheRecordersOwnOfItsProgramme() async throws {
        let (_, recorder, model) = try await connectedHome()
        let mine = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        XCTAssertTrue(mine.createdByApp, "the reader's reservation was meant to be one an app made")
        let request = ReservationRequest(title: mine.title, start: mine.start, durationSec: mine.durationSec,
                                         repeatCode: mine.repeatCode, broadcastingType: mine.broadcastingType,
                                         serviceID: mine.serviceID, qualityCode: mine.qualityCode,
                                         eventID: mine.eventID, destination: mine.destination)
        let itsOwn = XsrsElements.update(id: "0x00000000000b11ff", request)
            .replacingOccurrences(of: "</item></xsrs>",
                                  with: "<reservationCreatorID>1100</reservationCreatorID></item></xsrs>")

        for write in ReservationWrite.allCases {
            await recorder.answer(Kind.list, with: .result(itsOwn))
            let count = await recorder.heard.count
            expectEqual(await write.result(model, mine), .notDone(Said.gone), write.name)
            expectEqual(await recorder.heard(since: count), [Kind.list],
                        "\(write.name) went to the recorder's own reservation of the programme")
            XCTAssertNil(model.problem(for: .recorder), write.name)
            XCTAssertEqual(model.reservations.map(\.id), ["0x00000000000b11ff"],
                           "the list on screen is not the one just read")
        }
    }

    /// A recorder that turns a delete or a change down. A refusal with a code of its own is said in the
    /// recorder's words, and nothing is read after it. 804 -- it has no reservation of that number, though the
    /// list just read had one -- has the list read again, and is said in the app's own sentence. Either way
    /// nothing is sent a second time, the recorder is kept and the list is as it was.
    ///
    /// When the read after the 804 is itself turned down, the list has not been updated, and the read's own
    /// sentence is what is left on the line. Each is said in the result; the 804 settled by a read that went
    /// through is said there alone, that read having cleared the line.
    func testADeleteOrAChangeTheRecorderTurnsDownIsSaidAndNotSentAgain() async throws {
        let (_, recorder, model) = try await connectedHome()
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let listed = model.reservations

        for write in ReservationWrite.allCases {
            let cases: [(code: Int, readTurnedDown: Bool, line: String, heard: [String])] = [
                (402, false, Said.fault(402, write.rawValue), [Kind.list, write.rawValue]),
                (804, false, Said.renumbered, [Kind.list, write.rawValue, Kind.list]),
                (804, true, Said.fault(402, Kind.list), [Kind.list, write.rawValue, Kind.list]),
            ]
            for (code, readTurnedDown, line, heard) in cases {
                let what = "\(write.name) answered \(code)" + (readTurnedDown ? ", and the read after it 402" : "")
                let count = await recorder.heard.count
                await recorder.answer(write.rawValue, with: .fault(code))
                // The read before the write is let through first.
                if readTurnedDown { await recorder.answer(Kind.list, with: .fault(402), after: 1) }
                expectEqual(await write.result(model, row), .notDone(line), what)

                XCTAssertEqual(model.problem(for: .recorder), code == 804 && !readTurnedDown ? nil : line, what)
                expectEqual(await recorder.heard(since: count), heard, what)
                XCTAssertTrue(model.connected, "a refusal was taken for the recorder going: \(what)")
                XCTAssertFalse(model.gaveUp, what)
                XCTAssertEqual(model.reservations, listed, what)
                XCTAssertNil(model.busy, what)
            }
        }
    }

    /// Silence at the write itself. Whether it arrived is not known, so the app says it may have, gives up on
    /// the recorder, sends nothing again and reads nothing after it. The row stays on screen.
    ///
    /// The same when a connect to the same recorder was made while the write was out: the connect makes a
    /// client of its own and reads the list, and the write's silence still loses the recorder. Whatever comes
    /// to ask whether the recorder was let go of meanwhile has to leave both halves as they are: nothing was
    /// let go of.
    func testADeleteOrAChangeThatMeetsSilenceIsNotSentAgain() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let listed = model.reservations

        for write in ReservationWrite.allCases {
            for reconnects in [false, true] {
                let what = write.name + (reconnects ? ", with a connect made beside it" : "")
                let before = await recorder.asked
                let count = await recorder.heard.count
                await recorder.hold(only: write.rawValue)
                let asking = Task { await write.ask(model, row) }
                try await until("\(what): it never got to the recorder") {
                    await recorder.asked(write.rawValue, since: before) == 1
                }
                if reconnects {
                    let made = bench.clientsMade
                    await reconnect(model)
                    // What this half stands on, rather than what it holds: with the write's own client still
                    // in hand, it would say nothing more than the half before it.
                    XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
                }
                await recorder.goQuiet(on: write.rawValue)
                await recorder.letGo()
                expectFalse(await asking.value, what)

                XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived, what)
                XCTAssertTrue(model.gaveUp, "silence on \(what) did not leave the app given up")
                XCTAssertTrue(model.offline, what)
                expectEqual(await recorder.asked(write.rawValue, since: before), 1, "\(what) was sent again")
                if !reconnects {
                    expectEqual(await recorder.heard(since: count), [Kind.list, write.rawValue],
                                "the list was asked of a recorder that had just gone silent, after \(what)")
                }
                XCTAssertEqual(model.reservations, listed, what)
                XCTAssertNil(model.busy, what)
                await reconnect(model)
            }
        }
    }

    /// Silence is said once, as a television's: a pull-down's read asked for while a delete is out waits its
    /// turn behind the delete in the client's queue, and when the delete has met silence that read meets it
    /// too. It leaves what the delete said -- that it may have arrived, which is all the reader has to go by
    /// -- where it is, and sends nothing more.
    func testAReadBehindAWriteThatMetSilenceLeavesWhatTheWriteSaid() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.delete)
        let deleting = Task { await deleteAReservation(model, row) }
        try await until("the delete never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.delete)
        }
        let pulling = Task { await model.refreshReservations() }
        try await until("the pull-down's read was never asked for") { model.busy == "予約一覧を取得中" }
        // Long enough for that read to be waiting its turn behind the delete.
        try await Task.sleep(for: .milliseconds(300))
        // Silent to the delete held, and to the read after it.
        await recorder.goQuiet(for: 2)
        await recorder.letGo()
        expectFalse(await deleting.value, "a delete that met silence was taken for done")
        await pulling.value

        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.delete, Kind.list],
                    "the pull-down's read did not wait behind the delete, or something more was sent")
        XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived,
                       "the read's silence was said over what the delete's said")
        XCTAssertTrue(model.gaveUp)
        XCTAssertNil(model.busy)
    }

    /// The same at the connect asked for after it: a write that met silence says that it may have arrived, and
    /// the connect wakes the recorder, which answers the waking only to fall silent again in the attach after
    /// it. Neither the waking, as it begins, nor the attach that met silence writes over that sentence.
    func testAWakingAndAnAttachAfterAWriteThatMetSilenceLeaveWhatTheWriteSaid() async throws {
        let (_, recorder, model) = try await connectedHome(wakeable: true)
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        await recorder.goQuiet(on: Kind.delete)
        expectFalse(await deleteAReservation(model, row), "a delete that met silence was taken for done")
        XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived)
        XCTAssertTrue(model.gaveUp)

        // Silent to the connect's first ask, answering the waking's, and silent again inside the attach.
        let before = await recorder.asked
        await recorder.goQuiet(for: 1)
        await recorder.goQuiet(on: Kind.firmware)
        await model.connect()

        expectEqual(await recorder.asked(Kind.firmware, since: before), 1,
                    "the attach after the waking never got as far as the firmware")
        XCTAssertFalse(model.connected, "the recorder was meant to fall silent in the attach after the waking")
        XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived,
                       "the waking or the attach after it wrote over what the delete said")
        XCTAssertTrue(model.gaveUp)
    }

    /// A delete or a change whose read is out when a connect finds the same recorder at another address -- the
    /// router has handed it another lease -- with a client of its own. The write goes out once, on that client,
    /// and nothing more goes to the address the recorder left. Each reads the recorder's client again after its
    /// read rather than keep the one it had in hand when it was asked for: one kept would send to an address
    /// the recorder no longer answers at, or, after a connect at the same address, out of line with the
    /// connect's own client, whose queue it does not share, to a recorder that answers 503 to two at once.
    ///
    /// As it is today, and to stay: a later change that moves these writes has to read the client after the
    /// read as they do here.
    ///
    /// The address is moved by hand, where the search that finds the recorder elsewhere would move it: the
    /// choice of another address waits while the read's line is up (`canChangeRecorder`), and on the bench that
    /// search has no LAN to look round. Then 再接続 is asked for, as the reader does.
    func testADeleteOrAChangeGoesOutOnTheClientOfAConnectMadeWhileItsReadWasOut() async throws {
        for write in ReservationWrite.allCases {
            let bench = try aBench()
            try await bench.cacheAGuide()
            // The same recorder at either address: the one it had, and the one the router moved it to.
            let (left, found) = (NamedRecorder(1), NamedRecorder(1))
            let model = bench.model(recorders: [Bench.host: left, Bench.otherHost: found])
            addTeardownBlock { await left.letGo() }
            await model.start()
            try await untilConnected(model)
            let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
            let count = await left.heard.count
            await left.hold(only: Kind.list)
            let asking = Task { await write.ask(model, row) }
            try await until("\(write.name): its read never got to the recorder") {
                await left.heard(since: count).contains(Kind.list)
            }

            let made = bench.clientsMade
            model.host = Bench.otherHost
            await reconnect(model)
            // What this stands on, rather than what it holds: without a client made at the other address, the
            // client read after the read and the one in hand before it would ask the same recorder, and could
            // not be told apart.
            XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
            XCTAssertEqual(model.info?.host, Bench.otherHost, "the recorder was meant to answer at the other address")
            await left.letGo()
            expectTrue(await asking.value, "\(write.name): \(model.problem(for: .recorder) ?? "no reason given")")

            expectEqual(await left.heard(since: count), [Kind.list],
                        "\(write.name) went out on the client in hand before its read")
            expectEqual(await found.asked(write.rawValue), 1,
                        "\(write.name) did not go out once on the client the connect made")
        }
    }

    /// A delete out, its list read, when another recorder answers a connect beside it: the newcomer's arrival
    /// empties the lists in that turn, and the connect reads its reservations. The delete, on the recorder it
    /// began with, is then turned down, and what the reader has on screen afterwards is the newcomer's list --
    /// a reservation the newcomer holds and the first recorder never had among it -- and not the list the delete
    /// read before the newcomer arrived. The answer is no, under the refusal's sentence.
    ///
    /// As it is today, and to stay: a later change has whoever keeps a list read on an operation's behalf keep
    /// it only while the recorder the operation began with is still the one in play, and the newcomer's list is
    /// what is left on screen then as now.
    func testAWriteOutAcrossAnotherRecordersConnectLeavesTheNewcomersListOnScreen() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let program = try await programmesNotReserved(model, 1)[0]
        let forgotten = model.timesForgotten
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.delete)
        let deleting = Task { await deleteAReservation(model, row) }
        try await until("the delete never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.delete)
        }
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.delete])

        await recorder.become(2)
        // Made on the newcomer from its own screen, so that its list is not the one the delete read.
        try await aClient(of: recorder).create(try XCTUnwrap(ReservationRequest(program: program, quality: "DR",
                                                                                 repeating: "none")))
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertGreaterThan(model.timesForgotten, forgotten, "the lists were meant to go as the newcomer arrived")
        await recorder.answer(Kind.delete, with: .fault(402))
        await recorder.letGo()

        expectFalse(await deleting.value, "a delete the recorder turned down is said to have been done")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.delete))
        let listed = try await aClient(of: recorder).reservations()
        XCTAssertEqual(model.reservations, listed, "the list on screen is not the newcomer's")
        XCTAssertNotNil(model.reservation(for: program), "the list on screen is the one read before the newcomer")
    }

    /// A delete out when another recorder answers a connect beside it, and then taken: the row is not taken out
    /// of the newcomer's list, which may hold another row under the same number, and the list read after the
    /// delete is not put over it. The list on screen stays the one the newcomer's connect read.
    ///
    /// The bench's recorder answers as the newcomer from the same rows, so the row deleted is in the list the
    /// connect read, under the same number.
    func testADeleteTakenAcrossAnotherRecordersConnectLeavesTheNewcomersListAsItWasRead() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let forgotten = model.timesForgotten
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.delete)
        let deleting = Task { await deleteAReservation(model, row) }
        try await until("the delete never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.delete)
        }

        await recorder.become(2)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertGreaterThan(model.timesForgotten, forgotten, "the lists were meant to go as the newcomer arrived")
        let newcomers = model.reservations
        XCTAssertTrue(newcomers.contains { $0.id == row.id }, "the newcomer's list holds nothing under that number")
        await recorder.letGo()

        expectTrue(await deleting.value, model.problem(for: .recorder) ?? "no reason given")
        let listed = try await aClient(of: recorder).reservations()
        XCTAssertFalse(listed.contains { $0.id == row.id }, "the delete was not taken")
        XCTAssertEqual(model.reservations, newcomers,
                       "the delete for the recorder let go of changed the newcomer's list on screen")
    }

    /// A delete or a change whose read is out when another recorder answers a connect beside it. The write was
    /// asked of the recorder let go of, and nothing goes to the newcomer, whether or not a row of the same number
    /// is in its list: the delete is not done, and the change is not done and says that another recorder
    /// answered. Neither writes on the line, not even that the row has gone.
    ///
    /// The bench's recorder answers the held read as the newcomer, from the same rows, so the row asked for is in
    /// the list that read comes back with and in the one the connect read -- unless it is deleted on the
    /// newcomer's own screen first.
    func testAWriteWhoseReadIsOutWhenAnotherRecorderAnswersSendsItNothing() async throws {
        for write in ReservationWrite.allCases {
            for newcomerHoldsIt in [true, false] {
                let what = write.name + (newcomerHoldsIt ? "" : ", of a number the newcomer does not hold")
                let (_, recorder, model) = try await connectedHome()
                addTeardownBlock { await recorder.letGo() }
                let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
                let before = await recorder.asked
                await recorder.holdTheNext(Kind.list)
                let deleting = write == .delete ? Task { await deleteAReservation(model, row) } : nil
                let changing = write == .change
                    ? Task { await model.change(row, quality: "ER", repeating: "none") } : nil
                try await until("\(what): its read never got to the recorder") {
                    await recorder.asked(Kind.list, since: before) == 1
                }

                await recorder.become(2)
                if !newcomerHoldsIt { try await aClient(of: recorder).deleteReservation(id: row.id) }
                // Counted from here: that delete was the newcomer's own screen's.
                let sent = await recorder.asked
                await model.connect()
                XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2),
                               model.problem(for: .recorder) ?? "no reason given")
                XCTAssertEqual(model.reservations.contains { $0.id == row.id }, newcomerHoldsIt,
                               "the newcomer's list was meant to be so: \(what)")
                leaveALine(on: model)
                await recorder.letGo()

                if let deleting {
                    expectFalse(await deleting.value, "a delete asked of the recorder let go of went to the newcomer")
                }
                if let changing {
                    expectEqual(await changing.value, .notDone(Said.anotherAnswered), what)
                }
                expectEqual(await recorder.asked(write.rawValue, since: sent), 0, "\(what) was sent")
                XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(what) wrote on the newcomer's line")
            }
        }
    }

    /// A delete or a change out when another recorder answers a connect beside it, and then met by silence. What
    /// was sent may have arrived, and that is said, as for any write that meets silence; but the silence was the
    /// recorder let go of's, and the newcomer is neither lost nor given up on.
    func testAWritesSilenceBesideAnotherRecordersArrivalIsSaidAndLosesNobody() async throws {
        for write in ReservationWrite.allCases {
            let (_, recorder, model) = try await connectedHome()
            addTeardownBlock { await recorder.letGo() }
            let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
            let before = await recorder.asked
            await recorder.hold(only: write.rawValue)
            let asking = Task { await write.ask(model, row) }
            try await until("\(write.name) never got to the recorder") {
                await recorder.asked(write.rawValue, since: before) == 1
            }

            await recorder.become(2)
            await model.connect()
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
            await recorder.goQuiet(on: write.rawValue)
            await recorder.letGo()

            expectFalse(await asking.value, write.name)
            XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived, write.name)
            XCTAssertFalse(model.gaveUp, "silence on \(write.name) for the recorder let go of gave the newcomer up")
            XCTAssertTrue(model.connected, write.name)
            expectEqual(await recorder.asked(write.rawValue, since: before), 1, "\(write.name) was sent again")
        }
    }

    /// A delete or a change out when another recorder answers a connect beside it, and then taken. The line is
    /// the newcomer's by then, and what is on it -- here a line an earlier operation left -- is not cleared by a
    /// write that went through on the recorder let go of.
    func testAWriteTakenBesideAnotherRecordersArrivalLeavesTheNewcomersLine() async throws {
        for write in ReservationWrite.allCases {
            let (_, recorder, model) = try await connectedHome()
            addTeardownBlock { await recorder.letGo() }
            let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
            let before = await recorder.asked
            await recorder.hold(only: write.rawValue)
            let asking = Task { await write.ask(model, row) }
            try await until("\(write.name) never got to the recorder") {
                await recorder.asked(write.rawValue, since: before) == 1
            }

            await recorder.become(2)
            await model.connect()
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
            leaveALine(on: model)
            await recorder.letGo()

            expectTrue(await asking.value, "\(write.name) was meant to be taken")
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(write.name) cleared the newcomer's line")
        }
    }

    /// A read of the list out when another recorder answers a connect beside it: the newcomer's arrival empties
    /// the lists in that turn, and the connect reads its reservations, its own read going through while the first
    /// is held. The first read, asked for the recorder let go of, comes back afterwards and is not put over the
    /// newcomer's list, which is what the reader has on screen. A list read on an operation's behalf is kept only
    /// while the recorder the operation began with is still the one in play, as the television's host keeps its
    /// lists.
    ///
    /// The bench's recorder answers the held read as the newcomer, once a reservation has been made on the
    /// newcomer's own screen, so that what it read can be told from what the connect read.
    func testAListReadAcrossAnotherRecordersArrivalIsNotPutOverTheNewcomers() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let program = try await programmesNotReserved(model, 1)[0]
        let forgotten = model.timesForgotten
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.list)
        let reading = Task { await model.loadReservations() }
        try await until("the list was never asked for") {
            await recorder.asked(Kind.list, since: before) == 1
        }

        await recorder.become(2)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertGreaterThan(model.timesForgotten, forgotten, "the lists were meant to go as the newcomer arrived")
        let newcomers = model.reservations
        XCTAssertFalse(newcomers.isEmpty, "the newcomer's connect did not put its list on screen")
        // Made on the newcomer from its own screen, so that the list the held read comes back with is not the
        // one the connect read.
        try await aClient(of: recorder).create(try XCTUnwrap(ReservationRequest(program: program, quality: "DR",
                                                                                 repeating: "none")))
        await recorder.letGo()
        await reading.value

        expectEqual(await recorder.asked(Kind.list, since: before), 2, "a list was read again after the held one")
        XCTAssertEqual(model.reservations, newcomers,
                       "the list read for the recorder let go of was put over the newcomer's")
        XCTAssertNil(model.reservation(for: program), "the list on screen is the one read for the recorder let go of")
    }

    /// Reads of the list asked for together go as one request, as a television's do: a read asked for while
    /// one is out, for the same recorder, gets that one's answer, and the recorder is asked for its list once.
    /// Both come back with the list, which is the one on screen. (A read asked for once another recorder has
    /// answered does not join one out for the recorder let go of: the gate above.)
    func testReadsOfTheListAskedForTogetherGoAsOneRequest() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.list)
        let first = Task { await model.loadReservations(since: model.timesForgotten) }
        try await until("the list was never asked for") {
            await recorder.asked(Kind.list, since: before) == 1
        }
        let second = Task { await model.loadReservations(since: model.timesForgotten) }
        // Long enough for the second read to be asked for while the first is out.
        try await Task.sleep(for: .milliseconds(300))
        await recorder.letGo()
        let (one, two) = (await first.value, await second.value)

        expectEqual(await recorder.asked(Kind.list, since: before), 1, "the second read went as a request of its own")
        let list = try XCTUnwrap(one, "the first read came back with no list")
        XCTAssertEqual(two, list, "the second read did not come back with the list")
        XCTAssertEqual(model.reservations, list)
    }

    /// The same for a reservation: made on the recorder in play, whose list is read again once the create has
    /// been answered, and another recorder answers a connect while that read is out. The newcomer's arrival
    /// empties the lists in that turn and its connect reads its own. The list the reservation read comes back
    /// afterwards and is not put over the newcomer's, by the rule a read's list is kept by.
    ///
    /// The read is held only once the create has been heard, so that it is the read after the create and no
    /// read before it. The bench's recorder answers it as the newcomer, once a reservation has been made on the
    /// newcomer's own screen, so that what it read can be told from what the connect read.
    func testAReservationMadeAcrossAnotherRecordersArrivalLeavesTheNewcomersList() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let programs = try await programmesNotReserved(model, 2)
        let forgotten = model.timesForgotten
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.create)
        let reserving = Task { await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none") }
        try await until("the reservation never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.list)
        await recorder.letGo(only: Kind.create)
        try await until("the list was never read after the reservation") {
            await recorder.asked(Kind.list, since: before) == 1
        }

        await recorder.become(2)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertGreaterThan(model.timesForgotten, forgotten, "the lists were meant to go as the newcomer arrived")
        let newcomers = model.reservations
        XCTAssertFalse(newcomers.isEmpty, "the newcomer's connect did not put its list on screen")
        // Made on the newcomer from its own screen, so that the list the held read comes back with is not the
        // one the connect read.
        try await aClient(of: recorder).create(try XCTUnwrap(ReservationRequest(program: programs[1], quality: "DR",
                                                                                 repeating: "none")))
        await recorder.letGo()
        _ = await reserving.value

        XCTAssertEqual(model.reservations, newcomers,
                       "the list read after the reservation for the recorder let go of was put over the newcomer's")
        XCTAssertNil(model.reservation(for: programs[1]),
                     "the list on screen is the one read after the reservation for the recorder let go of")
    }

    /// A reservation whose create is out when another recorder answers a connect beside it, and is then met by
    /// silence. It may have been made on the recorder let go of: the answer and the line say so, as for a delete
    /// or a change whose silence came beside such an arrival, and the newcomer is neither lost nor given up on.
    /// Nothing is kept for whichever recorder answers next -- the row is taken out, as for any reservation across
    /// such an arrival -- and nothing is created on the newcomer, then or at the pull-down after.
    func testAReservationWhoseCreateMetSilenceBesideAnotherRecordersArrivalSaysItMayHaveArrived() async throws {
        let (bench, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.hold(only: Kind.create)
        let reserving = Task { await model.reserve(program, on: .recorder, quality: "DR", repeating: "none") }
        try await until("the reservation never got to the recorder") {
            await recorder.asked(Kind.create, since: before) == 1
        }

        await recorder.become(2)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        await recorder.goQuiet(on: Kind.create)
        await recorder.letGo()
        let came = await reserving.value
        try await untilIdle(model)

        XCTAssertEqual(came, .notDone(Said.mayHaveArrived))
        XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived, "the silence was not said on the line")
        XCTAssertFalse(model.gaveUp, "silence at the create for the recorder let go of gave the newcomer up")
        XCTAssertTrue(model.connected)
        expectEqual(try await store.pendingReservations(), [],
                    "the reservation waits for the recorder that answered next")
        XCTAssertNil(model.pending(for: program, on: .recorder), "the reservation is shown as waiting")
        await model.refreshReservations()
        try await untilIdle(model)
        expectEqual(await recorder.asked(Kind.create, since: before), 1, "the reservation was sent again")
    }

    /// A reservation asked for while the check before it is out, and the recorder let go of before the check
    /// answers: another address has been chosen, and the connect to it is under way. The check then meets
    /// silence where it asked. Nothing was sent, and the reservation is not kept either -- kept, it would wait as
    /// one made for the recorder let go of, and go to whichever answers that connect -- and nothing is created at
    /// either address.
    ///
    /// No MAC is kept, so that the silence ends the check at once: a waking given up on ends it the same way,
    /// half a minute later.
    func testAReservationWhoseRecorderIsLetGoOfWhileItIsMadeSureOfIsNotKept() async throws {
        try await reservingAcrossALetGo { await $0.goQuiet(on: Kind.description) }
    }

    /// The same when the check is answered busy with somebody else, through both tries after the first, where
    /// it asked: it has not heard which recorder answers, so nothing is sent, and the reservation is not kept
    /// either, the recorder having been let go of meanwhile.
    func testAReservationWhoseRecorderIsLetGoOfBeforeItsCheckHeardItBusyIsNotKept() async throws {
        try await reservingAcrossALetGo { await $0.beBusy(with: Kind.description) }
    }

    /// Asks for a reservation while the check before it is out on the recorder at `Bench.host`, lets go of that
    /// recorder and connects to `Bench.otherHost`, as a choice of another address does (`adopt`), and then has the
    /// first recorder answer the check as `answer` sets it to, while a second recorder at the other address holds
    /// the connect's first ask. The reservation is not done, nothing is kept, on screen or on the phone, and once
    /// the connect is over nothing has been created on either recorder.
    ///
    /// The recorder is let go of by hand: the screens hold the choice back while the check is out
    /// (`canChangeRecorder`), and what is pinned is what the reservation does however the recorder was let go of.
    private func reservingAcrossALetGo(_ answer: @escaping (NamedRecorder) async -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let (first, second) = (NamedRecorder(1), NamedRecorder(2))
        let model = bench.model(recorders: [Bench.host: first, Bench.otherHost: second])
        addTeardownBlock {
            await first.letGo()
            await second.letGo()
        }
        await model.start()
        try await untilConnected(model)
        let program = try await programmesNotReserved(model, 1)[0]

        let asked = await first.asked(Kind.description)
        await first.hold(only: Kind.description)
        let checking = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") { await first.asked(Kind.description) > asked }
        let reserving = Task { await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none") }
        try await until("the reservation was never begun") { model.busy != nil }
        model.forgetTheRecorder()
        model.host = Bench.otherHost
        await second.hold(only: Kind.description)
        let connecting = Task { await model.connect() }
        try await until("the other address was never asked") { await second.asked(Kind.description) == 1 }
        await answer(first)
        await first.letGo()
        _ = await checking.value
        // Bounded: a reservation sent on reads its list on the connect's client, behind the ask held there.
        let reserved = try await within(10, "the reservation never ended") { await reserving.value }
        await second.letGo()
        await connecting.value

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2),
                       "the connect to the other address was meant to go through", file: file, line: line)
        XCTAssertFalse(reserved, "the sheet would close as though the programme were reserved",
                       file: file, line: line)
        XCTAssertNil(keptJustNow(model), "kept for the recorder let go of", file: file, line: line)
        XCTAssertNil(model.pending(for: program), "shown as waiting", file: file, line: line)
        expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty, "kept on the phone",
                   file: file, line: line)
        expectEqual(await first.asked(Kind.create), 0, "created on the recorder let go of", file: file, line: line)
        expectEqual(await second.asked(Kind.create), 0, "created on the recorder at the other address",
                    file: file, line: line)
    }

    /// A delete or a change goes only from a list read now, as a television's does. A read the recorder turned
    /// down -- with a fault, or busy through both tries after the first -- leaves the app not offline, and the
    /// row is in the list on screen; nothing is sent all the same. The answer is no, the read's sentence is on
    /// the line, the recorder is kept, and the list on screen is as it was.
    func testADeleteOrAChangeAfterAReadThatWasTurnedDownSendsNothing() async throws {
        let (_, recorder, model) = try await connectedHome()
        let rows = try ReservationWrite.rows(of: model, atLeast: 2)
        let listed = model.reservations

        var count = await recorder.heard.count
        await recorder.answer(Kind.list, with: .fault(402))
        expectFalse(await deleteAReservation(model, rows[0]), "a delete went out after a read that was turned down")
        expectEqual(await recorder.heard(since: count), [Kind.list])
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.list))
        XCTAssertEqual(model.reservations, listed)

        count = await recorder.heard.count
        await recorder.beBusy(with: Kind.list)
        expectFalse(await changeOnTheRecorder(model, rows[1], quality: "ER", repeating: "none"),
                    "a change went out after a read that was turned down")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.list, Kind.list])
        XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.list))
        XCTAssertEqual(model.reservations, listed)
        XCTAssertTrue(model.connected)
    }

    /// A recorder that answered the connect busy with somebody else, and so never said which it is, is not
    /// offline: its list is read, as any that answered. Nothing is written to it: a reservation is kept on the
    /// phone, to go once it has said which it is, and a change and a delete of a reservation it lists say in
    /// their results that the app is not connected, with nothing sent and the line as the connect left it.
    /// (What waits in the queue does not go to such a recorder
    /// either: `SessionRuleTests`.)
    func testARecorderThatHasNotSaidWhichItIsIsReadFromAndNotWrittenTo() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = NamedRecorder(1)
        await recorder.busyAtTheDoor()
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await until("the first connect never ended") {
            !isConnecting(model) && model.problem(for: .recorder) != nil
        }
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.offline, "it answered, so the screens do not take it for gone")
        XCTAssertTrue(model.reservations.isEmpty)
        let before = await recorder.asked

        await model.loadReservations()
        XCTAssertFalse(model.reservations.isEmpty, "the list of a recorder that has not said which it is was not read")
        let program = try await programmesNotReserved(model, 1)[0]
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(keptJustNow(model)?.request.eventID, program.eventID, "the reservation was not kept")
        XCTAssertNotNil(model.pending(for: program), "the reservation kept is not shown as waiting")
        let listed = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let line = model.problem(for: .recorder)
        expectEqual(await model.change(listed, quality: "ER", repeating: "none"), .notDone(Said.notConnected),
                    "the change said something else")
        expectEqual(await model.cancel(listed), .notDone(Said.notConnected), "the delete said something else")
        XCTAssertEqual(model.problem(for: .recorder), line, "the change or the delete wrote the line")

        for kind in [Kind.create, Kind.change, Kind.delete] {
            expectEqual(await recorder.asked(kind, since: before), 0, kind)
        }
        expectEqual(await recorder.asked(Kind.description, since: before), 0, "it was asked again who it is")
        XCTAssertFalse(model.connected)

        // Silence from it is silence all the same: it is lost and given up on, and the line says so, as for
        // a recorder the app was connected to.
        await recorder.goQuiet(on: Kind.list)
        await model.loadReservations()
        XCTAssertTrue(model.offline, "silence from a recorder that has not said which it is did not lose it")
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
    }

    /// A connect under way has a client of its own, which has not yet heard which recorder answers it, while the
    /// app is still connected from the attach before. Nothing the reader asks for meanwhile is written on that
    /// client: a reservation is kept on the phone -- and the connect's own sending makes it, once the recorder
    /// has said which it is -- and a change and a delete say that the app is not connected, with nothing read
    /// or sent for them. The list is read as ever, on that client, once it has its turn. The connect's question
    /// of who answers is held, to keep it under way.
    func testNothingIsWrittenOnAConnectsClientBeforeTheRecorderHasSaidWhichItIs() async throws {
        let (bench, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let program = try await programmesNotReserved(model, 1)[0]
        let rows = try ReservationWrite.rows(of: model, atLeast: 2)
        let before = await recorder.asked
        let made = bench.clientsMade
        await recorder.hold(only: Kind.description)
        let connecting = Task { await model.connect() }
        try await until("the connect never asked who answers") {
            await recorder.asked(Kind.description, since: before) == 1
        }
        // What this stands on, rather than what it holds: a client more, its connect under way, the app still
        // connected from the attach before.
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        XCTAssertTrue(isConnecting(model))
        XCTAssertTrue(model.connected)

        let forgotten = model.timesForgotten
        let reading = Task { await model.loadReservations(since: forgotten) }
        let reserved = try await within(5, "the reservation waited for the connect") {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none")
        }
        let changed = try await within(5, "the change waited for the connect") {
            await model.change(rows[0], quality: "ER", repeating: "none")
        }
        let deleted = try await within(5, "the delete waited for the connect") {
            await deleteAReservation(model, rows[1])
        }
        await recorder.letGo()
        await connecting.value
        let read = await reading.value

        guard case .waiting(let row, _) = reserved else {
            return XCTFail("a reservation asked for during a connect was not kept: \(reserved)")
        }
        XCTAssertEqual(row.request.eventID, program.eventID)
        XCTAssertEqual(changed, .notDone(Said.notConnected))
        XCTAssertFalse(deleted, "a delete asked for during a connect went through")
        XCTAssertNotNil(read, "the list was not read on the connect's client")
        XCTAssertTrue(model.connected, model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.asked(Kind.change, since: before), 0, "the change was sent")
        expectEqual(await recorder.asked(Kind.delete, since: before), 0, "the delete was sent")
        expectEqual(await recorder.asked(Kind.create, since: before), 1,
                    "the reservation kept was not made once, by the connect's sending")
        XCTAssertNil(model.pending(for: program), "the reservation kept still waits after the connect")
        XCTAssertNotNil(model.reservation(for: program))
    }

    /// The one answer of the check before an operation that leaves the recorder neither connected nor offline.
    /// It says nothing to the check, is woken, and is then busy with somebody else as the waking's attach asks
    /// who it is: there, without having said which it is, and the check's answer is no. A reservation asked for
    /// meanwhile is queued unsent, and what the attach said stays on the line over it. A delete asked for
    /// meanwhile is not sent either: its read was not made, and nothing goes after a read that did not go
    /// through. What the attach said stays on the line over it too.
    func testACheckThatWokeTheRecorderOnlyToBeTurnedAwayQueuesAReservationAndSendsNoDelete() async throws {
        do {
            let (bench, recorder, model) = try await connectedHome(wakeable: true)
            let program = try await programmesNotReserved(model, 1)[0]
            let (kept, heard) = try await duringACheckTurnedAwayAfterAWaking(by: model, of: recorder) {
                await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none")
            }
            XCTAssertTrue(kept, model.problem(for: .recorder) ?? "no reason given")
            XCTAssertEqual(heard, [], "something was sent after a check that said no")
            XCTAssertNotNil(model.pending(for: program), "the reservation is not shown as waiting")
            XCTAssertEqual(keptJustNow(model)?.request.eventID, program.eventID)
            expectEqual(try await GuideStore(path: bench.guidePath).pendingReservations().map(\.request.eventID),
                        [program.eventID])
            XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.description),
                           "what the attach said was taken away by a reservation kept")
        }
        do {
            let (_, recorder, model) = try await connectedHome(wakeable: true)
            let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
            let (deleted, heard) = try await duringACheckTurnedAwayAfterAWaking(by: model, of: recorder) {
                await deleteAReservation(model, row)
            }
            XCTAssertFalse(deleted, "a delete was sent to a recorder that had not said which it is")
            XCTAssertEqual(heard, [], "something was sent after a check that said no")
            XCTAssertTrue(model.reservations.contains { $0.id == row.id }, "the reservation left the list")
            XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.description),
                           "what the attach said was written over by the delete")
        }
    }

    /// Asks `something` of the model while the check before an operation is out, and has that check end the one
    /// way that leaves the recorder there and not connected to: silent to the check's own ask, answering the
    /// first ask of the waking that follows -- so that nothing waits a second for it to come up -- and then busy
    /// with somebody else, through both tries after the first, as the waking's attach asks who it is. What
    /// `something` came to, and what the recorder was asked from the check on besides who it is.
    private func duringACheckTurnedAwayAfterAWaking<T: Sendable>(by model: AppModel, of recorder: NamedRecorder,
                                                                 _ something: @escaping @MainActor () async -> T)
        async throws -> (came: T, heard: [String]) {
        await recorder.hold(only: Kind.description)
        let before = await recorder.asked
        let count = await recorder.heard.count
        let check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") {
            await recorder.asked(Kind.description, since: before) == 1
        }
        let asking = Task { await something() }
        try await until("what was asked for was never begun") { model.busy != nil }
        await recorder.goQuiet(on: Kind.description)
        await recorder.answer(Kind.description, with: .status(503), times: 3, after: 1)
        await recorder.letGo()
        let there = await check.value
        let came = await asking.value

        XCTAssertFalse(there, "a recorder that turned the attach away was taken for one to ask")
        XCTAssertFalse(model.connected, "the recorder was meant not to have said which it is")
        XCTAssertFalse(model.offline, "the recorder was meant to have answered, if only as busy")
        return (came, await recorder.heard(since: count).filter { $0 != Kind.description })
    }

    /// A check before an operation whose question of who answers is answered busy with somebody else, through
    /// both tries after the first, has not heard which recorder answers, and nothing is written on its strength
    /// until a check hears it say which it is. The check writes nothing on the line itself: the question of
    /// what a reservation would clash with goes on after it, as ever, is answered, and leaves the line as it
    /// was. What is stopped says what the check heard: a delete and a change send nothing -- not the read
    /// before them either, which fails with it -- and each checks again, however lately the recorder answered;
    /// a reservation is kept on the phone; a pull-down's read fails with it and what waits is not sent; and
    /// 「もう一度送る」 sends nothing. Once the recorder is free, the next check hears it and what waits goes.
    func testNothingIsWrittenAfterACheckThatHeardTheRecorderBusy() async throws {
        let (_, recorder, model) = try await connectedHome()
        let rows = try ReservationWrite.rows(of: model, atLeast: 2)
        let programs = try await programmesNotReserved(model, 2)
        let busy = Said.busy(Kind.description)
        await recorder.busyAtTheDoor()

        // The check, made whatever the time since the last answer, and the clash check after it.
        leaveALine(on: model)
        var before = await recorder.asked
        expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
        expectEqual(await recorder.asked(Kind.description, since: before), 3, "the check did not ask who answers")
        let clashes = await model.conflicts(for: programs[1], quality: "DR", repeating: "none")
        XCTAssertNotNil(clashes, "the clash check was not answered after a check that heard the recorder busy")
        expectEqual(await recorder.asked(Kind.clashes, since: before), 1)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the check or the clash check wrote on the line")

        // A delete, twice: each checks again within the minute and a half, and nothing is read or sent.
        for attempt in ["the first delete", "the second delete"] {
            leaveALine(on: model)
            before = await recorder.asked
            expectFalse(await deleteAReservation(model, rows[0]), "\(attempt) went through")
            XCTAssertEqual(model.problem(for: .recorder), busy, attempt)
            expectEqual(await recorder.asked(Kind.description, since: before), 3, "\(attempt) did not check again")
            expectEqual(await recorder.asked(Kind.list, since: before), 0, "\(attempt) read the list")
            expectEqual(await recorder.asked(Kind.delete, since: before), 0, "\(attempt) was sent")
        }

        // A change.
        leaveALine(on: model)
        before = await recorder.asked
        expectEqual(await model.change(rows[1], quality: "ER", repeating: "none"), .notDone(busy))
        XCTAssertEqual(model.problem(for: .recorder), busy)
        expectEqual(await recorder.asked(Kind.list, since: before), 0, "the change read the list")
        expectEqual(await recorder.asked(Kind.change, since: before), 0, "the change was sent")

        // A reservation, kept.
        leaveALine(on: model)
        before = await recorder.asked
        let came = await model.reserve(programs[0], on: .recorder, quality: "DR", repeating: "none")
        guard case .waiting(let kept, _) = came else {
            return XCTFail("a reservation asked after a check that heard the recorder busy was not kept: \(came)")
        }
        XCTAssertEqual(model.problem(for: .recorder), busy, "the reservation kept did not say what the check heard")
        XCTAssertEqual(model.pending(for: programs[0])?.id, kept.id)
        expectEqual(await recorder.asked(Kind.create, since: before), 0, "the reservation was sent")

        // A pull-down, and the row kept sent again.
        leaveALine(on: model)
        before = await recorder.asked
        await model.refreshReservations()
        XCTAssertEqual(model.problem(for: .recorder), busy)
        leaveALine(on: model)
        await model.resend(kept)
        XCTAssertEqual(model.problem(for: .recorder), busy, "sending it again did not say what the check heard")
        expectEqual(await recorder.asked(Kind.create, since: before), 0, "what waits was sent")
        XCTAssertNotNil(model.pending(for: programs[0]), "the reservation kept no longer waits")

        // Free again: the pull-down's check hears it say which it is, and what waits goes.
        await recorder.comeFree()
        before = await recorder.asked
        await model.refreshReservations()
        expectEqual(await recorder.asked(Kind.create, since: before), 1, model.problem(for: .recorder) ?? "")
        XCTAssertNil(model.pending(for: programs[0]))
        XCTAssertNotNil(model.reservation(for: programs[0]))
    }

    // MARK: - how old the list is

    /// Since when the recorder's list on screen is old, for the screens to say so, as a television's: not while
    /// the recorder can be asked, since the list is then read as a screen appears; not while a connect to a
    /// recorder that answered last time is under way; and from when it was read once nothing can be asked of the
    /// recorder -- given up on after silence, or connected from the attach before a reconnect it answered busy,
    /// without saying which it is. A delete turned down unread leaves the list and its time; a pull-down that
    /// connects and reads it again makes it new.
    func testTheRecordersListSaysHowOldItIsWhileTheRecorderCannotBeAsked() async throws {
        let (_, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        XCTAssertFalse(model.reservations.isEmpty, "the demo was meant to list reservations")
        let read = try XCTUnwrap(model.reservationsRead, "the list the connect read has no time")
        XCTAssertNil(model.reservationsStaleSince, "the list of a recorder that can be asked is said to be old")

        // A connect again, to the recorder that answered last time: the list is not old while it is out.
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.description)
        let connecting = Task { await model.connect() }
        try await until("the connect was never out") {
            await recorder.heard(since: count).contains(Kind.description)
        }
        XCTAssertNil(model.reservationsStaleSince, "a connect to a recorder that answered last time made its list old")
        await recorder.letGo()
        await connecting.value
        XCTAssertNil(model.reservationsStaleSince)
        let reread = try XCTUnwrap(model.reservationsRead)
        XCTAssertGreaterThan(reread, read, "the list the connect read again has the old time")

        // Given up on after silence. A delete is turned down with nothing read, which its result says and the line
        // does not, and the list stands with its time.
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model), "a recorder that said nothing was taken for one to ask")
        XCTAssertTrue(model.gaveUp)
        let listed = model.reservations
        XCTAssertEqual(model.reservationsStaleSince, reread, "the list a recorder given up on left is not old")
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        expectEqual(await model.cancel(row), .notDone(Said.notConnected))
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertEqual(model.reservations, listed, "a delete turned down unread took the list")
        XCTAssertEqual(model.reservationsRead, reread, "a delete turned down unread counts as a read")
        XCTAssertEqual(model.reservationsStaleSince, reread)

        // Pulled down: connected to, and read again.
        await model.refreshReservations()
        XCTAssertTrue(model.connected, model.problem(for: .recorder) ?? "no reason given")
        XCTAssertNil(model.reservationsStaleSince)
        let back = try XCTUnwrap(model.reservationsRead)
        XCTAssertGreaterThan(back, reread, "the list read after the recorder came back has the old time")

        // A reconnect it answers busy as it is asked which it is: connected from the attach before, and nothing
        // can be asked of it.
        await recorder.busyAtTheDoor()
        await model.connect()
        XCTAssertTrue(model.connected, "the recorder was meant to stay connected from the attach before")
        XCTAssertFalse(model.offline, "the recorder was meant to have answered, if only as busy")
        XCTAssertEqual(model.reservationsStaleSince, back,
                       "the list of a recorder whose reconnect was answered busy is not said to be old")
    }

    // MARK: - what would clash, and a reservation made

    /// The question of what a reservation would clash with, asked as a programme's sheet opens. It hands back
    /// what the recorder found and leaves the failure line as it was: nobody has asked for anything yet. A mode
    /// the tables do not know asks nothing. A fault is said, with the recorder kept; silence loses it, under the
    /// read's sentence; and once it is known to be away nothing is asked and nothing said.
    ///
    /// The demo's recorder finds no clash, whatever it is asked, so one answer here is the test's own, with a
    /// reservation in it: an answer that was read can then be told from none.
    func testAskingWhatWouldClashSaysWhatWentWrongAndClearsNothing() async throws {
        let (_, recorder, model) = try await connectedHome()
        let program = try await aProgramme(model)
        func clashes(with quality: String = "DR") async -> [Reservation]? {
            await model.conflicts(for: program, quality: quality, repeating: "none")
        }

        leaveALine(on: model)
        var count = await recorder.heard.count
        expectEqual(await clashes(), [], "the recorder found no clash, and the app says otherwise")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the question cleared a failure nobody had read")
        expectEqual(await recorder.heard(since: count), [Kind.clashes])

        // A reservation at the programme's own hour, as the recorder lists one.
        let clash = "サンプル特番「重なる時間」"
        let item = "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\"><item id=\"0x00000000000a94ff\">"
            + "<title>\(clash)</title>"
            + "<scheduledStartDateTime>\(RecorderTime.format(program.start))</scheduledStartDateTime>"
            + "<scheduledDuration>1800</scheduledDuration></item></xsrs>"
        await recorder.answer(Kind.clashes, with: .result(item))
        expectEqual(await clashes()?.map(\.title), [clash], "what the recorder found was not handed back")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)

        count = await recorder.heard.count
        expectNil(await clashes(with: "知らない画質"))
        expectEqual(await recorder.heard(since: count), [], "a mode nobody knows was asked about")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)

        await recorder.answer(Kind.clashes, with: .fault(402))
        expectNil(await clashes(), "a fault was read as an answer")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.clashes))
        XCTAssertTrue(model.connected, "a refusal was taken for the recorder going")

        await recorder.goQuiet(on: Kind.clashes)
        expectNil(await clashes())
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertTrue(model.gaveUp, "silence on the question did not leave the app given up")

        leaveALine(on: model)
        count = await recorder.heard.count
        expectNil(await clashes())
        expectEqual(await recorder.heard(since: count), [], "a recorder known to be away was asked")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
    }

    /// A clash check out when a connect to the same recorder is made beside it. The connect makes a client of
    /// its own, and the check's request, out on the client before it, then meets silence. That silence is not
    /// taken for the recorder's: the answer is none, the app stays connected and is not given up on, and the
    /// line is left as it was after the connect -- what a client the model no longer holds ran into is not
    /// about the recorder in play.
    ///
    /// As it is today, and to stay: the check asks whether its client is still the one in hand. A later change
    /// that asks instead whether the recorder was let go of meanwhile has to answer this as it is answered
    /// here, since nothing was let go of.
    func testAClashCheckOutAcrossAConnectToTheSameRecorderSaysNothingOfItsSilence() async throws {
        let (bench, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let program = try await aProgramme(model)
        let before = await recorder.asked
        await recorder.hold(only: Kind.clashes)
        let asking = Task { await model.conflicts(for: program, quality: "DR", repeating: "none") }
        try await until("the clash check never got to the recorder") {
            await recorder.asked(Kind.clashes, since: before) == 1
        }

        let made = bench.clientsMade
        await reconnect(model)
        // What this stands on, rather than what it holds: with the check's own client still in hand, the
        // silence would be the recorder's.
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        // Left after the connect, whose attach cleared the line before it.
        leaveALine(on: model)
        await recorder.goQuiet(on: Kind.clashes)
        await recorder.letGo()

        expectNil(await asking.value, "a clash check that met silence handed back an answer")
        XCTAssertTrue(model.connected, "the silence of a client the model no longer holds lost the recorder")
        XCTAssertFalse(model.gaveUp, "the silence of a client the model no longer holds gave the recorder up")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft,
                       "the silence of a client the model no longer holds was said")
        expectEqual(await recorder.asked(Kind.clashes, since: before), 1, "the clash check was asked again")
    }

    /// A reservation made with the recorder there is kept on the phone first and sent as that one row, under a
    /// line of its own with the choice of another recorder held back: the list read as its round opens, the
    /// create once, then the list read back, and it is not said to be waiting. One the recorder does not make
    /// is kept, and none is sent twice: turned down with a code of its own -- 831, a channel the recorder
    /// cannot receive -- it waits with the recorder's words as its reason, for the reader; busy through both
    /// tries after the first, it waits with no reason, to go by itself; and one that went out and met silence
    /// may have been made all the same, so it waits held for the reader with the sentence the round writes on
    /// it, the whole of which is looked at here, and the recorder is lost. The line is left as it was by the
    /// refusal and by busy, as a television's round leaves it. A mode the tables do not know sends nothing and
    /// keeps nothing. Each is of the same programme, whose row waiting from the one before it replaces.
    func testAReservationTheRecorderTakesIsReadBackAndOneItDoesNotMakeIsKept() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let programmes = try await programmesNotReserved(model, 2)
        let (taken, refused) = (programmes[0], programmes[1])
        func reserve(_ program: GuideProgramRow, quality: String = "DR") async -> Bool {
            await reserveOnTheRecorder(model, program, quality: quality, repeating: "none")
        }
        func expectNothingWaits(_ what: String, line: UInt = #line) {
            XCTAssertNil(keptJustNow(model), "\(what) is said to be waiting", line: line)
            XCTAssertTrue(model.pending.isEmpty, "\(what) was queued", line: line)
        }
        // Kept on the phone, as the one row waiting, with `reason` on it or none.
        func expectKept(_ what: String, saying reason: String?, line: UInt = #line) {
            let kept = keptJustNow(model)
            XCTAssertNotNil(kept, "\(what) was not kept", line: line)
            XCTAssertEqual(kept?.problem, reason, "\(what) waits with another reason", line: line)
            XCTAssertEqual(model.pending.map(\.id), kept.map { [$0.id] } ?? [], "\(what) is not what waits", line: line)
        }

        var count = await recorder.heard.count
        await recorder.hold(only: Kind.create)
        let asking = Task { await reserve(taken) }
        try await until("the reservation never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.create])
        XCTAssertEqual(model.busy, "予約を登録中")
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with the reservation out")
        await recorder.letGo()
        expectTrue(await asking.value, model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.create, Kind.list],
                    "the reservation was sent again, or the list was not read after it")
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertNil(model.busy)
        expectNothingWaits("a reservation the recorder took")
        XCTAssertNotNil(model.reservation(for: taken), "the programme is not marked as reserved")

        count = await recorder.heard.count
        await recorder.answer(Kind.create, with: .fault(831))
        expectTrue(await reserve(refused))
        XCTAssertNil(model.problem(for: .recorder))
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.create], "something was read after a refusal")
        expectKept("a reservation the recorder refused", saying: Said.fault(831, Kind.create))
        XCTAssertTrue(model.connected)

        count = await recorder.heard.count
        await recorder.beBusy(with: Kind.create)
        expectTrue(await reserve(refused))
        XCTAssertNil(model.problem(for: .recorder))
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.create, Kind.create, Kind.create])
        expectKept("a reservation the recorder was too busy for", saying: nil)
        XCTAssertTrue(model.connected)

        leaveALine(on: model)
        count = await recorder.heard.count
        let waiting = model.pending
        expectFalse(await reserve(refused, quality: "知らない画質"))
        expectEqual(await recorder.heard(since: count), [], "a reservation in a mode nobody knows was sent")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        XCTAssertNil(keptJustNow(model), "a reservation in a mode nobody knows is said to be waiting")
        XCTAssertEqual(model.pending, waiting, "a reservation in a mode nobody knows was queued")

        count = await recorder.heard.count
        await recorder.goQuiet(on: Kind.create)
        expectTrue(await reserve(refused))
        XCTAssertEqual(model.problem(for: .recorder), Said.heldAfterSilence)
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.create],
                    "a reservation that met silence was sent again")
        XCTAssertTrue(model.gaveUp)
        expectKept("a reservation that may have arrived", saying: Said.heldAfterSilence)
        let onThePhone = try await GuideStore(path: bench.guidePath).pendingReservations()
        XCTAssertEqual(onThePhone.map(\.problem), [Said.heldAfterSilence])
        XCTAssertNil(model.reservation(for: refused))
    }

    /// A reservation or a change of the recorder's in a mode the tables do not know, which nothing can be built
    /// to send for, says so in its result, and leaves the line to the device. A reservation reads nothing before
    /// it gives up, so the line is the one an earlier operation left. A change reads the list first: when the
    /// recorder turns that read down, the change goes no further, and its result is the read's own sentence,
    /// which the read put on the line; when the read goes through, which clears the line, its result says that
    /// the mode cannot be sent, and the line stays clear.
    func testAReservationOrAChangeInAModeNobodyKnowsSaysSoInItsResult() async throws {
        let (_, recorder, model) = try await connectedHome()
        let program = try await programmesNotReserved(model, 1)[0]
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]

        leaveALine(on: model)
        var count = await recorder.heard.count
        expectEqual(await model.reserve(program, on: .recorder, quality: "知らない画質", repeating: "none"),
                    .notDone(Said.notInTheTables))
        expectEqual(await recorder.heard(since: count), [], "a reservation in a mode nobody knows was sent")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)

        await recorder.answer(Kind.list, with: .fault(402))
        count = await recorder.heard.count
        expectEqual(await model.change(row, quality: "知らない画質", repeating: "none"),
                    .notDone(Said.fault(402, Kind.list)), "a change that said nothing is not said by its read's line")
        expectEqual(await recorder.heard(since: count), [Kind.list], "a change in a mode nobody knows was sent")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.list))

        leaveALine(on: model)
        count = await recorder.heard.count
        expectEqual(await model.change(row, quality: "知らない画質", repeating: "none"), .notDone(Said.notInTheTables))
        expectEqual(await recorder.heard(since: count), [Kind.list], "a change in a mode nobody knows was sent")
        XCTAssertNil(model.problem(for: .recorder), "the read before the change did not clear the line")
    }
}

// MARK: - what the tests ask for

/// What the recorder is asked, as its fake on the bench names a kind of request. Named once: a name misspelt in
/// a test that looks for nothing having been asked would pass.
private enum Kind {
    /// The reservations' list, read before a delete or a change and after anything written.
    static let list = "X_GetRecordScheduleList"
    static let create = "X_CreateRecordSchedule"
    static let delete = ReservationWrite.delete.rawValue
    static let change = ReservationWrite.change.rawValue
    static let clashes = "X_GetConflictList"
    /// What a connect asks first, and the check before an operation.
    static let description = "description.xml"
    /// Read by every attach, after the description.
    static let firmware = "X_GetFirmwareVersion"
}

/// A delete or a change of one of the recorder's reservations, as a screen asks for it: each by what the
/// recorder is asked for it.
enum ReservationWrite: String, CaseIterable {
    case delete = "X_DeleteRecordSchedule"
    case change = "X_UpdateRecordSchedule"

    /// What a failure calls it.
    var name: String { self == .delete ? "the delete" : "the change" }

    /// What the strip says while it is out.
    var line: String { self == .delete ? "予約を削除中" : "予約を変更中" }

    /// Asks for it. The change asks for ER, a mode none of the demo's reservations has.
    @MainActor
    func ask(_ model: AppModel, _ row: Reservation) async -> Bool {
        switch self {
        case .delete: return await deleteAReservation(model, row)
        case .change: return await changeOnTheRecorder(model, row, quality: "ER", repeating: "none")
        }
    }

    /// Asks for it as `ask` does, and hands back what it came to, as the screen that asked says it.
    @MainActor
    func result(_ model: AppModel, _ row: Reservation) async -> Altered {
        switch self {
        case .delete: return await model.cancel(row)
        case .change: return await model.change(row, quality: "ER", repeating: "none")
        }
    }

    /// The recorder's reservations either can be asked of with nothing else in the way: the ones an app put in,
    /// which follow a programme and can still be changed -- not being recorded, and not over
    /// (`RecorderDriver.whyNot(changing:)`). Five in the demo, of which today's evening ones are over from their
    /// end until the demo's day turns at four; fewer than `count` ends the test. `toDelete`: for a delete alone,
    /// which nothing turns away for being over, any of the five that is not being recorded.
    @MainActor
    static func rows(of model: AppModel, atLeast count: Int, toDelete: Bool = false) throws -> [Reservation] {
        let rows = model.reservations.filter {
            $0.eventID != nil && !$0.createdByRecorder
                && (toDelete ? !$0.recording : RecorderDriver.whyNot(changing: $0) == nil)
        }
        return try XCTUnwrap(rows.count >= count ? rows : nil,
                             "the demo was meant to hold \(count) reservations to write to, and holds \(rows.count)")
    }
}
