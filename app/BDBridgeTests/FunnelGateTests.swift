import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The one funnel the recorder's operations run through (`AppModel.run`), and the operations themselves, each
/// asked for as a screen asks for it: what is on screen while one is out, what silence, a refusal and not being
/// connected each leave behind, and what a check, a connect or another recorder beside one does to it.
///
/// These are gates rather than rules. The recorder's operations are to move out of the model and into
/// RecorderKit with the app behaving as it did, and each test here pins what the app does today, so that it can
/// be shown to do the same afterwards with the test's body unchanged. That includes behaviour nobody would
/// choose. Where a test holds something that is to be changed on purpose, it says so, and that change rewrites
/// it. So a test asks only what a screen asks and reads only what a screen reads, with the bench's own words
/// for the rest (`Said`, `leaveALine`, `makeSure`): where an operation lives can change under it.
///
/// The recorder is the bench's (`NamedRecorder`), told what to answer a request at a time. It is told just
/// before the operation that is to meet it, since a connect asks for some of the same things.
@MainActor
final class FunnelGateTests: XCTestCase {
    // MARK: - what the tests start from

    /// At home with the first recorder (`connectedHome`), its recordings and its keyword conditions read as
    /// their screens read them, and the subjects taken from what it said. Nothing in the cache unless a guide
    /// is asked for: only a test that needs a programme does.
    private func settled(guide: Bool = false) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel, subjects: Subjects) {
        let (bench, recorder, model) = try await connectedHome(guide: guide)
        await model.loadTitles()
        await model.loadRecorderRules()
        let idle = model.titles.filter { !$0.recording && !$0.protected }
        let two = try XCTUnwrap(idle.count >= 2 ? idle : nil, "the demo was meant to hold two recordings to write to")
        let rule = try XCTUnwrap(model.recorderRules.first, "the demo was meant to hold a keyword condition")
        return (bench, recorder, model, Subjects(title: two[0], spare: two[1], rule: rule))
    }

    // MARK: - an operation by itself

    /// While an operation's request is out the strip says what it is doing, a failure an earlier operation left
    /// is still on screen -- cleared on the way in, a failure nobody had read yet went with the very next request
    /// -- and the recorder in play cannot be changed, for another address or for the demo: what comes back would
    /// land on the screens of whichever came after. Once it has gone through, and only then, the failure is
    /// cleared. It went once, and the model holds what it did without reading again a list it can put right.
    ///
    /// The last step is as it is today: a condition the recorder no longer has is sent for deletion all the
    /// same, with nothing read first. A later change reads the list first and says so instead, which puts a
    /// read before every delete of a condition: the count of reads here and the rows that remove a condition
    /// in the two tests below go with it.
    func testEachOperationSaysWhatItIsDoingHoldsTheRecorderAndOnlySuccessClearsTheLine() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let atTheStart = await recorder.asked
        let room = try XCTUnwrap(model.storage?.free, "the recorder never said how much room it has")

        for row in Funnelled.all {
            leaveALine(on: model)
            let before = await recorder.asked
            await recorder.hold(only: row.kind)
            let asking = Task { await row.ask(model, subjects) }
            try await until("the recorder was never asked for \(row.name)") {
                await recorder.asked(row.kind, since: before) == 1
            }

            XCTAssertEqual(model.busy, row.line, row.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) cleared the line on its way in")
            XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with \(row.name) out")
            // Only once that is so: where it is not, either of these would go through, and every row after
            // this one would wait out its ten seconds on a recorder the model had left.
            if !model.canChangeRecorder {
                await model.adopt(host: Bench.otherHost)
                XCTAssertEqual(model.host, Bench.host, "another address was taken with \(row.name) out")
                await model.enterDemo()
                XCTAssertFalse(model.demo, "the demo was entered with \(row.name) out")
            }
            if row.kind == Kind.guide[0] { XCTAssertEqual(model.guideDownloads, 1) }

            await recorder.letGo()
            let answer = await asking.value
            XCTAssertNotEqual(answer, false, "\(row.name): \(model.problem(for: .recorder) ?? "no reason given")")
            XCTAssertNil(model.problem(for: .recorder), "\(row.name) went through and left an earlier failure up")
            XCTAssertNil(model.busy, row.name)
            XCTAssertTrue(model.canChangeRecorder, row.name)
            expectEqual(await recorder.asked(row.kind, since: before), 1, "\(row.name) was sent more than once")
            XCTAssertTrue(row.holds(model, subjects), "the model does not hold what \(row.name) did")
        }

        expectEqual(await recorder.asked(Kind.recordings, since: atTheStart), 1,
                    "the recordings were read again after a protect or a delete")
        expectEqual(await recorder.asked(Kind.conditions, since: atTheStart), 3,
                    "the conditions are read when asked for, after one is added and after one is removed")
        expectEqual(await recorder.asked(Kind.freeSpace, since: atTheStart), 2,
                    "the free space is read with the recordings and after a delete")
        XCTAssertGreaterThan(model.storage?.free ?? 0, room, "the room the deleted recording took is not shown")
        for file in Kind.guide { expectEqual(await recorder.asked(file, since: atTheStart), 1, file) }
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertFalse(model.needsPower)

        // The condition just removed, removed again: what the model answers is the demo's doing, which takes a
        // number it does not know for done, and is not looked at.
        let count = await recorder.heard.count
        _ = await removeACondition(model, subjects.rule)
        expectEqual(await recorder.heard(since: count), [Kind.removeCondition, Kind.conditions],
                    "a condition the recorder no longer has is sent once, with no read before it")
    }

    /// Silence on an operation's own request leaves the app given up, whatever was being asked, and nothing is
    /// sent again -- then, or once the recorder is back. What changes something on the recorder says that it may
    /// have arrived all the same, which is why it is not sent again; anything else says what a read that met
    /// silence says. A recording's protect and delete mark the recordings unread, so that the list is read once
    /// the recorder answers rather than guessed at; a condition's write is not followed by a read of a recorder
    /// that has just gone silent.
    ///
    /// The free space is read after a delete and with the list, and is only shown: silence on it loses the
    /// recorder like any other and fails neither. And a condition's delete that was turned down is followed by
    /// a read, whose silence is the newer thing to say.
    ///
    /// Playing, pausing, stopping and powering on say the read's sentence today, though each asks the recorder to
    /// do something. A later change counts them as sent, which is four rows' sentence here.
    func testSilenceOnAnOperationLosesTheRecorderAndSaysWhetherItMayHaveArrived() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let unread: Set = [Kind.changeRecording, Kind.deleteRecording]
        let conditionWrites: Set = [Kind.addCondition, Kind.removeCondition]

        for row in Funnelled.bySOAP {
            let lists = Lists(model)
            leaveALine(on: model)
            let before = await recorder.asked
            await recorder.goQuiet(on: row.kind)
            let answer = await row.ask(model, subjects)

            XCTAssertNotEqual(answer, true, row.name)
            XCTAssertTrue(model.gaveUp, "silence on \(row.name) did not leave the app given up")
            XCTAssertFalse(model.connected, row.name)
            XCTAssertNil(model.busy, row.name)
            expectEqual(await recorder.asked(row.kind, since: before), 1, "\(row.name) was sent again")
            XCTAssertEqual(model.problem(for: .recorder), row.sends ? Said.mayHaveArrived : Said.noAnswer, row.name)
            XCTAssertTrue(Lists(model) == lists, "\(row.name) met silence and a list changed")
            XCTAssertEqual(model.titlesLoaded, !unread.contains(row.kind), row.name)
            if row.kind == Kind.conditions { XCTAssertEqual(model.recorderRulesFailure, Said.noAnswer) }
            if conditionWrites.contains(row.kind) {
                expectEqual(await recorder.asked(Kind.conditions, since: before), 0,
                            "the conditions were asked of a recorder that had just gone silent, after \(row.name)")
            }
            XCTAssertFalse(model.needsPower, row.name)

            await reconnect(model)
            await model.loadTitles()
            // A connect reads the reservations itself, and the screens read their lists again.
            if !row.reads {
                expectEqual(await recorder.asked(row.kind, since: before), 1,
                            "\(row.name) was sent again once the recorder was back")
            }
        }

        // The free space after a delete.
        let storage = model.storage
        leaveALine(on: model)
        let before = await recorder.asked
        await recorder.goQuiet(on: Kind.freeSpace)
        expectTrue(await deleteARecording(model, subjects.spare),
                   "silence on the free space failed the delete it followed")
        XCTAssertFalse(model.titles.contains { $0.id == subjects.spare.id })
        XCTAssertTrue(model.titlesLoaded, "the list is marked unread after a delete that went through")
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertTrue(model.gaveUp, "silence on the free space was not taken for silence")
        XCTAssertEqual(model.storage?.free, storage?.free)
        XCTAssertEqual(model.storage?.total, storage?.total)
        expectEqual(await recorder.asked(Kind.deleteRecording, since: before), 1)

        // And with the list.
        await reconnect(model)
        leaveALine(on: model)
        await recorder.goQuiet(on: Kind.freeSpace)
        await model.loadTitles(force: true)
        XCTAssertTrue(model.titlesLoaded)
        XCTAssertFalse(model.titles.isEmpty)
        XCTAssertNil(model.problem(for: .recorder), "silence on the free space failed the read it followed")
        XCTAssertTrue(model.gaveUp)

        // A condition's delete turned down, and silence on the read that follows it.
        await reconnect(model)
        await model.loadRecorderRules()
        XCTAssertNil(model.recorderRulesFailure)
        await recorder.answer(Kind.removeCondition, with: .fault(402))
        await recorder.goQuiet(on: Kind.conditions)
        expectFalse(await removeACondition(model, subjects.rule))
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the refusal was put back over the newer silence")
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.recorderRulesFailure, Said.noAnswer)
    }

    /// A recorder that answers and refuses is there: what it said is on screen in its own words, the app is
    /// still connected, nothing is sent again and the lists are as they were. Busy through both tries after the
    /// first is said as busy. An answer that cannot be read is said too, and loses nothing.
    ///
    /// A condition's delete that is refused has the list read again all the same -- the recorder renumbers a
    /// condition whenever its own screen edits one -- and its reason put back over the read's success, since
    /// the reason is what the screen shows; an add that is refused reads nothing. A recording still being
    /// written is turned down before anything is sent, which the delete says in what it hands back, the line
    /// left as it was. And a recorder that will not say how much room it has,
    /// after a delete, leaves the delete done and the room unknown.
    ///
    /// Where the sentence of an answer that cannot be read is put may change: it is not the recorder's.
    func testARefusalIsSaidAndTheRecorderIsKept() async throws {
        let (_, recorder, model, subjects) = try await settled()

        for row in Funnelled.bySOAP {
            let lists = Lists(model)
            leaveALine(on: model)
            let before = await recorder.asked
            await recorder.answer(row.kind, with: .fault(402))
            let answer = await row.ask(model, subjects)

            let refusal = Said.fault(402, row.kind)
            XCTAssertNotEqual(answer, true, row.name)
            XCTAssertTrue(model.connected, "a refusal of \(row.name) was taken for the recorder going")
            XCTAssertFalse(model.gaveUp, row.name)
            XCTAssertNil(model.busy, row.name)
            XCTAssertEqual(model.problem(for: .recorder), refusal, row.name)
            expectEqual(await recorder.asked(row.kind, since: before), 1, "\(row.name) was sent again")
            XCTAssertTrue(Lists(model) == lists, "\(row.name) was refused and a list changed")
            XCTAssertTrue(model.titlesLoaded, row.name)
            switch row.kind {
            case Kind.conditions:
                XCTAssertEqual(model.recorderRulesFailure, refusal)
            case Kind.addCondition:
                expectEqual(await recorder.asked(Kind.conditions, since: before), 0, "read after an add refused")
            case Kind.removeCondition:
                expectEqual(await recorder.asked(Kind.conditions, since: before), 1, "not read after a delete refused")
                XCTAssertNil(model.recorderRulesFailure, "the list was read, and its screen says it was not")
                XCTAssertTrue(model.recorderRules.contains { $0.id == subjects.rule.id })
            case Kind.deleteRecording:
                expectEqual(await recorder.asked(Kind.freeSpace, since: before), 0, "read after a delete refused")
            default:
                break
            }
        }

        // Busy with somebody else for the whole of one call.
        leaveALine(on: model)
        var before = await recorder.asked
        await recorder.beBusy(with: Kind.deleteRecording)
        expectFalse(await deleteARecording(model, subjects.spare))
        XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.deleteRecording))
        expectEqual(await recorder.asked(Kind.deleteRecording, since: before), 3)
        XCTAssertTrue(model.connected)

        // An answer that is no list. What is said of it is the error as Swift describes it, and is not compared.
        let reservations = model.reservations
        leaveALine(on: model)
        await recorder.answer(Kind.reservations, with: .result("一覧ではない文字列"))
        await model.loadReservations()
        XCTAssertNotNil(model.problem(for: .recorder), "an answer that could not be read was taken for a list")
        XCTAssertNotEqual(model.problem(for: .recorder), lineLeft, "nothing says the answer could not be read")
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.reservations, reservations)

        // A recording the recorder is still writing to.
        let writing = try XCTUnwrap(model.titles.first { $0.recording }, "the demo was meant to be recording")
        leaveALine(on: model)
        before = await recorder.asked
        expectFalse(await deleteARecording(model, writing))
        XCTAssertEqual(whyNotJustNow(model), Said.stillRecording)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        expectEqual(await recorder.asked, before, "a recording being written to was asked to be deleted")

        // The free space refused after a delete.
        leaveALine(on: model)
        await recorder.answer(Kind.freeSpace, with: .fault(402))
        expectTrue(await deleteARecording(model, subjects.spare),
                   "a refusal of the free space failed the delete it followed")
        XCTAssertTrue(model.connected)
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertNil(model.storage, "room is shown that the recorder would not give")
    }

    /// Known to be away -- the last ask met silence -- the app asks the recorder nothing. A read is simply not
    /// made, and leaves what is on screen alone; anything else says in what it hands back that the app is not
    /// connected, and leaves the line an earlier operation left. With no recorder in hand at all, nothing is
    /// asked and nothing written on the line either.
    ///
    /// As it is today in two places. A protect and a delete mark the recordings unread although nothing was
    /// sent, which costs a read of the list after the reconnect. The conditions' screen, with no list read,
    /// gives the line an earlier operation left as its reason. Another change keeps a write from a recorder that
    /// has not said which it is.
    func testNothingIsSentToARecorderTheAppIsNotConnectedTo() async throws {
        let (_, recorder, model, subjects) = try await settled()
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.gaveUp)
        XCTAssertTrue(model.titlesLoaded)
        let asked = await recorder.asked

        for row in Funnelled.all {
            leaveALine(on: model)
            let answer = await row.ask(model, subjects)
            if row.reads {
                XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) said something, unasked")
            } else {
                XCTAssertNotEqual(answer, true, row.name)
                XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line at its door")
                XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
            }
            XCTAssertEqual(model.guideDownloads, 0, row.name)
            XCTAssertNil(model.busy, row.name)
        }
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked")
        XCTAssertFalse(model.titlesLoaded)

        await model.adopt(host: "")
        leaveALine(on: model)
        for row in Funnelled.all where !row.reads {
            let answer = await row.ask(model, subjects)
            XCTAssertNotEqual(answer, true, row.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) said something, with no recorder")
        }
        expectEqual(await recorder.asked, asked, "a recorder the app had let go of was asked")
        await model.loadRecorderRules()
        XCTAssertEqual(model.recorderRulesFailure, lineLeft)
    }

    /// A recording the phone holds as protected, asked to be deleted, is turned away before anything is asked: the
    /// recorder refuses such a delete, and no screen offers one. The delete says why in what it hands back, and
    /// leaves the line and the list as they were.
    func testAProtectedRecordingIsTurnedAwayAtTheDeletesDoor() async throws {
        let (_, recorder, model, subjects) = try await settled()
        expectTrue(await protectARecording(model, subjects.spare, true), model.problem ?? "no reason given")
        let held = try XCTUnwrap(model.titles.first { $0.id == subjects.spare.id && $0.protected },
                                 "the recording was meant to be held as protected")
        let titles = model.titles
        leaveALine(on: model)
        let asked = await recorder.asked

        expectFalse(await deleteARecording(model, held), "a protected recording was deleted")

        XCTAssertEqual(whyNotJustNow(model), Said.protectedCannotBeDeleted)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the delete wrote over the line at its door")
        XCTAssertEqual(model.titles, titles)
        XCTAssertTrue(model.titlesLoaded)
        expectEqual(await recorder.asked, asked, "a protected recording was asked to be deleted")
    }

    /// What the recordings' and the conditions' writes turn away at their doors, with nothing sent, each says in
    /// what it hands back, and the line an earlier operation left stays: the recorder known to be away, and no
    /// recorder in hand at all, are that the app is not connected. A play, a pause or a stop turned away so
    /// leaves the offer to turn the recorder on where a pause the recorder turned down for its standby put it:
    /// nothing was asked of it.
    func testWhatADoorTurnsAwayIsSaidInTheResultAndLeavesTheLine() async throws {
        let (_, recorder, model, subjects) = try await settled()
        await recorder.answer(Kind.playback, with: .fault(880))
        await playARecording(model, subjects.title, "pause")
        XCTAssertTrue(model.needsPower, "the pause was meant to leave the offer up")
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        let asked = await recorder.asked

        for row in Funnelled.all where !row.reads {
            leaveALine(on: model)
            let answer = await row.ask(model, subjects)
            XCTAssertNotEqual(answer, true, row.name)
            XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line at its door")
            XCTAssertTrue(model.needsPower, "\(row.name) took the offer to turn the recorder on away at its door")
        }
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked")

        await model.adopt(host: "")
        for row in Funnelled.all where !row.reads {
            leaveALine(on: model)
            let answer = await row.ask(model, subjects)
            XCTAssertNotEqual(answer, true, row.name)
            XCTAssertEqual(whyNotJustNow(model), Said.notConnected, "\(row.name), with no recorder")
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line, with no recorder")
        }
        expectEqual(await recorder.asked, asked, "a recorder the app had let go of was asked")
    }

    // MARK: - beside a check, a connect, another recorder

    /// What is asked for while the recorder is being made sure of waits for that answer, rather than send a
    /// probe or a request of its own. When the check meets silence nothing is sent, and what is said is the
    /// check's -- the recorder could not be reached -- and not that something may have arrived. When the
    /// recorder answers the check, if only to say it is busy with somebody else, it is there and is not given up
    /// on; what is sent then depends on what it said (below).
    ///
    /// That is so of a write through the funnel, and of the two things that ask the check for themselves: the
    /// question of what a reservation would clash with, asked as a programme's sheet opens, and a waiting
    /// reservation the reader asks to be sent again. The question has no line and nothing to wait for, so it is
    /// asked beside each write here, whose line says that both have been asked. (After a check answered busy the
    /// order it goes in says nothing: the client sends one request at a time whoever asks.)
    ///
    /// Busy says nothing of which recorder answered, though: the write asked beside such a check is not sent,
    /// and says in its result and on the line what was heard, while the question, which has no line, is answered
    /// as before.
    ///
    /// As it is today: a protect and a delete turned away by a check that met silence mark the recordings unread
    /// all the same.
    func testWhatTheCheckFoundDecidesWhetherAWriteIsSent() async throws {
        let (bench, recorder, model, subjects) = try await settled(guide: true)
        let program = try await programmesNotReserved(model, 1)[0]
        let unread: Set = [Kind.changeRecording, Kind.deleteRecording]
        // The question, and `row` asked for beside it.
        func asking(_ row: Funnelled) -> @MainActor () async -> (clashes: [Reservation]?, done: Bool?) {
            {
                async let clashes = model.conflicts(for: program, quality: "DR", repeating: "none")
                let done = await row.ask(model, subjects)
                return (await clashes, done)
            }
        }

        for row in [Funnelled.delete, .protect, .add, .remove] {
            leaveALine(on: model)
            let count = await recorder.heard.count
            let (there, came) = try await duringACheck(by: model, of: recorder, endingIn: .silence, row.name,
                                                       waitingFor: { model.busy == row.line }, asking(row))

            XCTAssertFalse(there, row.name)
            XCTAssertEqual(came.done, false, row.name)
            XCTAssertNil(came.clashes, "the question was answered although the check met silence, beside \(row.name)")
            expectEqual(await recorder.heard(since: count), [Kind.description],
                        "\(row.name) or the question was sent, or sent a probe of its own, beside the check")
            XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, row.name)
            XCTAssertTrue(model.gaveUp, row.name)
            XCTAssertNil(model.busy, row.name)
            XCTAssertEqual(model.titlesLoaded, !unread.contains(row.kind), row.name)
            await reconnect(model)
            await model.loadTitles()
        }

        // A waiting reservation asked to be sent again. Its line goes up as the asking gets to the check, its
        // reason comes off once the check has answered, and the row is taken away before the reconnect, which
        // would send it.
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        try await GuideStore(path: bench.guidePath)
            .queue(PendingReservation(request: request, serviceName: program.serviceName, problem: "前に断られた理由"))
        await model.loadPending()
        let waiting = try XCTUnwrap(model.pending(for: program))
        leaveALine(on: model)
        let count = await recorder.heard.count
        let again = try await duringACheck(by: model, of: recorder, endingIn: .silence, "sending it again",
                                           waitingFor: { model.busy == "送信待ちの予約を登録中" }) {
            await model.resend(waiting)
        }
        XCTAssertFalse(again.there)
        expectEqual(await recorder.heard(since: count), [Kind.description],
                    "what waits was sent, or a probe of its own, beside a check that met silence")
        XCTAssertNil(model.flushReport)
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertTrue(model.gaveUp)
        XCTAssertNotNil(model.pending(for: program), "the reservation no longer waits")
        await model.removePending(waiting)
        await reconnect(model)
        await model.loadTitles()

        // Busy with somebody else as it is asked who it is, through both tries after the first.
        let before = await recorder.asked
        let (there, came) = try await duringACheck(by: model, of: recorder, endingIn: .busy, "the delete",
                                                   waitingFor: { model.busy == Funnelled.delete.line },
                                                   asking(.delete))
        XCTAssertTrue(there, "a recorder that answered busy was taken for gone")
        XCTAssertEqual(came.done, false, "a delete went out after a check that heard busy")
        XCTAssertEqual(whyNotJustNow(model), Said.busy(Kind.description))
        XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.description))
        XCTAssertEqual(came.clashes, [], "the question was not put to a recorder that had answered the check")
        expectEqual(await recorder.asked(Kind.description, since: before), 3, "a probe was sent beside the check's")
        expectEqual(await recorder.asked(Kind.deleteRecording, since: before), 0)
        expectEqual(await recorder.asked(Kind.clashes, since: before), 1)
        XCTAssertTrue(model.connected)
        await recorder.comeFree()
    }

    /// How the check before an operation ends: the recorder says nothing, or says it is busy with somebody else.
    private enum CheckEnd {
        case silence, busy
    }

    /// Asks `something` of the model while the check before an operation is out, and then has that check end as
    /// `end` says. The recorder is made sure of, and that ask is held; `something` is asked meanwhile, and has
    /// got as far as the check once `begun` says so; then the ask is let go, into silence or into a recorder busy
    /// as it is asked who it is. What the check found, and what `something` came to.
    private func duringACheck<T: Sendable>(by model: AppModel, of recorder: NamedRecorder, endingIn end: CheckEnd,
                                           _ what: String, waitingFor begun: @MainActor () -> Bool,
                                           _ something: @escaping @MainActor () async -> T) async throws
        -> (there: Bool, came: T) {
        await recorder.hold(only: Kind.description)
        let before = await recorder.asked
        let check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") {
            await recorder.asked(Kind.description, since: before) == 1
        }
        let asking = Task { await something() }
        try await until("\(what) was never begun") { begun() }
        switch end {
        case .silence: await recorder.goQuiet(on: Kind.description)
        case .busy: await recorder.busyAtTheDoor()
        }
        await recorder.letGo()
        return (await check.value, await asking.value)
    }

    /// A connect to the same recorder, made while an operation's request is out, makes a client of its own and
    /// takes nothing from the operation, which ends as it would have: a read that comes back is put in place,
    /// and a write that meets silence says it may have arrived, loses the recorder and marks its list unread.
    /// The funnel does not ask whether the client it began with is still the one in hand, and whatever comes to
    /// ask whether the recorder was let go of meanwhile has to leave this as it is: nothing was let go of.
    func testAConnectMadeBesideAnOperationThatIsOutTakesNothingFromIt() async throws {
        let (bench, recorder, model) = try await connectedHome(guide: false)

        await recorder.hold(only: Kind.recordings)
        var before = await recorder.asked
        let reading = Task { await model.loadTitles() }
        try await until("the recordings were never asked for") {
            await recorder.asked(Kind.recordings, since: before) == 1
        }
        let made = bench.clientsMade
        await model.connect()
        // What this test stands on, rather than what it holds: with the read's own client still in hand,
        // nothing below says anything about a client replaced under a request.
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        await recorder.letGo()
        await reading.value
        XCTAssertTrue(model.titlesLoaded, "a read that came back after a connect was not put in place")
        XCTAssertFalse(model.titles.isEmpty)
        XCTAssertTrue(model.connected)
        expectEqual(await recorder.asked(Kind.recordings, since: before), 1)

        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        await recorder.hold(only: Kind.deleteRecording)
        before = await recorder.asked
        let deleting = Task { await deleteARecording(model, title) }
        try await until("the delete never got to the recorder") {
            await recorder.asked(Kind.deleteRecording, since: before) == 1
        }
        await model.connect()
        XCTAssertTrue(model.connected)
        await recorder.goQuiet(on: Kind.deleteRecording)
        await recorder.letGo()
        expectFalse(await deleting.value)
        XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived)
        XCTAssertTrue(model.gaveUp, "silence on a write was not taken for the recorder's, after a connect")
        XCTAssertFalse(model.titlesLoaded)
        expectEqual(await recorder.asked(Kind.deleteRecording, since: before), 1)
    }

    /// The same with the connect answered by another recorder, whose arrival empties the lists in that turn. A
    /// list read out at the arrival is the last recorder's, and is not put over the newcomer's: the newcomer's
    /// connect reads its own, the read out having said that the reader was about to see the list. Nothing
    /// before it asks whether the recorder a write began with was let go of, so a write's silence is taken for
    /// the newcomer's: the app gives up on a recorder that has just answered, under a sentence about a write it
    /// was never sent.
    ///
    /// As it is today, and to be rewritten in part: a later change takes the write's silence as one across a
    /// let-go, and keeps the newcomer; the sentence stays.
    func testAnotherRecorderDescribingItselfBesideAnOperationThatIsOut() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)

        await recorder.holdTheNext(Kind.recordings)
        var before = await recorder.asked
        let forgotten = model.timesForgotten
        let reading = Task { await model.loadTitles() }
        try await until("the recordings were never asked for") {
            await recorder.asked(Kind.recordings, since: before) == 1
        }
        await recorder.become(2)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertGreaterThan(model.timesForgotten, forgotten, "the lists were meant to go as the newcomer arrived")
        XCTAssertTrue(model.titlesLoaded, "the newcomer's recordings were not read by its connect")
        let newcomers = model.titles
        XCTAssertFalse(newcomers.isEmpty)
        expectEqual(await recorder.asked(Kind.recordings, since: before), 2)
        // The read out comes back with a list of its own, to be told from the newcomer's.
        await recorder.answer(Kind.recordings, with: .result(Self.aListOfOne))
        await recorder.letGo()
        await reading.value
        XCTAssertEqual(model.titles, newcomers, "the last recorder's list was put over the newcomer's")
        XCTAssertTrue(model.titlesLoaded)

        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        await recorder.hold(only: Kind.deleteRecording)
        before = await recorder.asked
        let deleting = Task { await deleteARecording(model, title) }
        try await until("the delete never got to the recorder") {
            await recorder.asked(Kind.deleteRecording, since: before) == 1
        }
        await recorder.become(3)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(3), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertTrue(model.titlesLoaded, "the newcomer's recordings were meant to be read by its connect")
        await recorder.goQuiet(on: Kind.deleteRecording)
        await recorder.letGo()
        expectFalse(await deleting.value)
        XCTAssertEqual(model.problem(for: .recorder), Said.mayHaveArrived)
        XCTAssertTrue(model.gaveUp)
        XCTAssertFalse(model.titlesLoaded)
    }

    /// A list of the recordings with one recording, none of the demo's.
    private static let aListOfOne = "<xsrs><item id=\"0x1\"><title>サンプル</title>"
        + "<scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>"
        + "<scheduledDuration>1800</scheduledDuration></item></xsrs>"

    // MARK: - standby, and the guide

    /// A pause or a stop sent to a recorder in network standby says so in the recorder's words and offers to
    /// turn it on, with the recorder kept. The offer goes when the power is put on, and at the door of the next
    /// playback operation whatever becomes of that; a power request that meets silence leaves it, through the
    /// reconnect as well.
    ///
    /// Playing itself, which turns the recorder on and waits for it under a line that counts the seconds, is
    /// not here: the model hands the client no interval, so a test of it waits a real second. The sequence is
    /// held in the package (`RecorderClientTests`), and the app's part of it goes with the recordings' own gates.
    /// The sentence a power request's silence leaves is to change.
    func testStandbyIsSaidAndPowerIsOfferedUntilItIsPutOnOrPlaybackIsAskedForAgain() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let before = await recorder.asked

        await recorder.answer(Kind.playback, with: .fault(880))
        await playARecording(model, subjects.title, "pause")
        XCTAssertTrue(model.needsPower, "nothing offers to turn the recorder on")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(880, Kind.playback))
        XCTAssertTrue(model.connected)
        expectEqual(await recorder.asked(Kind.power, since: before), 0, "a pause turned the recorder on")

        await turnTheRecorderOn(model)
        expectEqual(await recorder.asked(Kind.power, since: before), 1)
        XCTAssertFalse(model.needsPower)
        XCTAssertNil(model.problem(for: .recorder))

        await recorder.answer(Kind.playback, with: .fault(880))
        await playARecording(model, subjects.title, "stop")
        XCTAssertTrue(model.needsPower)
        await recorder.goQuiet(on: Kind.power)
        await turnTheRecorderOn(model)
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertTrue(model.needsPower, "the offer went with a power request that never arrived")
        await reconnect(model)
        XCTAssertTrue(model.needsPower, "the offer went with the reconnect")

        await recorder.answer(Kind.playback, with: .fault(402))
        await playARecording(model, subjects.title, "stop")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.playback))
        XCTAssertFalse(model.needsPower, "the offer outlived the next thing asked of playback")
    }

    /// A guide asked for by hand passes over a type the recorder has no file for -- it answers 500 until it has
    /// built its files again -- fetches the rest, keeps the recorder and says a line for each type that failed.
    /// The task that asked being cancelled does not stop it between types: the guide is the app's rather than a
    /// screen's, and a pull-down's task goes with its screen. Silence stops it there, loses the recorder and
    /// says the read's sentence alone. The count of downloads comes back to nought either way.
    ///
    /// Whatever comes to fetch the guide's types in turn has to say so by name if it lets the cancellation
    /// through.
    func testAGuideAskedForByHandPassesOverWhatFailsAndStopsAtSilence() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        func missing(_ file: String) -> String { RecorderError.guideFileMissing(name: file, status: 500).explanation }

        var before = await recorder.asked
        await recorder.answer(Kind.guide[0], with: .status(500))
        await recorder.answer(Kind.guide[1], with: .status(500))
        await recorder.hold(only: Kind.guide[0])
        let asking = Task { await model.refreshGuide() }
        try await until("the guide was never asked for") { await recorder.asked(Kind.guide[0], since: before) == 1 }
        XCTAssertEqual(model.guideDownloads, 1)
        asking.cancel()
        await recorder.letGo()
        await asking.value
        for file in Kind.guide { expectEqual(await recorder.asked(file, since: before), 1, file) }
        XCTAssertEqual(model.problem(for: .recorder),
                       "地上デジタルの番組表：\(missing(Kind.guide[0]))\nBS の番組表：\(missing(Kind.guide[1]))")
        XCTAssertTrue(model.connected, "a file the recorder has not built was taken for the recorder going")
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertNil(model.busy)

        before = await recorder.asked
        await recorder.answer(Kind.guide[0], with: .status(500))
        await recorder.goQuiet(on: Kind.guide[2])
        await model.refreshGuide()
        for file in Kind.guide.prefix(3) { expectEqual(await recorder.asked(file, since: before), 1, file) }
        expectEqual(await recorder.asked(Kind.guide[3], since: before), 0, "a silent recorder was asked for more")
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the type that failed was said over the silence")
        XCTAssertEqual(model.guideDownloads, 0)
    }

    // MARK: - a recording's details

    /// A recording's details are asked as its sheet opens, before anybody has asked for anything, and have no
    /// line: nothing on the strip while they are out, the recorder in play can still be changed, and the line of
    /// what went wrong is left as it was whichever way they end. Answered, they are what the recorder said.
    /// Refused, there are none, and the recorder is kept. Met by silence, there are none, and the app gives up on
    /// the recorder without a word. With the recorder known to be away, nothing is asked.
    ///
    /// As it is, and to stay: a recording's details, as the clash check, have no line of their own.
    func testARecordingsDetailsHaveNoLineAndLeaveTheLineAsItWasHoweverTheyEnd() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let told = try await aClient(of: recorder).titleDetail(id: subjects.title.id)

        // Answered, held for a look at the screen while they are out.
        leaveALine(on: model)
        var before = await recorder.asked
        await recorder.hold(only: Kind.details)
        let reading = Task { await model.detail(of: subjects.title) }
        try await until("the details were never asked for") {
            await recorder.asked(Kind.details, since: before) == 1
        }
        XCTAssertNil(model.busy, "the details put a line up")
        XCTAssertTrue(model.canChangeRecorder, "the details held the recorder in play")
        await recorder.letGo()
        let answered = await reading.value
        XCTAssertEqual(answered?.summary, told.summary)
        XCTAssertEqual(answered?.details, told.details)
        XCTAssertFalse(told.summary.isEmpty, "the demo was meant to say what the recording is about")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "details that came back cleared the line")

        // Refused.
        before = await recorder.asked
        await recorder.answer(Kind.details, with: .fault(402))
        expectNil(await model.detail(of: subjects.title))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a refusal of the details was said")
        XCTAssertTrue(model.connected, "a refusal of the details was taken for the recorder going")
        XCTAssertFalse(model.gaveUp, "a refusal of the details was taken for silence")
        expectEqual(await recorder.asked(Kind.details, since: before), 1)

        // Silent.
        await recorder.goQuiet(on: Kind.details)
        expectNil(await model.detail(of: subjects.title))
        XCTAssertTrue(model.gaveUp, "silence on the details did not lose the recorder")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "silence on the details was said")

        // Known to be away.
        before = await recorder.asked
        expectNil(await model.detail(of: subjects.title))
        expectEqual(await recorder.asked, before, "a recorder known to be away was asked for a recording's details")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the details said something, unasked")
    }

    /// A recording's details asked while the recorder is being made sure of wait for that answer, as everything
    /// else does. When the check meets silence they are not asked, and what is said is the check's. When the
    /// recorder answers the check, if only to say it is busy with somebody else, they are asked and answered: a
    /// request with no line goes on after such a check, as the clash check does.
    ///
    /// As it is, and to stay: the clash check and the details are left as they are by a later change that sends
    /// no write and reads no list after a check that heard the recorder busy.
    func testARecordingsDetailsWaitForTheCheckAndGoOnAfterOneThatHeardTheRecorderBusy() async throws {
        let (_, recorder, model, subjects) = try await settled()
        // Nothing public says that the details are waiting for the check, so they are taken to be once ten looks
        // have gone by, about a fifth of a second. A guess, not a sign: on a loaded machine they can reach the
        // check only after it has answered. This still passes then -- the details are asked of nobody after the
        // silence, and asked and answered after the busy check -- but a mistake in how they wait for the check
        // would go unseen.
        var looks = 0

        leaveALine(on: model)
        var count = await recorder.heard.count
        let silent = try await duringACheck(by: model, of: recorder, endingIn: .silence, "the details",
                                            waitingFor: { looks += 1; return looks > 10 }) {
            await model.detail(of: subjects.title)
        }
        XCTAssertFalse(silent.there)
        XCTAssertNil(silent.came, "details were handed back although the check met silence")
        expectEqual(await recorder.heard(since: count), [Kind.description],
                    "the details were asked, or sent a probe of their own, beside a check that met silence")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertTrue(model.gaveUp)
        await reconnect(model)

        looks = 0
        count = await recorder.heard.count
        let busy = try await duringACheck(by: model, of: recorder, endingIn: .busy, "the details",
                                          waitingFor: { looks += 1; return looks > 10 }) {
            await model.detail(of: subjects.title)
        }
        XCTAssertTrue(busy.there, "a recorder that answered busy was taken for gone")
        XCTAssertNotNil(busy.came, "the details were not asked of a recorder that had answered the check")
        expectEqual(await recorder.heard(since: count).filter { $0 == Kind.details }, [Kind.details])
        XCTAssertTrue(model.connected)
        await recorder.comeFree()
    }

    /// A connect to the same recorder made while a recording's details are out makes a client of its own and
    /// lets go of nothing. Silence met by the details' client, which the model no longer holds, says nothing of
    /// the recorder in play: the app is not given up on, and nothing is said. Whatever comes to ask whether the
    /// recorder was let go of meanwhile has to leave this as it is: nothing was.
    func testSilenceOnARecordingsDetailsAcrossAConnectToTheSameRecorderLosesNobody() async throws {
        let (bench, recorder, model, subjects) = try await settled()
        let before = await recorder.asked
        await recorder.hold(only: Kind.details)
        let reading = Task { await model.detail(of: subjects.title) }
        try await until("the details were never asked for") {
            await recorder.asked(Kind.details, since: before) == 1
        }
        let made = bench.clientsMade
        await model.connect()
        // What this test stands on, rather than what it holds: the details' client is no longer the one in hand.
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        XCTAssertTrue(model.connected)
        leaveALine(on: model)
        await recorder.goQuiet(on: Kind.details)
        await recorder.letGo()

        expectNil(await reading.value)
        XCTAssertFalse(model.gaveUp, "silence met by a client the model no longer holds lost the recorder")
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the silence of a client let go of was said")
        expectEqual(await recorder.asked(Kind.details, since: before), 1)
    }

    // MARK: - the recordings' and the conditions' writes beside a connect, a busy check, another recorder

    /// A recording still being recorded, asked to be deleted while the recorder is known to be away, is turned
    /// away before anything is asked, saying why in what it hands back and leaving the line as it was; and the
    /// recordings are left as read. Nothing was sent, so there is nothing a read once the recorder answers would
    /// have to put right.
    func testARecordingStillBeingRecordedLeavesTheRecordingsReadWhileTheRecorderIsAway() async throws {
        let (_, recorder, model, _) = try await settled()
        let writing = try XCTUnwrap(model.titles.first { $0.recording }, "the demo was meant to be recording")
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.gaveUp, "the recorder was meant to be known to be away")
        XCTAssertTrue(model.titlesLoaded)
        leaveALine(on: model)
        let asked = await recorder.asked

        expectFalse(await deleteARecording(model, writing))

        XCTAssertEqual(whyNotJustNow(model), Said.stillRecording)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the delete wrote over the line at its door")
        XCTAssertTrue(model.titlesLoaded, "the recordings were marked unread with nothing sent")
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked")
    }

    /// Playing, pausing and stopping a recording, and turning the recorder on, act on the recorder as the other
    /// writes do, and are turned away at their doors in the same two moments: a connect under way, whose client
    /// has not yet heard which recorder answers it, and a reconnect the recorder answered busy with somebody
    /// else, which leaves the app connected beside such a client. Each comes back at once, is sent nowhere and
    /// says in what it hands back that the app is not connected, the line left as it was. Nothing was asked of
    /// the recorder, so the offer to turn it on that a pause it turned down for its standby put up stays.
    func testPlaybackAndThePowerAreNotSentOnAClientThatHasNotHeardWhichRecorderAnswersIt() async throws {
        let (bench, recorder, model, subjects) = try await settled()
        let asks = [Funnelled.play, .pause, .stop, .power]
        await recorder.answer(Kind.playback, with: .fault(880))
        await playARecording(model, subjects.title, "pause")
        XCTAssertTrue(model.needsPower, "the pause was meant to leave the offer up")

        // During a connect, with its ask of who answers held. One that went on would take the offer away and
        // put its line up, to be sent once the ask is let go.
        for row in asks {
            await recorder.hold(only: Kind.description)
            let before = await recorder.asked
            let connecting = Task { await model.connect() }
            try await until("the connect never asked who answers") {
                await recorder.asked(Kind.description, since: before) == 1
            }
            leaveALine(on: model)
            let back = Back()
            let asking = Task {
                _ = await row.ask(model, subjects)
                back.came = true
            }
            let deadline = Date().addingTimeInterval(2)
            while !back.came, model.busy != row.line, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotEqual(model.busy, row.line, "\(row.name) waited for the connect, rather than turned away")
            XCTAssertTrue(model.needsPower, "\(row.name) took the offer to turn the recorder on away, at its door")
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line at its door")
            await recorder.letGo()
            await asking.value
            await connecting.value
            XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
            expectEqual(await recorder.asked(row.kind, since: before), 0, "\(row.name) was sent beside the connect")
            XCTAssertTrue(model.needsPower, row.name)
            XCTAssertTrue(model.connected, row.name)
        }

        // After a reconnect answered busy, on the client that never heard.
        await recorder.busyAtTheDoor()
        let made = bench.clientsMade
        await model.connect()
        XCTAssertEqual(bench.clientsMade, made + 1, "the reconnect was meant to make a client of its own")
        XCTAssertTrue(model.connected, "the attach before was meant to stand")
        await recorder.comeFree()
        for row in asks {
            leaveALine(on: model)
            let before = await recorder.asked
            _ = await row.ask(model, subjects)
            XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line at its door")
            XCTAssertTrue(model.needsPower, "\(row.name) took the offer to turn the recorder on away, at its door")
            expectEqual(await recorder.asked(row.kind, since: before), 0, "\(row.name) was sent after the reconnect")
        }
        XCTAssertEqual(bench.clientsMade, made + 1, "playback or the power connected")
    }

    /// A connect under way has a client of its own that has not yet heard which recorder answers it, and a
    /// reconnect the recorder answered busy with somebody else leaves the app connected from the attach before,
    /// beside such a client. Nothing is written on it, as for the reservations: a protect, a delete, a condition
    /// added and one removed, asked during the connect or after the busy reconnect, are each turned away at their
    /// doors, at once, sent nowhere, and say in what they hand back that the app is not connected, the line left
    /// as it was. Nothing connects for them either.
    func testAWriteIsNotSentOnAClientThatHasNotHeardWhichRecorderAnswersIt() async throws {
        let (bench, recorder, model, subjects) = try await settled()
        let writes = [Funnelled.protect, .delete, .add, .remove]

        // During a connect, with its ask of who answers held. Turned away at its door, a write comes back at once
        // -- a condition removed has the list read after it, as every one has, which waits behind that ask on the
        // connect's client as a read does. One that went on would put its line up and wait there, to be sent
        // once the ask is let go.
        for row in writes {
            await recorder.hold(only: Kind.description)
            let before = await recorder.asked
            let connecting = Task { await model.connect() }
            try await until("the connect never asked who answers") {
                await recorder.asked(Kind.description, since: before) == 1
            }
            leaveALine(on: model)
            let back = Back()
            let asking = Task {
                let answer = await row.ask(model, subjects)
                back.came = true
                return answer
            }
            let deadline = Date().addingTimeInterval(2)
            while !back.came, model.busy != Funnelled.conditions.line, model.busy != row.line, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotEqual(model.busy, row.line, "\(row.name) waited for the connect, rather than turned away")
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line at its door")
            await recorder.letGo()
            let answer = await asking.value
            await connecting.value
            XCTAssertEqual(answer, false, row.name)
            XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
            expectEqual(await recorder.asked(row.kind, since: before), 0, "\(row.name) was sent beside the connect")
            XCTAssertTrue(model.connected, row.name)
        }

        // After a reconnect answered busy, on the client that never heard.
        await recorder.busyAtTheDoor()
        let made = bench.clientsMade
        await model.connect()
        XCTAssertEqual(bench.clientsMade, made + 1, "the reconnect was meant to make a client of its own")
        XCTAssertTrue(model.connected, "the attach before was meant to stand")
        await recorder.comeFree()
        for row in writes {
            leaveALine(on: model)
            let before = await recorder.asked
            let answer = await row.ask(model, subjects)
            XCTAssertEqual(answer, false, row.name)
            XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line at its door")
            expectEqual(await recorder.asked(row.kind, since: before), 0, "\(row.name) was sent after the reconnect")
        }
        XCTAssertEqual(bench.clientsMade, made + 1, "a write connected")
    }

    /// After a check that heard the recorder busy with somebody else as it was asked who it is, nothing the
    /// reader asks next is written to it or read from it, as for the reservations: each write, playback and the
    /// power are not sent, and the recordings and the conditions are not read. Each asks again who answers,
    /// however lately the recorder answered -- busy says nothing of which recorder it is -- hears busy again, and
    /// says so on the line, where it stays once the operation is over, and in its result. The lists are left as
    /// they were. A recording's details and the question of what a reservation would clash with, which have no
    /// line, go on after such a check and are answered, asking nothing again, and leave the line as it was.
    func testNothingIsSentOrReadAfterACheckThatHeardTheRecorderBusyAndEachAsksAgain() async throws {
        let (_, recorder, model, subjects) = try await settled(guide: true)
        let program = try await programmesNotReserved(model, 1)[0]
        await recorder.busyAtTheDoor()
        expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
        let busy = Said.busy(Kind.description)
        let lists = Lists(model)

        for row in Funnelled.all where row.kind != Kind.reservations && row.kind != Kind.guide[0] {
            leaveALine(on: model)
            let count = await recorder.asked
            let answer = await row.ask(model, subjects)
            XCTAssertNotEqual(answer, true, "\(row.name) went through after a check that heard busy")
            XCTAssertEqual(model.problem(for: .recorder), busy, "\(row.name) did not say what the check heard")
            XCTAssertNil(model.busy, row.name)
            if !row.reads { XCTAssertEqual(whyNotJustNow(model), busy, row.name) }
            expectEqual(await recorder.asked(row.kind, since: count), 0, "\(row.name) was sent")
            // Three asks each, busy through both tries after the first; a condition removed has the list read
            // after it, as every one has, which asks again too.
            expectEqual(await recorder.asked(Kind.description, since: count), row.kind == Kind.removeCondition ? 6 : 3,
                        "\(row.name) did not ask again who answers")
        }
        XCTAssertTrue(Lists(model) == lists, "a list changed after a check that heard busy")
        XCTAssertEqual(model.recorderRulesFailure, busy)
        XCTAssertTrue(model.connected)

        leaveALine(on: model)
        let count = await recorder.asked
        let details = await model.detail(of: subjects.title)
        XCTAssertNotNil(details, "a recording's details were not answered")
        let clashes = await model.conflicts(for: program, quality: "DR", repeating: "none")
        XCTAssertNotNil(clashes, "the question of what a reservation would clash with was not answered")
        expectEqual(await recorder.asked(Kind.description, since: count), 0,
                    "the details or the question asked again who answers")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the details or the question wrote on the line")
        await recorder.comeFree()
    }

    /// A write answered once another recorder has taken the place of the one it was asked of, which emptied the
    /// lists in that turn: queued on the last recorder's client behind a list read that was out when the
    /// newcomer described itself, it goes to the address once that read is back, and so to the newcomer; asked
    /// and held at its own request, it is answered by the newcomer. Either way it is taken to have gone
    /// through, and its success clears the newcomer's line. A protect, a delete, a condition added and one
    /// removed.
    ///
    /// As it is today, and to be rewritten in part: a later change takes such an answer as one across a let-go,
    /// as a reservation's delete takes it -- still sent, since what is in a client's queue goes, but not the
    /// newcomer's success, and the newcomer's line left alone. Not sending what is in a client's queue is not
    /// that change's, and the first half of this goes on holding it.
    func testAWriteAnsweredAfterAnotherRecorderDescribedItselfIsTakenToHaveGoneThrough() async throws {
        let (_, recorder, model, subjects) = try await settled()
        var newcomer = 1
        for row in [Funnelled.protect, .delete, .add, .remove] {
            for queued in [true, false] {
                let how = "\(row.name), \(queued ? "queued behind a read" : "held at its own request")"
                newcomer += 1
                // the lists as the screens of the recorder in play have them
                await model.loadTitles()
                await model.loadRecorderRules()
                let before = await recorder.asked
                await recorder.holdTheNext(queued ? Kind.recordings : row.kind)
                var reading: Task<Void, Never>?
                if queued {
                    reading = Task { await model.loadTitles(force: true) }
                    try await until("the recordings were never asked for, \(how)") {
                        await recorder.asked(Kind.recordings, since: before) == 1
                    }
                }
                let asking = Task { await row.ask(model, subjects) }
                if queued {
                    try await until("\(how) was never begun") { model.busy == row.line }
                } else {
                    try await until("\(how) never got to the recorder") {
                        await recorder.asked(row.kind, since: before) == 1
                    }
                }

                await recorder.become(newcomer)
                await model.connect()
                XCTAssertEqual(model.info?.udn, NamedRecorder.udn(newcomer),
                               model.problem(for: .recorder) ?? "no reason given")
                if queued {
                    // What this half stands on: the write still waits on the last recorder's client, behind the
                    // read, asked of nobody yet, as the newcomer has arrived.
                    expectEqual(await recorder.asked(row.kind, since: before), 0,
                                "\(how) was sent before the read it queued behind came back")
                }
                leaveALine(on: model)
                await recorder.letGo()
                await reading?.value
                let answer = await asking.value

                XCTAssertEqual(answer, true, "\(how): \(model.problem(for: .recorder) ?? "no reason given")")
                XCTAssertNil(model.problem(for: .recorder), "\(how) left the newcomer's line")
                XCTAssertFalse(model.gaveUp, how)
                expectEqual(await recorder.asked(row.kind, since: before), 1, how)
            }
        }
    }

    /// The keyword conditions read from the recorder in play, and still out when another recorder describes
    /// itself on a connect, whose arrival empties the lists in that turn: as the recordings are, the list that
    /// comes back afterwards is the last recorder's and is not put over the newcomer's, and the newcomer's
    /// connect reads its own, the read out having said that the reader was about to see the list, though none
    /// had been read when it arrived.
    func testTheConditionsReadAcrossAnotherRecordersArrivalAreNotPutOverTheNewcomersList() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        XCTAssertFalse(model.recorderRulesLoaded, "the conditions were meant not to have been read yet")
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.conditions)
        let reading = Task { await model.loadRecorderRules() }
        try await until("the conditions were never asked for") {
            await recorder.asked(Kind.conditions, since: before) == 1
        }
        await recorder.become(2)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertTrue(model.recorderRulesLoaded, "the newcomer's conditions were not read by its connect")
        let newcomers = model.recorderRules
        XCTAssertFalse(newcomers.isEmpty)
        expectEqual(await recorder.asked(Kind.conditions, since: before), 2)
        // The read out comes back with none, to be told from the newcomer's list.
        await recorder.answer(Kind.conditions, with: .result("<xsrs></xsrs>"))
        await recorder.letGo()
        await reading.value

        XCTAssertEqual(model.recorderRules, newcomers, "the last recorder's list was put over the newcomer's")
        XCTAssertTrue(model.recorderRulesLoaded)
        XCTAssertNil(model.recorderRulesFailure)
    }

    // MARK: - the keyword conditions' reason and lines

    /// Why the keyword conditions' screen has no list to show, and what a read of them leaves when the recorder
    /// cannot be asked. Known to be away with none read, the screen's reason is the line an earlier operation
    /// left. Known to be away with a list read before, the list, its screen and the line are left as they were.
    /// And a read whose silence is not said -- the recorder known to be away by the time it is answered, a
    /// connect made meanwhile having met silence and said so -- gives as its reason, over an empty line, that the
    /// app is not connected: with nothing on the line the recorder said nothing that can be told.
    ///
    /// As it is today, and to be rewritten in part: a later change has the read say its own reason, that the app
    /// is not connected, where it was turned away at its door with nothing read, rather than the line an earlier
    /// operation left. The last case stands for a read turned away for the local network permission, which
    /// writes nothing on the line either and which this bench cannot have a recorder's check meet: the bench
    /// puts nothing on the network, and its recorder's check never looks at the permission.
    func testTheConditionsReasonIsTheLineOrThatTheAppIsNotConnected() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)

        // Known to be away, with none read.
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertFalse(model.recorderRulesLoaded)
        leaveALine(on: model)
        var asked = await recorder.asked
        await model.loadRecorderRules()
        XCTAssertEqual(model.recorderRulesFailure, lineLeft)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked for its conditions")

        // Known to be away, with a list read before.
        await reconnect(model)
        await model.loadRecorderRules()
        let rules = model.recorderRules
        XCTAssertFalse(rules.isEmpty)
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        leaveALine(on: model)
        asked = await recorder.asked
        await model.loadRecorderRules()
        XCTAssertEqual(model.recorderRules, rules, "the list read before went")
        XCTAssertTrue(model.recorderRulesLoaded)
        XCTAssertNil(model.recorderRulesFailure, "the screen says the list it shows could not be read")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft)
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked for its conditions")

        // A read whose silence is not said: held, while a connect meets silence; then silent itself.
        await reconnect(model)
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.conditions)
        let reading = Task { await model.loadRecorderRules() }
        try await until("the conditions were never asked for") {
            await recorder.asked(Kind.conditions, since: before) == 1
        }
        await recorder.goQuiet(for: 1)
        await model.connect()
        XCTAssertTrue(model.gaveUp, "the connect was meant to meet silence")
        XCTAssertNotNil(model.problem(for: .recorder), "the connect's silence was meant to be said")
        clearTheLine(on: model)
        await recorder.goQuiet(on: Kind.conditions)
        await recorder.letGo()
        await reading.value
        XCTAssertNil(model.problem(for: .recorder), "the read's silence was said a second time")
        XCTAssertEqual(model.recorderRulesFailure, Said.conditionsNotAsked)
    }

    /// What the strip says while a keyword condition is added or removed and the list is read after it: the
    /// write's own line while the write is out, and then the read's own while the read is.
    ///
    /// As it is today, and to be rewritten: a later change keeps the write's line up until the read after it is
    /// in, the read having none of its own.
    func testAConditionsWriteAndTheReadAfterItEachPutUpTheirOwnLine() async throws {
        let (_, recorder, model, subjects) = try await settled()
        for row in [Funnelled.add, .remove] {
            let before = await recorder.asked
            await recorder.holdTheNext(row.kind)
            let asking = Task { await row.ask(model, subjects) }
            try await until("\(row.name) never got to the recorder") {
                await recorder.asked(row.kind, since: before) == 1
            }
            XCTAssertEqual(model.busy, row.line, row.name)
            await recorder.holdTheNext(Kind.conditions)
            await recorder.letGo(only: row.kind)
            try await until("the conditions were never read after \(row.name)") {
                await recorder.asked(Kind.conditions, since: before) == 1
            }
            XCTAssertEqual(model.busy, Funnelled.conditions.line, "after \(row.name)")
            await recorder.letGo()
            expectEqual(await asking.value, true, model.problem(for: .recorder) ?? "no reason given")
            XCTAssertNil(model.busy, row.name)
        }
    }

    // MARK: - a recording the recorder does not hold, and playback

    /// A recording's delete or protect that the recorder answers it holds no such recording (820) is said in the
    /// recorder's words, as any refusal is: the recorder is kept, the list is left as it was, and nothing is read
    /// after it -- neither the list nor, after a delete, the free space.
    ///
    /// This pins the code, not the recorder: a BDZ is documented to answer a delete of a number it does not know
    /// with success, and what it answers a change of one has not been seen. The reservations' delete and change
    /// read their list again after such an answer; this is written down as a difference, not aligned.
    func testARecordingTheRecorderSaysItDoesNotHoldIsSaidAndNothingIsReadAfter() async throws {
        let (_, recorder, model, subjects) = try await settled()
        for row in [Funnelled.delete, .protect] {
            let titles = model.titles
            leaveALine(on: model)
            let before = await recorder.asked
            await recorder.answer(row.kind, with: .fault(820))
            let answer = await row.ask(model, subjects)

            XCTAssertEqual(answer, false, row.name)
            XCTAssertEqual(model.problem(for: .recorder), Said.fault(820, row.kind), row.name)
            XCTAssertTrue(model.connected, row.name)
            XCTAssertFalse(model.gaveUp, row.name)
            XCTAssertEqual(model.titles, titles, "\(row.name) changed the list")
            XCTAssertTrue(model.titlesLoaded, row.name)
            expectEqual(await recorder.asked(row.kind, since: before), 1, row.name)
            expectEqual(await recorder.asked(Kind.recordings, since: before), 0, "the list was read after \(row.name)")
            expectEqual(await recorder.asked(Kind.freeSpace, since: before), 0, "the room was read after \(row.name)")
        }
    }

    /// Playing a recording on a recorder in network standby: it answers 880, is turned on, and is asked every
    /// second whether it is on yet, under a line that counts the seconds, before the play is sent again. The
    /// offer to turn it on, left up by a pause it turned down before, goes at the door, before anything is
    /// answered. This costs one real second: the model hands the client no interval.
    func testPlayingTurnsARecorderInStandbyOnAndCountsTheSecondsOnItsLine() async throws {
        let (_, recorder, model, subjects) = try await settled()
        await recorder.answer(Kind.playback, with: .fault(880))
        await playARecording(model, subjects.title, "pause")
        XCTAssertTrue(model.needsPower, "the pause was meant to leave the offer up")
        let before = await recorder.asked

        await recorder.answer(Kind.playback, with: .fault(880))
        await recorder.answer(Kind.playStatus, with: .result("<status><powerstatus>PowerOn</powerstatus></status>"))
        await recorder.hold(only: Kind.playStatus)
        let playing = Task { await playARecording(model, subjects.title, "play") }
        try await until("the recorder was never asked whether it is on") {
            await recorder.asked(Kind.playStatus, since: before) == 1
        }
        XCTAssertEqual(model.busy, "レコーダーの電源を入れています（0 秒）")
        XCTAssertFalse(model.needsPower, "the offer stayed up while the recorder was being turned on")
        await recorder.letGo()
        await playing.value

        expectEqual(await recorder.asked(Kind.playback, since: before), 2)
        expectEqual(await recorder.asked(Kind.power, since: before), 1)
        expectEqual(await recorder.asked(Kind.playStatus, since: before), 1)
        XCTAssertFalse(model.needsPower)
        XCTAssertNil(model.problem(for: .recorder), "the play that went through left an earlier failure up")
        XCTAssertNil(model.busy)
    }

    /// Playing and turning the recorder on, asked while the recorder is being made sure of, wait for that answer:
    /// when the check meets silence nothing is sent, and what is said is the check's. A power request the
    /// recorder turns down leaves the offer to turn it on where it was, and says why.
    func testPlaybackAndPowerWaitForTheCheckAndAPowerRequestTurnedDownKeepsTheOffer() async throws {
        let (_, recorder, model, subjects) = try await settled()
        for row in [Funnelled.play, .power] {
            leaveALine(on: model)
            let count = await recorder.heard.count
            let (there, _) = try await duringACheck(by: model, of: recorder, endingIn: .silence, row.name,
                                                    waitingFor: { model.busy == row.line }) {
                await row.ask(model, subjects)
            }
            XCTAssertFalse(there, row.name)
            expectEqual(await recorder.heard(since: count), [Kind.description],
                        "\(row.name) was sent, or sent a probe of its own, beside a check that met silence")
            XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, row.name)
            XCTAssertTrue(model.gaveUp, row.name)
            XCTAssertNil(model.busy, row.name)
            await reconnect(model)
        }

        await recorder.answer(Kind.playback, with: .fault(880))
        await playARecording(model, subjects.title, "stop")
        XCTAssertTrue(model.needsPower, "the stop was meant to leave the offer up")
        let before = await recorder.asked
        await recorder.answer(Kind.power, with: .fault(402))
        await turnTheRecorderOn(model)
        expectEqual(await recorder.asked(Kind.power, since: before), 1)
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.power))
        XCTAssertTrue(model.needsPower, "the offer went with a power request the recorder turned down")
        XCTAssertTrue(model.connected)
    }
}

