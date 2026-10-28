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
    private static let slotGone = "USBHDD はいま使えません。別の録画先を選んでください。"

    /// A keyword condition with a word of the test's own, to `destination`.
    private static func condition(to destination: String) -> RecorderRuleRequest {
        RecorderRuleRequest(keywords: ["ためしの言葉"], qualityCode: 240, destination: destination)
    }

    /// A model started and connected to a recorder whose slot answers `slot` the first `times` it is asked, and
    /// as the demo's does after that, which is none. `readAgainAfter` is how long an attach that finds none
    /// while a disk is known waits before reading the slot again. The slot is waited for, before something that
    /// names it is sent while the disk is kept, as the app waits for it in seconds, in milliseconds: six reads.
    /// With `sent`, each client the model makes reaches the recorder by a way of its own, which puts down there
    /// what it sent (`ThroughClient`). `connectFor` is how long that wait waits for a connect under way, the app's
    /// unless given, and `every` how often it reads the slot again and looks again for a connect or a check, five
    /// milliseconds unless given; `wakeable` saves the MAC the recorder's UDN carries, which the model sends
    /// nothing to.
    private func connected(answering slot: String = USBDiskTests.slot(), times: Int = 1000,
                           readAgainAfter: Duration = RecorderDriver.slotReadAgainAfter,
                           numbering sent: SentByClient? = nil, wakeable: Bool = false,
                           every interval: Duration = .milliseconds(5),
                           connectFor: Duration = SlotSettling.aConnect) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel) {
        let bench = try aBench()
        try await bench.cacheAGuide()
        if wakeable { bench.keep(mac: WhichRecorderTests.firstsMAC) }
        bench.slotReadAgainAfter = readAgainAfter
        bench.slotSettling = SlotSettling(every: interval, for: .milliseconds(25), connectFor: connectFor)
        let recorder = NamedRecorder(1)
        await recorder.answer("X_GetMediaInfo", with: .result(slot), times: times)
        let model = if let sent {
            bench.model(clientByClient: { ThroughClient(client: $0, recorder: recorder, sent: sent) })
        } else {
            bench.model(recorders: [Bench.host: recorder])
        }
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
                   model.problem(for: .recorder) ?? "no reason given")
        let request = try XCTUnwrap(ReservationRequest(program: programs[0], quality: "DR", repeating: "none"))
        expectEqual(await recorder.elements(of: "X_CreateRecordSchedule"), XsrsElements.create(request),
                    "the internal disk's reservation is not sent as it was")
        let made = try XCTUnwrap(model.reservation(for: programs[0]))
        XCTAssertEqual(made.destination, "HDD")
        expectTrue(await changeOnTheRecorder(model, made, quality: "ER", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
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
                   model.problem(for: .recorder) ?? "no reason given")

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
                   model.problem(for: .recorder) ?? "no reason given")
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
                   model.problem(for: .recorder) ?? "no reason given")

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
                   model.problem(for: .recorder) ?? "no reason given")
        expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem(for: .recorder) ?? "no reason given")
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let onTheInternalDisk = try XCTUnwrap(model.reservation(for: programs[0]))
        let onTheSlot = try XCTUnwrap(model.reservation(for: programs[1]))
        let before = await recorder.asked

        leaveALine(on: model)
        expectFalse(await changeOnTheRecorder(model, onTheInternalDisk, quality: "DR", repeating: "none",
                                              disk: "USBHDD"),
                    "a move to a disk the slot did not answer was sent")
        XCTAssertEqual(whyNotJustNow(model), "録画用ディスクはいま使えません。録画先は HDD のままです。")
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
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the condition wrote over the line")
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
            XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
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
            XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the slot's silence was not said")
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
            XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a condition given up wrote on the line")
            XCTAssertFalse(model.gaveUp)
            XCTAssertNil(model.busy)
            expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
        }
    }

    /// A clash check for a kept disk, waiting for the slot, while a connect to the same recorder is made beside
    /// it whose attach reads the slot on a client of its own and finds none either, the disk still kept and
    /// waited for: the wait goes on on the connect's client, not on the one it began with, and what that one
    /// met is nothing. The slot answering the disk there, the disk is had, as the slot's answer on the client the
    /// link holds is, and the clashes are asked.
    func testAClashChecksWaitForTheSlotGoesOnOnTheConnectsClient() async throws {
        let (bench, recorder, model, checking, program, sent) =
            try await aClashCheckWaitingForTheSlotBesideAConnect(finding: false)
        // The held read answers none as it is let go; the next read of the slot answers the disk.
        await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()), after: 1)
        leaveALine(on: model)
        let afterTheConnect = await recorder.asked
        let sentBefore = await sent.sent.count
        await recorder.letGo()
        let clashes = try await within(10, "the clash check never ended") { await checking.value }

        XCTAssertNil(model.diskNotHad, "the disk was taken as not had with the connect's client still to be asked")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft,
                       "something was said with the connect's client still to be asked")
        expectEqual(await recorder.asked(Ask.slot, since: afterTheConnect), 1,
                    "the slot was not read on the connect's client once the held read was back")
        expectEqual(await sent.clients(sending: Ask.slot, since: sentBefore), [bench.clientsMade],
                    "the slot was read again on the client the connect replaced")
        expectEqual(await recorder.asked("X_GetConflictList", since: afterTheConnect), 1,
                    "the clashes were not asked once the slot had answered the disk")
        XCTAssertNotNil(clashes, "a clash check whose slot answered the disk handed back nothing")
        XCTAssertTrue(model.connected)

        let again = await recorder.asked
        _ = await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
        expectEqual(await recorder.asked(Ask.slot, since: again), 0,
                    "the disk the slot answered on the connect's client was not kept")
    }

    /// A clash check for a kept disk, waiting for the slot, while a connect finds another recorder at the address,
    /// whose attach finds no USB disk: what the wait came to is about the recorder let go of, and nothing of it
    /// is put down in the session, which is the newcomer's, or said on its line, and no clashes are asked.
    func testAClashChecksWaitForTheSlotAcrossALetGoPutsNothingDown() async throws {
        let (_, recorder, model, checking, _, _) =
            try await aClashCheckWaitingForTheSlotBesideAConnect(becoming: 2, finding: false)
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), "the connect was meant to take up another recorder")
        leaveALine(on: model)
        let afterTheConnect = await recorder.asked
        await recorder.letGo()
        let clashes = try await within(10, "the clash check never ended") { await checking.value }

        XCTAssertNil(model.diskNotHad, "the newcomer was told a disk of the recorder let go of cannot be had")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "something was said on the newcomer's line")
        expectNil(clashes, "a clash check across a let-go handed back an answer")
        expectEqual(await recorder.asked("X_GetConflictList", since: afterTheConnect), 0,
                    "the last recorder's clash check was asked across the let-go")
    }

    /// A clash check for a kept disk, waiting for the slot, while a connect to the same recorder is made beside
    /// it -- a return to the app, 再接続 -- whose attach reads the slot itself on a client of its own and finds
    /// the disk: the wait ends at its next read, and the client it began with is asked nothing more. What that
    /// client then met is not the recorder's: the slot's read held through the connect and let go answering
    /// none, nothing more is read; let go into silence, the recorder is not lost and nothing is said. Either way
    /// the disk the connect's attach answered is what the slot says, and is not said to be unavailable.
    func testAClashChecksWaitForTheSlotEndsOnceAConnectHasAClientOfItsOwn() async throws {
        for silent in [false, true] {
            let how = silent ? "the held read met silence" : "the held read answered none"
            let (_, recorder, model, checking, _, _) = try await aClashCheckWaitingForTheSlotBesideAConnect()
            if silent { await recorder.answer(Ask.slot, with: .silence) }
            leaveALine(on: model)
            let afterTheConnect = await recorder.asked
            await recorder.letGo()
            _ = try await within(10, "the clash check never ended, \(how)") { await checking.value }

            expectEqual(await recorder.asked(Ask.slot, since: afterTheConnect), 0,
                        "the slot was read again on the client the connect replaced, \(how)")
            XCTAssertTrue(model.connected, "what the replaced client met lost the recorder, \(how)")
            XCTAssertFalse(model.gaveUp, how)
            XCTAssertNotEqual(model.problem(for: .recorder), Said.noAnswer, "the replaced client's silence was said")
            XCTAssertNil(model.diskNotHad, "the disk the connect's attach answered was taken as not had, \(how)")
        }
    }

    /// A clash check that waited for the slot beside a connect is asked on the client the link holds once the
    /// wait is over -- the connect's, whose attach has answered the disk -- and not on the one it began with:
    /// silence on it is the recorder's, which is lost and said. And with another recorder described by that
    /// connect, nothing is asked at all: the programme was the last recorder's to be checked against.
    func testAClashCheckAfterTheSlotsWaitIsAskedOnTheClientTheLinkHoldsAndNotAcrossALetGo() async throws {
        let (_, recorder, model, checking, _, _) = try await aClashCheckWaitingForTheSlotBesideAConnect()
        await recorder.goQuiet(on: "X_GetConflictList")
        await recorder.letGo()
        let met = try await within(10, "the clash check that met silence never ended") { await checking.value }
        expectNil(met, "a clash check that met silence handed back an answer")
        XCTAssertTrue(model.gaveUp, "silence on the client the link holds was not taken for the recorder's")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "silence on the clash check was not said")

        let (_, another, letGo, asking, _, _) = try await aClashCheckWaitingForTheSlotBesideAConnect(becoming: 2)
        XCTAssertEqual(letGo.info?.udn, NamedRecorder.udn(2), "the connect was meant to take up another recorder")
        leaveALine(on: letGo)
        let afterTheConnect = await another.asked
        await another.letGo()
        let across = try await within(10, "the clash check across a let-go never ended") { await asking.value }
        expectNil(across, "a clash check across a let-go handed back an answer")
        expectEqual(await another.asked("X_GetConflictList", since: afterTheConnect), 0,
                    "the last recorder's clash check was asked across the let-go")
        XCTAssertEqual(letGo.problem(for: .recorder), lineLeft, "something was said on the newcomer's line")
    }

    /// A clash check for the internal disk -- with nothing to wait for on the slot's account -- asked while a
    /// connect to the same recorder is under way beside it, held at its probe, which makes a client of its own
    /// that has yet to hear which recorder answers it: nothing is asked on that client until the connect has
    /// attached the recorder there -- not while the probe is out, nor, with a MAC kept and the probe met by
    /// silence, while the recorder is woken, when a request to it meets silence as well -- and nobody gives the
    /// recorder up or says that it did not answer. Once the connect has attached it, the clashes are asked on its
    /// client, once.
    func testAClashCheckBesideAConnectIsAskedOnlyOnceTheConnectHasAttachedTheRecorder() async throws {
        for waking in [false, true] {
            let how = waking ? "the connect waking the recorder" : "the connect's probe answered"
            let (recorder, model, checking, connecting, scene) =
                try await aClashCheckBesideAConnectHeldAtItsProbe(wakeable: waking)
            if waking {
                // Silent to the probe; the waking's first ask, which the recorder answers, is held in its turn.
                await recorder.goQuiet(on: Ask.description)
                await recorder.letTheFirstGo(of: Ask.description)
                try await until("the recorder was never woken") {
                    await recorder.asked(Ask.description, since: scene.before) == 2
                }
            }
            expectEqual(await recorder.asked("X_GetConflictList", since: scene.before), 0,
                        "the clashes were asked before the connect had attached the recorder, \(how)")
            XCTAssertFalse(model.gaveUp, "the recorder was given up on before the connect had attached it, \(how)")
            XCTAssertNotEqual(model.problem(for: .recorder), Said.noAnswer, "no answer was said mid-connect, \(how)")

            // Up from here on: the clash check is answered as the demo answers it.
            await recorder.answer("X_GetConflictList", with: .result(""))
            await recorder.letGo()
            let clashes = try await within(10, "the clash check never ended, \(how)") { await checking.value }
            try await within(10, "the connect never ended, \(how)") { await connecting.value }

            let asked = await scene.sent.sent.dropFirst(scene.sentBefore).filter { $0.client == scene.connects }
                .map(\.what)
            let clash = try XCTUnwrap(asked.firstIndex(of: "X_GetConflictList"),
                                      "the clashes were never asked on the connect's client, \(how): \(asked)")
            let freeSpace = try XCTUnwrap(asked.firstIndex(of: Ask.freeSpace), "the connect never attached: \(asked)")
            XCTAssertGreaterThan(clash, freeSpace,
                                 "the clashes were asked on the connect's client before its attach, \(how): \(asked)")
            expectEqual(await recorder.asked("X_GetConflictList", since: scene.before), 1, "the clashes were not asked once, \(how)")
            XCTAssertNotNil(clashes, "a clash check beside a connect that attached the recorder handed back nothing, \(how)")
            XCTAssertTrue(model.connected, how)
            XCTAssertFalse(model.gaveUp, "the recorder was given up on, \(how)")
            XCTAssertNotEqual(model.problem(for: .recorder), Said.noAnswer, "no answer was said, \(how)")
        }
    }

    /// The same clash check beside a connect that does not attach the recorder the sheet opened for: silent to its
    /// probe, with no MAC to wake it by; answered there by something that is not a recorder; or answered by
    /// another recorder, which lets the first go and is attached in its place. The connect has said why, or the
    /// line is the newcomer's: nothing is asked and nothing said, and the sheet is handed no clashes.
    func testAClashCheckBesideAConnectThatDoesNotAttachTheRecorderAsksAndSaysNothing() async throws {
        for end in ["silence", "something else", "another recorder"] {
            let how = "the connect answered by \(end)"
            let (recorder, model, checking, connecting, scene) = try await aClashCheckBesideAConnectHeldAtItsProbe()
            switch end {
            case "silence": await recorder.goQuiet(on: Ask.description)
            case "something else": await recorder.answer(Ask.description, with: .status(404))
            default: await recorder.become(2)
            }
            await recorder.letGo()
            let clashes = try await within(10, "the clash check never ended, \(how)") { await checking.value }
            try await within(10, "the connect never ended, \(how)") { await connecting.value }

            expectNil(clashes, "a clash check beside a connect that did not attach the recorder handed back an answer")
            expectEqual(await recorder.asked("X_GetConflictList", since: scene.before), 0, how)
            switch end {
            case "silence":
                XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the connect's line was not left, \(how)")
                XCTAssertTrue(model.gaveUp, how)
            case "something else":
                XCTAssertEqual(model.problem(for: .recorder), RecorderError.notARecorder(host: Bench.host).explanation,
                               "the connect's line was not left, \(how)")
                XCTAssertFalse(model.gaveUp, how)
            default:
                XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), "the connect was meant to take up another recorder")
                XCTAssertTrue(model.connected, how)
                XCTAssertNotEqual(model.problem(for: .recorder), Said.noAnswer, "something was said, \(how)")
            }
        }
    }

    /// A programme's sheet opened once a connect has left the recorder connected without attaching it on the
    /// connect's own client: the recorder answered that connect busy with somebody else, or something else
    /// answered at its address. No client the recorder was attached on is in hand: nothing is asked, nothing is
    /// said over the connect's line, and the sheet is handed no clashes. Until the next attach, and no longer:
    /// once the recorder answers again and a connect attaches it, the same sheet's clash check is asked once,
    /// on that connect's client, and hands back what the recorder answered, the line clear.
    func testAClashCheckAfterAConnectThatLeftTheRecorderUnattachedAsksNothingUntilTheNextAttach() async throws {
        for end in ["busy", "something else"] {
            let how = "the connect answered \(end)"
            let (_, recorder, model) = try await connected()
            let program = try await programmesNotReserved(model, 1)[0]
            if end == "busy" {
                await recorder.busyAtTheDoor()
            } else {
                await recorder.answer(Ask.description, with: .status(404), times: 1000)
            }
            try await within(10, "the connect never ended, \(how)") { await model.connect() }
            XCTAssertTrue(model.connected, "the connect was meant to leave the recorder connected, \(how)")
            let line = model.problem(for: .recorder)
            XCTAssertNotNil(line, "the connect was meant to say why it did not attach the recorder, \(how)")
            let before = await recorder.asked
            let clashes = try await within(10, "the clash check never ended, \(how)") {
                await model.conflicts(for: program, quality: "DR", repeating: "none", disk: RecorderDisk.internalID)
            }

            expectNil(clashes, "a clash check with no client the recorder was attached on handed back an answer")
            expectEqual(await recorder.asked("X_GetConflictList", since: before), 0, how)
            XCTAssertEqual(model.problem(for: .recorder), line, "something was said over the connect's line, \(how)")
            XCTAssertTrue(model.connected, how)

            // The recorder itself again at its address, and a connect that attaches it.
            if end == "busy" {
                await recorder.comeFree()
            } else {
                await recorder.stopAnswering(Ask.description)
            }
            try await within(10, "the next connect never ended, \(how)") { await model.connect() }
            XCTAssertNil(model.problem(for: .recorder), "the next connect was meant to attach the recorder, \(how)")
            let afterAttach = await recorder.asked
            let next = try await within(10, "the next clash check never ended, \(how)") {
                await model.conflicts(for: program, quality: "DR", repeating: "none", disk: RecorderDisk.internalID)
            }

            XCTAssertNotNil(next, "a clash check after the next attach handed back nothing, \(how)")
            expectEqual(await recorder.asked("X_GetConflictList", since: afterAttach), 1,
                        "the clash check after the next attach was not asked once, \(how)")
            XCTAssertNil(model.problem(for: .recorder), how)
            XCTAssertTrue(model.connected, how)
        }
    }

    /// A clash check for the internal disk asked while a connect is under way, held at its probe, which then
    /// attaches the recorder, and the check before another operation begins on the connect's client before the
    /// clash check looks again, its probe held: the clash check waits for that check too, as the slot's wait does.
    /// That check still out past the time the clash check waits for one, nothing is asked. Met by silence, with no
    /// MAC to wake the recorder by, it loses the recorder and says so: nothing is asked, and nothing more said.
    func testAClashCheckWaitingForAnotherCheckAsksNothingPastItsTimeOrOnceThatCheckHasLostTheRecorder()
        async throws {
        for past in [true, false] {
            let how = past ? "the other check out past the time" : "the other check met by silence"
            // Looking again every five seconds, so that the other check begins between two looks, seconds away
            // from either.
            let (_, recorder, model) = try await connected(every: .seconds(5),
                                                           connectFor: past ? .seconds(10) : SlotSettling.aConnect)
            addTeardownBlock { await recorder.letGo() }
            let program = try await programmesNotReserved(model, 1)[0]
            let before = await recorder.asked
            await recorder.hold(only: Ask.description)
            let connecting = Task { await model.connect() }
            try await until("the connect never asked who answers") {
                await recorder.asked(Ask.description, since: before) == 1
            }
            let checking = Task {
                await model.conflicts(for: program, quality: "DR", repeating: "none", disk: RecorderDisk.internalID)
            }
            // Long enough for the clash check to have looked once, and three seconds short of its next look.
            try await Task.sleep(for: .seconds(2))
            await recorder.letGo()
            try await within(10, "the connect never ended, \(how)") { await connecting.value }
            XCTAssertTrue(model.connected, "the connect was meant to attach the recorder, \(how)")
            let described = await recorder.asked(Ask.description, since: before)
            await recorder.holdTheNext(Ask.description)
            let makingSure = Task { await makeSure(model) }
            try await until("the other check never asked who answers") {
                await recorder.asked(Ask.description, since: before) == described + 1
            }
            if !past {
                await recorder.goQuiet(on: Ask.description)
                await recorder.letGo()
                let sure = try await within(10, "the other check never ended") { await makingSure.value }
                XCTAssertFalse(sure, "the other check was meant to meet silence")
            }
            let clashes = try await within(15, "the clash check never ended, \(how)") { await checking.value }

            expectNil(clashes, "a clash check handed back an answer, \(how)")
            expectEqual(await recorder.asked("X_GetConflictList", since: before), 0, how)
            if past {
                XCTAssertTrue(isMakingSure(model), "the other check was meant to be out still, \(how)")
                XCTAssertNotEqual(model.problem(for: .recorder), Said.noAnswer, "something was said, \(how)")
                await recorder.letGo()
                _ = try await within(10, "the other check never ended") { await makingSure.value }
            } else {
                XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the other check's line was not left")
                XCTAssertTrue(model.gaveUp)
            }
        }
    }

    /// A clash check for a kept disk asked while the check before another operation is out, its probe held, and
    /// so waiting for that check's answer, when the recorder is let go of -- as a check that hears another recorder
    /// at the address lets it go -- and connected to again, the same recorder answering, whose attach keeps the
    /// disk unanswered. The probe then answers: the recorder is there. The newcomer's slot answers none each time
    /// it is read, but the programme was to be checked against the recorder in play when the sheet opened, and that
    /// one was let go of: nothing is said over the newcomer's line, no clashes are asked, and the sheet is handed
    /// none.
    func testAClashCheckAcrossALetGoMadeWhileTheCheckBeforeItIsOutSaysNothing() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the disk was meant to be kept through an answer of none")
        let program = try await programmesNotReserved(model, 1)[0]
        // A disk put down as not had, which the clash check forgets as it begins: the sign that it has.
        _ = try await within(10, "the first clash check never ended") {
            await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        XCTAssertNotNil(model.diskNotHad, "the first clash check was meant to find the disk not had")
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.description)
        let makingSure = Task { await makeSure(model) }
        try await until("the other check never asked who answers") {
            await recorder.asked(Ask.description, since: before) == 1
        }
        XCTAssertTrue(isMakingSure(model), "the other check was meant to be out")
        let checking = Task {
            await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the clash check never began") { model.diskNotHad == nil }
        model.forgetTheRecorder()
        try await within(10, "the connect never ended") { await model.connect() }
        XCTAssertTrue(model.connected, model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the connect was meant to keep the disk unanswered")
        XCTAssertTrue(isMakingSure(model), "the other check was meant to be out still")
        leaveALine(on: model)
        let afterTheConnect = await recorder.asked
        await recorder.letGo()
        let sure = try await within(10, "the other check never ended") { await makingSure.value }
        let clashes = try await within(10, "the clash check never ended") { await checking.value }

        XCTAssertTrue(sure, "the other check's probe was meant to find the recorder there")
        expectNil(clashes, "a clash check across a let-go handed back an answer")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "something was said on the newcomer's line")
        expectEqual(await recorder.asked(Ask.slot, since: afterTheConnect), 6,
                    "the newcomer's slot was meant to be read, and answer none, the six times the wait reads it")
        expectEqual(await recorder.asked("X_GetConflictList", since: before), 0,
                    "the last recorder's clash check was asked across the let-go")
    }

    /// A model connected to a recorder whose slot answers the disk, with a connect to the same recorder made beside
    /// it, every ask of who answers held, which makes a client of its own; then a clash check for the internal
    /// disk, a programme no reservation holds, asked while that connect's probe is out. With `wakeable` a MAC is
    /// kept, for a connect silent to its probe to wake the recorder, and the recorder, asleep, is silent to the
    /// clash check until a test says otherwise. Handed back with the check and the connect still out, and where
    /// the scene stands; whatever is held is let go as the test ends.
    private func aClashCheckBesideAConnectHeldAtItsProbe(wakeable: Bool = false) async throws
        -> (recorder: NamedRecorder, model: AppModel, checking: Task<[Reservation]?, Never>,
            connecting: Task<Void, Never>, scene: BesideAConnect) {
        let sent = SentByClient()
        let (bench, recorder, model) = try await connected(numbering: sent, wakeable: wakeable)
        addTeardownBlock { await recorder.letGo() }
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.hold(only: Ask.description)
        let made = bench.clientsMade
        leaveALine(on: model)
        let connecting = Task { await model.connect() }
        try await until("the connect never asked who answers") {
            await recorder.asked(Ask.description, since: before) == 1
        }
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        if wakeable { await recorder.answer("X_GetConflictList", with: .silence) }
        let sentBefore = await sent.sent.count
        let checking = Task {
            await model.conflicts(for: program, quality: "DR", repeating: "none", disk: RecorderDisk.internalID)
        }
        // Long enough for the clash check to have been asked, had it gone at once.
        try await Task.sleep(for: .milliseconds(300))
        return (recorder, model, checking, connecting,
                BesideAConnect(before: before, sentBefore: sentBefore, sent: sent, connects: made + 1))
    }

    /// A model whose recorder's disk is kept through an answer of none, with a clash check for the disk waiting for
    /// the slot, the slot's next read held on the client in hand, and a connect made beside it and let end, whose
    /// own read of the slot answers the disk, or with `finding` false none, as the demo's does; with `becoming`,
    /// the recorder at the address is another one by then. Any programme of the guide serves: nothing turns on
    /// which. The check is handed back still out, with its programme and what each client sent; whatever is held
    /// is let go as the test ends.
    private func aClashCheckWaitingForTheSlotBesideAConnect(becoming last: Int? = nil,
                                                            finding: Bool = true) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel, checking: Task<[Reservation]?, Never>,
            program: GuideProgramRow, sent: SentByClient) {
        let sent = SentByClient()
        let (bench, recorder, model) = try await connected(times: 1, numbering: sent)
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the disk was meant to be kept through an answer of none")
        let found = await model.search("サンプル").hits.first?.program
        let program = try XCTUnwrap(found, "the cached guide had no programme")
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let checking = Task { await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD") }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        if finding { await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot())) }
        if let last { await recorder.become(last) }
        let made = bench.clientsMade
        await reconnect(model)
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        expectEqual(await recorder.asked(Ask.slot, since: before), 2, "the connect's attach did not read the slot")
        XCTAssertEqual(model.usbDisk, finding || last == nil ? USBDiskTests.disk : nil,
                       "the connect's attach was meant to answer the disk, or for a newcomer none")
        return (bench, recorder, model, checking, program, sent)
    }

    /// A clash check for a kept disk, waiting for the slot, while a connect to the same recorder is made beside it
    /// and held at its probe, which makes a client of its own that has yet to hear which recorder answers it: the
    /// wait reads nothing on that client until the connect has attached the recorder there -- not while the
    /// probe is out, nor, with a MAC kept and the probe met by silence, while the recorder is woken. The read the
    /// client the connect replaced had out answers none, which is not taken for the recorder's, and nobody gives
    /// the recorder up. Once the connect has attached it, the slot answering the disk, the disk is had and the
    /// clashes are asked.
    func testAClashChecksWaitForTheSlotReadsOnAConnectsClientOnlyOnceItHasAttachedTheRecorder() async throws {
        for waking in [false, true] {
            let how = waking ? "the connect waking the recorder" : "the connect's probe answered"
            let (_, recorder, model, checking, connecting, scene) =
                try await waitingForTheSlotBesideAConnectHeldAtItsProbe(wakeable: waking) { model, program in
                    await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
                }
            if waking {
                // Silent to the probe; the waking's first ask, which the recorder answers, is held in its turn.
                await recorder.answer(Ask.slot, with: .silence)
                await recorder.goQuiet(on: Ask.description)
                await recorder.letTheFirstGo(of: Ask.description)
                try await until("the recorder was never woken") {
                    await recorder.asked(Ask.description, since: scene.before) == 2
                }
                expectEqual(await scene.sent.clients(sending: Ask.slot, since: scene.sentBefore), [],
                            "the slot was read on the connect's client while it woke the recorder")
                XCTAssertFalse(model.gaveUp, "the recorder was given up on while the connect woke it")
            }
            // The slot answers the disk from here on.
            await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()), times: 1000)
            await recorder.letGo()
            let clashes = try await within(10, "the clash check never ended, \(how)") { await checking.value }
            try await within(10, "the connect never ended, \(how)") { await connecting.value }

            let asked = await scene.sent.sent.dropFirst(scene.sentBefore).filter { $0.client == scene.connects }
                .map(\.what)
            let slot = try XCTUnwrap(asked.firstIndex(of: Ask.slot), "the slot was never read again, \(how): \(asked)")
            let freeSpace = try XCTUnwrap(asked.firstIndex(of: Ask.freeSpace), "the connect never attached: \(asked)")
            XCTAssertGreaterThan(slot, freeSpace,
                                 "the slot was read on the connect's client before its attach, \(how): \(asked)")
            XCTAssertNotNil(clashes, "a clash check whose slot answered the disk handed back nothing, \(how)")
            expectEqual(await recorder.asked("X_GetConflictList", since: scene.before), 1,
                        "the clashes were not asked once, \(how)")
            XCTAssertTrue(model.connected, how)
            XCTAssertFalse(model.gaveUp, "the recorder was given up on, \(how)")
            XCTAssertNil(model.diskNotHad, "the disk was taken as not had, \(how)")
        }
    }

    /// The same wait, with the connect beside it not attaching the recorder: silent to its probe, with no MAC to
    /// wake it by, or answered there by something that is not a recorder. The connect has said why, and the wait
    /// ends with nothing read on the connect's client and nothing said over that line: the disk is not taken as
    /// not had, and no clashes are asked.
    func testAClashChecksWaitForTheSlotEndsUnsaidOnAConnectThatDoesNotAttachTheRecorder() async throws {
        for stranger in [false, true] {
            let how = stranger ? "something else answering the connect" : "the connect met by silence"
            let (_, recorder, model, checking, connecting, scene) =
                try await waitingForTheSlotBesideAConnectHeldAtItsProbe { model, program in
                    await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
                }
            if stranger {
                await recorder.answer(Ask.description, with: .status(404))
            } else {
                await recorder.goQuiet(on: Ask.description)
            }
            await recorder.letGo()
            let clashes = try await within(10, "the clash check never ended, \(how)") { await checking.value }
            try await within(10, "the connect never ended, \(how)") { await connecting.value }

            let line = stranger ? RecorderError.notARecorder(host: Bench.host).explanation : Said.noAnswer
            XCTAssertEqual(model.problem(for: .recorder), line, "the connect's line was not left as it said it, \(how)")
            expectNil(clashes, "a clash check beside a connect that did not attach the recorder handed back an answer")
            expectEqual(await scene.sent.clients(sending: Ask.slot, since: scene.sentBefore), [],
                        "the slot was read on a client the recorder was never attached on, \(how)")
            expectEqual(await recorder.asked("X_GetConflictList", since: scene.before), 0, how)
            XCTAssertNil(model.diskNotHad, "the disk was taken as not had, \(how)")
            XCTAssertEqual(model.gaveUp, !stranger, how)
        }
    }

    /// A reservation to a kept disk, waiting for the slot beside a connect that something else at the address
    /// answers: nothing was sent, and it is kept on the phone, as when the recorder is silent at that moment, the
    /// connect's line standing as it said it.
    func testAReservationWaitingForTheSlotBesideAConnectThatDoesNotAttachTheRecorderIsKept() async throws {
        let (_, recorder, model, reserving, connecting, scene) =
            try await waitingForTheSlotBesideAConnectHeldAtItsProbe { model, program in
                await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
            }
        await recorder.answer(Ask.description, with: .status(404))
        await recorder.letGo()
        let came = try await within(10, "the reservation never came back") { await reserving.value }
        try await within(10, "the connect never ended") { await connecting.value }

        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation beside a connect that did not attach the recorder was not kept: \(came)")
        }
        XCTAssertEqual(row.request.destination, "USBHDD")
        XCTAssertEqual(model.problem(for: .recorder), RecorderError.notARecorder(host: Bench.host).explanation,
                       "something was said over the connect's line")
        expectEqual(await recorder.asked(Ask.create, since: scene.before), 0)
        expectEqual(await scene.sent.clients(sending: Ask.slot, since: scene.sentBefore), [],
                    "the slot was read on a client the recorder was never attached on")
    }

    /// A reservation to a kept disk, waiting for the slot beside a connect held at its probe for longer than the
    /// wait waits for a connect: the wait gives up, nothing read on the connect's client and nothing sent, and
    /// the reservation is kept on the phone, as one pressed during the connect is kept at the door, the line left
    /// to the connect. Once the slot answers the disk, the connect's attach sends it, once.
    func testAReservationWhoseWaitForTheSlotGivesUpOnAConnectStillUnderWayPastItsTimeIsKept() async throws {
        let (_, recorder, model, reserving, connecting, scene) =
            try await waitingForTheSlotBesideAConnectHeldAtItsProbe(connectFor: .milliseconds(100)) { model, program in
                await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
            }
        let came = try await within(5, "the wait for the slot did not give up on the connect") {
            await reserving.value
        }

        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation whose wait gave up by itself was not kept: \(came)")
        }
        XCTAssertEqual(row.request.destination, "USBHDD")
        XCTAssertEqual(model.pending.map(\.id), [row.id], "the reservation kept is not what waits")
        XCTAssertTrue(isConnecting(model), "the connect was meant to be under way still")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "something was said over the connect's line")
        expectEqual(await recorder.asked(Ask.create, since: scene.before), 0, "sent while the connect was held")
        expectEqual(await scene.sent.clients(sending: Ask.slot, since: scene.sentBefore), [],
                    "the slot was read on the client of a connect still under way")

        // The slot answers the disk from here on, and the connect goes through.
        await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()), times: 1000)
        await recorder.letGo()
        try await within(10, "the connect never ended") { await connecting.value }
        expectEqual(await recorder.asked(Ask.create, since: scene.before), 1,
                    "the connect's attach did not send the reservation kept, or sent it twice")
        XCTAssertTrue(model.pending.isEmpty, "the reservation sent still waits")
    }

    /// A reservation to a kept disk whose wait for the slot has its last read out when a connect to the same
    /// recorder replaces the client it went on, the connect's own read of the slot answering none with the disk
    /// kept: the six reads are spent, the last of them on a client the link has left, so the slot was never heard
    /// to answer none to the last of them. The wait ends as given up, and not as a disk that cannot be had; the
    /// reservation is kept on the phone, nothing sent.
    func testAReservationWhoseWaitForTheSlotHasItsLastReadOvertakenByAConnectIsKept() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.hold(only: Ask.slot)
        let reserving = Task {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        for read in 1...5 {
            try await until("the slot's read \(read) never came") { await recorder.asked(Ask.slot, since: before) == read }
            await recorder.letTheFirstGo(of: Ask.slot)
        }
        try await until("the last read never came") { await recorder.asked(Ask.slot, since: before) == 6 }
        let connecting = Task { await model.connect() }
        try await until("the connect's attach never read the slot") {
            await recorder.asked(Ask.slot, since: before) == 7
        }
        await recorder.letGo(only: Ask.slot)
        let came = try await within(10, "the reservation never came back") { await reserving.value }
        try await within(10, "the connect never ended") { await connecting.value }

        // What it says is not asked: the connect's own round, whose slot answers none, can refuse the row before
        // or after it is kept.
        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation whose last read a connect overtook was not kept: \(came)")
        }
        XCTAssertEqual(row.request.destination, "USBHDD")
        XCTAssertNil(model.diskNotHad, "the disk was taken as not had on a read the link had left")
        expectEqual(await recorder.asked(Ask.create, since: before), 0)
    }

    /// A clash check for a kept disk, waiting for the slot, while the check before another operation -- a look at
    /// a changed network, another sheet -- makes sure of the recorder on the client the wait reads on, its probe
    /// met by silence and the recorder woken, with a MAC kept: the wait reads nothing while that check is out,
    /// says nothing and gives nobody up, and once the waking has attached the recorder, whose attach answers the
    /// disk, the disk is had and the clashes are asked.
    func testAClashChecksWaitForTheSlotReadsNothingWhileAnotherChecksWakingIsOut() async throws {
        let (_, recorder, model) = try await connected(times: 1, wakeable: true)
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the disk was meant to be kept through an answer of none")
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let checking = Task {
            await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        // The other check's probe, which goes behind the held read, is silent; the waking's asks are held.
        await recorder.hold(only: Ask.description)
        await recorder.goQuiet(on: Ask.description)
        let makingSure = Task { await makeSure(model) }
        try await until("the other check never began") { isMakingSure(model) }
        await recorder.letGo(only: Ask.slot)
        try await until("the other check never asked who answers") {
            await recorder.asked(Ask.description, since: before) == 1
        }
        await recorder.letTheFirstGo(of: Ask.description)
        try await until("the recorder was never woken") {
            await recorder.asked(Ask.description, since: before) == 2
        }

        expectEqual(await recorder.asked(Ask.slot, since: before), 1,
                    "the slot was read beside the other check's probe or its waking")
        XCTAssertTrue(model.settlingTheSlot, "the wait ended while the other check woke the recorder")
        XCTAssertFalse(model.gaveUp, "the recorder was given up on while the other check woke it")

        // The slot answers the disk from here on.
        await recorder.answer(Ask.slot, with: .result(USBDiskTests.slot()), times: 1000)
        await recorder.letGo()
        let sure = try await within(10, "the other check never ended") { await makingSure.value }
        let clashes = try await within(10, "the clash check never ended") { await checking.value }

        XCTAssertTrue(sure, "the waking was meant to attach the recorder")
        XCTAssertNotNil(clashes, "a clash check whose slot the waking's attach answered handed back nothing")
        expectEqual(await recorder.asked("X_GetConflictList", since: before), 1, "the clashes were not asked once")
        expectEqual(await recorder.asked(Ask.slot, since: before), 2,
                    "the slot was read other than by the held read and the waking's attach")
        XCTAssertTrue(model.connected)
        XCTAssertFalse(model.gaveUp, "the recorder was given up on")
        XCTAssertNotEqual(model.problem(for: .recorder), Said.noAnswer, "the other check's silence was said")
        XCTAssertNil(model.diskNotHad, "the disk the waking's attach answered was taken as not had")
    }

    /// A reservation to a kept disk, waiting for the slot while the check before another operation is out on the
    /// client it reads on, its probe held for longer than the wait waits for one: the wait gives up, with nothing
    /// more read or sent, and the reservation is kept on the phone.
    func testAReservationWhoseWaitForTheSlotGivesUpOnAnotherCheckStillOutPastItsTimeIsKept() async throws {
        let (_, recorder, model) = try await connected(times: 1, connectFor: .milliseconds(100))
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let reserving = Task {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        await recorder.hold(only: Ask.description)
        let makingSure = Task { await makeSure(model) }
        try await until("the other check never began") { isMakingSure(model) }
        await recorder.letGo(only: Ask.slot)
        let came = try await within(5, "the wait for the slot did not give up on the other check") {
            await reserving.value
        }

        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation whose wait gave up by itself was not kept: \(came)")
        }
        XCTAssertEqual(row.request.destination, "USBHDD")
        XCTAssertEqual(model.pending.map(\.id), [row.id], "the reservation kept is not what waits")
        XCTAssertTrue(isMakingSure(model), "the other check was meant to be out still")
        expectEqual(await recorder.asked(Ask.create, since: before), 0)
        expectEqual(await recorder.asked(Ask.slot, since: before), 1, "the slot was read beside the other check")
        await recorder.letGo()
        _ = try await within(10, "the other check never ended") { await makingSure.value }
    }

    /// A change moving a reservation to a kept disk, and a condition to it, each waiting for the slot beside a
    /// connect that does not attach the recorder: silent to its probe, with no MAC to wake it by, or answered there
    /// by something that is not a recorder. The connect has said why, and each hands back that sentence and says
    /// nothing over it: nothing is sent, nothing is read on the connect's client, and the disk is not taken as not
    /// had.
    func testAChangeAndAConditionWaitingForTheSlotBesideAConnectThatDoesNotAttachTheRecorderSayWhatItSaid()
        async throws {
        for stranger in [false, true] {
            for condition in [false, true] {
                let how = (condition ? "a condition" : "a change")
                    + (stranger ? ", something else answering the connect" : ", the connect met by silence")
                let (_, recorder, model, asking, connecting, scene) =
                    try await waitingForTheSlotBesideAConnectHeldAtItsProbe(reserved: !condition) { model, program in
                        if condition { return await addACondition(model, Self.condition(to: "USBHDD")) }
                        guard let row = model.reservation(for: program) else { return true }
                        return await changeOnTheRecorder(model, row, quality: "DR", repeating: "none", disk: "USBHDD")
                    }
                if stranger {
                    await recorder.answer(Ask.description, with: .status(404))
                } else {
                    await recorder.goQuiet(on: Ask.description)
                }
                await recorder.letGo()
                let done = try await within(10, "\(how) never came back") { await asking.value }
                try await within(10, "the connect never ended, \(how)") { await connecting.value }

                let line = stranger ? RecorderError.notARecorder(host: Bench.host).explanation : Said.noAnswer
                XCTAssertFalse(done, "\(how) went through, or found no reservation to change")
                XCTAssertEqual(whyNotJustNow(model), line, "\(how) handed back other than what the connect said")
                XCTAssertEqual(model.problem(for: .recorder), line,
                               "something was said over the connect's line, \(how)")
                XCTAssertNil(model.diskNotHad, "the disk was taken as not had, \(how)")
                expectEqual(await recorder.asked(condition ? "X_CreatePrefRecSetting" : "X_UpdateRecordSchedule",
                                                 since: scene.before), 0, how)
                expectEqual(await scene.sent.clients(sending: Ask.slot, since: scene.sentBefore), [],
                            "the slot was read on a client the recorder was never attached on, \(how)")
            }
        }
    }

    /// A reservation to a kept disk waiting for the slot while the check before another operation makes sure of
    /// the recorder, which is silent to it, with no MAC to wake it by: that check has lost the recorder and said
    /// so, and the wait ends there with nothing more read, nothing put down and nothing said, the reservation kept
    /// on the phone as when the recorder is silent at that moment.
    func testAWaitForTheSlotEndsUnsaidOnAnotherCheckThatDoesNotFindTheRecorder() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let reserving = Task {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        // The other check's probe, which goes behind the held read, meets silence.
        await recorder.goQuiet(on: Ask.description)
        let makingSure = Task { await makeSure(model) }
        try await until("the other check never began") { isMakingSure(model) }
        await recorder.letGo()
        let sure = try await within(10, "the other check never ended") { await makingSure.value }
        let came = try await within(10, "the reservation never came back") { await reserving.value }

        XCTAssertFalse(sure, "the other check was meant to find the recorder silent")
        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation beside a check that lost the recorder was not kept: \(came)")
        }
        XCTAssertEqual(row.request.destination, "USBHDD")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the other check's line was not left as it said it")
        XCTAssertTrue(model.gaveUp)
        XCTAssertNil(model.diskNotHad, "the disk was taken as not had")
        expectEqual(await recorder.asked(Ask.slot, since: before), 1,
                    "the slot was read again once the other check had lost the recorder")
        expectEqual(await recorder.asked(Ask.create, since: before), 0)
    }

    /// A reservation to a kept disk waiting for the slot, its read held, while a connect to the same recorder is
    /// made beside it that attaches the recorder on a client of its own and then loses it, silent to that attach's
    /// read of the slot, with no MAC to wake it by. The connect has said so; once the held read is back, met on a
    /// client the link has left, the wait reads nothing more and says nothing, and the reservation is kept on the
    /// phone as when the recorder is silent at that moment.
    func testAWaitForTheSlotReadsNothingOnAConnectThatAttachedTheRecorderAndLostIt() async throws {
        let sent = SentByClient()
        let (bench, recorder, model) = try await connected(times: 1, numbering: sent)
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let reserving = Task {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        // Silent to the next read of the slot: the connect's attach's own.
        await recorder.goQuiet(on: Ask.slot)
        let made = bench.clientsMade
        let sentBefore = await sent.sent.count
        try await within(10, "the connect never ended") { await model.connect() }
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        XCTAssertTrue(model.gaveUp, "the connect was meant to lose the recorder at the slot")
        expectEqual(await sent.clients(sending: Ask.freeSpace, since: sentBefore), [made + 1],
                    "the connect was meant to attach the recorder")
        await recorder.letGo()
        let came = try await within(10, "the reservation never came back") { await reserving.value }

        guard case .waiting(let row, _) = came else {
            return XCTFail("a reservation beside a connect that lost the recorder was not kept: \(came)")
        }
        XCTAssertEqual(row.request.destination, "USBHDD")
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer, "the connect's line was not left as it said it")
        XCTAssertNil(model.diskNotHad, "the disk was taken as not had")
        expectEqual(await sent.clients(sending: Ask.slot, since: sentBefore), [made + 1],
                    "the slot was read again on the client of a connect that had lost the recorder")
        expectEqual(await recorder.asked(Ask.create, since: before), 0)
    }

    /// A reservation to a kept disk waiting for the slot, its read held, while the recorder is let go of -- as a
    /// check that hears another recorder at the address lets it go before it connects again -- and connected to
    /// again, the same recorder answering, whose attach keeps the disk unanswered. The let-go ends the wait: once
    /// the held read is back, nothing is read on the new client beyond its attach's own, nothing is put down, and
    /// the reservation is not made, saying that another recorder answered.
    func testALetGoWhileTheSlotIsWaitedForEndsTheWait() async throws {
        let sent = SentByClient()
        let (bench, recorder, model) = try await connected(times: 1, numbering: sent)
        addTeardownBlock { await recorder.letGo() }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        let program = try await programmesNotReserved(model, 1)[0]
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let reserving = Task {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        let made = bench.clientsMade
        let sentBefore = await sent.sent.count
        model.forgetTheRecorder()
        try await within(10, "the connect never ended") { await model.connect() }
        XCTAssertTrue(model.connected, model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the connect was meant to keep the disk unanswered")
        await recorder.letGo()
        let came = try await within(10, "the reservation never came back") { await reserving.value }

        XCTAssertEqual(came, .notDone(RecorderDriver.anotherAnswered))
        expectEqual(await sent.clients(sending: Ask.slot, since: sentBefore), [made + 1],
                    "the slot was read on the new client after the let-go")
        XCTAssertNil(model.diskNotHad, "the disk was put down as not had across the let-go")
        XCTAssertTrue(model.pending.isEmpty, "a reservation across a let-go was kept")
        expectEqual(await recorder.asked(Ask.create, since: before), 0)
    }

    /// Where a wait for the slot beside a connect held at its probe stands (`waitingForTheSlotBesideAConnectHeldAtItsProbe`):
    /// what the recorder had been asked before, how many requests the clients had sent once the held read was let
    /// go, what each client sent, and the number the connect's client was made under.
    private struct BesideAConnect {
        let before: [String: Int]
        let sentBefore: Int
        let sent: SentByClient
        let connects: Int
    }

    /// A model whose recorder's disk is kept through an answer of none, with `ask` waiting for the slot for a
    /// programme no reservation holds -- or with `reserved`, one reserved on the internal disk before the disk was
    /// kept -- the slot's read held on the client in hand, and a connect to the same recorder made beside it, with
    /// every ask of who answers held, which makes a client of its own; then the held read let go, answering none,
    /// while the connect's probe is out. With `wakeable` a MAC is kept, for a connect silent to its probe to wake
    /// the recorder; `connectFor` is how long the wait waits for a connect. Handed back with `ask` and the connect
    /// still out; whatever is held is let go as the test ends.
    private func waitingForTheSlotBesideAConnectHeldAtItsProbe<T: Sendable>(
        wakeable: Bool = false, connectFor: Duration = SlotSettling.aConnect, reserved: Bool = false,
        _ ask: @escaping @MainActor (AppModel, GuideProgramRow) async -> T) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel, asking: Task<T, Never>,
            connecting: Task<Void, Never>, scene: BesideAConnect) {
        let sent = SentByClient()
        let (bench, recorder, model) = try await connected(times: 1, numbering: sent, wakeable: wakeable,
                                                           connectFor: connectFor)
        addTeardownBlock { await recorder.letGo() }
        var reservedFirst: GuideProgramRow?
        if reserved {
            let first = try await programmesNotReserved(model, 1)[0]
            expectTrue(await reserveOnTheRecorder(model, first, quality: "DR", repeating: "none"),
                       model.problem(for: .recorder) ?? "no reason given")
            reservedFirst = first
        }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the disk was meant to be kept through an answer of none")
        let program: GuideProgramRow
        if let reservedFirst { program = reservedFirst } else { program = try await programmesNotReserved(model, 1)[0] }
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let asking = Task { await ask(model, program) }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        await recorder.hold(only: Ask.description)
        let made = bench.clientsMade
        leaveALine(on: model)
        let connecting = Task { await model.connect() }
        try await until("the connect never asked who answers") {
            await recorder.asked(Ask.description, since: before) == 1
        }
        XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own")
        let sentBefore = await sent.sent.count
        await recorder.letGo(only: Ask.slot)
        // Long enough for the wait to have taken in what the held read came to while the probe is out.
        try await Task.sleep(for: .milliseconds(300))
        return (bench, recorder, model, asking, connecting,
                BesideAConnect(before: before, sentBefore: sentBefore, sent: sent, connects: made + 1))
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

        XCTAssertEqual(model.problem(for: .recorder), Self.diskNotHad)
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
    /// of its own: what the client it replaced met is not the recorder's, the wait goes on on the connect's
    /// client, read there once, and silence there keeps the reservation as if the connect had not come, the
    /// recorder lost and the line saying so. Nothing is created either way. The silence of a slot read for the
    /// recorder let go of is not the newcomer's, which is not given up on, and nothing is read after it.
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
            let afterTheConnect = await recorder.asked
            let who = anotherAnswers ? "another recorder answering" : "the same recorder answering"
            // What this stands on, rather than what it holds: the connect made a client of its own and was
            // answered by the recorder meant.
            XCTAssertEqual(bench.clientsMade, made + 1, "the connect was meant to make a client of its own, \(who)")
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(anotherAnswers ? 2 : 1),
                           "the connect was meant to be answered so, \(who)")
            // Silent to the held read, which the client the connect replaced sent, and to the next, which the
            // wait sends on the connect's client with the same recorder answering it; another recorder answering,
            // nothing is read after the held read.
            await recorder.answer("X_GetMediaInfo", with: .silence, times: anotherAnswers ? 1 : 2)
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
                // The silence on the connect's own client is the recorder's, and lost it.
                XCTAssertTrue(model.gaveUp, "the silence on the connect's client did not lose the recorder")
                XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer,
                               "the silence on the connect's client was not said")
            }
            expectEqual(await recorder.asked("X_GetMediaInfo", since: afterTheConnect), anotherAnswers ? 0 : 1,
                        "the slot was not read on the connect's client once, or was read for the newcomer, \(who)")
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
                           model.problem(for: .recorder) ?? "no reason given")
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
            XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
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
    /// so the slot is read no more -- what the check heard says nothing of it -- and neither is sent. The
    /// reservation is kept on the phone, as after its own check heard that; the change is not done; and each
    /// says what the check heard. The slot's first read is held until the check is out, so the check goes in
    /// before the wait could read the slot again.
    func testWhatWaitsForTheSlotWhileACheckHearsTheRecorderBusyIsNotSent() async throws {
        let busy = Said.busy(Ask.description)

        let reserved = try await aWaitForTheSlotWhileACheckHearsSomethingElse(hearing: .busy) { model, program, _ in
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        if case .waiting(let kept, _) = reserved.came {
            XCTAssertEqual(kept.request.destination, "USBHDD")
            XCTAssertEqual(reserved.model.pending(for: reserved.program, on: .recorder)?.id, kept.id)
        } else {
            XCTFail("a reservation whose slot was waited for while a check heard the recorder busy was not kept: "
                        + "\(reserved.came)")
        }

        let changed = try await aWaitForTheSlotWhileACheckHearsSomethingElse(hearing: .busy,
                                                                             reserving: true) { model, _, row in
            await model.change(row!, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        expectEqual(changed.came, .notDone(busy), "the change did not say what was heard")

        for (what, recorder, model, before) in [("the reservation", reserved.recorder, reserved.model, reserved.before),
                                                ("the change", changed.recorder, changed.model, changed.before)] {
            expectEqual(await recorder.asked(Ask.slot, since: before), 1,
                        "\(what): the slot was read after the check that heard the recorder busy")
            XCTAssertEqual(model.problem(for: .recorder), busy, "\(what) did not say what the check heard")
            for kind in [Ask.create, "X_UpdateRecordSchedule"] {
                expectEqual(await recorder.asked(kind, since: before), 0,
                            "\(what) was sent after a check that heard the recorder busy: \(kind)")
            }
        }
    }

    /// A condition to the USB disk whose slot is waited for while another operation's check hears the recorder
    /// busy with somebody else is not sent, as a reservation and a change are not, and the slot is read no more:
    /// it is asked, as the wait ends, whether it may be sent, and is not. What was heard is said in its result
    /// and on the line.
    func testAConditionWaitingForTheSlotWhileACheckHearsTheRecorderBusyIsNotSent() async throws {
        let busy = Said.busy(Ask.description)
        let added = try await aWaitForTheSlotWhileACheckHearsSomethingElse(hearing: .busy) { model, _, _ in
            await addACondition(model, Self.condition(to: "USBHDD"))
        }
        XCTAssertFalse(added.came, "a condition was made after a check that heard the recorder busy")
        expectEqual(await added.recorder.asked(Ask.slot, since: added.before), 1,
                    "the slot was read after the check that heard the recorder busy")
        XCTAssertEqual(whyNotJustNow(added.model), busy)
        XCTAssertEqual(added.model.problem(for: .recorder), busy, "the condition did not say what was heard")
        expectEqual(await added.recorder.asked("X_CreatePrefRecSetting", since: added.before), 0)
    }

    /// What names the USB disk -- a reservation, a change, a condition, a clash check -- waiting for the slot of a
    /// kept disk while the check before another operation finds something at the recorder's address that is not
    /// a recorder: what that check heard says nothing of which device answered, nor of the slot, so the wait reads
    /// nothing more and puts nothing down, and each answers as it does after such a check, as for a recorder
    /// heard busy. The reservation is kept on the phone, the change and the condition are not sent, and each says
    /// what was heard, on the line and in its result; the clash check asks nothing, says nothing and hands back
    /// no clashes, naming no disk the slot has not answered.
    func testWhatWaitsForTheSlotWhileACheckHearsSomethingElseIsNotSentAndReadsNothingMore() async throws {
        let heard = RecorderError.notARecorder(host: Bench.host).explanation

        let reserved = try await aWaitForTheSlotWhileACheckHearsSomethingElse { model, program, _ in
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        if case .waiting(let kept, _) = reserved.came {
            XCTAssertEqual(kept.request.destination, "USBHDD")
        } else {
            XCTFail("a reservation whose slot was waited for while a check heard something else was not kept: "
                        + "\(reserved.came)")
        }
        XCTAssertEqual(reserved.model.problem(for: .recorder), heard, "the reservation did not say what was heard")
        XCTAssertNil(reserved.model.diskNotHad, "the reservation took the disk as not had")
        expectEqual(await reserved.recorder.asked(Ask.slot, since: reserved.before), 1,
                    "the reservation's wait read the slot after the check")
        expectEqual(await reserved.recorder.asked(Ask.create, since: reserved.before), 0)

        let changed = try await aWaitForTheSlotWhileACheckHearsSomethingElse(reserving: true) { model, _, row in
            await model.change(row!, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        expectEqual(changed.came, .notDone(heard), "the change did not say what was heard")
        XCTAssertEqual(changed.model.problem(for: .recorder), heard)
        XCTAssertNil(changed.model.diskNotHad, "the change took the disk as not had")
        expectEqual(await changed.recorder.asked(Ask.slot, since: changed.before), 1,
                    "the change's wait read the slot after the check")
        expectEqual(await changed.recorder.asked("X_UpdateRecordSchedule", since: changed.before), 0)

        let added = try await aWaitForTheSlotWhileACheckHearsSomethingElse { model, _, _ in
            await addACondition(model, Self.condition(to: "USBHDD"))
        }
        XCTAssertFalse(added.came, "a condition was made after a check that heard something else")
        XCTAssertEqual(whyNotJustNow(added.model), heard, "the condition did not say what was heard")
        XCTAssertEqual(added.model.problem(for: .recorder), heard)
        XCTAssertNil(added.model.diskNotHad, "the condition took the disk as not had")
        expectEqual(await added.recorder.asked(Ask.slot, since: added.before), 1,
                    "the condition's wait read the slot after the check")
        expectEqual(await added.recorder.asked("X_CreatePrefRecSetting", since: added.before), 0)

        // Heard by the other check alone: the condition's own check, asking again who answers, would hear the
        // recorder, and the slot has still not answered the disk.
        let addedOnce = try await aWaitForTheSlotWhileACheckHearsSomethingElse(
            hearing: .somethingElse(times: 1)) { model, _, _ in
            await addACondition(model, Self.condition(to: "USBHDD"))
        }
        XCTAssertFalse(addedOnce.came, "a condition was made to a disk the slot has not answered")
        XCTAssertEqual(whyNotJustNow(addedOnce.model), heard, "the condition did not say what was heard")
        XCTAssertEqual(addedOnce.model.problem(for: .recorder), heard)
        expectEqual(await addedOnce.recorder.asked(Ask.slot, since: addedOnce.before), 1,
                    "the condition's wait read the slot after the check")
        expectEqual(await addedOnce.recorder.asked("X_CreatePrefRecSetting", since: addedOnce.before), 0,
                    "a condition was sent naming a disk the slot has not answered")

        let checked = try await aWaitForTheSlotWhileACheckHearsSomethingElse { model, program, _ in
            await model.conflicts(for: program, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        expectNil(checked.came, "a clash check named a disk the slot has not answered")
        expectEqual(await checked.recorder.asked("X_GetConflictList", since: checked.before), 0,
                    "the clashes were asked for a disk the slot has not answered")
        expectEqual(await checked.recorder.asked(Ask.slot, since: checked.before), 1,
                    "the clash check's wait read the slot after the check")
        XCTAssertEqual(checked.model.problem(for: .recorder), lineLeft, "the clash check said something")
        XCTAssertNil(checked.model.diskNotHad, "the clash check took the disk as not had")
    }

    /// What the check before another operation hears at the recorder's address: something that is not a
    /// recorder, for `times` checks from then on, or the recorder busy with somebody else.
    private enum Heard {
        case somethingElse(times: Int)
        case busy
    }

    /// A model whose recorder's disk is kept through an answer of none, with `ask` waiting for the slot, its read
    /// held; then the check before another operation, which hears what `heard` says at the address, the held
    /// read let go behind it. With `reserving`, a reservation made on the recorder first is handed to `ask`. What
    /// `ask` came to, once the check has reached the address, with the programme handed to it and where the
    /// scene began; whatever is held is let go, and the recorder made free, as the test ends.
    private func aWaitForTheSlotWhileACheckHearsSomethingElse<T: Sendable>(
        hearing heard: Heard = .somethingElse(times: 1000), reserving: Bool = false,
        _ ask: @escaping @MainActor (AppModel, GuideProgramRow, Reservation?) async -> T) async throws
        -> (came: T, recorder: NamedRecorder, model: AppModel, before: [String: Int], program: GuideProgramRow) {
        let (_, recorder, model) = try await connected(times: 1)
        addTeardownBlock {
            await recorder.comeFree()
            await recorder.letGo()
        }
        let programs = try await programmesNotReserved(model, 2)
        if reserving {
            expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none"),
                       model.problem(for: .recorder) ?? "no reason given")
        }
        // The demo's answer of none from here on: the disk is kept, and waited for before anything names it.
        await reconnect(model)
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk, "the disk was meant to be kept through an answer of none")
        let row = reserving ? try XCTUnwrap(model.reservation(for: programs[1])) : nil
        leaveALine(on: model)
        let before = await recorder.asked
        await recorder.holdTheNext(Ask.slot)
        let asking = Task { await ask(model, programs[0], row) }
        try await until("the slot was never waited for") { await recorder.asked(Ask.slot, since: before) == 1 }
        // What the other check's probe hears, which goes behind the held read, and any check after it as `heard`
        // says.
        switch heard {
        case .somethingElse(let times): await recorder.answer(Ask.description, with: .status(404), times: times)
        case .busy: await recorder.busyAtTheDoor()
        }
        let makingSure = Task { await makeSure(model) }
        try await until("the other check never began") { isMakingSure(model) }
        await recorder.letGo()
        let sure = try await within(10, "the other check never ended") { await makingSure.value }
        XCTAssertTrue(sure, "the other check was meant to find something answering at the address")
        let came = try await within(10, "what waited for the slot never came back") { await asking.value }
        return (came, recorder, model, before, programs[0])
    }

    /// A condition to the USB disk whose slot is waited for while another recorder describes itself on a connect
    /// is sent to neither: what the slot answered is about the recorder let go of, and the condition is for the
    /// recorder it was asked of. It says that another recorder answered.
    func testAConditionWaitingForTheSlotIsNotSentAcrossAnotherRecordersArrival() async throws {
        let (_, recorder, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        let before = await recorder.asked
        await recorder.holdTheNext("X_GetMediaInfo")
        let adding = Task { await addACondition(model, Self.condition(to: "USBHDD")) }
        try await until("the slot was never read") { await recorder.asked("X_GetMediaInfo", since: before) == 1 }
        await recorder.become(2)
        await model.connect()
        // What this stands on: the newcomer described itself, and was connected to, while the slot was waited for.
        XCTAssertEqual(model.info?.udn, NamedRecorder.udn(2), model.problem(for: .recorder) ?? "no reason given")
        await recorder.letGo()

        expectFalse(await adding.value, "a condition was made across another recorder's arrival")
        XCTAssertEqual(whyNotJustNow(model), Said.anotherAnswered)
        expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
        XCTAssertFalse(model.gaveUp)
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

        expectTrue(made, model.problem(for: .recorder) ?? "no reason given")
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
                       model.problem(for: .recorder) ?? "no reason given")
            let made = try XCTUnwrap(model.reservation(for: program), what)
            expectTrue(await changeOnTheRecorder(model, made, quality: "ER", repeating: "none"),
                       model.problem(for: .recorder) ?? "no reason given")
            expectTrue(await addACondition(model, Self.condition(to: disk)),
                       model.problem(for: .recorder) ?? "no reason given")

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
        XCTAssertEqual(whyNotJustNow(model), "USBHDD はいま使えません。録画先は HDD のままです。")
        leaveALine(on: model)
        expectFalse(await addACondition(model, Self.condition(to: "USBHDD")),
                    "a condition to a disk no longer offered was made")
        XCTAssertEqual(whyNotJustNow(model), Self.slotGone)
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "the condition wrote over the line at its door")

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
        XCTAssertEqual(model.problem(for: .recorder), lineLeft,
                       "a reservation to a disk no longer offered wrote the line")
        expectEqual(await model.change(onTheInternalDisk, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone("USBHDD はいま使えません。録画先は HDD のままです。"))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a move to a disk no longer offered wrote the line")
        expectEqual(await model.reserve(program, on: .recorder, quality: "知らない画質", repeating: "none"),
                    .notDone(Said.notInTheTables))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a reservation in a mode nobody knows wrote the line")
        expectEqual(await recorder.asked, before, "a reservation or a move turned away at its door asked the recorder")

        let count = await recorder.heard.count
        expectEqual(await model.change(onTheInternalDisk, quality: "知らない画質", repeating: "none"),
                    .notDone(Said.notInTheTables))
        expectEqual(await recorder.heard(since: count), ["X_GetRecordScheduleList"])
        XCTAssertNil(model.problem(for: .recorder), "a change in a mode nobody knows wrote the line")

        await recorder.goQuiet(for: 1)
        expectFalse(await makeSure(model))
        XCTAssertTrue(model.offline)
        leaveALine(on: model)
        let heard = await recorder.asked
        expectEqual(await model.change(onTheInternalDisk, quality: "ER", repeating: "none"),
                    .notDone(Said.notConnected))
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a change while the recorder is away wrote the line")
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
                   model.problem(for: .recorder) ?? "no reason given")
        expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem(for: .recorder) ?? "no reason given")
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
        XCTAssertEqual(whyNotJustNow(model), "USBHDD はいま使えません。録画先は HDD のままです。")
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
                   model.problem(for: .recorder) ?? "no reason given")
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
                   model.problem(for: .recorder) ?? "no reason given")
        let openedOn = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(openedOn.destination, "HDD")

        expectTrue(await changeOnTheRecorder(model, openedOn, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD", "the move was not sent")

        expectTrue(await changeOnTheRecorder(model, openedOn, quality: "SR", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.qualityName, "SR")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD",
                       "the disk the sheet was opened on was sent in place of the one the recorder holds")

        // The demo's answer from here on, which is none, twice.
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        let onTheSlot = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(model.diskChoices(for: onTheSlot).map(\.destination), ["HDD", "USBHDD"])
        expectTrue(await changeOnTheRecorder(model, onTheSlot, quality: "SR", repeating: "none", disk: "HDD"),
                   model.problem(for: .recorder) ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "HDD")
    }

    /// A move the recorder answers as made that the list read after it does not show -- a recorder a moment behind
    /// itself, its list still with the reservation on the disk it had -- is said not to show there, as a change of
    /// mode is, and the list on screen is the one read.
    func testAMoveTheListAfterItDoesNotShowIsSaidSo() async throws {
        let (_, recorder, model) = try await connected()
        let program = try await programmesNotReserved(model, 1)[0]
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
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

        expectTrue(await addACondition(model, Self.condition(to: "USBHDD")),
                   model.problem(for: .recorder) ?? "no reason given")

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
        XCTAssertEqual(model.problem(for: .recorder), refused + " (402: X_CreateRecordSchedule)")
        XCTAssertNil(model.reservation(for: programs[0]), "a reservation turned down was shown as made")
        XCTAssertTrue(model.pending.isEmpty, "a reservation turned down was kept to be sent")
        await recorder.answer("X_CreateRecordSchedule", with: .fault(402))
        expectTrue(await reserveOnTheRecorder(model, programs[0], quality: "DR", repeating: "none"))
        XCTAssertEqual(keptJustNow(model)?.problem, "レコーダーがこの要求を受け付けませんでした (402: X_CreateRecordSchedule)")

        expectTrue(await reserveOnTheRecorder(model, programs[1], quality: "DR", repeating: "none"),
                   model.problem(for: .recorder) ?? "no reason given")
        let made = try XCTUnwrap(model.reservation(for: programs[1]))
        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectFalse(await changeOnTheRecorder(model, made, quality: "DR", repeating: "none", disk: "USBHDD"))
        XCTAssertEqual(model.problem(for: .recorder), refused + " (402: X_UpdateRecordSchedule)")
        XCTAssertEqual(model.reservation(for: programs[1])?.destination, "HDD")
        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectFalse(await changeOnTheRecorder(model, made, quality: "ER", repeating: "none"))
        XCTAssertEqual(model.problem(for: .recorder), "レコーダーがこの要求を受け付けませんでした (402: X_UpdateRecordSchedule)")
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
                   model.problem(for: .recorder) ?? "no reason given")
        let onTheSlot = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(onTheSlot.destination, "USBHDD")
        let before = await recorder.asked

        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectEqual(await model.change(onTheSlot, quality: "ER", repeating: "none"),
                    .notDone(Said.fault(402, "X_UpdateRecordSchedule")),
                    "a change that leaves the disk as it was is said as the disk's refusal")

        XCTAssertEqual(model.problem(for: .recorder), Said.fault(402, "X_UpdateRecordSchedule"))
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
                   model.problem(for: .recorder) ?? "no reason given")
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
        expectEqual(await change(), .done(saying: nil), model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [list, slot, slot, update, list],
                    "the change was not sent right after the read that answered, or the slot was read before the list")
        XCTAssertEqual(model.reservation(for: programs[0])?.qualityName, "ER")

        // The change, the recorder silent while the slot is read.
        count = await keptThroughNone()
        await recorder.goQuiet(on: slot)
        expectEqual(await change(), .notDone(Said.noAnswer), "a change met by silence at the slot is said otherwise")
        expectEqual(await recorder.heard(since: count), [list, slot])
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer)
        XCTAssertTrue(model.gaveUp, "silence at the slot did not lose the recorder")

        // The change, given up while the slot is read. Its own read cleared the line before it.
        let changed = try await givenUp { await change() }
        XCTAssertEqual(changed.came, .notDone(Said.slotWaitGivenUp), "a change given up did not say so")
        XCTAssertEqual(changed.heard, [list, slot], "a change given up was sent")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a change given up wrote on the line")
        XCTAssertFalse(model.gaveUp)

        // The clash check, the slot answering on its second read.
        count = await keptThroughNone()
        await recorder.answer(slot, with: .result(USBDiskTests.slot()), times: 1, after: 1)
        expectEqual(await clashCheck(), [], model.problem(for: .recorder) ?? "no reason given")
        expectEqual(await recorder.heard(since: count), [slot, slot, clashes],
                    "the clash check was not asked right after the read that answered")

        // The clash check, the recorder silent while the slot is read.
        count = await keptThroughNone()
        await recorder.goQuiet(on: slot)
        expectNil(await clashCheck())
        expectEqual(await recorder.heard(since: count), [slot])
        XCTAssertEqual(model.problem(for: .recorder), Said.noAnswer,
                       "a clash check met by silence at the slot is said otherwise")
        XCTAssertTrue(model.gaveUp, "silence at the slot did not lose the recorder")

        // The clash check, given up while the slot is read.
        let checked = try await givenUp { await clashCheck() }
        XCTAssertNil(checked.came)
        XCTAssertEqual(checked.heard, [slot], "a clash check given up was asked")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a clash check given up wrote on the line")
        XCTAssertFalse(model.gaveUp)

        // A reservation, given up while the slot is read.
        let reserved = try await givenUp {
            await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD")
        }
        XCTAssertEqual(reserved.came, .notDone(Said.slotWaitGivenUp), "a reservation given up was kept, or not said")
        XCTAssertEqual(reserved.heard, [slot], "a reservation given up was sent")
        XCTAssertEqual(model.problem(for: .recorder), lineLeft, "a reservation given up wrote on the line")
        XCTAssertTrue(model.pending.isEmpty, "a reservation given up was kept to be sent")
        expectTrue(try await GuideStore(path: bench.guidePath).pendingReservations().isEmpty,
                   "a reservation given up was kept on the phone")
        XCTAssertNil(model.reservation(for: program))

        // The change, the slot answering the disk as not mounted. Last: the disk is taken as it answered.
        count = await keptThroughNone()
        await recorder.answer(slot, with: .result(USBDiskTests.slot(mount: "0")), times: 1)
        expectEqual(await change(), .notDone(Self.diskNotHad))
        expectEqual(await recorder.heard(since: count), [list, slot], "a change to a disk not mounted was sent")
        XCTAssertNil(model.problem(for: .recorder),
                     "the read before the change did not clear the line, or it says the result")
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
                    .notDone("USBHDD はいま使えません。録画先は HDD のままです。"),
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
                   model.problem(for: .recorder) ?? "no reason given")
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

            expectTrue(await ask(), "\(what) did not go through: \(model.problem(for: .recorder) ?? "no reason given")")
            XCTAssertFalse(model.diskCannotBeHad("USBHDD"), "\(what) left the USB disk not to be had")
        }
    }
}
