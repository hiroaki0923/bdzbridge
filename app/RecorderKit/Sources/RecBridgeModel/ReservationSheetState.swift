import Foundation
import Observation
import RecorderKit

/// One reservation's sheet as the reader works it: the reservation as the device that holds it has it -- the
/// recorder, or the television -- what can still be changed of it and the change to send, its delete, and the
/// one question or report up at a time. The screen lays it out and hands this the reader's presses.
///
/// It does not go through the guide, so it works for a reservation whose programme has dropped out of the eight
/// days the recorder publishes, and for one that records by time only.
///
/// A television's is shown, changed and deleted. What can be changed is its repeat, until its programme begins,
/// to what its driver offers (`TVDriver.repeats(changing:)`): the sheet has no rule of its own, and offers nothing
/// the change's door would turn away. A recorder's is offered the modes and the repeats its driver lists
/// (`RecorderDriver.recordsIn`, `repeats(startingAt:)`) while its driver would change it at all
/// (`RecorderDriver.whyNot(changing:)`), and what the sheet says of one in words of the recorder's is its
/// driver's too. What the change came to is said in the sheet's one question or report, under the device's name
/// when something is to be added to a change made. While a request of the sheet's own is out, the change or the
/// delete, its device's line for it is on the sheet, nothing on it can be pressed and the sheet cannot be closed,
/// for either device's row: what the request came to is said here, and a sheet that had gone would say it
/// nowhere. A recorder's can be out for as long as a waking and the wait for its disk take. Whatever is held
/// back, said in red or reported as a failure is the row's own device's, and the other device's work and trouble
/// are left out of it.
@MainActor
@Observable
public final class ReservationSheetState {
    public let reservation: Reservation
    @ObservationIgnored private let model: AppModel

    /// The question before a delete is up.
    public private(set) var confirming = false
    public private(set) var failure: String?
    /// The programme of the guide the reservation is of, once it has been looked up, for what it is about.
    public private(set) var program: GuideProgramRow?
    /// Set once the sheet is to close: the screen closes it.
    public private(set) var done = false
    /// What the pickers hold, seeded from the device and compared against it to know whether to offer the change.
    public var quality = ""
    public var repeating = ""
    /// The disk the reader moved it to, nil while it is left on its own, kept as picked: a move to a disk let go
    /// of since is refused when it is sent, not sent to another. Moved back, it is nil again, so that what the
    /// recorder holds it on is kept (`RecorderDriver.update`).
    public private(set) var movedTo: String?
    /// A change made, and what its device added to it, said before the sheet closes.
    public private(set) var said: String?
    /// A change of the recorder's not sent because the disk it goes to cannot be had: its report leaves the sheet
    /// open, the sentence asking for another disk on this sheet's picker, which offers what is left.
    @ObservationIgnored private var anotherDiskWanted = false
    /// The line of a request of this sheet's own to the device that holds the row, while it is out.
    public private(set) var asking: String?

    public init(reservation: Reservation, model: AppModel) {
        self.reservation = reservation
        self.model = model
    }

    /// The sheet has opened: the pickers start from what the device holds, and the programme is looked up.
    public func opened() async {
        quality = reservation.qualityName ?? RecorderDriver.recordsIn.first ?? "LSR"
        repeating = reservation.repeatName ?? "none"
        program = await model.program(for: reservation)
    }

    // MARK: - what the sheet shows

    /// A recorder's row the change's door would turn away -- being recorded, or over -- by its driver's rule
    /// (`RecorderDriver.whyNot(changing:)`): it is shown as values, and no change is offered.
    public var settled: Bool { RecorderDriver.whyNot(changing: reservation) != nil }
    public var onTelevision: Bool { reservation.device == .tv }

    /// What a recorder's row can be given, as its driver offers them: the weekly one only on the programme's own
    /// weekday (`RecorderDriver.repeats(startingAt:)`).
    public var repeatOptions: [String] { RecorderDriver.repeats(startingAt: reservation.start) }

    /// What a television's row can be changed to, the row's own repeat among them: none once its programme has
    /// begun, and none for a repeat that has no name here.
    public var televisionsRepeats: [String] { TVDriver.repeats(changing: reservation) }

    /// Whether the change is offered: for a television's row, only the repeat, and only while it has a picker,
    /// the one mode it records in being no choice made; for the recorder's, any of its pickers.
    public var changed: Bool {
        onTelevision
            ? !televisionsRepeats.isEmpty && repeating != (reservation.repeatName ?? "none")
            : !settled && (quality != (reservation.qualityName ?? "")
                || repeating != (reservation.repeatName ?? "none") || movedTo != nil)
    }

    /// The disks it can be moved between, while it can still be changed: none for a television's row, and none in
    /// a home with no USB disk, where no picker is drawn.
    public var diskChoices: [RecorderDisk] {
        settled ? [] : model.diskChoices(for: reservation)
    }

    /// 録画先 as a picker, while there is a disk to move it between (`diskChoices`): the disk it is on now, the one
    /// moved to or its own.
    public var disk: String { movedTo ?? reservation.destination }

    /// The reader picked a disk under 録画先: moved back to its own, it is left on its own again.
    public func pick(disk destination: String) {
        movedTo = destination == reservation.destination ? nil : destination
    }

    /// 録画先 as a value, where there is no disk to move it between: the one moved to, still named once it is no
    /// longer offered, or its own when that is off the internal disk. Nil in a home with no USB disk.
    public var diskShown: String? { movedTo.map(model.diskLabel) ?? model.diskShown(reservation) }