// MARK: - what the tests ask for

/// What the recorder is asked, as its fake on the bench names a kind of request: a SOAP action, or a file by its
/// name. Named once: a name misspelt in a test that looks for nothing having been asked would pass.
private enum Kind {
    static let reservations = "X_GetRecordScheduleList"
    static let recordings = "X_GetTitleList"
    static let conditions = "X_GetPrefRecSettingList"
    static let changeRecording = "X_UpdateTitle"
    static let deleteRecording = "X_DeleteTitle"
    static let playback = "X_PlayControlTitle"
    /// What playing asks while it waits for a recorder it has turned on.
    static let playStatus = "X_GetPlayStatus"
    static let power = "X_PowerControl"
    static let addCondition = "X_CreatePrefRecSetting"
    static let removeCondition = "X_DeletePrefRecSetting"
    static let freeSpace = "X_HDLnkGetRecordDestinationInfo"
    static let clashes = "X_GetConflictList"
    static let details = "X_GetTitleDetail"
    /// What a connect asks first, and the check before an operation.
    static let description = "description.xml"
    /// The guide's files in the order they are fetched: 地上デジタル, BS, CS, BS4K.
    static let guide = ["EPG_TRDEPG_FILE.dat", "EPG_BSEPG_FILE.dat", "EPG_CSEPG_FILE.dat", "EPG_ADVBSDEPG_FILE.dat"]
}

