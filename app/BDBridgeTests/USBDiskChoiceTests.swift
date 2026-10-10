import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// Which of the recorder's disks a reservation records to, as the model has it for the screens: what is offered,
/// what is sent and what is named, in a home with a USB disk and in one without. The disk is the test's own
/// answer to the slot (`USBDiskTests.slot`), given through the bench's recorder; the demo's recorder answers the
/// slot with nothing, which is no disk, and keeps what it is sent as sent, so a disk reads back as it went out.
@MainActor
final class USBDiskChoiceTests: XCTestCase {
    /// What the model says when a disk picked is no longer offered and none is known in the slot any more.
    private static let slotGone = "USBHDDはいま使えません。別の録画先を選んでください。"

    /// A keyword condition with a word of the test's own, to `destination`.
    private static func condition(to destination: String) -> RecorderRuleRequest {
        RecorderRuleRequest(keywords: ["ためしの言葉"], qualityCode: 240, destination: destination)
    }

    /// A model started and connected to a recorder whose slot answers `slot` the first `times` it is asked, and
    /// as the demo's does after that, which is none. `readAgainAfter` is how long an attach that finds none
    /// while a disk is known waits before reading the slot again. The slot is waited for, before something that
    /// names it is sent while the disk is kept, as the app waits for it in seconds, in milliseconds: six reads.
    private func connected(answering slot: String = USBDiskTests.slot(), times: Int = 1000,
                           readAgainAfter: Duration = RecorderDriver.slotReadAgainAfter) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel) {
        let bench = try aBench()
        try await bench.cacheAGuide()
        bench.slotReadAgainAfter = readAgainAfter
        bench.slotSettling = SlotSettling(every: .milliseconds(5), for: .milliseconds(25))
        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(slot), times: times)
        let model = bench.model(recorders: [Bench.host: recorder])
        await model.start()
        try await untilConnected(model)
        return (bench, recorder, model)
    }

    /// A model that knew a USB disk and has let it go: the slot answered none at an attach, and again when it was
    /// read a moment later.
    private func connectedWithTheDiskGone() async throws -> (bench: Bench, recorder: NamedRecorder,
                                                              model: AppModel) {
        let (bench, recorder, model) = try await connected(times: 1, readAgainAfter: .milliseconds(50))
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk)
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        return (bench, recorder, model)
    }

    /// A home with no USB disk is offered no disk anywhere and has none named -- not on a reservation, a row
    /// that waits or a condition -- and what it sends is what it always sent: a reservation and a change made
    /// with the model's own defaults go to the internal disk, the create's elements as they were, character for
    /// character.
    func testAHomeWithNoUSBDiskIsOfferedNoDiskAndNamesNone() async throws {
        let (bench, recorder, model) = try await connectedHome()
        XCTAssertNil(model.usbDisk)
        XCTAssertEqual(model.diskChoices, [])
        XCTAssertFalse(model.reservations.isEmpty)
        for reservation in model.reservations {
            XCTAssertEqual(model.diskChoices(for: reservation), [], reservation.title)
            XCTAssertNil(model.diskShown(reservation), reservation.title)
        }
        let programs = try await programmesNotReserved(model, 2)
        let waiting = PendingReservation(
            request: try XCTUnwrap(ReservationRequest(program: programs[1], quality: "DR", repeating: "none")),
            serviceName: programs[1].serviceName)
        try await GuideStore(path: bench.guidePath).queue(waiting)
        await model.loadPending()
        XCTAssertNil(model.diskShown(try XCTUnwrap(model.pending.first)), "a row that waits named a disk")
        await model.loadRecorderRules()
        XCTAssertFalse(model.recorderRules.isEmpty)
        for rule in model.recorderRules { XCTAssertNil(model.diskShown(rule), rule.name) }

        expectTrue(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        let request = try XCTUnwrap(ReservationRequest(program: programs[0], quality: "DR", repeating: "none"))
        expectEqual(await recorder.elements(of: "X_CreateRecordSchedule"), XsrsElements.create(request),
                    "the internal disk's reservation is not sent as it was")
        let made = try XCTUnwrap(model.reservation(for: programs[0]))
        XCTAssertEqual(made.destination, "HDD")
        expectTrue(await changeOnTheRecorder(model, made, quality: "ER", repeating: "none"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: programs[0])?.destination, "HDD")
        XCTAssertEqual(model.reservation(for: programs[0])?.qualityName, "ER")
    }

    /// A USB disk the recorder says is not mounted is offered for no new reservation, and a reservation already
    /// on it is still named after it and can be moved to the internal disk, or left where it is.
    func testADiskThatTakesNoRecordingsIsNamedAndNotOffered() async throws {
        let (_, recorder, model) = try await connected(answering: USBDiskTests.slot(mount: "0"))
        let unplugged = try XCTUnwrap(model.usbDisk)
        XCTAssertFalse(unplugged.mounted)
        XCTAssertEqual(model.diskChoices, [], "a disk not mounted was offered")

        // Made to the slot as the recorder's own screen would make it.
        let program = try await programmesNotReserved(model, 1)[0]
        try await aClient(of: recorder).create(try XCTUnwrap(ReservationRequest(
            program: program, quality: "DR", repeating: "none", destination: "USBHDD")))
        await model.loadReservations()
        let onTheSlot = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(model.diskShown(onTheSlot), "録画用ディスク")
        XCTAssertEqual(model.diskChoices(for: onTheSlot), [RecorderDisk.internalDisk, unplugged])
    }

    /// The clashes asked for while the sheet shows the USB disk are the ones on it: the clash check carries the
    /// elements a reservation to that disk would, and with no disk given, the internal disk's.
    func testTheClashCheckIsAskedWithTheChosenDisk() async throws {
        let (_, recorder, model) = try await connected()
        let program = try await programmesNotReserved(model, 1)[0]

        _ = await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
        expectEqual(await recorder.elements(of: "X_GetConflictList"), XsrsElements.create(try XCTUnwrap(
            ReservationRequest(program: program, quality: "DR", repeating: "none", destination: "USBHDD"))))

        _ = await model.conflicts(for: program, quality: "DR", repeating: "none")
        expectEqual(await recorder.elements(of: "X_GetConflictList"), XsrsElements.create(try XCTUnwrap(
            ReservationRequest(program: program, quality: "DR", repeating: "none"))))
    }

    /// With a USB disk that takes recordings, the internal disk and that disk are offered, the internal disk
    /// first; a reservation made to the USB disk is made there, and its row is named after the disk.
    func testAReservationToTheUSBDiskIsMadeThere() async throws {
        let (_, recorder, model) = try await connected()
        XCTAssertEqual(model.diskChoices, [RecorderDisk.internalDisk, USBDiskTests.disk])
        let program = try await programmesNotReserved(model, 1)[0]

        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")

        expectEqual(await recorder.elements(of: "X_CreateRecordSchedule"), XsrsElements.create(try XCTUnwrap(
            ReservationRequest(program: program, quality: "DR", repeating: "none", destination: "USBHDD"))))
        let made = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(made.destination, "USBHDD")
        XCTAssertEqual(model.diskShown(made), "録画用ディスク")
    }

    /// Right after a wake the slot answers none with a disk in it, and the disk known is kept until the slot is
    /// read again. It is offered all that while, as an answered one is, and a reservation to it is made there once
    /// the slot answers it.
    func testADiskKeptThroughAnAnswerOfNoneIsOffered() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        XCTAssertNotNil(model.recorder.readLeftForLater, "the slot was not left to be read again")
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk)
        XCTAssertEqual(model.diskChoices, [RecorderDisk.internalDisk, USBDiskTests.disk],
                       "a disk kept through an answer of none was not offered")

        let program = try await programmesNotReserved(model, 1)[0]
        await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot()), times: 1)
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD")
    }

    /// The line a screen says while the slot is waited for.
    private static let waitingForTheSlot = "録画先のディスクを確かめています"
    /// What the model says of the USB disk when it cannot be had and the sheet has another destination.
    private static let diskNotHad = "録画用ディスクはいま使えません。別の録画先を選んでください。"

    /// Right after a wake the disk is kept through the slot's answer of none, and a reservation to it waits for the
    /// slot first, under a line that says so, the sheet held as during any request. The slot answering none each
    /// time -- the disk unplugged -- nothing is created or kept to be sent, the reader is asked for another disk,
    /// and the disk and the read left for later stay as they were.
    func testAReservationToAKeptDiskTheSlotDoesNotAnswerIsNotSent() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let later = try XCTUnwrap(model.recorder.readLeftForLater, "the slot was not left to be read again")
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.hold(only: "X_GetMediaInfo")

        let reserving = Task {
            await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the slot was not waited for") { await recorder.asked("X_GetMediaInfo", since: before) == 1 }
        XCTAssertEqual(model.busy, Self.waitingForTheSlot)
        XCTAssertTrue(model.settlingTheSlot, "the sheet would not say the wait")
        XCTAssertTrue(model.working, "the sheet's buttons were left alive while the slot was waited for")
        await recorder.letGo()
        let made = await reserving.value

        XCTAssertFalse(made, "a reservation was made to a disk the slot did not answer")
        XCTAssertEqual(whyNotJustNow(model), Self.diskNotHad)
        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 6)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the disk known was let go of")
        XCTAssertEqual(model.recorder.readLeftForLater, later, "the read left for later was not left as it was")
        XCTAssertTrue(model.diskCannotBeHad("USBHDD"), "the sheet would not go back to the internal disk")
        XCTAssertTrue(model.pending.isEmpty, "a reservation to a disk not answered was kept to be sent")
        XCTAssertNil(model.reservation(for: program))
        XCTAssertFalse(model.settlingTheSlot)
    }

    /// The slot answering the disk on its second read -- a disk that comes up seconds after the wake -- the
    /// reservation's round goes right after that read, and the disk is taken as it answered, the read left for later
    /// ended.
    func testAReservationToAKeptDiskIsCreatedOnceTheSlotAnswersIt() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let later = try XCTUnwrap(model.recorder.readLeftForLater, "the slot was not left to be read again")
        let program = try await programmesNotReserved(model, 1)[0]
        await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot(remain: 100_000)), times: 1,
                              after: 1)
        let before = await recorder.heard.count

        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")

        expectEqual(await recorder.heard(since: before),
                    ["X_GetMediaInfo", "X_GetMediaInfo", "X_GetRecordScheduleList", "X_CreateRecordSchedule",
                     "X_GetRecordScheduleList"])
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD")
        XCTAssertEqual(model.usbDisk?.freeMB, 100_000, "the disk was not taken as it answered")
        XCTAssertNil(model.recorder.readLeftForLater, "the read left for later was not ended")
        XCTAssertTrue(later.isCancelled)
    }

    /// A change that goes to a kept disk -- moved there, or of a reservation on it -- waits for the slot as a
    /// reservation does. The slot answering none each time, neither is sent, and each is said as for a disk that
    /// cannot be had, by what its sheet has left to offer.
    func testAChangeToAKeptDiskTheSlotDoesNotAnswerIsNotSent() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        let programs = try await programmesNotReserved(model, 2)
        expectTrue(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let onTheInternalDisk = try XCTUnwrap(model.reservation(for: programs[0]))
        let onTheSlot = try XCTUnwrap(model.reservation(for: programs[1]))
        let before = await recorder.asked

        leaveALine(on: model)
        expectFalse(await changeOnTheRecorder(model, onTheInternalDisk, quality: "DR", repeating: "none",
                                              disk: "USBHDD"),
                    "a move to a disk the slot did not answer was sent")
        XCTAssertEqual(whyNotJustNow(model), "録画用ディスクはいま使えません。録画先はHDDのままです。")
        XCTAssertTrue(model.diskCannotBeHad("USBHDD"))
        leaveALine(on: model)
        expectFalse(await changeOnTheRecorder(model, onTheSlot, quality: "ER", repeating: "none"),
                    "a change of a reservation on a disk the slot did not answer was sent")
        XCTAssertEqual(whyNotJustNow(model), Self.diskNotHad)

        expectEqual(await recorder.asked("X_UpdateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 12)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk)
        XCTAssertNotNil(model.recorder.readLeftForLater)
        XCTAssertEqual(model.reservation(for: programs[1])?.qualityName, "DR")
    }

    /// A condition to a kept disk waits for the slot as a reservation does. The slot answering none each time,
    /// nothing is sent, and it is said as for a disk that cannot be had, its sheet going back to the internal disk:
    /// in what the condition hands back, the line left as it was.
    func testAConditionToAKeptDiskTheSlotDoesNotAnswerIsNotSent() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let before = await recorder.asked
        leaveALine(on: model)

        expectFalse(await addACondition(model, Self.condition(to: "USBHDD")),
                    "a condition to a disk the slot did not answer was sent")

        XCTAssertEqual(whyNotJustNow(model), Self.diskNotHad)
        XCTAssertEqual(model.problem, lineLeft, "the condition wrote over the line")
        XCTAssertTrue(model.diskCannotBeHad("USBHDD"), "the sheet would not go back to the internal disk")
        expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 6)
    }

    /// A condition to the USB disk is not sent past a check or a slot that said nothing. The check before it
    /// meeting silence, nothing is asked of the slot, and the line says that the recorder did not answer, as
    /// what the condition hands back does. The slot falling silent while it is waited for, the line and the
    /// result say the same and the recorder is lost. The wait given up, the result says that it was and that
    /// nothing was sent, and the line is left as an earlier operation left it.
    func testAConditionToTheUSBDiskIsNotSentPastACheckOrASlotThatSaidNothing() async throws {
        // The check meets silence, the disk answered at the connect.
        do {
            let (bench, recorder, model) = try await connected()
            bench.network = "away"
            await recorder.hold(only: "description.xml")
            addTeardownBlock { await recorder.letGo() }
            let check = Task { await lookAtTheNetwork(model) }
            try await until("the recorder was never made sure of") { isMakingSure(model) }
            let before = await recorder.asked
            leaveALine(on: model)
            let adding = Task { await addACondition(model, Self.condition(to: "USBHDD")) }
            try await until("the condition was never begun", within: 5) { model.busy != nil }
            await recorder.goQuiet(on: "description.xml")
            await recorder.letGo()
            expectFalse(await adding.value, "a condition was made past a check that met silence")
            _ = await check.value
            XCTAssertEqual(model.problem, Said.noAnswer)
            XCTAssertEqual(whyNotJustNow(model), Said.noAnswer)
            XCTAssertTrue(model.gaveUp)
            expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
            expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 0)
        }

        // The slot falls silent, the disk kept through an answer of none.
        do {
            let (_, recorder, model) = try await connected(times: 1)
            await reconnect(model)
            await recorder.goQuiet(on: "X_GetMediaInfo")
            let before = await recorder.asked
            leaveALine(on: model)
            expectFalse(await addACondition(model, Self.condition(to: "USBHDD")),
                        "a condition was made past a slot that fell silent")
            XCTAssertEqual(model.problem, Said.noAnswer, "the slot's silence was not said")
            XCTAssertEqual(whyNotJustNow(model), Said.noAnswer)
            XCTAssertTrue(model.gaveUp, "silence at the slot did not lose the recorder")
            XCTAssertFalse(model.diskCannotBeHad("USBHDD"), "a slot that said nothing was taken for one with no disk")
            expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
            expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 1)
        }

        // The wait given up while the slot is read.
        do {
            let (_, recorder, model) = try await connected(times: 1)
            addTeardownBlock { await recorder.letGo() }
            await reconnect(model)
            let before = await recorder.asked
            await recorder.hold(only: "X_GetMediaInfo")
            let adding = Task { await addACondition(model, Self.condition(to: "USBHDD")) }
            try await until("the slot was never read") { await recorder.asked("X_GetMediaInfo", since: before) == 1 }
            leaveALine(on: model)
            adding.cancel()
            await recorder.letGo()
            expectFalse(await adding.value, "a condition given up was made")
            XCTAssertEqual(whyNotJustNow(model), Said.slotWaitGivenUp)
            XCTAssertEqual(model.problem, lineLeft, "a condition given up wrote on the line")
            XCTAssertFalse(model.gaveUp)
            XCTAssertNil(model.busy)
            expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
        }
    }

    /// A clash check asked for a kept disk waits for the slot as a reservation does. The slot answering none each
    /// time, the clashes are not asked, and it is said as for a disk that cannot be had, its sheet going back to the
    /// internal disk.
    func testAClashCheckForAKeptDiskTheSlotDoesNotAnswerIsNotAsked() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        leaveALine(on: model)

        expectNil(await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD"),
                  "a clash check for a disk the slot did not answer was asked")

        XCTAssertEqual(model.problem, Self.diskNotHad)
        XCTAssertTrue(model.diskCannotBeHad("USBHDD"), "the sheet would not go back to the internal disk")
        expectEqual(await recorder.asked("X_GetConflictList", since: before), 0)
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 6)
    }

    /// From the moment the recorder answers a connect -- a waking one above all -- a reservation to the USB disk
    /// waits for the slot, though the slot answered the disk at the connect before and nothing has been left to
    /// read again yet: made while the attach still reads the slot, it waits behind that read. The slot answering
    /// none throughout, as right after a waking, nothing is sent to it and the reader is asked for another disk.
    func testAReservationMadeAsTheRecorderAnswersWaitsForTheSlot() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        let program = try await programmesNotReserved(model, 1)[0]
        // The demo's answer from here on, which is none; each read of it held until the reservation is out.
        await recorder.hold(only: "X_GetMediaInfo")
        addTeardownBlock { await recorder.letGo() }
        let before = await recorder.asked
        let connecting = Task { await model.connect() }
        try await until("the attach never read the slot") {
            await recorder.asked("X_GetMediaInfo", since: before) == 1
        }

        let reserving = Task {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the reservation did not wait for the slot", within: 5) { model.settlingTheSlot }
        await recorder.letGo()
        let came = await reserving.value
        await connecting.value

        XCTAssertEqual(came, .notDone(Self.diskNotHad))
        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0,
                    "a reservation was sent to a slot that had not answered since the recorder answered")
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 7)
        XCTAssertNil(model.reservation(for: program))
        XCTAssertTrue(model.pending.isEmpty)
    }

    /// The recorder falling silent while the slot is waited for is lost, as on any read, and the reservation, of
    /// which nothing was sent, is kept to be sent with its disk, as when the recorder could not be made sure of.
    func testAReservationIsKeptToBeSentWhenTheRecorderFallsSilentWhileTheSlotIsWaitedFor() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        await recorder.goQuiet(on: "X_GetMediaInfo")
        let before = await recorder.asked

        let came = await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")

        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation met by silence was not kept to be sent: \(came)")
        }
        XCTAssertEqual(row.request.destination, "USBHDD")
        XCTAssertEqual(model.pending(for: program, on: .recorder)?.request.destination, "USBHDD")
        XCTAssertTrue(model.offline, "the recorder was not lost")
        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 1)
    }

    /// The same silence while a pull-down sends a row that waits for the slot: nothing was sent, which the line
    /// says as it says a read's silence, over what was left there, and the recorder is lost. The row waits as
    /// it was, with no reason, to go the next time.
    func testASendingWhoseSlotFallsSilentSaysTheRecorderDidNotAnswer() async throws {
        let (bench, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none",
                                                       destination: "USBHDD"))
        try await GuideStore(path: bench.guidePath).queue(PendingReservation(request: request,
                                                                             serviceName: program.serviceName))
        await recorder.goQuiet(on: "X_GetMediaInfo")
        leaveALine(on: model)
        let before = await recorder.asked

        await model.refreshReservations()

        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the slot's silence was not said")
        XCTAssertTrue(model.gaveUp, "the recorder was not lost")
        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 1)
        let row = try XCTUnwrap(model.pending(for: program, on: .recorder), "the row no longer waits")
        XCTAssertNil(row.problem, "the row was held, and would not go by itself")
    }

    /// The same silence, with a connect made while the slot's read is out, keeps the reservation only while the
    /// recorder it was asked of is still the one in play. Another recorder taken up by that connect, it is not
    /// done and not kept: kept, it would wait as one made for the first, and go to the newcomer at its next
    /// connect. The same recorder answering the connect lets go of nothing, though the connect makes a client
    /// of its own: the reservation is kept as if the connect had not come. Nothing is created either way. The
    /// silence of a slot read for the recorder let go of is not the newcomer's, which is not given up on.
    func testASilentSlotKeepsAReservationOnlyForTheRecorderItWasAskedOf() async throws {
        for anotherAnswers in [true, false] {
            let (bench, recorder, model) = try await connected(times: 1)
            addTeardownBlock { await recorder.letGo() }
            // The demo's answer from here on, which is none; the read again is half a minute away.
            await reconnect(model)
            let program = try await programmesNotReserved(model, 1)[0]
            let before = await recorder.asked
            await recorder.holdTheNext("X_GetMediaInfo")

            let reserving = Task {
                await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
            }
            try await until("the slot was not waited for") {
                await recorder.asked("X_GetMediaInfo", since: before) == 1
            }
            if anotherAnswers { await recorder.become(2) }
            let made = bench.clientsMade
            await model.connect()
            let who = anotherAnswers ? "another recorder answering" : "the same recorder answering"
            // What this stands on, rather than what it holds: the connect made a client of its own and was
            // answered by the recorder meant.
            XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own, \(who)")
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(anotherAnswers ? 2 : 1),
                           "the connect was meant to be answered so, \(who)")
            await recorder.goQuiet(on: "X_GetMediaInfo")
            await recorder.letGo()
            let came = await reserving.value

            let onDisk = try await GuideStore(path: bench.guidePath).pendingReservations()
            if anotherAnswers {
                guard case .notDone = came else {
                    return XCTFail("a reservation for a recorder let go of was kept or made: \(came)")
                }
                XCTAssertNil(model.pending(for: program), "kept for a recorder the app had let go of")
                XCTAssertTrue(onDisk.isEmpty, "kept on the phone for a recorder the app had let go of")
                XCTAssertFalse(model.gaveUp, "the slot's silence for the recorder let go of gave the newcomer up")
            } else {
                guard case .waiting = came else {
                    return XCTFail("a reservation met by silence beside a connect to its recorder was not kept: "
                                       + "\(came)")
                }
                XCTAssertEqual(model.pending(for: program, on: .recorder)?.request.destination, "USBHDD")
                XCTAssertEqual(onDisk.map(\.request.eventID), [program.eventID])
            }
            expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0, who)
        }
    }

    /// A reservation to the USB disk, and a change that moves one there, whose slot is waited for when another
    /// recorder answers a connect beside it, and the slot then answers the disk: each was asked of the recorder
    /// let go of, and nothing is sent to either. Each is not done and says that another recorder answered, and
    /// nothing is kept. The newcomer's slot answers a disk too, so that the disk is offered by the time the
    /// slot's read comes back.
    func testWhatWaitsForTheSlotWhenAnotherRecorderAnswersIsNotSent() async throws {
        for changes in [false, true] {
            let what = changes ? "the change" : "the reservation"
            let (bench, recorder, model) = try await connected(times: 1)
            addTeardownBlock { await recorder.letGo() }
            let programs = try await programmesNotReserved(model, 2)
            if changes {
                expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none"),
                           model.problem ?? "no reason given")
            }
            // The demo's answer from here on, which is none; the read again is half a minute away.
            await reconnect(model)
            let row = changes ? try XCTUnwrap(model.reservation(for: programs[1])) : nil
            let before = await recorder.asked
            await recorder.holdTheNext("X_GetMediaInfo")
            let asking = Task { () -> String? in
                if let row {
                    let came = await model.change(row, quality: "DR", repeating: "none", disk: "USBHDD")
                    return came == .notDone(Said.anotherAnswered) ? nil : "\(came)"
                }
                let came = await model.reserve(programs[0], on: .recorder, quality: "DR", repeating: "none",
                                               disk: "USBHDD")
                return came == .notDone(Said.anotherAnswered) ? nil : "\(came)"
            }
            try await until("\(what): the slot was not waited for") {
                await recorder.asked("X_GetMediaInfo", since: before) == 1
            }

            await recorder.become(2)
            // The newcomer's attach reads the slot, and then the read held comes back: both answer the disk.
            await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot()), times: 2)
            await model.connect()
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem ?? "no reason given")
            XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the newcomer's disk was meant to be offered")
            await recorder.letGo()

            let otherwise = await asking.value
            XCTAssertNil(otherwise, "\(what) asked of the recorder let go of came to something else")
            for kind in ["X_CreateRecordSchedule", "X_UpdateRecordSchedule"] {
                expectEqual(await recorder.asked(kind, since: before), 0, "\(what) was sent: \(kind)")
            }
            XCTAssertNil(model.pending(for: programs[0]), "kept for a recorder the app had let go of")
            expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty,
                       "kept on the phone for a recorder the app had let go of")
        }
    }

    /// A reservation to the USB disk, and a change that moves one there, whose slot is waited for while another
    /// operation's check hears the recorder busy with somebody else: nothing has heard it say which it is since,
    /// so neither is sent once the slot answers the disk. The reservation is kept on the phone, as after its own
    /// check heard that; the change is not done; and each says what the check heard.
    ///
    /// The check goes in between two reads of the slot, as it does while the slot answers none: the slot's reads
    /// here are half a second apart, so that the check is over before the second, which answers the disk.
    func testWhatWaitsForTheSlotWhileACheckHearsTheRecorderBusyIsNotSent() async throws {
        for changes in [false, true] {
            let what = changes ? "the change" : "the reservation"
            let bench = try aBench()
            try await bench.cacheAGuide()
            bench.slotSettling = SlotSettling(every: .milliseconds(500), for: .seconds(2))
            let recorder = NamedRecorder(1)
            await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot()), times: 1)
            let model = bench.model(recorders: [Bench.host: recorder])
            await model.start()
            try await untilConnected(model)
            let programs = try await programmesNotReserved(model, 2)
            if changes {
                expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none"),
                           model.problem ?? "no reason given")
            }
            // The demo's answer from here on, which is none; the read again is half a minute away.
            await reconnect(model)
            let row = changes ? try XCTUnwrap(model.reservation(for: programs[1])) : nil
            let before = await recorder.asked
            // None to the first read of the slot, the disk to the second.
            await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot()), times: 1, after: 1)
            let reserving = row == nil ? Task {
                await model.reserve(programs[0], on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
            } : nil
            let changing = row.map { row in
                Task { await model.change(row, quality: "DR", repeating: "none", disk: "USBHDD") }
            }
            try await until("\(what): the slot was not waited for") {
                await recorder.asked("X_GetMediaInfo", since: before) == 1
            }

            await recorder.busyAtTheDoor()
            expectTrue(await makeSure(model), "a recorder that answered busy was taken for gone")
            expectEqual(await recorder.asked("description.xml", since: before), 3, "the check did not ask who answers")
            expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 1,
                        "\(what): the slot was read again before the check was over")
            let busy = Said.busy("description.xml")
            if let reserving {
                let came = await reserving.value
                guard case .waiting(let kept, _) = came else {
                    return XCTFail("a reservation whose slot came back after a check heard the recorder busy was "
                                       + "not kept: \(came)")
                }
                XCTAssertEqual(kept.request.destination, "USBHDD")
                XCTAssertEqual(model.pending(for: programs[0], on: .recorder)?.id, kept.id)
            }
            if let changing {
                expectEqual(await changing.value, .notDone(busy))
            }
            expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 2,
                        "\(what): the slot did not answer the disk")
            XCTAssertEqual(model.problem, busy, "\(what) did not say what the check heard")
            for kind in ["X_CreateRecordSchedule", "X_UpdateRecordSchedule"] {
                expectEqual(await recorder.asked(kind, since: before), 0,
                            "\(what) was sent after a check that heard the recorder busy: \(kind)")
            }
        }
    }

    /// The slot answering the disk as not mounted while it is waited for -- registered, and taking no recordings --
    /// is no disk to send to: the reservation is refused as for a disk no longer offered, nothing sent, and the disk
    /// is taken as it answered.
    func testAReservationToADiskTheSlotAnswersAsNotMountedIsNotSent() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot(mount: "0")), times: 1)
        let before = await recorder.asked

        let came = await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")

        XCTAssertEqual(came, .notDone(Self.diskNotHad))
        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0,
                    "a reservation was sent to a disk that takes no recordings")
        expectEqual(await recorder.asked("X_GetMediaInfo", since: before), 1)
        XCTAssertEqual(model.usbDisk?.mounted, false, "the disk was not taken as it answered")
        XCTAssertTrue(model.diskCannotBeHad("USBHDD"))
        XCTAssertTrue(model.pending.isEmpty)
    }

    /// A condition to the USB disk says what it is doing from the press, before the recorder is made sure of: the
    /// sheet's button, held while a line is up, cannot be pressed a second time to make a second condition.
    func testAConditionToTheUSBDiskSaysWhatItIsDoingFromThePress() async throws {
        let (bench, recorder, model) = try await connected()
        // The network moves, and the recorder is made sure of with its answer held.
        bench.network = "away"
        await recorder.hold(only: "description.xml")
        addTeardownBlock { await recorder.letGo() }
        let check = Task { await lookAtTheNetwork(model) }
        try await until("the recorder was never made sure of") { isMakingSure(model) }
        let before = await recorder.asked

        let adding = Task { await addACondition(model, Self.condition(to: "USBHDD")) }
        try await until("the press put up no line while the recorder was made sure of", within: 5) {
            model.busy != nil
        }
        XCTAssertEqual(model.busy, "レコーダーに登録中")
        XCTAssertTrue(isMakingSure(model))
        await recorder.letGo()
        let made = await adding.value
        _ = await check.value

        expectTrue(made, model.problem ?? "no reason given")
        expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 1)
        XCTAssertNil(model.busy)
    }

    /// Nothing is waited for, and no read of the slot added, where nothing names a disk kept through an answer of
    /// none: in a home with no USB disk the clash check, a change and a condition each send what they always
    /// sent, and a reservation that and the list its round opens with; and so do the same to a USB disk the slot
    /// has answered since the recorder woke.
    func testNoReadOfTheSlotIsAddedWithNoUSBDiskOrWithTheDiskAnswered() async throws {
        let (_, home, noUSB) = try await connectedHome()
        let (_, recorder, answered) = try await connected()
        let sent = ["X_GetConflictList", "X_GetRecordScheduleList", "X_CreateRecordSchedule", "X_GetRecordScheduleList",
                    "X_GetRecordScheduleList", "X_UpdateRecordSchedule", "X_GetRecordScheduleList",
                    "X_CreatePrefRecSetting", "X_GetPrefRecSettingList"]
        for (what, model, transport, disk) in [("no USB disk", noUSB, home, "HDD"),
                                               ("the disk answered", answered, recorder, "USBHDD")] {
            let program = try await programmesNotReserved(model, 1)[0]
            let before = await transport.heard.count

            _ = await model.conflicts(for: program, quality: "DR", repeating: "none", disk: disk)
            expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: disk),
                       model.problem ?? "no reason given")
            let made = try XCTUnwrap(model.reservation(for: program), what)
            expectTrue(await changeOnTheRecorder(model, made, quality: "ER", repeating: "none"),
                       model.problem ?? "no reason given")
            expectTrue(await addACondition(model, Self.condition(to: disk)), model.problem ?? "no reason given")

            expectEqual(await transport.heard(since: before), sent, what)
        }
    }

    /// A disk picked while it was offered and let go of before it is sent is not sent, and not swapped for the
    /// internal disk either: a reservation, a move and a condition to it are each refused before anything goes
    /// out, with the sentence that names the disk and asks for another.
    func testADiskNoLongerOfferedIsNotSent() async throws {
        let (_, recorder, model) = try await connectedWithTheDiskGone()
        let program = try await programmesNotReserved(model, 1)[0]
        let onTheInternalDisk = try XCTUnwrap(model.reservations.first {
            !$0.recording && $0.end > Date() && $0.destination == RecorderDisk.internalID
        })
        let before = await recorder.asked

        expectFalse(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: "USBHDD"),
                    "a reservation to a disk no longer offered was made")
        XCTAssertEqual(whyNotJustNow(model), Self.slotGone)
        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone(Self.slotGone))
        expectFalse(await changeOnTheRecorder(model, onTheInternalDisk, quality: "DR", repeating: "none",
                                              disk: "USBHDD"),
                    "a move to a disk no longer offered was made")
        XCTAssertEqual(whyNotJustNow(model), "USBHDDはいま使えません。録画先はHDDのままです。")
        leaveALine(on: model)
        expectFalse(await addACondition(model, Self.condition(to: "USBHDD")),
                    "a condition to a disk no longer offered was made")
        XCTAssertEqual(whyNotJustNow(model), Self.slotGone)
        XCTAssertEqual(model.problem, lineLeft, "the condition wrote over the line at its door")

        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_UpdateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
        XCTAssertNil(model.reservation(for: program))
        XCTAssertTrue(model.pending.isEmpty, "a reservation to a disk no longer offered was kept to be sent")
    }

    /// What a reservation and a change of the recorder's turn away at their doors, with nothing sent, is said in
    /// their results, and the line of what went wrong is left as an earlier operation left it: a disk no longer
    /// offered, for a reservation and for a move, each by what the sheet has left to offer; a mode the tables do
    /// not know, for a reservation, which asks the recorder nothing, and for a change, whose read before it went
    /// through and cleared the line, the sentence not put there; and a change while the recorder is known to be
    /// away, that the app is not connected.
    func testWhatADoorTurnsAwayIsSaidInTheResultAndTheLineIsLeft() async throws {
        let (_, recorder, model) = try await connectedWithTheDiskGone()
        let program = try await programmesNotReserved(model, 1)[0]
        let onTheInternalDisk = try XCTUnwrap(model.reservations.first {
            !$0.recording && $0.end > Date() && $0.destination == RecorderDisk.internalID
        })
        let before = await recorder.asked
        leaveALine(on: model)

        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone(Self.slotGone))
        XCTAssertEqual(model.problem, lineLeft, "a reservation to a disk no longer offered wrote the line")
        expectEqual(await model.change(onTheInternalDisk, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone("USBHDDはいま使えません。録画先はHDDのままです。"))
        XCTAssertEqual(model.problem, lineLeft, "a move to a disk no longer offered wrote the line")
        expectEqual(await model.reserve(program, on: .recorder, quality: "知らない画質", repeating: "none"),
                    .notDone(Said.notInTheTables))
        XCTAssertEqual(model.problem, lineLeft, "a reservation in a mode nobody knows wrote the line")
        expectEqual(await recorder.asked, before, "a reservation or a move turned away at its door asked the recorder")

        let count = await recorder.heard.count
        expectEqual(await model.change(onTheInternalDisk, quality: "知らない画質", repeating: "none"),
                    .notDone(Said.notInTheTables))
        expectEqual(await recorder.heard(since: count), ["X_GetRecordScheduleList"])
        XCTAssertNil(model.problem, "a change in a mode nobody knows wrote the line")

        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.offline)
        leaveALine(on: model)
        let heard = await recorder.asked
        expectEqual(await model.change(onTheInternalDisk, quality: "ER", repeating: "none"),
                    .notDone(Said.notConnected))
        XCTAssertEqual(model.problem, lineLeft, "a change while the recorder is away wrote the line")
        expectEqual(await recorder.asked, heard, "a recorder known to be away was asked")
        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_UpdateRecordSchedule", since: before), 0)
        XCTAssertTrue(model.pending.isEmpty, "a reservation turned away at its door was kept to be sent")
    }

    /// What a picker shows of the disk the reader picked: that disk while it is offered, and the internal disk
    /// once it has been let go of, as when nothing was picked.
    func testAPickerShowsThePickedDiskOnlyWhileItIsOffered() async throws {
        let (_, _, model) = try await connected(times: 1, readAgainAfter: .milliseconds(50))
        XCTAssertEqual(model.diskOffered("USBHDD"), "USBHDD", "a disk offered was not shown")
        XCTAssertEqual(model.diskOffered("HDD"), "HDD")
        XCTAssertEqual(model.diskOffered(nil), "HDD", "nothing picked")

        // The demo's answer from here on, which is none, twice.
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        XCTAssertEqual(model.diskOffered("USBHDD"), "HDD", "a disk let go of was still shown")
        XCTAssertEqual(model.diskOffered(nil), "HDD", "nothing picked, the disk let go of")
    }

    /// A move to a disk let go of is refused, and said by what the reservation's sheet has left to offer. One on
    /// the internal disk is offered no other disk once the USB disk has gone, and is told that it stays where it
    /// is rather than asked for a choice its sheet does not show. One left on the gone disk still has the
    /// internal disk to go to, and is asked for another. Nothing is sent for either.
    func testAMoveRefusedIsSaidByWhatTheSheetHasLeftToOffer() async throws {
        let (_, recorder, model) = try await connected(times: 1, readAgainAfter: .milliseconds(50))
        let programs = try await programmesNotReserved(model, 2)
        expectTrue(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        // The demo's answer from here on, which is none, twice.
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        let onTheInternalDisk = try XCTUnwrap(model.reservation(for: programs[0]))
        let onTheSlot = try XCTUnwrap(model.reservation(for: programs[1]))
        XCTAssertEqual(model.diskChoices(for: onTheInternalDisk), [], "the internal disk's sheet offers a disk")
        let before = await recorder.asked

        expectFalse(await changeOnTheRecorder(model, onTheInternalDisk, quality: "DR", repeating: "none",
                                              disk: "USBHDD"),
                    "a move to a disk no longer offered was made")
        XCTAssertEqual(whyNotJustNow(model), "USBHDDはいま使えません。録画先はHDDのままです。")
        expectFalse(await changeOnTheRecorder(model, onTheSlot, quality: "DR", repeating: "none", disk: "USBHDD"),
                    "a move to a disk no longer offered was made")
        XCTAssertEqual(whyNotJustNow(model), Self.slotGone, "a reservation with the internal disk left to it")

        expectEqual(await recorder.asked("X_UpdateRecordSchedule", since: before), 0)
        XCTAssertEqual(model.reservation(for: programs[0])?.destination, "HDD")
        XCTAssertEqual(model.reservation(for: programs[1])?.destination, "USBHDD")
    }

    /// A reservation to the USB disk made while the recorder is away is kept with its disk, named after it while
    /// it waits, and sent with it once the recorder answers.
    func testAReservationKeptWhileAwayKeepsItsDiskAndIsSentWithIt() async throws {
        let (bench, recorder, model) = try await connected()
        let program = try await programmesNotReserved(model, 1)[0]
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.offline)

        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        let waiting = try XCTUnwrap(model.pending(for: program, on: .recorder))
        XCTAssertEqual(waiting.request.destination, "USBHDD")
        XCTAssertEqual(model.diskShown(waiting), "録画用ディスク")
        expectEqual(try await GuideStore(path: bench.guidePath).pendingReservations().map(\.request.destination),
                    ["USBHDD"])

        await reconnect(model)
        XCTAssertTrue(model.pending.isEmpty, "what waited was not sent")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD")
    }

    /// A change sends a disk only when the reader moved the reservation: moved, it goes there; not moved, it
    /// stays on the disk the recorder holds it on, whatever disk the sheet was opened on. A reservation left on
    /// the slot once the disk has gone can still be moved to the internal disk.
    func testAChangeMovesTheDiskOnlyWhenAsked() async throws {
        let (_, _, model) = try await connected(times: 1, readAgainAfter: .milliseconds(50))
        let program = try await programmesNotReserved(model, 1)[0]
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        let openedOn = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(openedOn.destination, "HDD")

        expectTrue(await changeOnTheRecorder(model, openedOn, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD", "the move was not sent")

        expectTrue(await changeOnTheRecorder(model, openedOn, quality: "SR", repeating: "none"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.qualityName, "SR")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD",
                       "the disk the sheet was opened on was sent in place of the one the recorder holds")

        // The demo's answer from here on, which is none, twice.
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        let onTheSlot = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(model.diskChoices(for: onTheSlot).map(\.destination), ["HDD", "USBHDD"])
        expectTrue(await changeOnTheRecorder(model, onTheSlot, quality: "SR", repeating: "none", disk: "HDD"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "HDD")
    }

    /// A move the recorder answers as made that the list read after it does not show -- a recorder a moment behind
    /// itself, its list still with the reservation on the disk it had -- is said not to show there, as a change of
    /// mode is, and the list on screen is the one read.
    func testAMoveTheListAfterItDoesNotShowIsSaidSo() async throws {
        let (_, recorder, model) = try await connected()
        let program = try await programmesNotReserved(model, 1)[0]
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        let made = try XCTUnwrap(model.reservation(for: program))

        await recorder.beAMomentBehind()
        expectEqual(await model.change(made, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone(Said.changeNotReflected))
        XCTAssertEqual(model.reservation(for: program)?.destination, "HDD",
                       "the list on screen is not the one read after the move")
    }

    /// A television's row is offered no disk and named after none, with a USB disk known: not as listed, carrying
    /// no disk, nor with the slot's id.
    func testATelevisionsRowIsNeverNamed() async throws {
        let (_, _, model) = try await connected()
        var row = try XCTUnwrap(model.reservations.first)
        row.device = .tv
        for destination in ["", "USBHDD"] {
            row.destination = destination
            XCTAssertNil(model.diskShown(row), "a television's row with \(destination)")
            XCTAssertEqual(model.diskChoices(for: row), [], "a television's row with \(destination)")
        }
    }

    /// A reservation on the television reads no disk of the recorder's, whatever disk it is handed: with the USB
    /// disk let go of, one asked for with the slot is not refused for the slot, and is the television's.
    func testATelevisionsReservationIsNotRefusedForTheRecordersDisk() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        bench.slotReadAgainAfter = .milliseconds(50)
        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(USBDiskTests.slot()), times: 1)
        let television = DemoTV()
        let model = bench.model(recorder: recorder, television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk)
        // The demo's answer from here on, which is none, twice.
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        let program = try await programmesNotReserved(model, 1)[0]
        await television.receives([DemoTV.Station(scheme: program.broadcasting == "bs" ? "isdbbs" : "isdbt",
                                                  serviceID: program.serviceID, name: program.serviceName)])

        let came = await model.reserve(program, on: .tv, quality: "DR", repeating: "none", disk: "USBHDD")

        XCTAssertNotEqual(came, .notDone(Self.slotGone), "the television's reservation was refused for the slot")
        XCTAssertEqual(came, .made(saying: nil))
        expectEqual(await television.schedules.map(\.eventId), [program.eventID])
        XCTAssertEqual(model.reservations(for: program).map(\.device), [.tv])

        // A change of it is the television's too, whatever disk comes with it.
        let made = try XCTUnwrap(model.reservations(for: program).first)
        let altered = await model.change(made, quality: "DR", repeating: "none", disk: "USBHDD")
        if case .notDone(let why) = altered {
            XCTAssertFalse(why.contains("いま使えません"),
                           "a change of the television's reservation was refused for the slot: \(why)")
        }
        XCTAssertEqual(altered, .done(saying: nil))
    }

    /// A condition made to the USB disk is made there, is read back with that disk, and names it on its row.
    func testAConditionToTheUSBDiskIsMadeThereAndNamed() async throws {
        let (_, recorder, model) = try await connected()

        expectTrue(await addACondition(model, Self.condition(to: "USBHDD")), model.problem ?? "no reason given")

        expectEqual(await recorder.elements(of: "X_CreatePrefRecSetting"),
                    XsrsElements.recorderRule(Self.condition(to: "USBHDD")))
        let made = try XCTUnwrap(model.recorderRules.first { $0.keywords == ["ためしの言葉"] })
        XCTAssertEqual(made.destination, "USBHDD")
        XCTAssertEqual(model.diskShown(made), "録画用ディスク")
    }

    /// The recorder turning down a reservation to the USB disk, or a move to it, is said as the disk and what to
    /// do, and nothing is left looking made or kept to be sent. A reservation to the internal disk turned down is
    /// kept, waiting with the recorder's words as its reason, as any refusal of a reservation is; a change's is
    /// said as it always was.
    func testARefusalOfTheUSBDiskSaysWhichDiskAndWhatToDo() async throws {
        let (_, recorder, model) = try await connected()
        let programs = try await programmesNotReserved(model, 2)
        let refused = "レコーダーが録画用ディスクへの予約を受け付けませんでした。別の録画先を選んでください"

        await recorder.answer("X_CreateRecordSchedule", with: .fault(402))
        expectFalse(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none", disk: "USBHDD"))
        XCTAssertEqual(model.problem, refused + " (402: X_CreateRecordSchedule)")
        XCTAssertNil(model.reservation(for: programs[0]), "a reservation turned down was shown as made")
        XCTAssertTrue(model.pending.isEmpty, "a reservation turned down was kept to be sent")
        await recorder.answer("X_CreateRecordSchedule", with: .fault(402))
        expectTrue(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none"))
        XCTAssertEqual(keptJustNow(model)?.problem, "レコーダーがこの要求を受け付けませんでした (402: X_CreateRecordSchedule)")

        expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        let made = try XCTUnwrap(model.reservation(for: programs[1]))
        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectFalse(await changeOnTheRecorder(model, made, quality: "DR", repeating: "none", disk: "USBHDD"))
        XCTAssertEqual(model.problem, refused + " (402: X_UpdateRecordSchedule)")
        XCTAssertEqual(model.reservation(for: programs[1])?.destination, "HDD")
        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectFalse(await changeOnTheRecorder(model, made, quality: "ER", repeating: "none"))
        XCTAssertEqual(model.problem, "レコーダーがこの要求を受け付けませんでした (402: X_UpdateRecordSchedule)")
    }

    /// A change of a reservation already on the USB disk, which the reader did not move, turned down by the
    /// recorder: said as the recorder says any request it turns down, and not as the disk's refusal. The disk
    /// went out as the recorder holds it, which the reader did not pick here; the disk's sentence asks for another
    /// destination, about a choice nobody made.
    ///
    /// As it is today, and meant.
    func testAChangeTurnedDownForAReservationOnTheUSBDiskThatStaysThereIsSaidPlainly() async throws {
        let (_, recorder, model) = try await connected()
        let program = try await programmesNotReserved(model, 1)[0]
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        let onTheSlot = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(onTheSlot.destination, "USBHDD")
        let before = await recorder.asked

        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectEqual(await model.change(onTheSlot, quality: "ER", repeating: "none"),
                    .notDone(Said.fault(402, "X_UpdateRecordSchedule")),
                    "a change that leaves the disk as it was is said as the disk's refusal")

        XCTAssertEqual(model.problem, Said.fault(402, "X_UpdateRecordSchedule"))
        expectEqual(await recorder.asked("X_UpdateRecordSchedule", since: before), 1)
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD")
        XCTAssertEqual(model.reservation(for: program)?.qualityName, "DR")
    }

    /// What the slot comes to decides a change and a clash check that go to the USB disk as it decides a
    /// reservation, each asked while the disk is kept through an answer of none -- after a connect, here, which
    /// reads none. A row each:
    ///
    /// - the slot answering the disk on its second read: the change is sent right after that read, which comes
    ///   after the list read before it, and so is the clash check, which reads nothing before;
    /// - the recorder falling silent while the slot is read: nothing is sent, and the recorder is lost under
    ///   the read's sentence, which is what the change and the clash check say;
    /// - whoever asked giving up while the slot is read: nothing is sent, the reservation is not kept, and the
    ///   change and the reservation say that the disk was not made sure of, in their results alone -- the line
    ///   left while the read was out is the line afterwards;
    /// - the slot answering the disk as not mounted: the change is not sent, the disk is taken as it answered,
    ///   and the change is said as for a disk that cannot be had, in its result, the line left clear by its read.
    ///
    /// As it is today. A change waits for the slot only once its list has been read, which is to stay.
    func testWhatTheSlotCameToDecidesAChangeAndAClashCheckToo() async throws {
        let (bench, recorder, model) = try await connected(times: 1)
        addTeardownBlock { await recorder.letGo() }
        let programs = try await programmesNotReserved(model, 2)
        expectTrue(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        let onTheSlot = try XCTUnwrap(model.reservation(for: programs[0]))
        let program = programs[1]
        let (list, slot, update, clashes) = ("X_GetRecordScheduleList", "X_GetMediaInfo", "X_UpdateRecordSchedule",
                                            "X_GetConflictList")
        @MainActor func change() async -> Altered {
            await model.change(onTheSlot, quality: "ER", repeating: "none")
        }
        @MainActor func clashCheck() async -> [Reservation]? {
            await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        // The disk kept through an answer of none, which the demo gives from here on: what the recorder had heard
        // by then.
        @MainActor func keptThroughNone() async -> Int {
            await reconnect(model)
            XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the disk was meant to be kept through an answer of none")
            return await recorder.heard.count
        }
        // Asks `something` with the slot's read held, and gives it up while the read is out: a line left, the
        // task cancelled, the read let go. What it came to, and what the recorder heard.
        @MainActor func givenUp<T: Sendable>(_ something: @escaping @MainActor () async -> T) async throws
            -> (came: T, heard: [String]) {
            let count = await keptThroughNone()
            await recorder.hold(only: slot)
            let asking = Task { await something() }
            try await until("the slot was never read") { await recorder.heard(since: count).contains(slot) }
            leaveALine(on: model)
            asking.cancel()
            await recorder.letGo()
            return (await asking.value, await recorder.heard(since: count))
        }

        // The change, the slot answering on its second read.
        var count = await keptThroughNone()
        await recorder.answer(slot, with: .result(USBDiskTests.slot()), times: 1, after: 1)
        expectEqual(await change(), .done(saying: nil), model.problem ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [list, slot, slot, update, list],
                    "the change was not sent right after the read that answered, or the slot was read before the list")
        XCTAssertEqual(model.reservation(for: programs[0])?.qualityName, "ER")

        // The change, the recorder silent while the slot is read.
        count = await keptThroughNone()
        await recorder.goQuiet(on: slot)
        expectEqual(await change(), .notDone(Said.noAnswer), "a change met by silence at the slot is said otherwise")
        expectEqual(await recorder.heard(since: count), [list, slot])
        XCTAssertEqual(model.problem, Said.noAnswer)
        XCTAssertTrue(model.gaveUp, "silence at the slot did not lose the recorder")

        // The change, given up while the slot is read. Its own read cleared the line before it.
        let changed = try await givenUp { await change() }
        XCTAssertEqual(changed.came, .notDone(Said.slotWaitGivenUp), "a change given up did not say so")
        XCTAssertEqual(changed.heard, [list, slot], "a change given up was sent")
        XCTAssertEqual(model.problem, lineLeft, "a change given up wrote on the line")
        XCTAssertFalse(model.gaveUp)

        // The clash check, the slot answering on its second read.
        count = await keptThroughNone()
        await recorder.answer(slot, with: .result(USBDiskTests.slot()), times: 1, after: 1)
        expectEqual(await clashCheck(), [], model.problem ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [slot, slot, clashes],
                    "the clash check was not asked right after the read that answered")

        // The clash check, the recorder silent while the slot is read.
        count = await keptThroughNone()
        await recorder.goQuiet(on: slot)
        expectNil(await clashCheck())
        expectEqual(await recorder.heard(since: count), [slot])
        XCTAssertEqual(model.problem, Said.noAnswer, "a clash check met by silence at the slot is said otherwise")
        XCTAssertTrue(model.gaveUp, "silence at the slot did not lose the recorder")

        // The clash check, given up while the slot is read.
        let checked = try await givenUp { await clashCheck() }
        XCTAssertNil(checked.came)
        XCTAssertEqual(checked.heard, [slot], "a clash check given up was asked")
        XCTAssertEqual(model.problem, lineLeft, "a clash check given up wrote on the line")
        XCTAssertFalse(model.gaveUp)

        // A reservation, given up while the slot is read.
        let reserved = try await givenUp {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        XCTAssertEqual(reserved.came, .notDone(Said.slotWaitGivenUp), "a reservation given up was kept, or not said")
        XCTAssertEqual(reserved.heard, [slot], "a reservation given up was sent")
        XCTAssertEqual(model.problem, lineLeft, "a reservation given up wrote on the line")
        XCTAssertTrue(model.pending.isEmpty, "a reservation given up was kept to be sent")
        expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty,
                   "a reservation given up was kept on the phone")
        XCTAssertNil(model.reservation(for: program))

        // The change, the slot answering the disk as not mounted. Last: the disk is taken as it answered.
        count = await keptThroughNone()
        await recorder.answer(slot, with: .result(USBDiskTests.slot(mount: "0")), times: 1)
        expectEqual(await change(), .notDone(Self.diskNotHad))
        expectEqual(await recorder.heard(since: count), [list, slot], "a change to a disk not mounted was sent")
        XCTAssertNil(model.problem, "the read before the change did not clear the line, or it says the result")
        XCTAssertEqual(model.usbDisk?.mounted, false, "the disk was not taken as it answered")
        XCTAssertTrue(model.diskCannotBeHad("USBHDD"))
        XCTAssertEqual(model.reservation(for: programs[0])?.qualityName, "ER")
    }

    /// A disk no longer offered is refused at the door before anything else is looked at, the recorder known to
    /// be away included: with the USB disk let go of and the recorder silent to the check, a reservation to the
    /// disk is not kept to be sent, and a move to it is not said to be for want of a connection, each said by the
    /// disk and what the sheet has left. Nothing is asked of the recorder.
    ///
    /// As it is today, and meant: a reservation kept here would be sent to a disk the reader can no longer have.
    func testADiskNoLongerOfferedIsRefusedBeforeTheRecorderIsKnownToBeAway() async throws {
        let (bench, recorder, model) = try await connectedWithTheDiskGone()
        let program = try await programmesNotReserved(model, 1)[0]
        let onTheInternalDisk = try XCTUnwrap(model.reservations.first {
            !$0.recording && $0.end > Date() && $0.destination == RecorderDisk.internalID
        })
        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.offline, "the recorder was meant to be known to be away")
        let before = await recorder.asked

        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone(Self.slotGone), "a reservation to a disk no longer offered was kept to be sent")
        XCTAssertTrue(model.pending.isEmpty, "a reservation to a disk no longer offered waits")
        expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty,
                   "a reservation to a disk no longer offered was kept on the phone")
        expectEqual(await model.change(onTheInternalDisk, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone("USBHDDはいま使えません。録画先はHDDのままです。"),
                    "a move to a disk no longer offered was said to be for want of a connection")
        expectEqual(await recorder.asked, before, "a recorder known to be away was asked")
    }

    /// A disk the slot answered none for is forgotten by the next request that can name a disk, whatever disk
    /// that names: a clash check, a reservation, a change and a keyword condition, each to the internal disk and
    /// each going through, leave the USB disk to be had again -- a sheet goes back to offering it.
    ///
    /// As it is today, and meant.
    func testTheNextRequestThatNamesADiskForgetsTheDiskNotHad() async throws {
        let (_, _, model) = try await connected(times: 1)
        let programs = try await programmesNotReserved(model, 2)
        expectTrue(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        let made = try XCTUnwrap(model.reservation(for: programs[0]))
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let requests: [(what: String, ask: @MainActor () async -> Bool)] = [
            ("a clash check", { await model.conflicts(for: programs[1], quality: "DR", repeating: "none") != nil }),
            ("a reservation", { await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none") }),
            ("a change", { await changeOnTheRecorder(model, made, quality: "ER", repeating: "none") }),
            ("a keyword condition", { await addACondition(model, Self.condition(to: RecorderDisk.internalID)) }),
        ]

        for (what, ask) in requests {
            // The slot answering none throughout, to a clash check for the USB disk.
            _ = await model.conflicts(for: programs[1], quality: "DR", repeating: "none", disk: "USBHDD")
            XCTAssertTrue(model.diskCannotBeHad("USBHDD"), "the slot's none was not put down, before \(what)")

            expectTrue(await ask(), "\(what) did not go through: \(model.problem ?? "no reason given")")
            XCTAssertFalse(model.diskCannotBeHad("USBHDD"), "\(what) left the USB disk not to be had")
        }
    }
}
