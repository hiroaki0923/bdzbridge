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
    /// Which line is up while the lists are read is to change. The line is looked at only while the write
    /// itself is out, where it is the same before and after.
    func testADeleteOrAChangeThatGoesThroughIsReadBack() async throws {
        let (_, recorder, model) = try await connectedHome()
        let rows = try ReservationWrite.rows(of: model, atLeast: 4)

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
        expectTrue(await model.cancel(rows[2]), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertFalse(model.reservations.contains { $0.id == rows[2].id },
                       "a recorder a moment behind itself brought the deleted reservation back")

        // The read after the delete turned down. The read before it is let through first.
        await recorder.answer(Kind.list, with: .fault(402), after: 1)
        expectTrue(await model.cancel(rows[3]), "a read that failed took back the delete it followed")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.list))
        XCTAssertFalse(model.reservations.contains { $0.id == rows[3].id })
        XCTAssertTrue(model.connected)
    }

    /// What keeps a delete or a change from being sent, and what is said of each. A reservation that is not in
    /// the list just read has gone -- deleted on the recorder's own screen -- and the list on screen is the new
    /// one. A read before it that meets silence ends it there, under the read's sentence. Known to be away after
    /// that, not even the list is asked for, and the app says it is not connected. A change to a mode the tables
    /// do not know reads the list, and then sends nothing and says nothing.
    ///
    /// As it is today: with no recorder in hand both are false without a word, where a later change says why.
    func testADeleteOrAChangeThatCannotBeSentSaysWhyAndSendsNothing() async throws {
        let (_, recorder, model) = try await connectedHome()
        let rows = try ReservationWrite.rows(of: model, atLeast: 3)
        let kept = rows[2]

        for (write, gone) in zip(ReservationWrite.allCases, rows) {
            // Deleted on the recorder's own screen since the app read its list.
            try await aClient(of: recorder).deleteReservation(id: gone.id)
            var count = await recorder.heard.count
            expectFalse(await write.ask(model, gone), write.name)
            XCTAssertEqual(model.problem(for: .recorder), Said.gone, write.name)
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
            expectFalse(await write.ask(model, kept), write.name)
            XCTAssertEqual(model.problem(for: .recorder), Said.notConnected, write.name)
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
            expectFalse(await write.ask(model, kept), write.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(write.name) said something, with no recorder")
        }
        expectEqual(await recorder.heard(since: count), [], "a recorder the app had let go of was asked")
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
    /// As it is today: a number that still stands is taken at its word whatever else of the row differs --
    /// another channel, another programme. A later change sends nothing then, and says that the list has been
    /// updated.
    func testAReservationTheRecorderHasRenumberedIsFoundByItsChannelAndStart() async throws {
        let (_, recorder, model) = try await connectedHome()
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        // What a list has at the row's channel and start, which is where a renumbered reservation is found.
        func there(_ list: [Reservation]) -> [Reservation] {
            list.filter {
                $0.broadcastingType == row.broadcastingType && $0.serviceID == row.serviceID && $0.start == row.start
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
        expectTrue(await changeOnTheRecorder(model, odd, quality: "SR", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.change, Kind.list])
        held = there(model.reservations)
        XCTAssertEqual(held.map(\.id), [row.id])
        XCTAssertEqual(held.first?.qualityCode, Codes.quality["SR"], "the row of that number was not changed")

        count = await recorder.heard.count
        expectTrue(await model.cancel(stale), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.delete, Kind.list])
        XCTAssertTrue(there(model.reservations).isEmpty)
        let onTheRecorder = try await aClient(of: recorder).reservations()
        XCTAssertTrue(there(onTheRecorder).isEmpty,
                      "the delete went out under the number the screen held, and the recorder still records it")
    }

    /// A recorder that turns a delete or a change down. A refusal with a code of its own is said in the
    /// recorder's words, and nothing is read after it. 804 -- it has no reservation of that number, though the
    /// list just read had one -- has the list read again, and is said in the app's own sentence. Either way
    /// nothing is sent a second time, the recorder is kept and the list is as it was.
    ///
    /// As it is today: that sentence stands, saying the list has been updated, when the read after the 804 was
    /// itself turned down. A later change leaves the read's own sentence there.
    func testADeleteOrAChangeTheRecorderTurnsDownIsSaidAndNotSentAgain() async throws {
        let (_, recorder, model) = try await connectedHome()
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
        let listed = model.reservations

        for write in ReservationWrite.allCases {
            let cases: [(code: Int, readTurnedDown: Bool, line: String, heard: [String])] = [
                (402, false, Said.fault(402, write.rawValue), [Kind.list, write.rawValue]),
                (804, false, Said.renumbered, [Kind.list, write.rawValue, Kind.list]),
                (804, true, Said.renumbered, [Kind.list, write.rawValue, Kind.list]),
            ]
            for (code, readTurnedDown, line, heard) in cases {
                let what = "\(write.name) answered \(code)" + (readTurnedDown ? ", and the read after it 402" : "")
                let count = await recorder.heard.count
                await recorder.answer(write.rawValue, with: .fault(code))
                // The read before the write is let through first.
                if readTurnedDown { await recorder.answer(Kind.list, with: .fault(402), after: 1) }
                expectFalse(await write.ask(model, row), what)

                XCTAssertEqual(model.problem(for: .recorder), line, what)
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
        let deleting = Task { await model.cancel(row) }
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
        let deleting = Task { await model.cancel(row) }
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

    /// As it is today, and to be rewritten whole: only silence stops a write after the read before it. A
    /// read the recorder turned down -- with a fault, or busy through both tries after the first -- leaves the
    /// app not offline, so the reservation is looked for in the list in hand, and the write goes out. Afterwards
    /// the answer is no, under the read's sentence, and nothing is written.
    func testADeleteOrAChangeGoesOutFromTheListInHandWhenTheReadBeforeItIsTurnedDown() async throws {
        let (_, recorder, model) = try await connectedHome()
        let rows = try ReservationWrite.rows(of: model, atLeast: 2)

        var count = await recorder.heard.count
        await recorder.answer(Kind.list, with: .fault(402))
        expectTrue(await model.cancel(rows[0]), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.delete, Kind.list])
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertFalse(model.reservations.contains { $0.id == rows[0].id })

        count = await recorder.heard.count
        await recorder.beBusy(with: Kind.list)
        expectTrue(await changeOnTheRecorder(model, rows[1], quality: "ER", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.list, Kind.list, Kind.list, Kind.change, Kind.list])
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertEqual(model.reservations.first { $0.id == rows[1].id }?.qualityCode, Codes.quality["ER"])
    }

    /// As it is today, and to be rewritten: the reservations' operations ask whether the app is offline,
    /// not whether it is connected. A recorder that answered the connect busy with somebody else, and so never
    /// said which it is, is not offline: its list is read, and a reservation is made, changed and deleted on
    /// it, each sent once and none queued, with the app not connected throughout. (What waits in the queue does
    /// not go to such a recorder: `SessionRuleTests`.) Afterwards the reservation goes to the queue, and the
    /// change and the delete say that the app is not connected.
    func testARecorderThatHasNotSaidWhichItIsIsStillReadFromAndWrittenTo() async throws {
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
        XCTAssertNil(keptJustNow(model), "the reservation went to the queue")
        XCTAssertNil(model.pending(for: program))
        let made = try XCTUnwrap(model.reservation(for: program), "the programme is not marked as reserved")
        expectTrue(await changeOnTheRecorder(model, made, quality: "ER", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.qualityCode, Codes.quality["ER"])
        expectTrue(await model.cancel(made), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertNil(model.reservation(for: program))

        for kind in [Kind.create, Kind.change, Kind.delete] {
            expectEqual(await recorder.asked(kind, since: before), 1, kind)
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

    /// As it is today, and the delete's half to be rewritten: the one answer of the check before an
    /// operation that leaves the recorder neither connected nor offline. It says nothing to the check, is woken,
    /// and is then busy with somebody else as the waking's attach asks who it is: there, without having said
    /// which it is, and the check's answer is no. A reservation asked for meanwhile is queued unsent, and
    /// keeping it takes away what the attach had said -- as it is today: a later change leaves the device's
    /// line to the device. A delete asked for meanwhile is sent all the same: the
    /// read before it was not made, the app is not offline, and the reservation is found in the list in hand.
    func testACheckThatWokeTheRecorderOnlyToBeTurnedAwayQueuesAReservationAndStillSendsADelete() async throws {
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
            XCTAssertNil(model.problem(for: .recorder), "what the attach said stayed over a reservation kept")
        }
        do {
            let (_, recorder, model) = try await connectedHome(wakeable: true)
            let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]
            let (deleted, heard) = try await duringACheckTurnedAwayAfterAWaking(by: model, of: recorder) {
                await model.cancel(row)
            }
            XCTAssertTrue(deleted, model.problem(for: .recorder) ?? "no reason given")
            XCTAssertEqual(heard, [Kind.delete, Kind.list], "the delete was not the first thing sent after the check")
            XCTAssertFalse(model.reservations.contains { $0.id == row.id })
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

    /// A reservation made with the recorder there: sent once, under a line of its own with the choice of
    /// another recorder held back, then read back from the recorder's list, and not said to be waiting. A
    /// refusal with a code of its own -- 831, a channel the recorder cannot receive -- and busy through both
    /// tries after the first are said in the recorder's words and are not queued: only silence before anything
    /// was sent is. A mode the tables do not know sends nothing and keeps nothing. And one that went out and met
    /// silence may have been made all the same, so it is not queued either, and says so in a sentence of its
    /// own, the whole of which is looked at here.
    ///
    /// A television's routing is to come in front of this. The recorder's own way has to stay as it is here.
    func testAReservationTheRecorderTakesIsReadBackAndOneItTurnsDownIsNotQueued() async throws {
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

        var count = await recorder.heard.count
        await recorder.hold(only: Kind.create)
        let asking = Task { await reserve(taken) }
        try await until("the reservation never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        expectEqual(await recorder.heard(since: count), [Kind.create])
        XCTAssertEqual(model.busy, "予約を登録中")
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with the reservation out")
        await recorder.letGo()
        expectTrue(await asking.value, model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [Kind.create, Kind.list],
                    "the reservation was sent again, or the list was not read after it")
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertNil(model.busy)
        expectNothingWaits("a reservation the recorder took")
        XCTAssertNotNil(model.reservation(for: taken), "the programme is not marked as reserved")

        count = await recorder.heard.count
        await recorder.answer(Kind.create, with: .fault(831))
        expectFalse(await reserve(refused))
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(831, Kind.create))
        expectEqual(await recorder.heard(since: count), [Kind.create], "something was read after a refusal")
        expectNothingWaits("a reservation the recorder refused")
        XCTAssertTrue(model.connected)

        count = await recorder.heard.count
        await recorder.beBusy(with: Kind.create)
        expectFalse(await reserve(refused))
        XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.create))
        expectEqual(await recorder.heard(since: count), [Kind.create, Kind.create, Kind.create])
        expectNothingWaits("a reservation the recorder was too busy for")
        XCTAssertTrue(model.connected)

        leaveALine(on: model)
        count = await recorder.heard.count
        expectFalse(await reserve(refused, quality: "知らない画質"))
        expectEqual(await recorder.heard(since: count), [], "a reservation in a mode nobody knows was sent")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        expectNothingWaits("a reservation in a mode nobody knows")

        count = await recorder.heard.count
        await recorder.goQuiet(on: Kind.create)
        expectFalse(await reserve(refused))
        XCTAssertEqual(model.problem(for: .recorder), Said.reservationMayHaveArrived)
        expectEqual(await recorder.heard(since: count), [Kind.create], "a reservation that met silence was sent again")
        XCTAssertTrue(model.gaveUp)
        expectNothingWaits("a reservation that may have arrived")
        expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty)
        XCTAssertNil(model.reservation(for: refused))
    }

    /// What a reservation or a change of the recorder's says when it was not done and the recorder's own
    /// operation said nothing of why -- a mode the tables do not know, here -- is whatever the recorder's line
    /// holds as it ends. A reservation reads nothing before it gives up, so that is the line an earlier
    /// operation left. A change reads the list first, so it is the line that read left: the read's own
    /// sentence when the recorder turned it down -- the row is found in the list in hand all the same -- and
    /// when the read went through, which cleared the line, the words the sheet has for a recorder that
    /// returned an error.
    ///
    /// As it is today, and to be rewritten: a later change has each say a reason of its own, and leaves the
    /// line to the device.
    func testWhatTheRecordersResultSaysWhenItSaidNothingIsWhateverTheLineHolds() async throws {
        let (_, recorder, model) = try await connectedHome()
        let program = try await programmesNotReserved(model, 1)[0]
        let row = try ReservationWrite.rows(of: model, atLeast: 1)[0]

        leaveALine(on: model)
        var count = await recorder.heard.count
        expectEqual(await model.reserve(program, on: .recorder, quality: "知らない画質", repeating: "none"),
                    .notDone(lineLeft), "a reservation that said nothing is not said by the line an earlier one left")
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
        expectEqual(await model.change(row, quality: "知らない画質", repeating: "none"),
                    .notDone("レコーダーがエラーを返しました"),
                    "a change that said nothing, its read gone through, is not said in the sheet's own words")
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
        case .delete: return await model.cancel(row)
        case .change: return await changeOnTheRecorder(model, row, quality: "ER", repeating: "none")
        }
    }

    /// The recorder's reservations either can be asked of with nothing else in the way: the ones an app put in,
    /// which follow a programme and are not being recorded. Five in the demo; fewer than `count` ends the test.
    @MainActor
    static func rows(of model: AppModel, atLeast count: Int) throws -> [Reservation] {
        let rows = model.reservations.filter { $0.eventID != nil && !$0.createdByRecorder && !$0.recording }
        return try XCTUnwrap(rows.count >= count ? rows : nil,
                             "the demo was meant to hold \(count) reservations to write to, and holds \(rows.count)")
    }
}