/// A recording to protect and to play, another to delete, a condition to remove and one to add: none being
/// recorded, none protected, all of the demo's.
private struct Subjects {
    let title: RecordedTitle, spare: RecordedTitle, rule: RecorderRule
    let request = RecorderRuleRequest(keywords: ["みほん"], qualityCode: 220)
}

/// Whether what a test set going has come back, for a test that does not wait for it to.
@MainActor
private final class Back {
    var came = false
}

/// The three lists the model holds of what the recorder said, to be looked at again after something failed.
private struct Lists: Equatable {
    let reservations: [Reservation], titles: [RecordedTitle], rules: [RecorderRule]

    @MainActor
    init(_ model: AppModel) {
        reservations = model.reservations
        titles = model.titles
        rules = model.recorderRules
    }
}

/// One of the operations that go through the funnel, as a screen asks for it.
@MainActor
private struct Funnelled {
    let name: String
    /// What the recorder is asked: a SOAP action, or a file by its name.
    let kind: String
    /// What the strip says while it is out.
    let line: String
    /// Whether it is taken to change something on the recorder: silence then leaves that unknown.
    var sends = false
    /// Whether it reads a list, or the guide: not made at all of a recorder known to be away, and made again by
    /// the screens, or by a connect, once the recorder is back.
    var reads = false
    /// Asks for it. What it returned, for the ones that say; nil for the others.
    let ask: @MainActor (AppModel, Subjects) async -> Bool?
    /// What the model holds once it has gone through.
    var holds: @MainActor (AppModel, Subjects) -> Bool = { _, _ in true }

