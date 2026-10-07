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
    /// while a disk is known waits before reading the slot again.
    private func connected(answering slot: String = USBDiskTests.slot(), times: Int = 1000,
                           readAgainAfter: Duration = RecorderDriver.slotReadAgainAfter) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel) {
        let bench = try aBench()
        try await bench.cacheAGuide()
        bench.slotReadAgainAfter = readAgainAfter
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

        expectTrue(await model.reserve(programs[0], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        let request = try XCTUnwrap(ReservationRequest(program: programs[0], quality: "DR", repeating: "none"))
        expectEqual(await recorder.elements(of: "X_CreateRecordSchedule"), XsrsElements.create(request),
                    "the internal disk's reservation is not sent as it was")
        let made = try XCTUnwrap(model.reservation(for: programs[0]))
        XCTAssertEqual(made.destination, "HDD")
        expectTrue(await model.update(made, quality: "ER", repeating: "none"), model.problem ?? "no reason given")
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

        expectTrue(await model.reserve(program, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")

        expectEqual(await recorder.elements(of: "X_CreateRecordSchedule"), XsrsElements.create(try XCTUnwrap(
            ReservationRequest(program: program, quality: "DR", repeating: "none", destination: "USBHDD"))))
        let made = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(made.destination, "USBHDD")
        XCTAssertEqual(model.diskShown(made), "録画用ディスク")
    }

    /// Right after a wake the slot answers none with a disk in it, and the disk known is kept until the slot is
    /// read again. It is offered all that while, as an answered one is, and a reservation to it is made there.
    func testADiskKeptThroughAnAnswerOfNoneIsOffered() async throws {
        let (_, _, model) = try await connected(times: 1)
        // The demo's answer from here on, which is none; the read again is half a minute away.
        await reconnect(model)
        XCTAssertNotNil(model.recorder.readLeftForLater, "the slot was not left to be read again")
        XCTAssertEqual(model.usbDisk, USBDiskTests.disk)
        XCTAssertEqual(model.diskChoices, [RecorderDisk.internalDisk, USBDiskTests.disk],
                       "a disk kept through an answer of none was not offered")

        let program = try await programmesNotReserved(model, 1)[0]
        expectTrue(await model.reserve(program, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD")
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

        expectFalse(await model.reserve(program, quality: "DR", repeating: "none", disk: "USBHDD"),
                    "a reservation to a disk no longer offered was made")
        XCTAssertEqual(model.problem, Self.slotGone)
        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none", disk: "USBHDD"),
                    .notDone(Self.slotGone))
        expectFalse(await model.update(onTheInternalDisk, quality: "DR", repeating: "none", disk: "USBHDD"),
                    "a move to a disk no longer offered was made")
        XCTAssertEqual(model.problem, "USBHDDはいま使えません。録画先はHDDのままです。")
        expectFalse(await model.addRecorderRule(Self.condition(to: "USBHDD")),
                    "a condition to a disk no longer offered was made")
        XCTAssertEqual(model.problem, Self.slotGone)

        expectEqual(await recorder.asked("X_CreateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_UpdateRecordSchedule", since: before), 0)
        expectEqual(await recorder.asked("X_CreatePrefRecSetting", since: before), 0)
        XCTAssertNil(model.reservation(for: program))
        XCTAssertTrue(model.pending.isEmpty, "a reservation to a disk no longer offered was kept to be sent")
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
        expectTrue(await model.reserve(programs[0], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        expectTrue(await model.reserve(programs[1], quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        // The demo's answer from here on, which is none, twice.
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        let onTheInternalDisk = try XCTUnwrap(model.reservation(for: programs[0]))
        let onTheSlot = try XCTUnwrap(model.reservation(for: programs[1]))
        XCTAssertEqual(model.diskChoices(for: onTheInternalDisk), [], "the internal disk's sheet offers a disk")
        let before = await recorder.asked

        expectFalse(await model.update(onTheInternalDisk, quality: "DR", repeating: "none", disk: "USBHDD"),
                    "a move to a disk no longer offered was made")
        XCTAssertEqual(model.problem, "USBHDDはいま使えません。録画先はHDDのままです。")
        expectFalse(await model.update(onTheSlot, quality: "DR", repeating: "none", disk: "USBHDD"),
                    "a move to a disk no longer offered was made")
        XCTAssertEqual(model.problem, Self.slotGone, "a reservation with the internal disk left to it")

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

        expectTrue(await model.reserve(program, quality: "DR", repeating: "none", disk: "USBHDD"),
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
        expectTrue(await model.reserve(program, quality: "DR", repeating: "none"), model.problem ?? "no reason given")
        let openedOn = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(openedOn.destination, "HDD")

        expectTrue(await model.update(openedOn, quality: "DR", repeating: "none", disk: "USBHDD"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD", "the move was not sent")

        expectTrue(await model.update(openedOn, quality: "SR", repeating: "none"), model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.qualityName, "SR")
        XCTAssertEqual(model.reservation(for: program)?.destination, "USBHDD",
                       "the disk the sheet was opened on was sent in place of the one the recorder holds")

        // The demo's answer from here on, which is none, twice.
        await reconnect(model)
        try await until("the disk was not let go", within: 5) { model.usbDisk == nil }
        let onTheSlot = try XCTUnwrap(model.reservation(for: program))
        XCTAssertEqual(model.diskChoices(for: onTheSlot).map(\.destination), ["HDD", "USBHDD"])
        expectTrue(await model.update(onTheSlot, quality: "SR", repeating: "none", disk: "HDD"),
                   model.problem ?? "no reason given")
        XCTAssertEqual(model.reservation(for: program)?.destination, "HDD")
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
        _ = await model.update(made, quality: "DR", repeating: "none", disk: "USBHDD")
        XCTAssertFalse(model.problem?.contains("いま使えません") == true,
                       "a change of the television's reservation was refused for the slot: \(model.problem ?? "")")
    }

    /// A condition made to the USB disk is made there, is read back with that disk, and names it on its row.
    func testAConditionToTheUSBDiskIsMadeThereAndNamed() async throws {
        let (_, recorder, model) = try await connected()

        expectTrue(await model.addRecorderRule(Self.condition(to: "USBHDD")), model.problem ?? "no reason given")

        expectEqual(await recorder.elements(of: "X_CreatePrefRecSetting"),
                    XsrsElements.recorderRule(Self.condition(to: "USBHDD")))
        let made = try XCTUnwrap(model.recorderRules.first { $0.keywords == ["ためしの言葉"] })
        XCTAssertEqual(made.destination, "USBHDD")
        XCTAssertEqual(model.diskShown(made), "録画用ディスク")
    }

    /// The recorder turning down a reservation to the USB disk, or a move to it, is said as the disk and what to
    /// do, and nothing is left looking made or kept to be sent; the internal disk's refusals are said as they
    /// always were.
    func testARefusalOfTheUSBDiskSaysWhichDiskAndWhatToDo() async throws {
        let (_, recorder, model) = try await connected()
        let programs = try await programmesNotReserved(model, 2)
        let refused = "レコーダーが録画用ディスクへの予約を受け付けませんでした。別の録画先を選んでください"

        await recorder.answer("X_CreateRecordSchedule", with: .fault(402))
        expectFalse(await model.reserve(programs[0], quality: "DR", repeating: "none", disk: "USBHDD"))
        XCTAssertEqual(model.problem, refused + " (402: X_CreateRecordSchedule)")
        XCTAssertNil(model.reservation(for: programs[0]), "a reservation turned down was shown as made")
        XCTAssertTrue(model.pending.isEmpty, "a reservation turned down was kept to be sent")
        await recorder.answer("X_CreateRecordSchedule", with: .fault(402))
        expectFalse(await model.reserve(programs[0], quality: "DR", repeating: "none"))
        XCTAssertEqual(model.problem, "レコーダーがこの要求を受け付けませんでした (402: X_CreateRecordSchedule)")

        expectTrue(await model.reserve(programs[1], quality: "DR", repeating: "none"),
                   model.problem ?? "no reason given")
        let made = try XCTUnwrap(model.reservation(for: programs[1]))
        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectFalse(await model.update(made, quality: "DR", repeating: "none", disk: "USBHDD"))
        XCTAssertEqual(model.problem, refused + " (402: X_UpdateRecordSchedule)")
        XCTAssertEqual(model.reservation(for: programs[1])?.destination, "HDD")
        await recorder.answer("X_UpdateRecordSchedule", with: .fault(402))
        expectFalse(await model.update(made, quality: "ER", repeating: "none"))
        XCTAssertEqual(model.problem, "レコーダーがこの要求を受け付けませんでした (402: X_UpdateRecordSchedule)")
    }
}
