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
/// choose. Where a test holds something that is to be changed on purpose, it says so, with the name that change
/// goes by in the plan for the move in brackets -- (A4), (R2) -- and that change rewrites it. So a test asks
/// only what a screen asks and reads only what a screen reads, with the bench's own words for the rest
/// (`Said`, `leaveALine`, `makeSure`): where an operation lives can change under it.
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

    /// 再接続, as the reader asks for it once silence has lost the recorder. Over when the reads that follow a
    /// connect are.
    private func reconnect(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) async {
        await model.connect()
        let why = model.problem(for: .recorder) ?? "no reason given"
        XCTAssertTrue(model.connected, "the recorder did not come back: \(why)", file: file, line: line)
    }

    // MARK: - an operation by itself

    /// While an operation's request is out the strip says what it is doing, a failure an earlier operation left
    /// is still on screen -- cleared on the way in, a failure nobody had read yet went with the very next request
    /// -- and the recorder in play cannot be changed, for another address or for the demo: what comes back would
    /// land on the screens of whichever came after. Once it has gone through, and only then, the failure is
    /// cleared. It went once, and the model holds what it did without reading again a list it can put right.
    ///
    /// The last step is as it is today: a condition the recorder no longer has is sent for deletion all the
    /// same, with nothing read first. A later change reads the list first and says so instead (R3).
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
        _ = await model.removeRecorderRule(subjects.rule)
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
    /// do something. A later change counts them as sent (R2), which is four rows' sentence here.
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
        expectTrue(await model.delete(subjects.spare), "silence on the free space failed the delete it followed")
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
        expectFalse(await model.removeRecorderRule(subjects.rule))
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
    /// written is turned down before anything is sent. And a recorder that will not say how much room it has,
    /// after a delete, leaves the delete done and the room unknown.
    ///
    /// Where the sentence of an answer that cannot be read is put may change (A9): it is not the recorder's.
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
        expectFalse(await model.delete(subjects.spare))
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
        expectFalse(await model.delete(writing))
        XCTAssertEqual(model.problem(for: .recorder), Said.stillRecording)
        expectEqual(await recorder.asked, before, "a recording being written to was asked to be deleted")

        // The free space refused after a delete.
        leaveALine(on: model)
        await recorder.answer(Kind.freeSpace, with: .fault(402))
        expectTrue(await model.delete(subjects.spare), "a refusal of the free space failed the delete it followed")
        XCTAssertTrue(model.connected)
        XCTAssertNil(model.problem(for: .recorder))
        XCTAssertNil(model.storage, "room is shown that the recorder would not give")
    }

    /// Known to be away -- the last ask met silence -- the app asks the recorder nothing. A read is simply not
    /// made, and leaves what is on screen alone; anything else says that the app is not connected. With no
    /// recorder in hand at all, nothing is asked and nothing said.
    ///
    /// As it is today in three places. A protect and a delete mark the recordings unread although nothing was
    /// sent, which costs a read of the list after the reconnect. The conditions' screen, with no list read,
    /// gives the line an earlier operation left as its reason. And with no recorder in hand a write fails
    /// without a word, where a later change says why (A8); another keeps a write from a recorder that has not
    /// said which it is (A2).
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
                XCTAssertEqual(model.problem(for: .recorder), Said.notConnected, row.name)
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

    // MARK: - beside a check, a connect, another recorder

    /// What is asked for while the recorder is being made sure of waits for that answer, rather than send a
    /// probe or a request of its own. When the check meets silence nothing is sent, and what is said is the
    /// check's -- the recorder could not be reached -- and not that something may have arrived. When the
    /// recorder answers the check, if only to say it is busy with somebody else, it is there, and what was asked
    /// for goes.
    ///
    /// That is so of a write through the funnel, and of the two things that ask the check for themselves: the
    /// question of what a reservation would clash with, asked as a programme's sheet opens, and a waiting
    /// reservation the reader asks to be sent again. The question has no line and nothing to wait for, so it is
    /// asked beside each write here, whose line says that both have been asked. (After a check answered busy the
    /// order it goes in says nothing: the client sends one request at a time whoever asks.)
    ///
    /// As it is today: a protect and a delete that were not sent mark the recordings unread all the same.
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

        // A waiting reservation asked to be sent again. Its reason comes off the row in the turn in which the
        // asking gets to the check, and the row is taken away before the reconnect, which would send it.
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        try await GuideStore(path: bench.guidePath)
            .queue(PendingReservation(request: request, serviceName: program.serviceName, problem: "前に断られた理由"))
        await model.loadPending()
        let waiting = try XCTUnwrap(model.pending(for: program))
        leaveALine(on: model)
        let count = await recorder.heard.count
        let again = try await duringACheck(by: model, of: recorder, endingIn: .silence, "sending it again",
                                           waitingFor: { model.pending(for: program)?.problem == nil }) {
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
        XCTAssertEqual(came.done, true, model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(came.clashes, [], "the question was not put to a recorder that had answered the check")
        expectEqual(await recorder.asked(Kind.description, since: before), 3, "a probe was sent beside the check's")
        expectEqual(await recorder.asked(Kind.deleteRecording, since: before), 1)
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
        let deleting = Task { await model.delete(title) }
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

    /// As it is today, and to be rewritten (A4): the same with the connect answered by another recorder, whose
    /// arrival empties the lists in that turn. Nothing in the funnel asks whether the recorder it began with
    /// was let go of, so a read that comes back afterwards is put over the emptied list, and a write's silence
    /// is taken for the newcomer's: the app gives up on a recorder that has just answered, under a sentence
    /// about a write it was never sent. Afterwards the read is not put in place and the newcomer is kept; the
    /// sentence stays. Until then nothing may change this.
    func testAnotherRecorderDescribingItselfBesideAnOperationThatIsOut() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)

        await recorder.hold(only: Kind.recordings)
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
        XCTAssertTrue(model.titles.isEmpty)
        await recorder.letGo()
        await reading.value
        XCTAssertTrue(model.titlesLoaded)
        XCTAssertFalse(model.titles.isEmpty)
        expectEqual(await recorder.asked(Kind.recordings, since: before), 1)

        let title = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        await recorder.hold(only: Kind.deleteRecording)
        before = await recorder.asked
        let deleting = Task { await model.delete(title) }
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

    // MARK: - standby, and the guide

    /// A pause or a stop sent to a recorder in network standby says so in the recorder's words and offers to
    /// turn it on, with the recorder kept. The offer goes when the power is put on, and at the door of the next
    /// playback operation whatever becomes of that; a power request that meets silence leaves it, through the
    /// reconnect as well.
    ///
    /// Playing itself, which turns the recorder on and waits for it under a line that counts the seconds, is
    /// not here: the model hands the client no interval, so a test of it waits a real second. The sequence is
    /// held in the package (`RecorderClientTests`), and the app's part of it goes with the recordings' own gates.
    /// The sentence a power request's silence leaves is to change (R2).
    func testStandbyIsSaidAndPowerIsOfferedUntilItIsPutOnOrPlaybackIsAskedForAgain() async throws {
        let (_, recorder, model, subjects) = try await settled()
        let before = await recorder.asked

        await recorder.answer(Kind.playback, with: .fault(880))
        await model.play(subjects.title, "pause")
        XCTAssertTrue(model.needsPower, "nothing offers to turn the recorder on")
        XCTAssertEqual(model.problem(for: .recorder), Said.fault(880, Kind.playback))
        XCTAssertTrue(model.connected)
        expectEqual(await recorder.asked(Kind.power, since: before), 0, "a pause turned the recorder on")

        await model.powerOn()
        expectEqual(await recorder.asked(Kind.power, since: before), 1)
        XCTAssertFalse(model.needsPower)
        XCTAssertNil(model.problem(for: .recorder))

        await recorder.answer(Kind.playback, with: .fault(880))
        await model.play(subjects.title, "stop")
        XCTAssertTrue(model.needsPower)
        await recorder.goQuiet(on: Kind.power)
        await model.powerOn()
        XCTAssertTrue(model.gaveUp)
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertTrue(model.needsPower, "the offer went with a power request that never arrived")
        await reconnect(model)
        XCTAssertTrue(model.needsPower, "the offer went with the reconnect")

        await recorder.answer(Kind.playback, with: .fault(402))
        await model.play(subjects.title, "stop")
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
    static let power = "X_PowerControl"
    static let addCondition = "X_CreatePrefRecSetting"
    static let removeCondition = "X_DeletePrefRecSetting"
    static let freeSpace = "X_HDLnkGetRecordDestinationInfo"
    static let clashes = "X_GetConflictList"
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
        ask: { model, subjects in await model.setProtected(subjects.title, true) },
        holds: { model, subjects in model.titles.first { $0.id == subjects.title.id }?.protected == true })
    static let unprotect = Funnelled(
        name: "the unprotect", kind: Kind.changeRecording, line: "保護を解除中", sends: true,
        ask: { model, subjects in await model.setProtected(subjects.title, false) },
        holds: { model, subjects in model.titles.first { $0.id == subjects.title.id }?.protected == false })
    static let delete = Funnelled(
        name: "the delete", kind: Kind.deleteRecording, line: "削除中", sends: true,
        ask: { model, subjects in await model.delete(subjects.spare) },
        holds: { model, subjects in !model.titles.contains { $0.id == subjects.spare.id } })
    static let play = Funnelled(name: "the play", kind: Kind.playback, line: "再生を指示中",
                                ask: { model, subjects in await model.play(subjects.title, "play"); return nil })
    static let pause = Funnelled(name: "the pause", kind: Kind.playback, line: "再生を指示中",
                                 ask: { model, subjects in await model.play(subjects.title, "pause"); return nil })
    static let stop = Funnelled(name: "the stop", kind: Kind.playback, line: "停止中",
                                ask: { model, subjects in await model.play(subjects.title, "stop"); return nil })
    static let power = Funnelled(name: "the power", kind: Kind.power, line: "電源を入れています",
                                 ask: { model, _ in await model.powerOn(); return nil })
    static let add = Funnelled(
        name: "the condition added", kind: Kind.addCondition, line: "レコーダーに登録中", sends: true,
        ask: { model, subjects in await model.addRecorderRule(subjects.request) },
        holds: { model, subjects in model.recorderRules.contains { $0.keywords == subjects.request.keywords } })
    static let remove = Funnelled(
        name: "the condition removed", kind: Kind.removeCondition, line: "レコーダーから削除中", sends: true,
        ask: { model, subjects in await model.removeRecorderRule(subjects.rule) },
        holds: { model, subjects in !model.recorderRules.contains { $0.id == subjects.rule.id } })
    static let guide = Funnelled(name: "the guide", kind: Kind.guide[0], line: "番組表を取得中 (地上デジタル)",
                                 reads: true, ask: { model, _ in await model.refreshGuide(); return nil })

    /// Every one, in an order in which each can follow the one before it on one recorder.
    static let all = [reservations, recordings, conditions, protect, unprotect, delete, play, pause, stop, power,
                      add, remove, guide]
    /// The ones that are a SOAP action: all but the guide, whose failures are a test of their own.
    static let bySOAP = all.filter { $0.kind.hasPrefix("X_") }
}