    static let reservations = Funnelled(name: "the reservations", kind: Kind.reservations, line: "予約一覧を取得中",
                                        reads: true, ask: { model, _ in await model.loadReservations(); return nil })
    static let recordings = Funnelled(name: "the recordings", kind: Kind.recordings, line: "録画一覧を取得中",
                                      reads: true, ask: { model, _ in await model.loadTitles(force: true); return nil })
    static let conditions = Funnelled(name: "the conditions", kind: Kind.conditions,
                                      line: "おまかせ・まる録の設定を取得中", reads: true,
                                      ask: { model, _ in await model.loadRecorderRules(); return nil })
    static let protect = Funnelled(
        name: "the protect", kind: Kind.changeRecording, line: "保護中", sends: true,
        ask: { model, subjects in await protectARecording(model, subjects.title, true) },
        holds: { model, subjects in model.titles.first { $0.id == subjects.title.id }?.protected == true })
    static let unprotect = Funnelled(
        name: "the unprotect", kind: Kind.changeRecording, line: "保護を解除中", sends: true,
        ask: { model, subjects in await protectARecording(model, subjects.title, false) },
        holds: { model, subjects in model.titles.first { $0.id == subjects.title.id }?.protected == false })
    static let delete = Funnelled(
        name: "the delete", kind: Kind.deleteRecording, line: "削除中", sends: true,
        ask: { model, subjects in await deleteARecording(model, subjects.spare) },
        holds: { model, subjects in !model.titles.contains { $0.id == subjects.spare.id } })
    static let play = Funnelled(name: "the play", kind: Kind.playback, line: "再生を指示中",
                                ask: { model, subjects in
                                    await playARecording(model, subjects.title, "play"); return nil })
    static let pause = Funnelled(name: "the pause", kind: Kind.playback, line: "再生を指示中",
                                 ask: { model, subjects in
                                     await playARecording(model, subjects.title, "pause"); return nil })
    static let stop = Funnelled(name: "the stop", kind: Kind.playback, line: "停止中",
                                ask: { model, subjects in
                                    await playARecording(model, subjects.title, "stop"); return nil })
    static let power = Funnelled(name: "the power", kind: Kind.power, line: "電源を入れています",
                                 ask: { model, _ in await turnTheRecorderOn(model); return nil })
    static let add = Funnelled(
        name: "the condition added", kind: Kind.addCondition, line: "レコーダーに登録中", sends: true,
        ask: { model, subjects in await addACondition(model, subjects.request) },
        holds: { model, subjects in model.recorderRules.contains { $0.keywords == subjects.request.keywords } })
    static let remove = Funnelled(
        name: "the condition removed", kind: Kind.removeCondition, line: "レコーダーから削除中", sends: true,
        ask: { model, subjects in await removeACondition(model, subjects.rule) },
        holds: { model, subjects in !model.recorderRules.contains { $0.id == subjects.rule.id } })
    static let guide = Funnelled(name: "the guide", kind: Kind.guide[0], line: "番組表を取得中 (地上デジタル)",
                                 reads: true, ask: { model, _ in await model.refreshGuide(); return nil })

    /// Every one, in an order in which each can follow the one before it on one recorder.
    static let all = [reservations, recordings, conditions, protect, unprotect, delete, play, pause, stop, power,
                      add, remove, guide]
    /// The ones that are a SOAP action: all but the guide, whose failures are a test of their own.
    static let bySOAP = all.filter { $0.kind.hasPrefix("X_") }
}
