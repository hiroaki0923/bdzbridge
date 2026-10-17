import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder's operations, each asked for as a screen asks for it -- its recordings, its keyword conditions
/// and its guide, fetched by hand and at a connect, all of them the driver's steps (`RecorderDriver`): what is
/// on screen while one is out, what silence, a refusal and not being connected each leave behind, and what a
/// check, a connect or another recorder beside one does to it. Of the guide as well: what a refresh hands back
/// for the screen that asked to say, which files it asks for and of which client, that it waits its turn behind
/// another refresh and is made sure of once the turn has come and before each later file, and which cache
/// takes what it fetched.
///
/// They were written as gates: each pinned what the app did, so that the operations could be moved out of the
/// model and into RecorderKit with the test's body unchanged, and each change made on purpose afterwards
/// rewrote the tests it changed. Where a test holds something that is still to be changed on purpose, it says
/// so, and that change rewrites it. So a test asks only what a screen asks and reads only what a screen reads,
/// with the bench's own words for the rest (`Said`, `leaveALine`, `makeSure`): where an operation lives can
/// change under it, as the guide's did last. Every test that holds a file of the guide lets it go in its
/// teardown: the turn for fetching the guide is the process's, and one left held would keep every later
/// refresh waiting.
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
    /// Where an operation asks something before its own request -- a recording's delete asks whether the
    /// recording is still there, a condition's delete reads the list of conditions -- what is held is that
    /// question or that read, before which the line still stands.
    ///
    /// Last, a condition's delete goes only from the list just read: one the recorder no longer has, and one
    /// whose number stands there with other contents, are not sent for, and the result says so; one that is
    /// there is read, deleted, and read again.
    func testEachOperationSaysWhatItIsDoingHoldsTheRecorderAndOnlySuccessClearsTheLine() async throws {
        let (_, recorder, model, subjects) = try await settled()
        addTeardownBlock { await recorder.letGo() }
        let atTheStart = await recorder.asked
        let room = try XCTUnwrap(model.storage?.free, "the recorder never said how much room it has")

        for row in Funnelled.all {
            leaveALine(on: model)
            let before = await recorder.asked
            let held = row.asksFirst ?? row.kind
            await recorder.hold(only: held)
            let asking = Task { await row.ask(model, subjects) }
            try await until("the recorder was never asked for \(row.name)") {
                await recorder.asked(held, since: before) == 1
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
        expectEqual(await recorder.asked(Kind.conditions, since: atTheStart), 4,
                    "the conditions are read when asked for, after one is added, and before and after one is removed")
        expectEqual(await recorder.asked(Kind.freeSpace, since: atTheStart), 2,
                    "the free space is read with the recordings and after a delete")
        XCTAssertGreaterThan(model.storage?.free ?? 0, room, "the room the deleted recording took is not shown")
        for file in Kind.guide { expectEqual(await recorder.asked(file, since: atTheStart), 1, file) }
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertFalse(model.needsPower)

        // The condition just removed, removed again: the list is read, and nothing is sent.
        var count = await recorder.heard.count
        expectFalse(await removeACondition(model, subjects.rule))
        expectEqual(await recorder.heard(since: count), [Kind.conditions],
                    "a condition the recorder no longer has was sent for, or the list was not read first")
        XCTAssertNotEqual(whyNotJustNow(model), Said.notConnected)
        XCTAssertEqual(whyNotJustNow(model), Said.conditionNotInList)
        XCTAssertEqual(Said.conditionNotInList, RecorderDriver.conditionNotInList)
        XCTAssertNil(model.problem(for: .recorder), "the read before the delete went through and left the line")

        // One whose number stands on the recorder with other contents than the screen showed: nothing is sent.
        let present = try XCTUnwrap(model.recorderRules.first, "the demo was meant to hold another condition")
        var changed = present
        changed.keywords += ["ほかの語"]
        count = await recorder.heard.count
        expectFalse(await removeACondition(model, changed))
        expectEqual(await recorder.heard(since: count), [Kind.conditions],
                    "a condition changed on the recorder was sent for by its number")
        XCTAssertEqual(whyNotJustNow(model), Said.conditionNotInList)

        // One that is there as shown: read, deleted, and read again.
        count = await recorder.heard.count
        expectTrue(await removeACondition(model, present))
        expectEqual(await recorder.heard(since: count), [Kind.conditions, Kind.removeCondition, Kind.conditions])
    }

    /// Silence on an operation's own request leaves the app given up, whatever was being asked, and nothing is
    /// sent again -- then, or once the recorder is back. What changes something on the recorder says that it may
    /// have arrived all the same, which is why it is not sent again; anything else says what a read that met
    /// silence says. A recording's protect and delete mark the recordings unread, so that the list is read once
    /// the recorder answers rather than guessed at; a condition's write is not followed by a read of a recorder
    /// that has just gone silent.
    ///
    /// The free space is read after a delete and with the list, and is only shown: silence on it loses the
    /// recorder like any other and fails neither, and is said as a read's silence is, on the line the delete or
    /// the list cleared, where it stays. And a condition's delete that was turned down is followed by
    /// a read, whose silence is the newer thing to say.
    ///
    /// Playing, pausing, stopping and powering on are sent too, and say that they may have arrived in a sentence
    /// of their own, which sends the reader to the television's screen rather than to a list: on the line and in
    /// what each hands back.
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
            let said = row.sends ? Said.mayHaveArrived : row.instructs ? Said.instructionMayHaveArrived : Said.noAnswer
            XCTAssertEqual(model.problem(for: .recorder), said, row.name)
            if row.instructs {
                XCTAssertNotEqual(model.problem(for: .recorder), Said.noAnswer, "\(row.name) said a read's silence")
                XCTAssertEqual(whyNotJustNow(model), said, row.name)
                XCTAssertEqual(said, RecorderDriver.instructionMayHaveArrived)
            }
            XCTAssertTrue(Lists(model) == lists, "\(row.name) met silence and a list changed")
            XCTAssertEqual(model.titlesLoaded, !unread.contains(row.kind), row.name)
            if row.kind == Kind.conditions { XCTAssertEqual(model.recorderRulesFailure, Said.noAnswer) }
            if conditionWrites.contains(row.kind) {
                // A delete reads the list before it, and nothing after the silence.
                expectEqual(await recorder.asked(Kind.conditions, since: before), row.asksFirst == nil ? 0 : 1,
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
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "silence on the free space was not said")
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
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "silence on the free space was not said")
        XCTAssertTrue(model.gaveUp)

        // A condition's delete turned down, and silence on the read that follows it.
        await reconnect(model)
        await model.loadRecorderRules()
        XCTAssertNil(model.recorderRulesFailure)
        await recorder.answer(Kind.removeCondition, with: .fault(402))
        await recorder.answer(Kind.conditions, with: .silence, after: 1)
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
    /// condition whenever its own screen edits one, so the refusal may be of a number it no longer has -- and its
    /// reason is said in what it hands back, while the read, going through, clears the line, as the read after
    /// a reservation's delete refused for such a number does; an add that is refused reads nothing. A recording still being
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
            if row.kind == Kind.removeCondition {
                XCTAssertNil(model.problem(for: .recorder), "the refusal was put back over the read after it")
                XCTAssertEqual(whyNotJustNow(model), refusal, row.name)
            } else {
                XCTAssertEqual(model.problem(for: .recorder), refusal, row.name)
            }
            expectEqual(await recorder.asked(row.kind, since: before), 1, "\(row.name) was sent again")
            XCTAssertTrue(Lists(model) == lists, "\(row.name) was refused and a list changed")
            XCTAssertTrue(model.titlesLoaded, row.name)
            switch row.kind {
            case Kind.conditions:
                XCTAssertEqual(model.recorderRulesFailure, refusal)
            case Kind.addCondition:
                expectEqual(await recorder.asked(Kind.conditions, since: before), 0, "read after an add refused")
            case Kind.removeCondition:
                expectEqual(await recorder.asked(Kind.conditions, since: before), 2,
                            "not read before the delete, or not after it was refused")
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
    /// connected, and leaves the line an earlier operation left. So does the guide asked for by hand, which is
    /// a read with something to hand back: it makes no connect for a recorder known to be away. With no
    /// recorder in hand at all, nothing is asked and nothing written on the line either.
    ///
    /// The conditions' screen, with no list read, gives as its reason that the app is not connected, said by the
    /// read itself rather than the line an earlier operation left. And the recordings stay as read: nothing was
    /// sent, so there is nothing a read once the recorder answers would have to put right.
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
                // The guide asked for by hand hands back what it came to, for its screen to say.
                if row.kind == Kind.guide[0] {
                    XCTAssertEqual(answer, false, row.name)
                    XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
                }
            } else {
                XCTAssertNotEqual(answer, true, row.name)
                XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) wrote over the line at its door")
                XCTAssertEqual(whyNotJustNow(model), Said.notConnected, row.name)
            }
            XCTAssertEqual(model.guideDownloads, 0, row.name)
            XCTAssertNil(model.busy, row.name)
        }
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked")
        XCTAssertTrue(model.titlesLoaded, "the recordings were marked unread with nothing sent")

        await model.adopt(host: "")
        leaveALine(on: model)
        for row in Funnelled.all where !row.reads {
            let answer = await row.ask(model, subjects)
            XCTAssertNotEqual(answer, true, row.name)
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(row.name) said something, with no recorder")
        }
        expectEqual(await recorder.asked, asked, "a recorder the app had let go of was asked")
        await model.loadRecorderRules()
        XCTAssertEqual(model.recorderRulesFailure, Said.notConnected)
    }

    /// A recording the phone holds as protected, asked to be deleted, is turned away before anything is asked: the
    /// recorder refuses such a delete, and no screen offers one. The delete says why in what it hands back, and
    /// leaves the line and the list as they were.
    func testAProtectedRecordingIsTurnedAwayAtTheDeletesDoor() async throws {
        let (_, recorder, model, subjects) = try await settled()
        expectTrue(await protectARecording(model, subjects.spare, true),
                   model.problem(for: .recorder) ?? "no reason given")
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
    /// That is so of a write to a recording or a condition, and of the two things that ask the check for
    /// themselves: the question of what a reservation would clash with, asked as a programme's sheet opens, and a
    /// waiting reservation the reader asks to be sent again. The question has no line and nothing to wait for, so it is
    /// asked beside each write here, whose line says that both have been asked. (After a check answered busy the
    /// order it goes in says nothing: the client sends one request at a time whoever asks.)
    ///
    /// Busy says nothing of which recorder answered, though: the write asked beside such a check is not sent,
    /// and says in its result and on the line what was heard, while the question, which has no line, is answered
    /// as before.
    ///
    /// A protect and a delete turned away by a check that met silence leave the recordings as read: nothing was
    /// sent.
    func testWhatTheCheckFoundDecidesWhetherAWriteIsSent() async throws {
        let (bench, recorder, model, subjects) = try await settled(guide: true)
        let program = try await programmesNotReserved(model, 1)[0]
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
            XCTAssertTrue(model.titlesLoaded, "\(row.name) marked the recordings unread with nothing sent")
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

    /// A connect to the same recorder, made while an operation's request is out, makes a client of its own and
    /// takes nothing from the operation, which ends as it would have: a read that comes back is put in place,
    /// and a write that meets silence says it may have arrived, loses the recorder and marks its list unread.
    /// An operation does not ask whether the client it began with is still the one in hand: what it asks is
    /// whether the recorder was let go of meanwhile (`DeviceLink.letGo(since:)`), and nothing was let go of.
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
    /// connect reads its own, the read out having said that the reader was about to see the list -- once the
    /// read out is back, so that the last recorder's client and the newcomer's do not ask at once. A write's
    /// silence across the arrival is the last recorder's: it still says that the write may have arrived, but the
    /// newcomer, which has just answered, is not given up on, and its recordings, read by its connect, are not
    /// marked unread.
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
        let connecting = Task { await model.connect() }
        // Waiting for the read out, or sent beside it, which the assertion after says is wrong.
        try await until("the newcomer's connect never asked for its recordings") {
            if model.titleReads == 2 { return true }
            return await recorder.asked(Kind.recordings, since: before) > 1
        }
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertGreaterThan(model.timesForgotten, forgotten, "the lists were meant to go as the newcomer arrived")
        // Time enough for a read sent beside the one out to have reached the recorder.
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await recorder.asked(Kind.recordings, since: before), 1,
                    "the newcomer's recordings were asked for while the last recorder's read was out")
        XCTAssertTrue(isConnecting(model), "the newcomer's connect did not wait for the read out")
        // The read out comes back with a list of its own, to be told from the newcomer's.
        await recorder.answer(Kind.recordings, with: .result(Self.aListOfOne))
        await recorder.letGo()
        try await within(10, "the read across the arrival never came back") { await reading.value }
        try await within(10, "the newcomer's connect never came back") { await connecting.value }
        // And the newcomer's guide, which its connect started and did not wait for: a connect asked for while it
        // is out is made once it has ended.
        try await until("the newcomer's guide was never fetched") { !isConnecting(model) }
        XCTAssertTrue(model.titlesLoaded, "the newcomer's recordings were not read by its connect")
        XCTAssertGreaterThan(model.titles.count, 1, "the last recorder's list was put over the newcomer's")
        expectEqual(await recorder.asked(Kind.recordings, since: before), 2)

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
        XCTAssertFalse(model.gaveUp, "the newcomer was given up on for the last recorder's silence")
        XCTAssertTrue(model.titlesLoaded, "the newcomer's recordings were marked unread")
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
    /// not here: the model hands the driver no interval, so a test of it waits a real second. The sequence is
    /// held in the package (`RecorderRecordingsTests`), and the app's part of it goes with the recordings' own
    /// gates. A power request's silence says that it may have arrived, as playback's does.
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
        XCTAssertEqual(model.problem(for: .recorder), Said.instructionMayHaveArrived)
        XCTAssertTrue(model.needsPower, "the offer went with a power request that met silence")
        await reconnect(model)
        XCTAssertTrue(model.needsPower, "the offer went with the reconnect")

        await recorder.answer(Kind.playback, with: .fault(402))
        await playARecording(model, subjects.title, "stop")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, Kind.playback))
        XCTAssertFalse(model.needsPower, "the offer outlived the next thing asked of playback")
    }

    /// A guide asked for by hand passes over a type the recorder has no file for -- it answers 500 until it has
    /// built its files again -- fetches the rest, keeps the recorder and says a line for each type that failed,
    /// on the line of what went wrong and in what it hands back for its screen to say.
    /// The task that asked being cancelled does not stop it before a file: the guide is the app's rather than a
    /// screen's, and a pull-down's task goes with its screen. Silence stops it there, loses the recorder and
    /// says the read's sentence alone on the line; what it hands back says the type that failed before the
    /// silence and then the silence. The count of downloads comes back to nought either way.
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
        addTeardownBlock { await recorder.letGo() }
        let asking = Task { await refreshTheGuideByHand(model) }
        try await until("the guide was never asked for") { await recorder.asked(Kind.guide[0], since: before) == 1 }
        XCTAssertEqual(model.guideDownloads, 1)
        asking.cancel()
        await recorder.letGo()
        expectTrue(await asking.value, "a refresh that passed two types over was said not to have gone through")
        for file in Kind.guide { expectEqual(await recorder.asked(file, since: before), 1, file) }
        XCTAssertEqual(model.problem(for: .recorder),
                       "地上デジタルの番組表：\(missing(Kind.guide[0]))\nBS の番組表：\(missing(Kind.guide[1]))")
        XCTAssertEqual(whyNotJustNow(model), model.problem(for: .recorder),
                       "what was handed back does not say what the line says")
        XCTAssertTrue(model.connected, "a file the recorder has not built was taken for the recorder going")
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertNil(model.busy)

        before = await recorder.asked
        await recorder.answer(Kind.guide[0], with: .status(500))
        await recorder.goQuiet(on: Kind.guide[2])
        expectFalse(await refreshTheGuideByHand(model), "a refresh that silence stopped was said to have gone through")
        for file in Kind.guide.prefix(3) { expectEqual(await recorder.asked(file, since: before), 1, file) }
        expectEqual(await recorder.asked(Kind.guide[3], since: before), 0, "a silent recorder was asked for more")
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the type that failed was said over the silence")
        XCTAssertEqual(whyNotJustNow(model), "地上デジタルの番組表：\(missing(Kind.guide[0]))\n\(Said.noAnswer)",
                       "what was handed back does not say the type that failed before the silence, and the silence")
        XCTAssertEqual(model.guideDownloads, 0)
    }

    /// What 番組表を更新 came to is handed back to the screen it was pressed on, which says it in an alert. The
    /// guide's tab shows the line of what went wrong only where it has no guide to show: over a guide, a type
    /// that failed was said where nobody reads it, and the press seemed to do nothing.
    ///
    /// Over a guide on screen, with two types the recorder has not built: the refresh went through, and what it
    /// hands back to say is a line for each, the two the line of what went wrong holds; the guide on screen
    /// stays. Pressed again with every type answered for, it went through and has nothing to say.
    ///
    /// Pressed while the recorder is being made sure of, by a check that then meets silence: nothing is asked
    /// for, it did not go through, and what it hands back to say is what that check left on the line, that the
    /// recorder did not answer. What is said after a check's no is whatever stands on that line once the check
    /// has ended, and that the app is not connected where nothing does: the rest of that is held in the package
    /// (`RecorderRecordingsTests`), the bench's recorder having no other way to end a check than this one.
    func testWhatAGuideAskedForByHandCameToIsHandedBackForItsScreenToSay() async throws {
        let (_, recorder, model) = try await connectedHome()
        func missing(_ file: String) -> String { RecorderError.guideFileMissing(name: file, status: 500).explanation }
        let shown = model.counts[model.broadcasting]?.programs ?? 0
        XCTAssertGreaterThan(shown, 0, "a guide was meant to be on screen")

        let before = await recorder.asked
        await recorder.answer(Kind.guide[0], with: .status(500))
        await recorder.answer(Kind.guide[1], with: .status(500))
        expectTrue(await refreshTheGuideByHand(model), "a refresh that passed two types over did not go through")
        let lines = "地上デジタルの番組表：\(missing(Kind.guide[0]))\nBS の番組表：\(missing(Kind.guide[1]))"
        XCTAssertEqual(whyNotJustNow(model), lines, "what was handed back does not say the two types that failed")
        XCTAssertEqual(model.problem(for: .recorder), lines)
        for file in Kind.guide { expectEqual(await recorder.asked(file, since: before), 1, file) }
        XCTAssertEqual(model.counts[model.broadcasting]?.programs, shown,
                       "the guide on screen went with a type that failed")

        expectTrue(await refreshTheGuideByHand(model))
        XCTAssertNil(whyNotJustNow(model), "a refresh that went through with nothing failed had something to say")
        XCTAssertNil(model.problem(for: .recorder))

        leaveALine(on: model)
        let count = await recorder.heard.count
        let (there, went) = try await duringACheck(by: model, of: recorder, endingIn: .silence, "the guide",
                                                   waitingFor: { model.busy == "番組表を取得中" }) {
            await refreshTheGuideByHand(model)
        }
        XCTAssertFalse(there)
        XCTAssertFalse(went, "a refresh turned away by its check was said to have gone through")
        expectEqual(await recorder.heard(since: count), [Kind.description], "a file was asked for")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertEqual(whyNotJustNow(model), Said.noAnswer, "what was handed back does not say what the check left")
    }

    /// The guide asked for by hand beside a check, and after one. While the recorder is being made sure of, the
    /// asking waits for that answer under its own line, as a write does. When the check meets silence no file is
    /// asked for and no probe is sent beside the check's, what is said is the check's, and the count of
    /// downloads comes back to nought.
    ///
    /// After a check that heard the recorder busy with somebody else as it was asked who it is, nothing is
    /// fetched, as no list is read after one: busy says nothing of which recorder answered, and the files' own
    /// server names none. The press asks again who answers, however lately the recorder answered, hears busy
    /// again, and says so on the line and in what it hands back; the recorder is kept. Pressed once more with
    /// the recorder free, it asks who answers once more -- the one request this costs -- hears it, and fetches
    /// each file once, which clears the line.
    func testAGuideAskedForByHandWaitsForTheCheckAndIsNotFetchedAfterOneThatHeardTheRecorderBusy() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)

        leaveALine(on: model)
        let count = await recorder.heard.count
        let (there, _) = try await duringACheck(by: model, of: recorder, endingIn: .silence, "the guide",
                                                waitingFor: { model.busy == "番組表を取得中" }) {
            await refreshTheGuideByHand(model)
        }
        XCTAssertFalse(there)
        expectEqual(await recorder.heard(since: count), [Kind.description],
                    "a file was asked for, or a probe of the guide's own sent, beside a check that met silence")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertNil(model.busy)
        await reconnect(model)

        // Busy with somebody else as it is asked who it is, through both tries after the first.
        await recorder.busyAtTheDoor()
        expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
        leaveALine(on: model)
        var heard = await recorder.heard.count
        expectFalse(await refreshTheGuideByHand(model), "a guide went through after a check that heard busy")
        expectEqual(await recorder.heard(since: heard), [Kind.description, Kind.description, Kind.description],
                    "the guide was meant to ask again who answers, through its tries, and for no file")
        XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.description))
        XCTAssertEqual(whyNotJustNow(model), Said.busy(Kind.description),
                       "what was handed back does not say what the check heard")
        XCTAssertTrue(model.connected, "a recorder that answered busy was given up on")
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertNil(model.busy)

        await recorder.comeFree()
        heard = await recorder.heard.count
        expectTrue(await refreshTheGuideByHand(model), whyNotJustNow(model) ?? "nothing said")
        expectEqual(await recorder.heard(since: heard), [Kind.description, Ask.portOfTheGuide] + Kind.guide,
                    "who answers was meant to be asked once more, and then each file once")
        XCTAssertNil(model.problem(for: .recorder), "the guide went through and left what the check heard up")
        XCTAssertNil(whyNotJustNow(model))
        XCTAssertEqual(model.guideDownloads, 0)
    }

    /// A reconnect the recorder answered busy with somebody else leaves the app connected from the attach before,
    /// beside a client that has not heard which recorder answers it: nothing can be written to the recorder, the
    /// guide's buttons are live, and no 再接続 is offered. 番組表を更新 pressed then is the reader asking for it
    /// to be tried again, as a list pulled down is. It connects first, on a client of its own that asks once who
    /// answers, and the guide is fetched from a recorder that has said which it is, into the cache that is
    /// its own, and is on screen. A recording's and a condition's writes are turned away there and connect for
    /// nothing (`testAWriteIsNotSentOnAClientThatHasNotHeardWhichRecorderAnswersIt`).
    ///
    /// Each file is asked for once, whoever asks for it. A connect that goes through starts the refresh of what
    /// the cache says is behind as it hands back, and the press asks only for the types not answered for since
    /// it began: the two wait their turns, and whichever comes second goes by the cache's marks then. With
    /// every type's mark two days old, whichever comes first fetches all four and the other none. With the
    /// marks fresh and older than the press -- at the recorder's last rebuild, to the second -- the connect
    /// starts no refresh and the press fetches all four. Either way the eight files, each type's guide and its
    /// logos, are asked for once each.
    ///
    /// A type the recorder could not give has no mark, and is asked for once more by whichever comes second:
    /// with none of the four files built, each is asked for twice, the press went through, and what it says is
    /// a line for each type, the four the line of what went wrong holds.
    ///
    /// With the recorder busy still as the press connects, the connect comes to no recorder that can be asked:
    /// nothing is fetched, the app stays connected from the attach before, and the press says what the connect
    /// heard, which the line of what went wrong holds, as after a check that said no. It does not say that the
    /// app is not connected, with no 再接続 on offer.
    ///
    /// And where another recorder answers the press's connect, it is taken up, and its guide is fetched by the
    /// refresh that connect starts, as any that takes a recorder up does, each file once. The press fetches
    /// nothing after it, and says that another recorder answered.
    ///
    /// The marks are the test's own. Those at the last rebuild are read as fresh unless the recorder's hour of
    /// rebuilding passes between their writing and the press.
    func testAGuideAskedForByHandConnectsFirstWhereTheRecorderHasNotSaidWhichItIsAndAsksForEachFileOnce()
        async throws {
        let guide = try vectorFile("epg-sample.dat")
        /// At home, every type marked as answered for at `marks`, and then a reconnect the recorder answers busy.
        func afterABusyReconnect(marks: Date) async throws -> (bench: Bench, recorder: NamedRecorder, model: AppModel) {
            let (bench, recorder, model) = try await connectedHome(guide: false)
            let cache = try GuideStore(path: bench.guidePath)
            for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: marks) }
            await recorder.busyAtTheDoor()
            let made = bench.clientsMade
            await model.connect()
            XCTAssertEqual(bench.clientsMade, made + 1, "the reconnect was meant to make a client of its own")
            XCTAssertTrue(model.connected, "the attach before was meant to stand")
            return (bench, recorder, model)
        }
        func files(_ recorder: NamedRecorder, since count: Int) async -> [String] {
            await recorder.heard(since: count).filter { (Kind.guide + Ask.logos).contains($0) }
        }

        let behind = Date().addingTimeInterval(-2 * 86_400)
        for row in [(marks: behind, name: "marks two days old"),
                    (marks: GuideRefresh.lastRebuild(), name: "marks of the last rebuild")] {
            let (bench, recorder, model) = try await afterABusyReconnect(marks: row.marks)
            await recorder.comeFree()
            for file in Kind.guide { await recorder.answer(file, with: .body(guide)) }
            let made = bench.clientsMade
            let before = await recorder.asked
            let count = await recorder.heard.count

            expectTrue(await refreshTheGuideByHand(model), "\(row.name): \(whyNotJustNow(model) ?? "nothing said")")
            try await until("\(row.name): the refresh the press's connect started never ended") {
                !isConnecting(model) && model.guideDownloads == 0
            }

            XCTAssertNil(whyNotJustNow(model), row.name)
            XCTAssertNil(model.problem(for: .recorder), row.name)
            XCTAssertEqual(bench.clientsMade, made + 1, "\(row.name): the press was meant to connect, once")
            expectEqual(await recorder.asked(Kind.description, since: before), 1,
                        "\(row.name): who answers was meant to be asked once, by the press's connect")
            for file in Kind.guide + Ask.logos {
                expectEqual(await recorder.asked(file, since: before), 1, "\(file), \(row.name)")
            }
            expectEqual(await recorder.heard(since: count).first, Kind.description,
                        "\(row.name): something was asked before the recorder had said which it is")
            let cache = try GuideStore(path: bench.guidePath)
            expectEqual(try await cache.owner(), NamedRecorder.udn(1))
            for type in GuideRefresh.broadcastingTypes {
                expectTrue(try await cache.counts()[type]?.programs ?? 0 > 0,
                           "\(type) is not in the cache, \(row.name)")
            }
            XCTAssertGreaterThan(model.counts["td"]?.programs ?? 0, 0, "what was fetched is not on screen")
            XCTAssertFalse(model.guideIsStale, row.name)
            XCTAssertEqual(model.guideDownloads, 0, row.name)
            XCTAssertNil(model.busy, row.name)
        }

        // None of the four files built, for the press's connect or for the press.
        let (_, unbuilt, home) = try await afterABusyReconnect(marks: behind)
        await unbuilt.comeFree()
        for file in Kind.guide { await unbuilt.answer(file, with: .status(500), times: 2) }
        let asked = await unbuilt.asked
        expectTrue(await refreshTheGuideByHand(home), "a press that passed every type over did not go through")
        try await until("the refresh the press's connect started never ended") {
            !isConnecting(home) && home.guideDownloads == 0
        }
        for file in Kind.guide {
            expectEqual(await unbuilt.asked(file, since: asked), 2,
                        "\(file): once by the press and once by the refresh its connect started")
        }
        let lines = zip(["地上デジタル", "BS ", "CS ", "BS4K "], Kind.guide).map { type, file in
            "\(type)の番組表：\(RecorderError.guideFileMissing(name: file, status: 500).explanation)"
        }.joined(separator: "\n")
        XCTAssertEqual(whyNotJustNow(home), lines, "the press does not say the types its connect could not fetch")
        XCTAssertEqual(home.problem(for: .recorder), lines)
        XCTAssertEqual(home.guideDownloads, 0)

        // Busy with somebody else still as the press connects.
        let (bench, recorder, model) = try await afterABusyReconnect(marks: behind)
        var made = bench.clientsMade
        var count = await recorder.heard.count
        expectFalse(await refreshTheGuideByHand(model), "a press whose connect was answered busy went through")
        XCTAssertEqual(bench.clientsMade, made + 1, "the press was meant to connect")
        expectEqual(await files(recorder, since: count), [],
                    "a file was asked of a recorder that has not said which it is")
        XCTAssertEqual(whyNotJustNow(model), Said.busy(Kind.description),
                       "the press does not say what its connect left on the line")
        XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.description))
        XCTAssertTrue(model.connected, "the attach before was meant to stand")
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertNil(model.busy)

        // And another recorder at the address by the time the press connects.
        await recorder.become(2)
        await recorder.comeFree()
        made = bench.clientsMade
        count = await recorder.heard.count
        expectFalse(await refreshTheGuideByHand(model), "a press that took another recorder up went through")
        try await until("the newcomer's refresh never ended") { !isConnecting(model) && model.guideDownloads == 0 }
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(whyNotJustNow(model), Said.anotherAnswered)
        XCTAssertEqual(bench.clientsMade, made + 1, "the press was meant to connect, once")
        expectEqual(await files(recorder, since: count), Kind.guide,
                    "the newcomer's guide was meant to be fetched once, by the refresh its connect started")
        XCTAssertEqual(model.guideDownloads, 0)
        XCTAssertNil(model.busy)
    }

    /// What a refresh puts on the screens, and when. A type is on screen as soon as it is stored, before the next
    /// type has answered: the first run does not wait for BS, CS and BS4K behind the terrestrial programmes it
    /// opens on. And a type stored before the recorder fell silent over its logos, which nothing reports as
    /// stored, is on screen once the refresh has ended, by the read of the cache that ends every refresh however
    /// it went.
    func testATypeOfTheGuideIsOnScreenAsSoonAsItIsStoredAndOneStoredBeforeSilenceOnceTheRefreshEnds() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        let guide = try vectorFile("epg-sample.dat")
        XCTAssertEqual(model.counts["td"]?.programs, 0, "the cache was meant to hold no programme")
        XCTAssertTrue(model.channels.isEmpty, "the cache was meant to hold no station")

        let before = await recorder.asked
        await recorder.answer(Kind.guide[0], with: .body(guide))
        await recorder.hold(only: Kind.guide[1])
        addTeardownBlock { await recorder.letGo() }
        let asking = Task { await refreshTheGuideByHand(model) }
        try await until("the second type was never asked for") {
            await recorder.asked(Kind.guide[1], since: before) == 1
        }
        XCTAssertGreaterThan(model.counts["td"]?.programs ?? 0, 0,
                             "the first type was stored and is not on screen while the second is out")
        XCTAssertFalse(model.channels.isEmpty, "the stations of the type on screen are not shown")
        XCTAssertEqual(model.counts["bs"]?.programs, 0)

        // The second type comes with a guide, and the recorder says nothing when asked for its logos.
        await recorder.answer(Kind.guide[1], with: .body(guide))
        await recorder.goQuiet(on: Ask.logos[1])
        await recorder.letGo()
        _ = await asking.value
        XCTAssertTrue(model.gaveUp, "the recorder was meant to have fallen silent over the logos")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        expectEqual(await recorder.asked(Kind.guide[2], since: before), 0, "a silent recorder was asked for more")
        XCTAssertGreaterThan(model.counts["bs"]?.programs ?? 0, 0,
                             "a type stored before the silence is not on screen once the refresh has ended")
        XCTAssertEqual(model.guideDownloads, 0)
    }

    /// Which types a connect fetches is judged by what the cache holds as the connect asks, not by what the model
    /// read from it last: the overnight run writes the cache through a connection of its own, in this very
    /// process when the app was kept alive behind it. A type marked there as answered for, after the model read
    /// its marks, is not fetched, and its mark is on screen; a type whose mark there is behind the recorder's
    /// last rebuild, though the model holds a newer one, is fetched, and alone.
    ///
    /// The marks are the test's own, a day ahead of now and two days back: the hour the recorder rebuilds its
    /// files at cannot fall between a mark and the look at it.
    func testAConnectFetchesTheTypesTheCacheSaysAreBehindAndNoOther() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let cache = try GuideStore(path: bench.guidePath)
        let ahead = Date().addingTimeInterval(86_400), behind = Date().addingTimeInterval(-2 * 86_400)
        for type in GuideRefresh.broadcastingTypes {
            try await cache.noteNoGuide(broadcasting: type, at: type == "cs" ? behind : ahead)
        }
        let recorder = NamedRecorder(1)
        // The one type behind is asked for at the first connect and not had, so the model goes on holding it
        // as behind.
        await recorder.answer(Kind.guide[2], with: .status(500))
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        func files(since count: Int) async -> [String] {
            await recorder.heard(since: count).filter { Kind.guide.contains($0) }
        }
        expectEqual(await files(since: 0), [Kind.guide[2]], "the first connect was meant to ask for the one type")
        XCTAssertEqual(model.staleBroadcastingTypes, ["cs"], "the model was meant to hold the type as behind")

        // Marked through another connection as answered for, as the overnight run marks it.
        try await cache.noteNoGuide(broadcasting: "cs", at: ahead)
        var count = await recorder.heard.count
        await reconnect(model)
        expectEqual(await files(since: count), [], "a type the cache says was answered for was fetched")
        XCTAssertEqual(model.counts["cs"]?.checked, RecorderTime.format(ahead),
                       "what another connection wrote to the cache is not on screen")
        XCTAssertFalse(model.guideIsStale)

        // And one behind in the cache alone: the model read a mark a day ahead for it at the connect before.
        try await cache.noteNoGuide(broadcasting: "bs", at: behind)
        count = await recorder.heard.count
        await reconnect(model)
        expectEqual(await files(since: count), [Kind.guide[1]],
                    "the one type the cache says is behind was to be fetched, and no other")
    }

    /// A refresh that is out when another recorder takes the address: a guide goes only into the cache of the
    /// recorder it was fetched from. The newcomer is taken up by a connect while the first file is held, which
    /// makes the cache over to it, and comes back once its lists are in; its own refresh, on a client of its own,
    /// waits its turn behind the one that is out, and has asked for no file. Then the file held comes back with a
    /// guide, and the newcomer's refresh has its turn: its own first file is held in its turn, so that nothing of
    /// its own has answered. Nothing of the last recorder's is in the cache, which is the newcomer's by now, or
    /// on its screens: no programme, and no type marked as answered for. No further file was asked for of a
    /// recorder the press was not made for. The line left for the newcomer stands, neither cleared nor written.
    /// And the press did not go through: it says that another recorder answered. The newcomer's refresh then asks
    /// for each of its files once.
    func testAGuideFetchedAcrossAnotherRecordersArrivalStaysOutOfTheNewcomersCacheAndLeavesItsLine() async throws {
        let (bench, recorder, model) = try await connectedHome(guide: false)
        let cache = try GuideStore(path: bench.guidePath)
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.guide[0])
        addTeardownBlock { await recorder.letGo() }
        let asking = Task { await refreshTheGuideByHand(model) }
        try await until("the guide was never asked for") { await recorder.asked(Kind.guide[0], since: before) == 1 }

        // The newcomer's connect comes back once its lists are in: its refresh waits its turn behind the file
        // held.
        let arrived = await recorder.heard.count
        await recorder.become(2)
        try await within(5, "the newcomer's connect waited for the refresh that was out") { await model.connect() }
        try await until("the newcomer's refresh was never asked for") { model.guideDownloads == 2 }
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(try await cache.owner(), NamedRecorder.udn(2), "the cache was meant to be the newcomer's")
        leaveALine(on: model)

        // The file held comes back with a guide, and the next of its name, the newcomer's own, is held in turn.
        var heard = await recorder.heard.count
        await recorder.answer(Kind.guide[0], with: .body(try vectorFile("epg-sample.dat")))
        await recorder.holdTheNext(Kind.guide[0])
        await recorder.letTheFirstGo(of: Kind.guide[0])
        expectFalse(try await within(10, "the refresh let go of never came back") { await asking.value },
                    "a refresh went through for a recorder let go of meanwhile")
        // Whichever file the newcomer's refresh asks for first: its own first, unless the cache says otherwise.
        try await until("the newcomer's refresh never had its turn") {
            await recorder.heard(since: arrived).contains { Kind.guide.contains($0) }
        }

        expectEqual(await recorder.heard(since: heard), [Ask.portOfTheGuide, Kind.guide[0]],
                    "a file was asked for once the recorder was let go of, besides the newcomer's first")
        expectEqual(try await cache.owner(), NamedRecorder.udn(2))
        let counts = try await cache.counts()
        for type in GuideRefresh.broadcastingTypes {
            XCTAssertEqual(counts[type]?.programs, 0, "\(type): the last recorder's programmes are in the cache")
            XCTAssertNil(counts[type]?.lastAnswered, "\(type) is marked as answered for")
        }
        XCTAssertEqual(model.counts["td"]?.programs, 0, "the last recorder's programmes are on the newcomer's screens")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the line left for the newcomer was cleared or written")
        XCTAssertEqual(whyNotJustNow(model), Said.anotherAnswered)
        XCTAssertEqual(model.guideDownloads, 1, "the newcomer's refresh was meant to be out still")

        heard = await recorder.heard.count
        await recorder.letGo()
        try await until("the newcomer's refresh never ended") { !isConnecting(model) && model.guideDownloads == 0 }
        expectEqual(await recorder.heard(since: heard), Array(Kind.guide.dropFirst()),
                    "the newcomer's refresh was meant to ask for the rest of its files, each once")
    }

    /// One refresh of the guide at a time, whoever asks. The screens and the overnight run each have a client
    /// and a connection to the cache of their own, and a client's queue keeps apart only what is asked of that
    /// client: asked together, the two would ask the recorder for the same files at once. Here every type is
    /// behind, by marks two days old, and a refresh as the night makes one is out, its first file held, when a
    /// connect is made. The connect reads its lists and comes back: the guide is on its way meanwhile, as the
    /// guide's tab says on a first run, and the refresh it starts is counted as out and waits its turn under its
    /// line, asking for no file beside the one that is out. A second connect asked for meanwhile asks nothing.
    /// Let go, the night's refresh fetches its four types; and the connect's, its turn come, fetches what is
    /// still behind by the cache's marks then, which is nothing. Each file was asked for once, where each would
    /// have been asked for twice. Then the second connect, held off while the refresh was out, is made (in the
    /// first row only).
    ///
    /// A refresh that has asked the recorder for nothing leaves the line of what went wrong as it stands. In
    /// the second row the connect's read of the reservations, which comes before its guide, is answered busy
    /// with somebody else through its tries, and has said so on the line; the connect's refresh then waits its
    /// turn and finds nothing left to fetch, and the line is as the read left it, over reservations that were
    /// not read.
    ///
    /// The night's marks are of this moment. They are read as fresh unless the recorder's hour of rebuilding
    /// passes between their writing and the connect's look at them.
    func testAConnectMadeWhileAnotherRefreshIsOutWaitsItsTurnAndFetchesOnlyWhatIsStillBehind() async throws {
        for readIsAnsweredBusy in [false, true] {
            let row = readIsAnsweredBusy ? "the connect's read answered busy" : "the connect's read answered"
            let (bench, recorder, model) = try await connectedHome(guide: false)
            let cache = try GuideStore(path: bench.guidePath)
            let behind = Date().addingTimeInterval(-2 * 86_400)
            for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: behind) }
            // On screen too, as a launch reads them, so that the guide is behind before the connect looks.
            await model.reloadFromCache()
            XCTAssertTrue(model.guideIsStale, "the cache was meant to say that every type is behind")
            let night = aClient(of: recorder)
            let before = await recorder.asked
            await recorder.holdTheNext(Kind.guide[0])
            addTeardownBlock { await recorder.letGo() }
            let out = Task { await GuideRefresh.run(client: night, store: cache) }
            try await until("the night's guide was never asked for") {
                await recorder.asked(Kind.guide[0], since: before) == 1
            }

            if readIsAnsweredBusy {
                await recorder.beBusy(with: Kind.reservations)
            } else {
                await recorder.hold(only: Kind.reservations)
            }
            // What stands as the connect ends, before the refresh it started has had a turn of its own.
            let connecting = Task { () -> (connecting: Bool, onItsWay: Bool, run: Bool, choice: Bool) in
                await model.connect()
                return (model.connecting, model.guideOnItsWay, model.canStartARun, model.canChangeRecorder)
            }
            if !readIsAnsweredBusy {
                try await until("the connect never read the reservations") {
                    await recorder.asked(Kind.reservations, since: before) == 1
                }
                XCTAssertTrue(model.guideOnItsWay, "the guide is not said to be on its way while the connect reads")
                XCTAssertEqual(model.guideDownloads, 0)
                await recorder.letTheFirstGo(of: Kind.reservations)
            }
            let back = try await within(5, "\(row): the connect waited for its refresh") { await connecting.value }
            XCTAssertFalse(back.connecting, row)
            XCTAssertTrue(back.onItsWay, "\(row): the guide is not said to be on its way as the connect ends")
            XCTAssertFalse(back.run, "\(row): a run could be started as the connect ended")
            XCTAssertFalse(back.choice, "\(row): the recorder could be changed as the connect ended")
            XCTAssertTrue(model.guideIsStale, "the cache was meant to say that every type is behind")
            try await until("\(row): the connect's refresh was never asked for") {
                model.guideDownloads == 1 && model.busy == "番組表を取得中"
            }
            XCTAssertTrue(model.guideOnItsWay, row)
            // A second connect meanwhile asks nothing, and is made once the refresh has ended. Not in the row
            // whose read was answered busy: made, it would read the reservations again and clear the line, which
            // is what that row looks at.
            let asked = await recorder.asked(Kind.description, since: before)
            if !readIsAnsweredBusy {
                try await within(5, "\(row): a second connect waited for the refresh") { await model.connect() }
                expectEqual(await recorder.asked(Kind.description, since: before), asked,
                            "\(row): a second connect was made beside the connect's refresh")
            }

            await recorder.letGo()
            let fetched = try await within(10, "the night's refresh never ended") { await out.value }
            try await until("\(row): the connect's refresh never ended") {
                model.guideDownloads == 0 && !model.recorderHost.refreshesTheGuideAfterAConnect
            }
            try await until("\(row): the connect held off was never made once the refresh had ended") {
                await recorder.asked(Kind.description, since: before) == asked + (readIsAnsweredBusy ? 0 : 1)
                    && !isConnecting(model) && model.busy == nil
            }

            XCTAssertEqual(fetched.answered, GuideRefresh.broadcastingTypes, "the night's refresh did not end as asked")
            for file in Kind.guide {
                expectEqual(await recorder.asked(file, since: before), 1,
                            "\(row): \(file) was asked for by the connect as well, or beside the refresh that was out")
            }
            XCTAssertFalse(model.guideIsStale, "what the night fetched is not on screen")
            XCTAssertEqual(model.problem(for: .recorder), readIsAnsweredBusy ? Said.busy(Kind.reservations) : nil,
                           "\(row): a refresh that asked for nothing wrote on the line, or cleared it")
            XCTAssertEqual(model.guideDownloads, 0)
            XCTAssertNil(model.busy)
        }
    }

    /// The refresh a connect started is made sure of once its turn has come, as any refresh is, and not as part
    /// of the connect, whose checks pass without asking: here a check made while the refresh waits its turn hears
    /// the recorder busy with somebody else, and once the recorder is free and the night's refresh is let go,
    /// the connect's refresh asks who answers before it asks for the one type the night could not fetch.
    func testAConnectsRefreshIsMadeSureOfOnceItsTurnHasComeAsAnyRefreshIs() async throws {
        let (bench, recorder, model) = try await connectedHome(guide: false)
        let cache = try GuideStore(path: bench.guidePath)
        // Behind whatever the hour: marks from years ago.
        let behind = Date(timeIntervalSince1970: 1_700_000_000)
        for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: behind) }
        let night = aClient(of: recorder)
        let before = await recorder.asked
        await recorder.answer(Kind.guide[1], with: .status(500))
        await recorder.holdTheNext(Kind.guide[0])
        addTeardownBlock { await recorder.letGo() }
        let out = Task { await GuideRefresh.run(client: night, store: cache) }
        try await until("the night's guide was never asked for") {
            await recorder.asked(Kind.guide[0], since: before) == 1
        }
        let connecting = Task { await model.connect() }
        try await until("the connect's refresh was never asked for") { model.guideDownloads == 1 }

        await recorder.busyAtTheDoor()
        expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
        await recorder.comeFree()
        let heard = await recorder.heard.count
        await recorder.letGo()
        let fetched = try await within(10, "the night's refresh never ended") { await out.value }
        XCTAssertFalse(fetched.answered.contains("bs"), "the night was meant to be turned away for one type")
        try await within(10, "the connect never ended") { await connecting.value }
        try await until("the connect's refresh never ended") { !isConnecting(model) && model.busy == nil }

        let since = await recorder.heard(since: heard).filter { $0 == Kind.description || Kind.guide.contains($0) }
        // The night's ask for that type, answered with a fault after `heard` was noted, and the connect's after it.
        XCTAssertEqual(since.filter { $0 == Kind.guide[1] }.count, 2,
                       "the connect's refresh did not fetch the type the night could not: \(since)")
        let fileOfTheConnect = since.lastIndex(of: Kind.guide[1])
        XCTAssertTrue(since.prefix(upTo: fileOfTheConnect ?? 0).contains(Kind.description),
                      "the connect's refresh asked for its file without asking who answers first: \(since)")
        XCTAssertFalse(model.guideIsStale, model.problem(for: .recorder) ?? "no reason given")
    }

    /// A connect's refresh holds a second connect off only while the recorder it was for is in play. Here it
    /// waits its turn behind the night's refresh when a check hears another recorder at the address: the connect
    /// that takes the newcomer up is made at once, and not kept waiting behind a refresh of the recorder let go
    /// of, which is still waiting its turn.
    func testAConnectsRefreshDoesNotHoldOffTheConnectThatTakesANewcomerUp() async throws {
        let (bench, recorder, model) = try await connectedHome(guide: false)
        let cache = try GuideStore(path: bench.guidePath)
        // Behind whatever the hour: marks from years ago.
        let behind = Date(timeIntervalSince1970: 1_700_000_000)
        for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: behind) }
        let night = aClient(of: recorder)
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.guide[0])
        addTeardownBlock { await recorder.letGo() }
        let out = Task { await GuideRefresh.run(client: night, store: cache) }
        try await until("the night's guide was never asked for") {
            await recorder.asked(Kind.guide[0], since: before) == 1
        }
        try await within(5, "the connect waited for its refresh") { await model.connect() }
        try await until("the connect's refresh was never asked for") { model.guideDownloads == 1 }

        await recorder.become(2)
        expectFalse(await makeSure(model), "the check was meant to hear another recorder")
        XCTAssertEqual(model.problem(for: .recorder), Said.anotherAnswered)
        try await until("the newcomer was not taken up while the refresh of the last recorder was out") {
            model.info?.udn == NamedRecorder.udn(2)
        }
        expectEqual(await recorder.asked(Kind.guide[0], since: before), 1,
                    "the night's file was meant to be held still")

        await recorder.letGo()
        _ = try await within(10, "the night's refresh never ended") { await out.value }
        try await until("the newcomer's connect never ended", within: 20) { !isConnecting(model) && model.busy == nil }
    }

    /// Only the refresh a connect started last takes its hold on a second connect down as it ends. The turn is
    /// another refresh's, on a recorder and into a cache of the test's own, its first file held, when a connect's
    /// refresh starts and waits behind it, and then a check hears another recorder: the newcomer is taken up, and
    /// its own refresh waits behind the one for the recorder let go of. A connect asked for then is held off. Once
    /// the other refresh is let go, the refresh for the recorder let go of ends first, fetching nothing; the
    /// newcomer's, its first file held, still holds that connect off, which is made once the newcomer's refresh
    /// has ended.
    func testARefreshForARecorderLetGoOfEndingFirstLeavesTheNewcomersHoldInPlace() async throws {
        let (bench, recorder, model) = try await connectedHome(guide: false)
        let cache = try GuideStore(path: bench.guidePath)
        // Behind whatever the hour: marks from years ago.
        let behind = Date(timeIntervalSince1970: 1_700_000_000)
        for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: behind) }
        let other = NamedRecorder(1)
        let elsewhere = try GuideStore(path: bench.folder.appendingPathComponent("another.sqlite3").path)
        await other.holdTheNext(Kind.guide[0])
        addTeardownBlock { await other.letGo() }
        addTeardownBlock { await recorder.letGo() }
        let out = Task { await GuideRefresh.run(client: aClient(of: other), store: elsewhere) }
        try await until("the other refresh was never asked for") { await other.asked(Kind.guide[0]) == 1 }
        let before = await recorder.asked
        try await within(5, "the connect waited for its refresh") { await model.connect() }
        try await until("the connect's refresh was never asked for") { model.guideDownloads == 1 }

        await recorder.become(2)
        expectFalse(await makeSure(model), "the check was meant to hear another recorder")
        try await until("the newcomer's refresh was never asked for", within: 20) {
            model.info?.udn == NamedRecorder.udn(2) && !model.connecting && model.guideDownloads == 2
        }
        let asked = await recorder.asked(Kind.description, since: before)
        try await within(5, "a second connect waited for the newcomer's refresh") { await model.connect() }
        expectEqual(await recorder.asked(Kind.description, since: before), asked,
                    "a second connect was made beside the newcomer's refresh")

        // The other refresh goes, and the newcomer's own first file is held as it is asked for.
        await recorder.holdTheNext(Kind.guide[0])
        await other.letGo()
        _ = try await within(10, "the other refresh never ended") { await out.value }
        try await until("the refresh for the recorder let go of never ended", within: 20) {
            await recorder.asked(Kind.guide[0], since: before) == 1 && model.guideDownloads == 1
        }
        XCTAssertTrue(model.recorderHost.refreshesTheGuideAfterAConnect,
                      "the refresh for the recorder let go of took the newcomer's hold down as it ended")
        expectEqual(await recorder.asked(Kind.description, since: before), asked,
                    "the connect held off was made beside the newcomer's refresh")

        await recorder.letGo()
        try await until("the connect held off was never made once the newcomer's refresh had ended", within: 20) {
            await recorder.asked(Kind.description, since: before) == asked + 1 && !isConnecting(model)
                && model.busy == nil
        }
        XCTAssertFalse(model.guideIsStale, model.problem(for: .recorder) ?? "no reason given")
    }

    /// A connect whose reads lost the recorder starts no refresh of the guide: the guide is behind, but there is
    /// nothing to fetch it from. Here the connect's read of the reservations meets silence. As the connect ends,
    /// no refresh is out, the guide is not said to be on its way, and nothing of the guide is asked.
    func testAConnectWhoseReadsLostTheRecorderStartsNoRefreshOfTheGuide() async throws {
        let (bench, recorder, model) = try await connectedHome(guide: false)
        let cache = try GuideStore(path: bench.guidePath)
        // Behind whatever the hour: marks from years ago.
        let behind = Date(timeIntervalSince1970: 1_700_000_000)
        for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: behind) }
        await model.reloadFromCache()
        XCTAssertTrue(model.guideIsStale, "the cache was meant to say that every type is behind")
        let before = await recorder.asked
        await recorder.goQuiet(on: Kind.reservations)
        // What stands as the connect ends, before anything it might have started has had a turn of its own.
        let connecting = Task { () -> (out: Bool, onItsWay: Bool) in
            await model.connect()
            return (model.recorderHost.refreshesTheGuideAfterAConnect, model.guideOnItsWay)
        }
        let back = try await within(20, "the connect never came back") { await connecting.value }
        XCTAssertFalse(model.connected, "the read was meant to lose the recorder")
        XCTAssertFalse(back.out, "a refresh of the guide was started for a recorder lost")
        XCTAssertFalse(back.onItsWay, "the guide was said to be on its way from a recorder lost")
        try await untilIdle(model)
        for file in Kind.guide {
            expectEqual(await recorder.asked(file, since: before), 0, "\(file) was asked of a recorder lost")
        }
    }

    /// The recorder is made sure of once a refresh has its turn, and not before the wait for it, which can be as
    /// long as the refresh in front. Here the turn is another refresh's, on a recorder and into a cache of the
    /// test's own, its first file held. 番組表を更新 is pressed: its line goes up and it waits its turn. Then
    /// something else makes sure of the recorder, and the other refresh is let go, so that the press has its
    /// turn.
    ///
    /// That check hears the recorder busy with somebody else, and the recorder is busy still: the press asks
    /// again who answers, through its tries, and for nothing of the guide, neither the port of its files nor a
    /// file. It did not go through, and says what it heard, on the line and in what it hands back, as a press
    /// made after such a check does. With the recorder free again by the time the turn comes, the press asks
    /// once who answers, hears it, and fetches each file, on a client that looked for their port at the connect.
    ///
    /// That check meets silence, with nothing to wake the recorder with: the recorder is known to be away by
    /// the time the turn comes, and nothing at all is asked of it. The press did not go through, the line is as
    /// that check left it, and the press says what stands there.
    func testAGuideThatWaitedItsTurnIsFetchedOnlyFromARecorderMadeSureOfOnceTheTurnHasCome() async throws {
        for row in ["busy", "busy, and free again", "silent"] {
            let (bench, recorder, model) = try await connectedHome(guide: false)
            let other = NamedRecorder(1)
            let elsewhere = try GuideStore(path: bench.folder.appendingPathComponent("another.sqlite3").path)
            await other.holdTheNext(Kind.guide[0])
            addTeardownBlock { await other.letGo() }
            let out = Task { await GuideRefresh.run(client: aClient(of: other), store: elsewhere) }
            try await until("the other refresh was never asked for") { await other.asked(Kind.guide[0]) == 1 }

            let count = await recorder.heard.count
            let back = Back()
            let pressing = Task {
                let went = await refreshTheGuideByHand(model)
                back.came = true
                return went
            }
            try await until("the press never put its line up") { model.busy == "番組表を取得中" || back.came }
            XCTAssertFalse(back.came, "\(row): the press did not wait for the refresh that was out")
            XCTAssertEqual(model.guideDownloads, 1, row)

            leaveALine(on: model)
            if row == "silent" {
                await recorder.goQuiet(on: Kind.description)
                expectFalse(await makeSure(model), "a recorder that said nothing was taken for one to ask")
            } else {
                await recorder.busyAtTheDoor()
                expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
                XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the check that heard busy wrote on the line")
            }
            if row == "busy, and free again" { await recorder.comeFree() }
            XCTAssertFalse(back.came, "\(row): the press did not wait for the refresh that was out")
            await other.letGo()
            _ = await out.value
            let went = await pressing.value

            let heard = await recorder.heard(since: count)
            switch row {
            case "busy":
                XCTAssertFalse(went, "a guide that waited its turn went through after a check that heard busy")
                XCTAssertEqual(heard, Array(repeating: Kind.description, count: 6),
                               "the press was meant to ask again who answers, through its tries, and for no file")
                XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.description))
                XCTAssertEqual(whyNotJustNow(model), Said.busy(Kind.description))
                XCTAssertTrue(model.connected, "a recorder that answered busy was given up on")
                await recorder.comeFree()
            case "silent":
                XCTAssertFalse(went, "a guide that waited its turn went through for a recorder known to be away")
                XCTAssertEqual(heard, [Kind.description], "a recorder known to be away was asked once the turn came")
                XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the line is not as the check left it")
                XCTAssertEqual(whyNotJustNow(model), Said.noAnswer, "the press does not say what the check said")
                XCTAssertTrue(model.gaveUp)
            default:
                XCTAssertTrue(went, whyNotJustNow(model) ?? "nothing said")
                XCTAssertEqual(heard, Array(repeating: Kind.description, count: 4) + Kind.guide,
                               "who answers was meant to be asked once more, and then each file once")
                XCTAssertNil(model.problem(for: .recorder), "the guide went through and left the line up")
            }
            XCTAssertEqual(model.guideDownloads, 0, row)
            XCTAssertNil(model.busy, row)
        }
    }

    /// Each file of the guide after the first is asked for only of a recorder made sure of, as each request of a
    /// run is: a refresh is as many requests as it has files, a type's guide and then its logos. Here the first
    /// type's file is out, held at the recorder, when a check is asked for beside it. The check waits its turn
    /// behind the file on the one client. The file comes with a guide, which is stored and on screen.
    ///
    /// The check hears the recorder busy with somebody else as it asks who it is, and the recorder is busy
    /// still: before the logos of the type it has stored the press asks again who answers, hears busy through
    /// its tries, and asks for no further file, not those logos either. It did not go through, and says what
    /// it heard, on the line and in what it hands back. The recorder is kept.
    ///
    /// That is so in both orders the check and the press can come in. Left to itself the check has as a rule
    /// ended by the time the press, with the file's programmes to store first, asks before the logos. In the
    /// row after it the check's ask is held at the recorder once the file has been answered, until the type
    /// is in the cache and the press has had its turns to come to its asking, so that the press is waiting
    /// for the check as it ends: it asks who answers itself all the same, as often.
    ///
    /// The check meets silence, with nothing to wake the recorder with: the recorder is lost, and that check
    /// says so on the line. The press asks for no further file and not who answers, and what it hands back
    /// says what the line says, not that the app is not connected.
    func testNoFurtherFileOfTheGuideIsAskedForOfARecorderHeardBusyOrLostBesideTheFirst() async throws {
        let waitedFor = "busy, the press waiting for the check as it ends"
        for row in ["busy", waitedFor, "silent"] {
            let (bench, recorder, model) = try await connectedHome(guide: false)
            let before = await recorder.asked
            await recorder.answer(Kind.guide[0], with: .body(try vectorFile("epg-sample.dat")))
            await recorder.holdTheNext(Kind.guide[0])
            addTeardownBlock { await recorder.letGo() }
            let pressing = Task { await refreshTheGuideByHand(model) }
            try await until("the guide was never asked for") { await recorder.asked(Kind.guide[0], since: before) == 1 }

            if row == "silent" { await recorder.goQuiet(on: Kind.description) } else { await recorder.busyAtTheDoor() }
            if row == waitedFor { await recorder.hold(only: Kind.description) }
            let check = Task { await makeSure(model) }
            try await until("the recorder was never made sure of") { isMakingSure(model) }
            let count = await recorder.heard.count
            if row == waitedFor {
                // The file alone, and the check's ask held behind it until the press has come to its asking.
                await recorder.letGo(only: Kind.guide[0])
                let cache = try GuideStore(path: bench.guidePath)
                try await until("the check never asked who answers, or the type was never stored") {
                    let asked = await recorder.asked(Kind.description, since: before)
                    let stored = (try? await cache.counts())?["td"]?.programs ?? 0
                    return asked == 1 && stored > 0
                }
                for _ in 0..<10_000 { await Task.yield() }
                XCTAssertTrue(isMakingSure(model), "the check was meant to be out still")
            }
            await recorder.letGo()
            expectEqual(await check.value, row != "silent", "\(row): the check did not end as it was meant to")
            expectFalse(await pressing.value, "\(row): a guide went on after a check beside its first file")

            let heard = await recorder.heard(since: count)
            XCTAssertEqual(heard.filter { (Kind.guide + Ask.logos).contains($0) }, [],
                           "\(row): a further file was asked for")
            if row != "silent" {
                XCTAssertEqual(heard.filter { $0 == Kind.description }.count, 6,
                               "\(row): who answers was meant to be asked by the check and again before the logos, "
                                   + "each thrice")
                XCTAssertEqual(model.problem(for: .recorder), Said.busy(Kind.description))
                XCTAssertEqual(whyNotJustNow(model), Said.busy(Kind.description),
                               "what was handed back does not say what was heard")
                XCTAssertTrue(model.connected, "a recorder that answered busy was given up on")
                await recorder.comeFree()
            } else {
                XCTAssertEqual(heard, [Kind.description], "a recorder known to be away was asked once it was lost")
                XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the line is not as the check left it")
                XCTAssertEqual(whyNotJustNow(model), Said.noAnswer,
                               "what was handed back does not say what the line says")
                XCTAssertTrue(model.gaveUp)
            }
            XCTAssertGreaterThan(model.counts["td"]?.programs ?? 0, 0,
                                 "\(row): the type stored before the stop is not on screen")
            XCTAssertEqual(model.guideDownloads, 0, row)
            XCTAssertNil(model.busy, row)
        }
    }

    /// A connect asks for the guide only where the cache says a type is behind. Over marks that are fresh it
    /// asks for none: no line goes up and no refresh is counted as out -- every connect would otherwise flash
    /// 番組表を取得中, and wait for whatever refresh is out. Here one is out, on a recorder and into a cache of
    /// the test's own, its first file held, so that a refresh asked for by the connect would be waiting its
    /// turn, counted and under its line; and the connect ends with none.
    ///
    /// The marks are the test's own, a day ahead of now.
    func testAConnectOverFreshMarksAsksForNoGuideWhateverRefreshIsOut() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let cache = try GuideStore(path: bench.guidePath)
        let ahead = Date().addingTimeInterval(86_400)
        for type in GuideRefresh.broadcastingTypes { try await cache.noteNoGuide(broadcasting: type, at: ahead) }
        let other = NamedRecorder(1)
        let elsewhere = try GuideStore(path: bench.folder.appendingPathComponent("another.sqlite3").path)
        await other.holdTheNext(Kind.guide[0])
        addTeardownBlock { await other.letGo() }
        let out = Task { await GuideRefresh.run(client: aClient(of: other), store: elsewhere) }
        try await until("the other refresh was never asked for") { await other.asked(Kind.guide[0]) == 1 }

        let count = await recorder.heard.count
        let back = Back()
        let connecting = Task {
            await model.connect()
            back.came = true
        }
        try await until("the connect neither ended nor asked for a refresh") { back.came || model.guideDownloads > 0 }
        XCTAssertTrue(back.came, "the connect waits, for a refresh it had no reason to ask for")
        XCTAssertEqual(model.guideDownloads, 0, "a refresh was counted as out over a cache with nothing behind")
        XCTAssertNil(model.busy, "a line is up over a cache with nothing behind")
        XCTAssertTrue(model.connected)
        expectEqual(await recorder.heard(since: count).filter { ([Ask.portOfTheGuide] + Kind.guide).contains($0) }, [],
                    "a file was asked for over a cache with nothing behind")

        await other.letGo()
        _ = await out.value
        await connecting.value
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
    /// As it is, and to stay: the clash check and the details go on after a check that heard the recorder busy,
    /// whatever is done about the writes and the reads of a list after such a check.
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

        // During a connect, with its ask of who answers held. Turned away at its door, a write comes back at once,
        // with nothing read after it. One that went on would put its line up and wait there, to be sent once the
        // ask is let go.
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
            while !back.came, model.busy != row.line, Date() < deadline {
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
    /// they were. Nor is the guide fetched: what its press hands back is held where the guide is asked for after
    /// such a check by itself
    /// (`testAGuideAskedForByHandWaitsForTheCheckAndIsNotFetchedAfterOneThatHeardTheRecorderBusy`). A
    /// recording's details and the question of what a reservation would clash with, which have no line, go on
    /// after such a check and are answered, asking nothing again, and leave the line as it was.
    func testNothingIsSentOrReadAfterACheckThatHeardTheRecorderBusyAndEachAsksAgain() async throws {
        let (_, recorder, model, subjects) = try await settled(guide: true)
        let program = try await programmesNotReserved(model, 1)[0]
        await recorder.busyAtTheDoor()
        expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
        let busy = Said.busy(Kind.description)
        let lists = Lists(model)

        for row in Funnelled.all where row.kind != Kind.reservations {
            leaveALine(on: model)
            let count = await recorder.asked
            let answer = await row.ask(model, subjects)
            XCTAssertNotEqual(answer, true, "\(row.name) went through after a check that heard busy")
            XCTAssertEqual(model.problem(for: .recorder), busy, "\(row.name) did not say what the check heard")
            XCTAssertNil(model.busy, row.name)
            if !row.reads { XCTAssertEqual(whyNotJustNow(model), busy, row.name) }
            expectEqual(await recorder.asked(row.kind, since: count), 0, "\(row.name) was sent")
            // Three asks each, busy through both tries after the first; nothing is read after a write not sent.
            expectEqual(await recorder.asked(Kind.description, since: count), 3,
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

    /// The free space is read after a delete, and with the recordings, only where a check of the recorder made
    /// then would have nothing to ask: that read makes no check of its own. A check asked for while a delete is
    /// out waits its turn behind it; its ask of who answers is held at the recorder, so that the check is still
    /// out once the delete has been answered, and then hears the recorder busy with somebody else. The delete
    /// has gone through and says so, and its row has left the list; the free space is not asked for behind that
    /// check, of a recorder that has not said which it is, and what is shown stays as it was last read. So it is
    /// with the recordings, read a row shorter after a delete on the recorder's own screen: the list is on
    /// screen, and no free space is asked for after it. The next read of the recordings, the recorder saying
    /// which it is again, reads it.
    func testTheFreeSpaceIsNotReadBehindACheckThatCameInBehindADeleteOrTheRecordings() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let room = try XCTUnwrap(model.storage?.free, "the recorder never said how much room it has")

        // A delete.
        await recorder.hold(only: Kind.deleteRecording)
        var before = await recorder.asked
        let deleting = Task { await deleteARecording(model, subjects.spare) }
        try await until("the delete never got to the recorder") {
            await recorder.asked(Kind.deleteRecording, since: before) == 1
        }
        await recorder.holdTheNext(Kind.description)
        var check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") { isMakingSure(model) }
        await recorder.letGo(only: Kind.deleteRecording)
        try await until("the delete was never answered") { !model.titles.contains { $0.id == subjects.spare.id } }
        await recorder.busyAtTheDoor()
        await recorder.letGo()
        expectTrue(await deleting.value, "a check that came in behind a delete failed it")
        expectTrue(await check.value, "a recorder that answered busy was taken for gone")
        expectEqual(await recorder.asked(Kind.description, since: before), 3,
                    "the check was meant to ask who answers, through the client's tries")
        expectEqual(await recorder.asked(Kind.freeSpace, since: before), 0,
                    "the free space was read after a delete, behind a check that heard the recorder busy")
        XCTAssertEqual(model.storage?.free, room, "the free space shown is not as it was last read")
        await recorder.comeFree()
        expectTrue(await makeSure(model), "the recorder was meant to say which it is again")

        // The recordings, a row shorter than they were last read.
        try await aClient(of: recorder).deleteTitle(id: subjects.title.id)
        await recorder.hold(only: Kind.recordings)
        before = await recorder.asked
        let reading = Task { await model.loadTitles(force: true) }
        try await until("the recordings were never asked for") {
            await recorder.asked(Kind.recordings, since: before) == 1
        }
        await recorder.holdTheNext(Kind.description)
        check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") { isMakingSure(model) }
        await recorder.letGo(only: Kind.recordings)
        try await until("the recordings were never read") { !model.titles.contains { $0.id == subjects.title.id } }
        await recorder.busyAtTheDoor()
        await recorder.letGo()
        await reading.value
        expectTrue(await check.value, "a recorder that answered busy was taken for gone")
        XCTAssertTrue(model.titlesLoaded, "a check that came in behind the recordings failed their read")
        expectEqual(await recorder.asked(Kind.description, since: before), 3,
                    "the check was meant to ask who answers, through the client's tries")
        expectEqual(await recorder.asked(Kind.freeSpace, since: before), 0,
                    "the free space was read with the recordings, behind a check that heard the recorder busy")
        XCTAssertEqual(model.storage?.free, room, "the free space shown is not as it was last read")

        // Read again once the recorder says which it is: the free space with them.
        await recorder.comeFree()
        await model.loadTitles(force: true)
        XCTAssertGreaterThan(model.storage?.free ?? 0, room, "the room the deleted recordings took is not shown")
    }

    /// A write asked of a recorder once another has taken its place, which emptied the lists in that turn. Asked
    /// and held at its own request, it is answered by the newcomer, and its answer is taken as one across a
    /// let-go, as a reservation's delete takes it: done, but the newcomer's line is left alone, and nothing of
    /// it is put on the newcomer's lists, which its connect read -- nor is the list read after a condition added
    /// or removed, which would be the newcomer's. A protect, a delete, a condition added and one removed.
    ///
    /// Queued on the last recorder's client behind a list read that was out when the newcomer described itself,
    /// it is not sent once that read is back: the client was made for the recorder let go of, and sends nothing
    /// more. It is turned away as one let go of, saying that another recorder answered, the newcomer kept. What
    /// the line and the lists come to there is the newcomer's connect's, which waits for that read to be back to
    /// read its own list and clears the line as it goes through. A recording's delete asks first whether the
    /// recording is still there, and a condition's delete reads the list of conditions first: there that
    /// question or that read is what waits, and the delete is turned away the same way.
    func testAWriteAnsweredAfterAnotherRecorderDescribedItselfIsTakenAsAcrossALetGo() async throws {
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
                let reads = model.titleReads
                let connecting = Task { await model.connect() }
                if queued {
                    // The newcomer's connect waits to read its recordings until the read out is back.
                    try await until("the newcomer's connect never asked for its recordings, \(how)") {
                        if model.titleReads == reads + 1 { return true }
                        return await recorder.asked(Kind.recordings, since: before) > 1
                    }
                } else {
                    try await within(10, "the newcomer's connect never came back, \(how)") { await connecting.value }
                    // And the newcomer's guide, which its connect started and did not wait for.
                    try await until("the newcomer's guide was never fetched, \(how)") { !isConnecting(model) }
                }
                XCTAssertEqual(model.info?.udn, NamedRecorder.udn(newcomer),
                               model.problem(for: .recorder) ?? "no reason given")
                if queued {
                    // What this half stands on: the write still waits on the last recorder's client, behind the
                    // read, asked of nobody yet, as the newcomer has arrived.
                    expectEqual(await recorder.asked(row.kind, since: before), 0,
                                "\(how) was sent before the read it queued behind came back")
                    expectEqual(await recorder.asked(Kind.recordings, since: before), 1,
                                "the newcomer's recordings were asked for beside the read out, \(how)")
                }
                leaveALine(on: model)
                let newcomers = Lists(model)
                await recorder.letGo()
                _ = try await within(10, "the read never came back, \(how)") { await reading?.value }
                let answer = try await within(10, "\(how) never came back") { await asking.value }
                try await within(10, "the newcomer's connect never came back, \(how)") { await connecting.value }
                try await until("the newcomer's guide was never fetched, \(how)") { !isConnecting(model) }

                if queued {
                    XCTAssertEqual(answer, false, "\(how) was sent across the let-go")
                    XCTAssertEqual(whyNotJustNow(model), Said.anotherAnswered, how)
                    XCTAssertFalse(model.gaveUp, how)
                    expectEqual(await recorder.asked(row.kind, since: before), 0, how)
                    continue
                }
                XCTAssertEqual(answer, true, "\(how): \(model.problem(for: .recorder) ?? "no reason given")")
                XCTAssertFalse(model.gaveUp, how)
                expectEqual(await recorder.asked(row.kind, since: before), 1, how)
                if !queued {
                    XCTAssertEqual(model.problem(for: .recorder), lineLeft, "\(how) cleared the newcomer's line")
                    XCTAssertTrue(Lists(model) == newcomers, "\(how) was put on the newcomer's lists")
                }
            }
        }
    }

    /// The keyword conditions read from the recorder in play, and still out when another recorder describes
    /// itself on a connect, whose arrival empties the lists in that turn: as the recordings are, the list that
    /// comes back afterwards is the last recorder's and is not put over the newcomer's, and the newcomer's
    /// connect reads its own, the read out having said that the reader was about to see the list, though none
    /// had been read when it arrived -- once the read out is back, as for the recordings.
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
        let connecting = Task { await model.connect() }
        // Waiting for the read out, or sent beside it, which the assertion after says is wrong.
        try await until("the newcomer's connect never asked for its conditions") {
            if model.conditionReads == 2 { return true }
            return await recorder.asked(Kind.conditions, since: before) > 1
        }
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        // Time enough for a read sent beside the one out to have reached the recorder.
        try await Task.sleep(for: .milliseconds(300))
        expectEqual(await recorder.asked(Kind.conditions, since: before), 1,
                    "the newcomer's conditions were asked for while the last recorder's read was out")
        // The read out comes back with none, to be told from the newcomer's list.
        await recorder.answer(Kind.conditions, with: .result("<xsrs></xsrs>"))
        await recorder.letGo()
        await reading.value
        await connecting.value

        XCTAssertTrue(model.recorderRulesLoaded, "the newcomer's conditions were not read by its connect")
        XCTAssertFalse(model.recorderRules.isEmpty, "the last recorder's list was put over the newcomer's")
        expectEqual(await recorder.asked(Kind.conditions, since: before), 2)
        XCTAssertNil(model.recorderRulesFailure)
    }

    /// The recordings, and the keyword conditions, asked for a second time while a read of them is out -- the
    /// tab, a pull-down and the search come together -- are read once: the second is handed what the first came
    /// to, as for the reservations, and the list is the one read.
    func testTwoReadsOfAListAskedTogetherSendOne() async throws {
        let (_, recorder, model, subjects) = try await settled()
        for row in [Funnelled.recordings, .conditions] {
            let before = await recorder.asked
            await recorder.holdTheNext(row.kind)
            let first = Task { _ = await row.ask(model, subjects) }
            try await until("\(row.name) were never asked for") {
                await recorder.asked(row.kind, since: before) == 1
            }
            let second = Task { _ = await row.ask(model, subjects) }
            try await until("\(row.name) were never asked for a second time") {
                (row.kind == Kind.recordings ? model.titleReads : model.conditionReads) == 2
            }
            await recorder.letGo()
            await first.value
            await second.value

            expectEqual(await recorder.asked(row.kind, since: before), 1, "\(row.name) were read twice")
            XCTAssertTrue(row.kind == Kind.recordings ? !model.titles.isEmpty : !model.recorderRules.isEmpty)
            XCTAssertNil(model.problem(for: .recorder), row.name)
            XCTAssertNil(model.busy, row.name)
        }
    }

    /// The list read after a keyword condition added or removed is one of the conditions' reads: asked for while
    /// it is out, the conditions are read once, the read after handing over what it came to. It takes no read out
    /// as it begins, though: that one was asked before the write was answered, so it is waited for, and the list
    /// is read again after it. Either way the list kept shows the write. A delete reads the list before it as
    /// well, which is let through here and counted.
    func testTheListReadAfterAConditionAddedOrRemovedIsOneOfItsReadsAndTakesNoEarlierOne() async throws {
        for row in [Funnelled.add, .remove] {
            // Which read of the conditions the list after the write is.
            let afterTheWrite = row.asksFirst == nil ? 1 : 2
            for readOutFirst in [false, true] {
                let how = "\(row.name), \(readOutFirst ? "a read asked while it was out" : "a read asked after it")"
                let (_, recorder, model, subjects) = try await settled()
                addTeardownBlock { await recorder.letGo() }
                let before = await recorder.asked
                // The read asked for while the write is out queues behind it on the client; the one asked for
                // after it, behind the list read after it.
                if readOutFirst {
                    await recorder.holdTheNext(row.kind)
                } else if afterTheWrite == 1 {
                    await recorder.holdTheNext(Kind.conditions)
                } else {
                    await recorder.hold(only: Kind.conditions)
                }
                let writing = Task { await row.ask(model, subjects) }
                if !readOutFirst, afterTheWrite == 2 {
                    try await until("the list before the write was never asked for, \(how)") {
                        await recorder.asked(Kind.conditions, since: before) == 1
                    }
                    await recorder.letTheFirstGo(of: Kind.conditions)
                }
                try await until("\(readOutFirst ? "the write" : "the list after it") was never asked for, \(how)") {
                    if readOutFirst { return await recorder.asked(row.kind, since: before) == 1 }
                    return await recorder.asked(Kind.conditions, since: before) == afterTheWrite
                }
                let reading = Task { await model.loadRecorderRules() }
                try await until("the conditions were never asked for, \(how)") { model.conditionReads == 2 }
                await recorder.letGo()
                let answer = await writing.value
                await reading.value

                XCTAssertEqual(answer, true, "\(how): \(model.problem(for: .recorder) ?? "no reason given")")
                let reads = afterTheWrite + (readOutFirst ? 1 : 0)
                expectEqual(await recorder.asked(Kind.conditions, since: before), reads,
                            readOutFirst ? "the list after the write was taken from a read asked before it, \(how)"
                                : "the conditions were read beside the list after the write, \(how)")
                XCTAssertTrue(row.holds(model, subjects), "the list kept does not show the write, \(how)")
                XCTAssertNil(model.problem(for: .recorder), how)
                XCTAssertNil(model.busy, how)
            }
        }
    }

    /// A play that has turned the recorder on and waits for it, while another recorder describes itself on a
    /// connect: once the wait is over the play is not sent again, to the newcomer, which would play a recording
    /// of its own of that number. It says that another recorder answered; the offer to turn the recorder on is
    /// left as the newcomer has it. This waits a real second, the poll's.
    func testAPlayWaitingForThePowerIsNotSentToAnotherRecorderThatAnswersMeanwhile() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let before = await recorder.asked
        await recorder.answer(Kind.playback, with: .fault(880))
        await recorder.answer(Kind.playStatus, with: .result("<status><powerstatus>PowerOn</powerstatus></status>"))
        await recorder.holdTheNext(Kind.playStatus)
        let playing = Task { await playARecording(model, subjects.title, "play") }
        try await until("the recorder was never asked whether it is on") {
            await recorder.asked(Kind.playStatus, since: before) == 1
        }
        await recorder.become(2)
        await model.connect()
        // What this stands on: the newcomer described itself, and was connected to, during the power wait.
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertTrue(model.connected)
        await recorder.letGo()
        await playing.value

        expectEqual(await recorder.asked(Kind.playback, since: before), 1, "the play was sent again, to the newcomer")
        expectEqual(await recorder.asked(Kind.power, since: before), 1)
        XCTAssertEqual(whyNotJustNow(model), Said.anotherAnswered)
        XCTAssertFalse(model.needsPower)
        XCTAssertFalse(model.gaveUp)
    }

    /// A play whose first request is answered 880 once another recorder has described itself on a connect --
    /// the request held across the arrival -- turns nobody on: the power-on is for the recorder the play began
    /// with, and the newcomer is sent nothing, neither the power-on nor the play after it. It says that another
    /// recorder answered, and puts up no offer to turn the newcomer on.
    func testAPlayAnsweredStandbyAcrossAnotherRecordersArrivalTurnsNobodyOn() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let before = await recorder.asked
        await recorder.answer(Kind.playback, with: .fault(880))
        await recorder.answer(Kind.playStatus, with: .result("<status><powerstatus>PowerOn</powerstatus></status>"))
        await recorder.holdTheNext(Kind.playback)
        let playing = Task { await playARecording(model, subjects.title, "play") }
        try await until("the play never got to the recorder") {
            await recorder.asked(Kind.playback, since: before) == 1
        }
        await recorder.become(2)
        await model.connect()
        // What this stands on: the newcomer described itself, and was connected to, with the play out.
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertTrue(model.connected)
        await recorder.letGo()
        await playing.value

        expectEqual(await recorder.asked(Kind.power, since: before), 0, "the newcomer was turned on")
        expectEqual(await recorder.asked(Kind.playback, since: before), 1, "the play was sent again, to the newcomer")
        expectEqual(await recorder.asked(Kind.playStatus, since: before), 0)
        XCTAssertEqual(whyNotJustNow(model), Said.anotherAnswered)
        XCTAssertFalse(model.needsPower)
        XCTAssertFalse(model.gaveUp)
    }

    /// A write whose check is out as the recorder is let go of -- another address chosen, and a connect to it
    /// under way, before the check meets silence -- says that another recorder answered, as a reservation asked
    /// in that moment does, rather than that the app is not connected: what the check met was the recorder let
    /// go of. Nothing is sent to either. No screen gets here, the choice of a recorder being held while a check
    /// is out; the model's own entry is asked.
    func testAWriteWhoseCheckEndsAcrossALetGoSaysAnotherRecorderAnswered() async throws {
        let bench = try aBench()
        let (first, second) = (NamedRecorder(1), NamedRecorder(2))
        let model = bench.model(recorders: [Bench.host: first, Bench.otherHost: second])
        addTeardownBlock {
            await first.letGo()
            await second.letGo()
        }
        await model.start()
        try await untilConnected(model)
        await model.loadTitles()
        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })

        let asked = await first.asked(Kind.description)
        await first.hold(only: Kind.description)
        let checking = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") { await first.asked(Kind.description) > asked }
        let protecting = Task { await protectARecording(model, title, true) }
        try await until("the protect was never begun") { model.busy == Funnelled.protect.line }
        model.forgetTheRecorder()
        model.host = Bench.otherHost
        await second.hold(only: Kind.description)
        let connecting = Task { await model.connect() }
        try await until("the other address was never asked") { await second.asked(Kind.description) == 1 }
        await first.goQuiet(on: Kind.description)
        await first.letGo()
        _ = await checking.value
        let protected = try await within(10, "the protect never ended") { await protecting.value }
        await second.letGo()
        await connecting.value

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2),
                       "the connect to the other address was meant to go through")
        XCTAssertFalse(protected)
        XCTAssertEqual(whyNotJustNow(model), Said.anotherAnswered)
        expectEqual(await first.asked(Kind.changeRecording), 0, "protected on the recorder let go of")
        expectEqual(await second.asked(Kind.changeRecording), 0, "protected on the recorder at the other address")
    }

    // MARK: - the keyword conditions' reason and lines

    /// Why the keyword conditions' screen has no list to show, and what a read of them leaves when the recorder
    /// cannot be asked, said by the read itself. Known to be away with none read, turned away at its door, the
    /// screen's reason is that the app is not connected, whatever line an earlier operation left. Known to be
    /// away with a list read before, the list, its screen and the line are left as they were. And a read whose
    /// silence is not said -- the recorder known to be away by the time it is answered, a connect made meanwhile
    /// having met silence and said so -- gives what the link said of it, as the reservations' delete and change
    /// do: over an empty line, that the app is not connected, the recorder having said nothing that can be told.
    ///
    /// A read turned away for the local network permission is not this last case: the link takes the line down
    /// as it begins to wait for the permission (`DeviceLink`), so no line left is the reason there, and what is
    /// said is that the permission is not given. That is the test after this one.
    func testTheConditionsReasonIsTheLineOrThatTheAppIsNotConnected() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)

        // Known to be away, with none read.
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertFalse(model.recorderRulesLoaded)
        leaveALine(on: model)
        var asked = await recorder.asked
        await model.loadRecorderRules()
        XCTAssertEqual(model.recorderRulesFailure, Said.notConnected)
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
        XCTAssertEqual(model.recorderRulesFailure, Said.notConnected)
    }

    /// A recorder silent at its address on a phone the system keeps off the local network, its connect waiting for
    /// the permission (`connectBlocked`), with no keyword conditions read: the conditions' screen says that the
    /// local network is not allowed, and so does a protect pressed meanwhile, and nothing is sent for either. The
    /// recordings were read before, so that the protect has one to name.
    func testTheConditionsReasonAndAWriteSayThePermissionWhileTheRecorderIsKeptOffTheLocalNetwork() async throws {
        let (bench, recorder, model) = try await connectedHome(guide: false)
        addTeardownBlock { await recorder.letGo() }
        await model.loadTitles()
        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        XCTAssertFalse(model.recorderRulesLoaded, "the conditions were meant to be unread")
        bench.linksAreKeptOff = true
        await recorder.goQuiet(for: 1_000)
        await model.connect()
        guard model.connectBlocked else { return XCTFail("a recorder silent behind the permission was not waited for") }
        let heard = await recorder.heard.count

        await model.loadRecorderRules()
        XCTAssertEqual(model.recorderRulesFailure, LocalNetwork.accessNotAllowed)
        expectFalse(await protectARecording(model, title, true))
        XCTAssertEqual(whyNotJustNow(model), LocalNetwork.accessNotAllowed)
        expectEqual(await recorder.heard(since: heard), [], "something was sent while the permission was waited for")

        // The wait ended by a connect that went through, so that nothing is left waiting after the test.
        await recorder.goQuiet(for: 0)
        await reconnect(model)
        bench.theLinksPermissionComes()
    }

    /// What the strip says while a keyword condition is added or removed and the list is read after it: the
    /// write's own line, from the press until the read after it is in, the read having none of its own -- one
    /// thing asked for, one line.
    func testAConditionsWriteKeepsItsLineUpUntilTheListReadAfterItIsIn() async throws {
        let (_, recorder, model, subjects) = try await settled()
        for row in [Funnelled.add, .remove] {
            let before = await recorder.asked
            await recorder.holdTheNext(row.kind)
            let asking = Task { await row.ask(model, subjects) }
            try await until("\(row.name) never got to the recorder") {
                await recorder.asked(row.kind, since: before) == 1
            }
            XCTAssertEqual(model.busy, row.line, row.name)
            let sent = await recorder.asked
            await recorder.holdTheNext(Kind.conditions)
            await recorder.letGo(only: row.kind)
            try await until("the conditions were never read after \(row.name)") {
                await recorder.asked(Kind.conditions, since: sent) == 1
            }
            XCTAssertEqual(model.busy, row.line, "the read after \(row.name) put up a line of its own")
            await recorder.letGo()
            expectEqual(await asking.value, true, model.problem(for: .recorder) ?? "no reason given")
            XCTAssertNil(model.busy, row.name)
        }
    }

    /// A keyword condition added or removed, held at its own request while another recorder describes itself on
    /// a connect and answered afterwards, has no list read after it: the list to read is the newcomer's, which
    /// its connect has read, and a read after would ask the newcomer for it again for nothing.
    func testNoListIsReadAfterAConditionsWriteAnsweredAcrossAnotherRecordersArrival() async throws {
        let (_, recorder, model, subjects) = try await settled()
        var newcomer = 1
        for row in [Funnelled.add, .remove] {
            newcomer += 1
            let before = await recorder.asked
            await recorder.holdTheNext(row.kind)
            let asking = Task { await row.ask(model, subjects) }
            try await until("\(row.name) never got to the recorder") {
                await recorder.asked(row.kind, since: before) == 1
            }
            await recorder.become(newcomer)
            await model.connect()
            // And the newcomer's guide, which its connect started and did not wait for.
            try await until("the newcomer's guide was never fetched, \(row.name)") { !isConnecting(model) }
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(newcomer),
                           model.problem(for: .recorder) ?? "no reason given")
            let read = await recorder.asked
            await recorder.letGo()
            expectEqual(try await within(10, "\(row.name) never came back") { await asking.value }, true,
                        model.problem(for: .recorder) ?? "no reason given")
            expectEqual(await recorder.asked(Kind.conditions, since: read), 0,
                        "the list was read after \(row.name), across the arrival")
        }
    }

    /// A keyword condition added before any list of the conditions has been read -- the first read failed, and
    /// the reader pressed + all the same -- while another recorder describes itself on a connect, with the
    /// registration out or the list read after it: the add is a list the reader is about to see, so the
    /// newcomer's connect reads the newcomer's conditions, and what the last recorder answers is not put over
    /// them. With the list read after it out, the newcomer's connect reads them once that read is back, as for
    /// any read of them out at the arrival, so that the two clients do not ask at once.
    func testAConditionAddedAsAnotherRecorderArrivesHasTheNewcomersConditionsRead() async throws {
        let request = RecorderRuleRequest(keywords: ["みほん"], qualityCode: 220)
        for held in [Kind.addCondition, Kind.conditions] {
            let how = held == Kind.addCondition ? "with the registration out" : "with the read after it out"
            let (_, recorder, model) = try await connectedHome(guide: false)
            XCTAssertFalse(model.recorderRulesLoaded, "the conditions were meant not to have been read yet")
            let before = await recorder.asked
            await recorder.holdTheNext(held)
            let asking = Task { await addACondition(model, request) }
            try await until("\(held) was never asked for, \(how)") {
                await recorder.asked(held, since: before) == 1
            }
            await recorder.become(2)
            let connecting = Task { await model.connect() }
            if held == Kind.conditions {
                // Waiting for the read out, or sent beside it, which the assertion after says is wrong.
                try await until("the newcomer's connect never asked for its conditions, \(how)") {
                    if model.conditionReads == 2 { return true }
                    return await recorder.asked(Kind.conditions, since: before) > 1
                }
                // Time enough for a read sent beside the one out to have reached the recorder.
                try await Task.sleep(for: .milliseconds(300))
                expectEqual(await recorder.asked(Kind.conditions, since: before), 1,
                            "the newcomer's conditions were asked for while the list after the add was out")
                XCTAssertTrue(isConnecting(model), "the newcomer's connect did not wait for the list after the add")
                // The last recorder answers with none, to be told from the newcomer's list.
                await recorder.answer(Kind.conditions, with: .result("<xsrs></xsrs>"))
            } else {
                await connecting.value
            }
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
            await recorder.letGo()
            _ = await asking.value
            await connecting.value

            XCTAssertTrue(model.recorderRulesLoaded, "the newcomer's conditions were not read by its connect, \(how)")
            XCTAssertFalse(model.recorderRules.isEmpty, "the last recorder's list was put over the newcomer's, \(how)")
            XCTAssertNil(model.recorderRulesFailure, how)
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

/// One of the recorder's operations, as a screen asks for it.
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
    /// What it asks the recorder before its own request, where it asks something first: nil for the others.
    var asksFirst: String?
    /// Whether it tells the recorder to do something on the television -- play, pause, stop, the power -- whose
    /// silence says so in its own sentence (`Said.instructionMayHaveArrived`).
    var instructs = false
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
        name: "the delete", kind: Kind.deleteRecording, line: "削除中", sends: true, asksFirst: Kind.details,
        ask: { model, subjects in await deleteARecording(model, subjects.spare) },
        holds: { model, subjects in !model.titles.contains { $0.id == subjects.spare.id } })
    static let play = Funnelled(name: "the play", kind: Kind.playback, line: "再生を指示中", instructs: true,
                                ask: { model, subjects in
                                    await playARecording(model, subjects.title, "play"); return nil })
    static let pause = Funnelled(name: "the pause", kind: Kind.playback, line: "再生を指示中", instructs: true,
                                 ask: { model, subjects in
                                     await playARecording(model, subjects.title, "pause"); return nil })
    static let stop = Funnelled(name: "the stop", kind: Kind.playback, line: "停止中", instructs: true,
                                ask: { model, subjects in
                                    await playARecording(model, subjects.title, "stop"); return nil })
    static let power = Funnelled(name: "the power", kind: Kind.power, line: "電源を入れています", instructs: true,
                                 ask: { model, _ in await turnTheRecorderOn(model); return nil })
    static let add = Funnelled(
        name: "the condition added", kind: Kind.addCondition, line: "レコーダーに登録中", sends: true,
        ask: { model, subjects in await addACondition(model, subjects.request) },
        holds: { model, subjects in model.recorderRules.contains { $0.keywords == subjects.request.keywords } })
    static let remove = Funnelled(
        name: "the condition removed", kind: Kind.removeCondition, line: "レコーダーから削除中", sends: true,
        asksFirst: Kind.conditions,
        ask: { model, subjects in await removeACondition(model, subjects.rule) },
        holds: { model, subjects in !model.recorderRules.contains { $0.id == subjects.rule.id } })
    static let guide = Funnelled(name: "the guide", kind: Kind.guide[0], line: "番組表を取得中 (地上デジタル)",
                                 reads: true, ask: { model, _ in await refreshTheGuideByHand(model) })

    /// Every one, in an order in which each can follow the one before it on one recorder.
    static let all = [reservations, recordings, conditions, protect, unprotect, delete, play, pause, stop, power,
                      add, remove, guide]
    /// The ones that are a SOAP action: all but the guide, whose failures are a test of their own.
    static let bySOAP = all.filter { $0.kind.hasPrefix("X_") }
}
