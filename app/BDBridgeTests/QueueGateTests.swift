import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The reservations that wait on the phone for the recorder to answer: when they are sent and what is read
/// around the sending, what the strip says became of them, what one that could not be kept says, what asking for
/// one again or taking one away does while the recorder is away, and how the ones held for another recorder are
/// counted.
///
/// Gates, as `FunnelGateTests` and `ReservationGateTests` are and for the same move: each pins what the app does
/// today, and where a later change is to rewrite a test it says so, with that change's name in the plan in
/// brackets. A test asks only what a screen asks and reads only what a screen reads. The one that looks at the
/// sentences a sending comes to asks the queue itself (`PendingQueue.flush`), which is what the screens' sending
/// and the two runs with no screen all end in; neither of those runs is called here.
///
/// What is said of a sending is compared with the bench's own words (`Said`): a rewording is one edit,
/// there. With a television saved the sentences name the device (`QueueWithATelevisionTests`); here there is
/// none, and they are the ones a home with a recorder alone has always read.
@MainActor
final class QueueGateTests: XCTestCase {
    // MARK: - sending what waits

    /// Pulling the reservations down while connected sends what waits and then reads the list, once, as a
    /// television's pull-down does: the read after the sending is what puts the new reservation on screen. With
    /// nothing waiting, or nothing but what was turned down before, the recorder is asked for its list and for
    /// nothing else. A sending with nothing to say leaves the strip's last line where it was.
    ///
    /// The sending has a line of its own, and while it is out the recorder in play cannot be changed. A
    /// reservation the recorder turns down keeps the recorder's reason on its row, on screen and on the phone,
    /// and is said on the strip in the queue's words. It is not put on the failure line, which is for what the
    /// reader asked the recorder for and is left as it was. Leaving the app takes the strip's line away: it was
    /// for that visit.
    func testPullingDownWhileConnectedSendsWhatWaitsUnderALineOfItsOwnThenReads() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)
        let (taken, refused) = (programmes[0], programmes[1])

        // Nothing waiting.
        var count = await recorder.heard.count
        await model.refreshReservations()
        expectEqual(await recorder.heard(since: count), [Kind.list], "with nothing waiting, only the list is read")
        XCTAssertNil(model.flushReport, "the strip says something of a queue with nothing in it")

        // One waiting.
        try await store.queue(waiting(for: taken))
        count = await recorder.heard.count
        await model.refreshReservations()
        expectEqual(await recorder.heard(since: count), [Kind.create, Kind.list],
                    "what waits is sent, and the list is read once after it")
        XCTAssertEqual(model.flushReport, Said.sent(taken.title))
        XCTAssertNotNil(model.reservation(for: taken), "the programme is not marked as reserved")
        XCTAssertTrue(model.pending.isEmpty, "what was sent is still shown as waiting")
        expectEqual(reasons(try await store.pendingReservations()), [:], "what was sent stayed in the queue")

        // One the recorder turned down before: not sent again by itself, so nothing was made and nothing new is
        // to be said.
        let reason = "前に断られた理由"
        try await store.queue(waiting(for: refused, problem: reason))
        count = await recorder.heard.count
        await model.refreshReservations()
        expectEqual(await recorder.heard(since: count), [Kind.list],
                    "a reservation turned down before was sent, or the list was read with nothing made")
        XCTAssertEqual(model.flushReport, Said.sent(taken.title), "a sending with nothing to say changed the strip")
        let row = try XCTUnwrap(model.pending(for: refused), "the reservation turned down before is not shown")
        XCTAssertEqual(row.problem, reason)

        // The reader asks for it again, and the recorder turns it down again: 831, a channel it cannot receive.
        leaveALine(on: model)
        count = await recorder.heard.count
        await recorder.answer(Kind.create, with: .fault(831))
        await recorder.hold(only: Kind.create)
        let asking = Task { await model.resend(row) }
        try await until("what waits never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        XCTAssertEqual(model.busy, "送信待ちの予約を登録中")
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with what waits being sent")
        await recorder.letGo()
        await asking.value

        let refusal = Said.fault(831, Kind.create)
        expectEqual(await recorder.heard(since: count), [Kind.create],
                    "it was sent again, or the list was read with nothing made")
        XCTAssertEqual(reasons(model.pending), [row.id: refusal], "the row on screen does not say why")
        expectEqual(reasons(try await store.pendingReservations()), [row.id: refusal],
                    "the reason was not kept, and the reservation would be sent again by itself")
        XCTAssertEqual(model.flushReport, Said.sent(taken.title) + "。" + Said.refused(refused.title))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the queue's refusal went on the failure line")
        XCTAssertNil(model.busy)
        XCTAssertTrue(model.connected, "a refusal was taken for the recorder going")

        model.wentToBackground()
        XCTAssertNil(model.flushReport, "the strip's line outlived the visit it was for")
    }

    /// A sending has one line, up from before its check to after its last read, as a television's: the list
    /// read after a row sent again was made goes under the sending's line, with none of its own, and a row sent
    /// again from its swipe has the sending's line up while the recorder is made sure of. A pull-down's sending
    /// is under that line, and the pull-down's read, after what waits is sent, is a read by itself and has its
    /// own line.
    ///
    /// The read after the create is held only once the create has been heard, so that it is that read and no
    /// other. The check before a row sent again is made only when the recorder has not answered for a while, or
    /// when the check before heard something else than the recorder saying which it is: here, a check that heard
    /// it busy with somebody else.
    func testASendingShowsItsOwnLineFromItsCheckToItsReadAfter() async throws {
        let (bench, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)

        // A pull-down, with one row waiting.
        try await store.queue(waiting(for: programmes[0]))
        var count = await recorder.heard.count
        await recorder.hold(only: Kind.create)
        let pulling = Task { await model.refreshReservations() }
        try await until("what waits never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        XCTAssertEqual(model.busy, "送信待ちの予約を登録中", "the pull-down's sending is not under its line")
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with what waits being sent")
        let before = await recorder.asked
        await recorder.holdTheNext(Kind.list)
        await recorder.letGo(only: Kind.create)
        try await until("the list was never read after what was made") {
            await recorder.asked(Kind.list, since: before) == 1
        }
        XCTAssertEqual(model.busy, "予約一覧を取得中", "the pull-down's read after its sending is not under its own line")
        await recorder.letGo()
        await pulling.value
        XCTAssertNil(model.pending(for: programmes[0]), "what waited was not sent")
        XCTAssertNil(model.busy)

        // A row sent again, after a check that heard the recorder busy: the next check is made at once.
        let reason = "前に断られた理由"
        let row = try waiting(for: programmes[1], problem: reason)
        try await store.queue(row)
        await recorder.busyAtTheDoor()
        expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
        await recorder.comeFree()
        count = await recorder.heard.count
        await recorder.hold(only: Kind.description)
        let asking = Task { await model.resend(row) }
        try await until("the recorder was never made sure of") {
            await recorder.heard(since: count).contains(Kind.description)
        }
        XCTAssertEqual(model.busy, "送信待ちの予約を登録中", "the check before the sending showed no line")
        XCTAssertFalse(model.canChangeRecorder, "another recorder could be chosen with what waits being sent")
        await recorder.letGo()
        await asking.value
        expectEqual(await recorder.heard(since: count), [Kind.description, Kind.create, Kind.list],
                    model.problem(for: .recorder) ?? "no reason given")
        XCTAssertNil(model.pending(for: programmes[1]), "the row sent again was not sent")
        XCTAssertNil(model.busy)
    }

    /// The order of a connect. What waits is sent inside the attach, which reads nothing after it; then the
    /// reservations are read, once, before a guide that is behind is fetched -- the guide marks what is already
    /// set to record from that list, the reservation just made among them. Nothing of the guide is asked for
    /// before that read.
    ///
    /// The strip's sentence is to name the device.
    func testAConnectSendsWhatWaitsThenReadsTheReservationsThenTheGuide() async throws {
        let bench = try aBench()
        // No guide in the cache, so every type of it is behind; and so the reservation is of the test's making.
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        try await GuideStore(path: bench.guidePath).queue(morning)
        let recorder = NamedRecorder(1)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)

        // Of everything a connect asks, what this is about: the reservation, the list, and the guide's files.
        let heard = await recorder.heard.filter { $0 == Kind.create || $0 == Kind.list || $0.hasPrefix(Kind.guide) }
        XCTAssertEqual(Array(heard.prefix(2)), [Kind.create, Kind.list],
                       "what waits is sent, and the reservations are read once, before the guide")
        let afterwards = heard.dropFirst(2)
        XCTAssertFalse(afterwards.isEmpty, "the guide was meant to be behind, and so to be fetched")
        XCTAssertTrue(afterwards.allSatisfy { $0.hasPrefix(Kind.guide) },
                      "something was sent or read once the guide was being fetched: \(heard)")
        XCTAssertEqual(model.flushReport, Said.sent(morning.request.title))
        XCTAssertTrue(model.pending.isEmpty, "what was sent is still shown as waiting")
        XCTAssertTrue(model.reservations.contains { $0.eventID == morning.request.eventID },
                      "the reservation made is not in the list on screen")
    }

    /// Silence at a create while a pull-down sends what waits: the recorder is lost and given up on, nothing
    /// more is sent or read -- the pull-down's read after the sending among it -- and the reservation stays in
    /// the queue, on screen and on the phone, held for the reader with a reason that says it may have arrived:
    /// it is not sent again by itself. The line says so too, over what was left there while the create was
    /// out. Nothing is said on the strip.
    func testSilenceAtACreateInAPullDownsSendingHoldsTheRowForTheReaderAndSaysSo() async throws {
        let (bench, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let program = try await programmesNotReserved(model, 1)[0]
        let row = try waiting(for: program)
        try await store.queue(row)
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.create)

        let pulling = Task { await model.refreshReservations() }
        try await until("what waits never got to the recorder") {
            await recorder.heard(since: count).contains(Kind.create)
        }
        leaveALine(on: model)
        await recorder.goQuiet(on: Kind.create)
        await recorder.letGo()
        await pulling.value

        expectEqual(await recorder.heard(since: count), [Kind.create],
                    "something was sent or read after the create met silence")
        XCTAssertTrue(model.gaveUp, "silence at the create did not lose the recorder")
        XCTAssertEqual(model.problem(for: .recorder), Said.heldAfterSilence, "silence at the create was not said")
        XCTAssertEqual(reasons(model.pending), [row.id: Said.heldAfterSilence],
                       "the reservation does not wait on screen held for the reader")
        expectEqual(reasons(try await store.pendingReservations()), [row.id: Said.heldAfterSilence],
                    "the reservation does not wait on the phone held for the reader")
        XCTAssertNil(model.flushReport, "the strip says something of a sending that sent nothing")
        XCTAssertNil(model.busy)
    }

    /// The same silence, met once another recorder has answered a connect beside the sending: the silence is the
    /// recorder let go of's, so nothing is said of it, and the newcomer is neither lost nor given up on. The
    /// pull-down's read after its sending goes to the newcomer and through, which clears the line. Nothing is
    /// sent again. The row keeps the reason the newcomer's arrival wrote while the create was out -- held for the
    /// recorder before, the sentence the strip counts such rows by -- and the reason a create that met silence
    /// leaves is not written over it.
    func testSilenceAtACreateOnceAnotherRecorderHasAnsweredSaysNothingAndLosesNobody() async throws {
        let (bench, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let row = try waiting(for: try await programmesNotReserved(model, 1)[0])
        try await store.queue(row)
        let before = await recorder.asked
        await recorder.hold(only: Kind.create)
        let pulling = Task { await model.refreshReservations() }
        try await until("what waits never got to the recorder") {
            await recorder.asked(Kind.create, since: before) == 1
        }

        await recorder.become(2)
        await model.connect()
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        await recorder.goQuiet(on: Kind.create)
        await recorder.letGo()
        await pulling.value

        XCTAssertNil(model.problem(for: .recorder), "the silence was said on the newcomer's line")
        XCTAssertFalse(model.gaveUp, "silence at the create for the recorder let go of gave the newcomer up")
        XCTAssertTrue(model.connected)
        expectEqual(await recorder.asked(Kind.create, since: before), 1, "the row was sent again")
        expectEqual(reasons(try await store.pendingReservations()), [row.id: Said.heldForAnotherRecorder])
    }

    /// A pull-down's sending makes sure of the recorder first, and a check that meets silence, with a MAC kept,
    /// wakes it before anything waiting is sent: the row goes in the waking's attach, once the recorder has
    /// answered, and no create goes to a recorder that has said nothing since it dozed off the LAN. Made once:
    /// the sending after the check finds nothing left to send. The check here is one already out when the
    /// sending asks, which the sending's joins -- the bench has no clock to let a minute and a half go by for
    /// the last answer to grow old -- with its probe held until then and silent once let go.
    func testAPullDownWhoseCheckMeetsSilenceWakesTheRecorderBeforeAnythingIsSent() async throws {
        let (bench, recorder, model) = try await connectedHome(wakeable: true)
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let program = try await programmesNotReserved(model, 1)[0]
        try await store.queue(try waiting(for: program))
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.description)
        let check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") {
            await recorder.heard(since: count).contains(Kind.description)
        }
        let pulling = Task { await model.refreshReservations() }
        // Long enough for the pull-down's sending to be waiting on the check before its probe is let go.
        try await Task.sleep(for: .milliseconds(300))
        await recorder.goQuiet(on: Kind.description)
        await recorder.letGo()
        expectTrue(await check.value, "the recorder was not woken")
        await pulling.value

        let heard = await recorder.heard(since: count)
        XCTAssertEqual(heard.first, Kind.description, "the check's probe was not the first thing asked: \(heard)")
        let answered = try XCTUnwrap(heard.dropFirst().firstIndex(of: Kind.description),
                                     "the recorder was never asked again after the silence: \(heard)")
        let create = try XCTUnwrap(heard.firstIndex(of: Kind.create), "what waits was never sent: \(heard)")
        XCTAssertGreaterThan(create, answered, "a create went before the recorder had answered the waking: \(heard)")
        XCTAssertEqual(heard.filter { $0 == Kind.create }.count, 1, "what waits was sent twice: \(heard)")
        XCTAssertNil(model.pending(for: program), "what waited was not sent")
        XCTAssertNotNil(model.reservation(for: program), "the reservation made is not on screen")
        XCTAssertFalse(model.gaveUp, "the recorder woken was given up on")
    }

    /// The check before an operation that wakes the recorder -- silent to its probe, with a MAC kept -- has
    /// what waits sent by the waking's attach, outside any connect, and nothing reads the list after that
    /// attach but the sending itself: so it does, after a round that made something. The row made is on screen
    /// as a reservation, the strip says it was sent, and its programme is no longer offered the recorder.
    func testASendingInTheAttachOfACheckThatWokeTheRecorderReadsTheListAfter() async throws {
        let (bench, recorder, model) = try await connectedHome(wakeable: true)
        let store = try GuideStore(path: bench.guidePath)
        let program = try await programmesNotReserved(model, 1)[0]
        try await store.queue(try waiting(for: program))
        await model.loadPending()
        XCTAssertEqual(model.destinations(for: program), [], "a programme waiting was offered the recorder again")
        let count = await recorder.heard.count
        await recorder.goQuiet(on: Kind.description)

        expectTrue(await makeSure(model), "the recorder was not woken")

        let heard = await recorder.heard(since: count)
        XCTAssertEqual(heard.filter { $0 == Kind.create }.count, 1, "what waits was not sent once: \(heard)")
        XCTAssertNil(model.pending(for: program), "what waited was not sent")
        XCTAssertNotNil(model.reservation(for: program), "the reservation made is not on screen")
        XCTAssertEqual(model.destinations(for: program), [], "a programme the recorder holds was offered it again")
        XCTAssertEqual(model.flushReport, Said.sent(program.title))
    }

    // MARK: - keeping one, asking for one again, taking one away

    /// A reservation that could not be saved has been made nowhere: the answer is no, the reason is said, and
    /// nothing says it is waiting, on screen or on the phone. That is so when the cache is busy with another
    /// writer for longer than the app waits, and when there is no cache at all -- in which case no connect was
    /// ever set going either. One that is kept asks the recorder nothing.
    ///
    /// Why it was not saved is said in its result, and not on the failure line, which keeps what the connect
    /// that gave up left there; keeping one leaves that line as it was too. Both sentences stay as they are.
    func testAReservationThatCannotBeKeptOnThePhoneIsNotSaidToBeWaiting() async throws {
        let bench = try aBench()
        // The lock is held on purpose: what is tested is giving up, not the wait.
        bench.storeBusyTimeoutMilliseconds = 200
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilGivenUp(model)
        let program = try await aProgramme(model)
        let store = try GuideStore(path: bench.guidePath)
        let asked = await recorder.asked
        func reserve(with model: AppModel) async -> Bool {
            await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none")
        }

        let writer = Writer(to: bench.guidePath)
        let line = model.problem(for: .recorder)
        expectFalse(await reserve(with: model), "a reservation that could not be saved is said to have been kept")
        let said = whyNotJustNow(model) ?? "nothing"
        XCTAssertEqual(model.problem(for: .recorder), line, "a reservation that could not be saved wrote the line")
        XCTAssertTrue(said.hasPrefix("予約を端末に保存できませんでした: "), "what is said instead: \(said)")
        XCTAssertNil(keptJustNow(model), "a reservation that was not saved is said to be waiting")
        XCTAssertNil(model.pending(for: program))
        expectEqual(reasons(try await store.pendingReservations()), [:])

        writer.letGo()
        expectTrue(await reserve(with: model), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.problem(for: .recorder), line, "keeping a reservation wrote on the line")
        XCTAssertEqual(keptJustNow(model)?.request.eventID, program.eventID)
        XCTAssertNotNil(model.pending(for: program), "the reservation kept is not shown as waiting")
        expectEqual(try await store.pendingReservations().map(\.request.eventID), [program.eventID])
        expectEqual(await recorder.asked, asked, "a recorder known to be away was asked")

        // No cache: a folder stands where the database would be, so it cannot be opened.
        let other = try aBench()
        try FileManager.default.createDirectory(atPath: other.guidePath, withIntermediateDirectories: true)
        let without = other.model(recorder: SilentRecorder())
        expectFalse(await reserve(with: without), "a reservation with nowhere to be saved is said to have been kept")
        XCTAssertEqual(whyNotJustNow(without), "予約を端末に保存できませんでした（端末内のデータベースを開けませんでした）")
        XCTAssertNil(keptJustNow(without))
        XCTAssertTrue(without.pending.isEmpty)
        XCTAssertEqual(other.clientsMade, 0, "a connect was set going with no cache to connect over")
    }

    /// A reservation that was saved is kept, whatever reading the queue back would come to: the save alone says
    /// so, as for a television's, and a row saved is one that goes. Here the queue takes the row and fails every
    /// read of it (`QueueUnreadable`). The answer is that the reservation waits, nothing is said of the read on
    /// the line, and once the queue can be read again the row is there, on the phone and then on screen.
    func testAReservationSavedIsKeptThoughTheQueueCannotBeReadBack() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilGivenUp(model)
        let program = try await aProgramme(model)
        leaveALine(on: model)

        let unreadable = QueueUnreadable(in: bench.guidePath)
        let came = await model.reserve(program, on: .recorder, quality: "DR", repeating: "none")
        // What this stands on: the row saved cannot be read back, through the store the app reads the queue with.
        let readBack: Result<[PendingReservation], any Error>
        do {
            readBack = .success(try await GuideStore(path: bench.guidePath).pendingReservations())
        } catch {
            readBack = .failure(error)
        }
        XCTAssertThrowsError(try readBack.get(), "the queue was meant to fail a read of what it holds")
        unreadable.putBack()

        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation that was saved was said not to be: \(came)")
        }
        XCTAssertEqual(row.request.eventID, program.eventID)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the read back was said, or the line cleared")
        expectEqual(try await GuideStore(path: bench.guidePath).pendingReservations().map(\.id), [row.id])
        await model.loadPending()
        XCTAssertEqual(model.pending(for: program)?.id, row.id, "the row saved is not shown as waiting")
    }

    /// With the recorder known to be away. Asking for a waiting reservation to be sent again takes the reason
    /// off its row, on the phone and on screen, so that it goes with the rest the next time the recorder
    /// answers, and connects, as a television's row sent again does: the reader asked. Here the connect meets
    /// silence, asking the recorder once, and the failure line says so; nothing is said on the strip. Taking one
    /// away removes it from the phone, and asks the recorder nothing.
    func testAwayFromTheRecorderAWaitingReservationAskedForAgainConnectsAndOneTakenAwayAsksNothing() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let recorder = SilentRecorder()
        let model = bench.model(recorder: recorder)
        await model.start()
        try await untilGivenUp(model)
        let store = try GuideStore(path: bench.guidePath)
        let reason = "前に断られた理由"
        let again = try waiting(for: try await aProgramme(model), problem: reason)
        let unwanted = try waiting(for: try await aProgramme(model, skipping: 1), problem: reason)
        try await store.queue(again)
        try await store.queue(unwanted)
        await model.loadPending()
        XCTAssertEqual(reasons(model.pending), [again.id: reason, unwanted.id: reason])
        let asked = await recorder.asked
        leaveALine(on: model)

        await model.resend(again)
        XCTAssertEqual(reasons(model.pending), [again.id: "", unwanted.id: reason],
                       "the row on screen still says it was turned down, or the other no longer does")
        expectEqual(reasons(try await store.pendingReservations()), [again.id: "", unwanted.id: reason],
                    "the reason is still on the phone, and the reservation would not go with the rest")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the connect asked for did not say its silence")
        XCTAssertNil(model.flushReport)

        await model.removePending(unwanted)
        XCTAssertEqual(reasons(model.pending), [again.id: ""], "the reservation taken away is still shown")
        expectEqual(reasons(try await store.pendingReservations()), [again.id: ""])
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        expectEqual(await recorder.asked, asked + 1, "the recorder was asked other than by the connect")
        XCTAssertTrue(model.gaveUp)
    }

    /// With the recorder there, asking for one waiting reservation to be sent again sends that row alone, its
    /// reason taken off, as a television's row sent again is, and the list is read once after it. It leaves the
    /// queue, on screen and on the phone, and the strip says it. The other row, which had no reason, still
    /// waits, for the next sending of what waits.
    func testSendingOneAgainSendsThatRowAlone() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)
        let asked = try waiting(for: programmes[0], problem: "前に断られた理由")
        let other = try waiting(for: programmes[1])
        try await store.queue(asked)
        try await store.queue(other)
        await model.loadPending()
        XCTAssertEqual(reasons(model.pending), [asked.id: "前に断られた理由", other.id: ""])

        let count = await recorder.heard.count
        await model.resend(asked)

        expectEqual(await recorder.heard(since: count), [Kind.create, Kind.list],
                    "the other row was sent too, or the list was read more than once")
        XCTAssertEqual(reasons(model.pending), [other.id: ""], "the row sent is still shown, or the other is not")
        expectEqual(reasons(try await store.pendingReservations()), [other.id: ""],
                    "the row sent stayed in the queue, or the other left it")
        XCTAssertNotNil(model.reservation(for: programmes[0]), "the row asked for is not marked as reserved")
        XCTAssertNil(model.reservation(for: programmes[1]), "the other row was made")
        XCTAssertEqual(model.flushReport, Said.sent(asked.request.title))
        XCTAssertNil(model.problem(for: .recorder))
    }

    /// What a row sent again came to is handed back for the screen the reader asked on, as a television's is:
    /// one the recorder makes, as made, with nothing to add; one it turns down again -- 831, a channel it
    /// cannot receive -- as waiting, the row as it waits now carrying the recorder's reason, which is what is
    /// said.
    func testARowSentAgainIsAnsweredWithWhatItCameTo() async throws {
        let (bench, recorder, model) = try await connectedHome()
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)
        let (made, refused) = (try waiting(for: programmes[0], problem: "前に断られた理由"),
                               try waiting(for: programmes[1], problem: "前に断られた理由"))
        try await store.queue(made)
        try await store.queue(refused)

        expectEqual(await model.sendAgain(made), .made(saying: nil), "a row made was not said to be")
        XCTAssertNotNil(model.reservation(for: programmes[0]), "the row made is not marked as reserved")

        await recorder.answer(Kind.create, with: .fault(831))
        let refusal = Said.fault(831, Kind.create)
        let came = await model.sendAgain(refused)

        guard case .waiting(let row, let saying)? = came else {
            return XCTFail("a row turned down again was not said to wait: \(String(describing: came))")
        }
        XCTAssertEqual(row.id, refused.id)
        XCTAssertEqual(row.problem, refusal, "the row handed back does not carry the recorder's reason")
        XCTAssertEqual(saying, refusal)
    }

    /// A row sent again that another sending takes out of the queue while its round waits for the queue's
    /// turn -- here a pull-down's, its create held -- is in none of its round's lists, and is answered from the
    /// recorder's list read after that round, as a television's is: made when the list holds a reservation of
    /// it, and when it does not, that it could not be confirmed. Nothing is sent for it.
    func testARowSentAgainThatAnotherSendingTookIsAnsweredFromTheListReadAfter() async throws {
        for listed in [true, false] {
            let (bench, recorder, model) = try await connectedHome()
            addTeardownBlock { await recorder.letGo() }
            let store = try GuideStore(path: bench.guidePath)
            let programmes = try await programmesNotReserved(model, 2)
            let pressed = try waiting(for: programmes[0], problem: "前に断られた理由")
            try await store.queue(pressed)
            try await store.queue(try waiting(for: programmes[1]))
            if listed {
                // What the other sending would have made of it, on the recorder's own screen.
                try await aClient(of: recorder).create(pressed.request)
            }
            let before = await recorder.asked
            await recorder.hold(only: Kind.create)
            let pulling = Task { await model.refreshReservations() }
            try await until("what waits never got to the recorder") {
                await recorder.asked(Kind.create, since: before) == 1
            }
            let asking = Task { await model.sendAgain(pressed) }
            // Long enough for the row sent again to be waiting for the queue's turn.
            try await Task.sleep(for: .milliseconds(300))
            try await store.removePending(pressed.id)
            await recorder.letGo()
            await pulling.value
            let came = await asking.value

            expectEqual(came, listed ? .made(saying: nil) : .notDone(Said.couldNotBeConfirmed), "listed: \(listed)")
            expectEqual(await recorder.asked(Kind.create, since: before), 1, "the row taken was sent: \(listed)")
        }
    }

    /// A row sent again whose check wakes the recorder -- the check here one already out, its probe held and
    /// then silent, with a MAC kept -- keeps its reason through the sending the waking's attach makes, which
    /// sends the other row that waits. It goes in a round of its own after that, which makes it, and it is
    /// answered as made; the strip says each sending.
    func testARowSentAgainWhoseCheckWakesTheRecorderGoesInARoundOfItsOwn() async throws {
        let (bench, recorder, model) = try await connectedHome(wakeable: true)
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let programmes = try await programmesNotReserved(model, 2)
        let pressed = try waiting(for: programmes[0], problem: "前に断られた理由")
        let other = try waiting(for: programmes[1])
        try await store.queue(pressed)
        try await store.queue(other)
        let count = await recorder.heard.count
        await recorder.hold(only: Kind.description)
        let check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") {
            await recorder.heard(since: count).contains(Kind.description)
        }
        let asking = Task { await model.sendAgain(pressed) }
        // Long enough for the row's check to be waiting on the one out before its probe is let go.
        try await Task.sleep(for: .milliseconds(300))
        await recorder.goQuiet(on: Kind.description)
        await recorder.letGo()
        expectTrue(await check.value, "the recorder was not woken")
        let came = await asking.value

        XCTAssertEqual(came, .made(saying: nil))
        XCTAssertEqual(model.flushReport, Said.sent(other.request.title) + "。" + Said.sent(pressed.request.title),
                       "the row sent again went with the waking's sending")
        expectEqual(await recorder.heard(since: count).filter { $0 == Kind.create }.count, 2)
        XCTAssertTrue(model.pending.isEmpty, "what was sent is still shown as waiting")
    }

    /// The same check, whose waking finds another recorder answering where the first was: the newcomer's
    /// arrival holds every waiting row for the recorder before, and the row the reader pressed keeps that
    /// reason, on screen and on the phone, rather than have the reason it was pressed with taken off. The
    /// answer is that another recorder answered, and nothing goes to the newcomer, then, at the connect the
    /// app makes to it, or at the pull-down after.
    func testARowSentAgainWhoseCheckWakesAnotherRecorderStaysHeldForTheOneBefore() async throws {
        let (bench, recorder, model) = try await connectedHome(wakeable: true)
        addTeardownBlock { await recorder.letGo() }
        let store = try GuideStore(path: bench.guidePath)
        let pressed = try waiting(for: try await programmesNotReserved(model, 1)[0], problem: "前に断られた理由")
        try await store.queue(pressed)
        let before = await recorder.asked
        await recorder.hold(only: Kind.description)
        let check = Task { await makeSure(model) }
        try await until("the recorder was never made sure of") {
            await recorder.asked(Kind.description, since: before) == 1
        }
        let asking = Task { await model.sendAgain(pressed) }
        // Long enough for the row's check to be waiting on the one out before its probe is let go.
        try await Task.sleep(for: .milliseconds(300))
        await recorder.goQuiet(on: Kind.description)
        await recorder.become(2)
        await recorder.letGo()
        _ = await check.value
        let came = await asking.value
        try await untilIdle(model)

        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(came, .notDone(Said.anotherAnswered))
        XCTAssertEqual(reasons(model.pending), [pressed.id: Said.heldForAnotherRecorder],
                       "the row is not shown held for the recorder before")
        expectEqual(reasons(try await store.pendingReservations()), [pressed.id: Said.heldForAnotherRecorder],
                    "the row does not wait on the phone held for the recorder before")
        await model.refreshReservations()
        try await untilIdle(model)
        expectEqual(await recorder.asked(Kind.create, since: before), 0, "the row went to the newcomer")
    }

    // MARK: - what the strip says

    /// How many reservations the strip says are held for another recorder is the number of waiting rows whose
    /// reason is one sentence, letter for letter -- and that sentence is in the phone's database, where a build
    /// that words it otherwise would no longer find what an earlier one wrote. So it is written here as it
    /// reads: a row an earlier launch left in those words is counted at the first connect, and a row with any
    /// other reason is not; they are the words another recorder's arrival writes on every row; the strip's own
    /// sentence carries the count, comes first, and is joined to what was sent with a full stop; and one the
    /// reader asks for again goes to the recorder in play.
    ///
    /// The sentence on the rows is never to change. The strip's own may be reworded.
    func testWhatIsHeldForAnotherRecorderIsCountedByTheSentenceWrittenOnIt() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let store = try GuideStore(path: bench.guidePath)
        let recorder = NamedRecorder(1)
        let model = bench.model(recorders: [Bench.host: recorder])
        // Held until the reservations are in the queue, so that the first connect finds them waiting.
        await recorder.hold()
        await model.start()
        let written = [Said.heldForAnotherRecorder, Said.heldForAnotherRecorder, "受信できないチャンネルです"]
        for (skipping, reason) in written.enumerated() {
            try await store.queue(waiting(for: aProgramme(model, skipping: skipping), problem: reason))
        }
        await recorder.letGo()
        try await untilConnected(model)

        XCTAssertEqual(model.pending.count, written.count)
        XCTAssertEqual(model.flushReport, Said.heldBack(2),
                       "what an earlier launch left held is not counted, or what was turned down is counted too")
        expectEqual(await recorder.asked(Kind.create), 0, "a reservation with a reason on it was sent")

        await recorder.become(2)
        await model.connect()
        try await untilIdle(model)
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(try await store.pendingReservations().map(\.problem),
                    Array(repeating: Said.heldForAnotherRecorder, count: written.count),
                    "another recorder's arrival did not write the sentence on every row")
        XCTAssertEqual(model.flushReport, Said.heldBack(3))
        expectEqual(await recorder.asked(Kind.create), 0, "what waited for the first recorder went to the second")

        let first = try XCTUnwrap(model.pending.first)
        await model.resend(first)
        XCTAssertEqual(model.flushReport, Said.heldBack(2) + "。" + Said.sent(first.request.title))
        expectEqual(await recorder.asked(Kind.create), 1, "the one asked for again did not go to the recorder in play")
        XCTAssertEqual(model.pending.count, 2)
    }

    /// What became of the queue, as a sending says it: the other half of the strip's line, and the whole of the
    /// overnight notification and of the Shortcuts action's answer. A sentence each for what was sent, what was
    /// dropped because its programme was over, what the recorder turned down and what could not be sent this
    /// time, in that order and joined with a full stop; the first by its title and the others by their number;
    /// the recorder going silent part way said only after something else, since by itself it is the app going
    /// offline, which the strip says already; and nothing at all when there is nothing to say.
    ///
    /// Each sending is the queue's own (`PendingQueue.flush`) to a recorder of its own, with no model and no
    /// connect: what a sending came to cannot be made by hand. The queue is emptied before each, so that what one
    /// left behind is not what the next one finds.
    ///
    /// The sentences live beside the queue's outcome, in the package; this holds them as the app says them
    /// with no television saved.
    func testWhatBecameOfTheQueueIsSaidInTheseWords() async throws {
        let store = try GuideStore(path: try aBench().guidePath)
        // Read from the queue in the order they start: the one that is over, then the morning's, then noon's.
        let over = waiting("終わった番組", startingIn: -120, programme: 4320)
        let morning = waiting("朝の番組", startingIn: 120, programme: 4321)
        let noon = waiting("昼の番組", startingIn: 121, programme: 4322)
        let sendings = [
            Sending("one sent", [morning], says: Said.sent("朝の番組")),
            Sending("two sent", [morning, noon], says: Said.sent("朝の番組", andOthers: 1)),
            Sending("one that is over", [over], says: Said.expired("終わった番組")),
            Sending("one turned down", [morning], says: Said.refused("朝の番組")) {
                await $0.answer(Kind.create, with: .fault(831))
            },
            Sending("one the recorder was too busy for", [morning], says: Said.deferred("朝の番組")) {
                await $0.beBusy(with: Kind.create)
            },
            // The morning's is taken and noon's turned down.
            Sending("one over, one sent, one turned down", [over, morning, noon],
                    says: [Said.sent("朝の番組"), Said.expired("終わった番組"), Said.refused("昼の番組")]
                        .joined(separator: "。")) {
                await $0.answer(Kind.create, with: .fault(831), after: 1)
            },
            Sending("one sent, then silence", [morning, noon], says: Said.sent("朝の番組") + "。" + Said.interrupted) {
                await $0.goQuiet(for: 1, after: 1)
            },
            Sending("silence at the first", [morning], says: nil) { await $0.goQuiet(for: 1) },
        ]

        for sending in sendings {
            for left in try await store.pendingReservations() { try await store.removePending(left.id) }
            for waiting in sending.waits { try await store.queue(waiting) }
            let recorder = NamedRecorder(1)
            await sending.told(recorder)

            let outcome = await PendingQueue.flush(client: aClient(of: recorder), store: store)
            XCTAssertEqual(outcome.summary, sending.says, sending.name)
        }
    }

    // MARK: - what the tests put in the queue

    /// A reservation of `program` as the app queues one, turned down before when `problem` is given.
    private func waiting(for program: GuideProgramRow, problem: String? = nil) throws -> PendingReservation {
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        return PendingReservation(request: request, serviceName: program.serviceName, problem: problem)
    }

    /// One of the test's own making, for where there is no guide to take a programme from: half an hour on the
    /// demo's first channel, in DR and not repeated, starting so many minutes from now.
    private func waiting(_ title: String, startingIn minutes: Double, programme: Int) -> PendingReservation {
        let request = ReservationRequest(title: title, start: Date().addingTimeInterval(minutes * 60),
                                         durationSec: 1800, repeatCode: "1", broadcastingType: 2, serviceID: 1024,
                                         qualityCode: 100, eventID: programme)
        return PendingReservation(request: request, serviceName: "サンプルテレビ")
    }

    /// What is written on each of the rows waiting, by the row: its reason, and nothing where it has none. Which
    /// rows there are and what each says, in one comparison and whatever order they come in.
    private func reasons(_ rows: [PendingReservation]) -> [String: String] {
        Dictionary(rows.map { ($0.id, $0.problem ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - what the tests ask for

/// What the recorder is asked, as its fake on the bench names a kind of request. Named once: a name misspelt in
/// a test that looks for nothing having been asked would pass.
private enum Kind {
    /// The reservations' list, read when asked for, by a connect, and after something waiting was made.
    static let list = "X_GetRecordScheduleList"
    static let create = "X_CreateRecordSchedule"
    /// What a connect asks first, and the check before an operation.
    static let description = "description.xml"
    /// What the name of each of the guide's files begins with.
    static let guide = "EPG_"
}

/// One sending of the queue: what waits, what the recorder is told beforehand, and what is said of it afterwards.
@MainActor
private struct Sending {
    let name: String
    let waits: [PendingReservation]
    /// What became of the queue, in words; nil when nothing is to be said.
    let says: String?
    let told: @MainActor (NamedRecorder) async -> Void

    init(_ name: String, _ waits: [PendingReservation], says: String?,
         told: @escaping @MainActor (NamedRecorder) async -> Void = { _ in }) {
        (self.name, self.waits, self.says, self.told) = (name, waits, says, told)
    }
}