    /// The button that sends the change, to the device that holds the row.
    public var changeLabel: String { "変更を\(reservation.device.label)に送る" }

    /// What the change does beyond what the pickers say, under its button: the driver's words.
    public var changeFooter: String {
        onTelevision
            ? TVDriver.changesTheRepeatOnly
            : RecorderDriver.changeFooter(followsItsProgramme: reservation.eventID != nil,
                                          offersADisk: !diskChoices.isEmpty)
    }

    /// The change and the delete are held back while the device that holds the row works.
    public var holdsItsButtons: Bool { model.isBusy(for: reservation.device) }

    /// The recorder's 重複, and the reservations at the same hours, by when, where and what: the recorder does not
    /// say which one it clashes with (`AppModel.overlapping`).
    public static let clashLine = "ほかの予約と重複しています"
    public static let noneOverlapping = "読み込んだ予約一覧には、時間が重なる予約がありません"
    public static let overlappingHeading = "時間が重なる予約"
    public struct Overlap: Identifiable, Sendable {
        /// The reservation's own id.
        public let id: String
        /// When, where and what.
        public let line: String
    }

    public var overlapping: [Overlap] {
        model.overlapping(reservation).map { other in
            Overlap(id: other.id, line: "\(Format.dateTime.string(from: other.start))〜\(Format.time.string(from: other.end))"
                        + "　\(model.channelName(for: other))　\(other.title)")
        }
    }

    // MARK: - the question or the report

    /// Whether the one question or report is up.
    public var isAsking: Bool { confirming || failure != nil || said != nil }

    /// Its title: what went wrong, what a change made added under the name of the device that holds the row, or
    /// the question before a delete.
    public var askTitle: String {
        failure != nil ? "エラー" : said != nil ? "\(reservation.device.label)の予約" : "この予約を削除しますか？"
    }

    /// What it says under its title.
    public var askMessage: String {
        if let failure { return failure.asABody }
        if let said { return said.asABody }
        return "\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
            + reservation.whatDeletingDoes(fromTheList: false)
    }

    /// Whether it is the question before a delete, with 削除する and キャンセル, rather than a report with OK.
    public var asksBeforeDeleting: Bool { failure == nil && said == nil }

    // MARK: - the reader's presses

    /// 予約を削除: the question first. 削除, the word the list's swipe and every other delete in the app use:
    /// 取り消す would stand beside キャンセル in the question, two words for going back on something.
    public func delete() { confirming = true }

    /// 削除する, under the question.
    public func confirmDelete() {
        asking = line(TVDriver.deletingLine, or: RecorderDriver.deletingLine)
        Task {
            let deleted = await model.cancel(reservation)
            asking = nil
            switch deleted {
            case .done: done = true
            case .notDone(let why): failure = why
            }
        }
    }

    /// The question or report has been closed, whichever it was. The report of a failed change or delete takes
    /// the sheet with it, for either device's row: the list was read again on the way, and the row this sheet
    /// holds may no longer be the device's as it holds it, so trying again starts from the list -- but for a
    /// change of the recorder's not sent because the disk it goes to cannot be had, whose sentence asks for
    /// another disk on this sheet (`anotherDiskWanted`). What a change made added takes the sheet with it as
    /// well, as a change made with nothing to add does at once. Looked at here and not in the button, before the
    /// report is cleared: closing it is what clears it.
    public func askClosed() {
        if failure != nil, !anotherDiskWanted { done = true }
        if said != nil { done = true }
        confirming = false
        failure = nil
        said = nil
        anotherDiskWanted = false
    }

    /// 変更を〈機器〉に送る: the change goes to the device that holds the row, with what the pickers hold as it is
    /// pressed, and what it came to is said. Made with nothing to add closes the sheet; made with something to add
    /// says it, and closing that closes the sheet; not made says why, and closing that closes the sheet too, unless
    /// the disk the change goes to cannot be had (`askClosed`). The request holds the sheet open until it is
    /// answered (`asking`).
    public func sendTheChange() {
        let moved = movedTo
        asking = line(TVDriver.changingLine, or: RecorderDriver.changingLine)
        Task {
            let altered = await model.change(reservation, quality: quality, repeating: repeating, disk: moved)
            asking = nil
            switch altered {
            case .done(nil): done = true
            case .done(let more?): said = more
            case .notDone(let why):
                failure = why
                // By why the change was not sent, not by whether the reservation's own disk is offered now: a disk
                // moved to that is not offered, or the slot answering no disk for the disk it went to.
                let notOffered = moved.map { !RecorderDisk.offers($0, with: model.usbDisk) } ?? false
                anotherDiskWanted = !onTelevision
                    && (notOffered || model.diskNotHad == (moved ?? reservation.destination))
            }
            // A move to a disk that cannot be had -- no longer offered, or not answered by the slot while it was
            // waited for -- is forgotten: the reservation stays where the recorder holds it, and the picker offers
            // what is left.
            if let moved, model.diskCannotBeHad(moved) { movedTo = nil }
        }
    }

    /// The line a request of this sheet's is held under, as the device's driver puts it up: the recorder's names
    /// the recorder once a television is saved beside it (`RecorderDriver.line(_:withATelevisionSaved:)`).
    private func line(_ television: String, or recorder: String) -> String {
        onTelevision ? television : RecorderDriver.line(recorder, withATelevisionSaved: model.tv != nil)
    }
}
