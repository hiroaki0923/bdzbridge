import Foundation
import Observation
import RecBridgeModel
import RecorderKit

// The programme's sheet and the reservation's, over the model's own states of them (`ProgramSheetState`,
// `ReservationSheetState`): what each holds, offers, holds back and says, and what each press does, are the model's,
// as on iOS. A window is made as its sheet opens and ended as it closes. While it is open it does for the sheet what
// the iOS sheet does with `onChange` and `task(id:)`: it tells the state when the model's lists are let go of or a
// recorder is attached, and asks the recorder again what a reservation would clash with when what it is asked for
// changes.

/// A value with its words: what a picker offers and what a row says.
public struct Labelled: Sendable {
    public var code: String
    public var label: String
}

/// The one question or answer up at a time: its title and what it says, the button that does something (`action`,
/// red when `destructive`, none when empty) and the one that closes. `key` tells this question from the next: a press
/// is for the one it was shown with, and does nothing once another has taken its place, as an iOS alert's button
/// acts on the value it was presented with.
public struct Asked: Sendable {
    public var key: String
    public var title: String
    public var message: String
    public var action: String
    public var destructive: Bool
    public var closing: String
}

/// A device's reservation of the programme, as the programme's sheet shows it.
public struct HeldReservation: Sendable {
    public var heading: String
    /// Empty where the device's row does not say.
    public var quality: String
    public var repeating: String
    public var disk: String
    public var recording: Bool
    /// 予約を変更する is offered, and whether it is held back now; 予約を削除 likewise.
    public var offersChanging: Bool
    public var changeHeld: Bool
    public var deleteHeld: Bool
    /// What went wrong with the device, said under its buttons (the television's; the recorder's is at the foot).
    public var problem: String
}

/// A reservation waiting on this device for one device, as the programme's sheet shows it.
public struct WaitingReservation: Sendable {
    public var heading: String
    public var quality: String
    public var repeating: String
    public var disk: String
    /// What the device said when it refused it, with もう一度送る; or, with none, when it goes.
    public var problem: String
    public var notYet: String
    public var sendAgainHeld: Bool
    public var deleteHeld: Bool
}

/// The programme's sheet (`ProgramSheet` on iOS).
public struct ProgrammeSheetScreen: Sendable {
    public var title: String
    public var station: String
    public var starts: String
    public var length: String
    public var genre: String
    public var summary: String
    public var extended: String
    /// The recorder being woken, or its USB slot waited for, while the sheet is up.
    public var waking: String
    public var hasRecorders: Bool
    public var recorders: HeldReservation
    public var hasTelevisions: Bool
    public var televisions: HeldReservation
    public var hasWaitingForTheRecorder: Bool
    public var waitingForTheRecorder: WaitingReservation
    public var hasWaitingForTheTelevision: Bool
    public var waitingForTheTelevision: WaitingReservation
    /// The line of a request of the sheet's own while it is out: nothing on the sheet can be pressed then, and it
    /// cannot be closed (`holdsTheSheet`).
    public var asking: String
    public var held: Bool
    /// 録画予約 for `recorder` or `tv`, or nothing.
    public var offer: String
    /// 予約先: a choice with both devices free, or one fixed line (`destinationAlone`), or nothing.
    public var destinations: [Labelled]
    public var destinationAlone: String
    public var device: String
    /// 録画先, the recorder's disk: a choice while a USB disk that takes recordings is known, or the disk picked
    /// and let go of since as a value, or nothing.
    public var disks: [Labelled]
    public var disk: String
    public var diskAlone: String
    /// 録画モード: the recorder's choice, or the television's one mode as a value (`qualityAlone`).
    public var qualities: [Labelled]
    public var quality: String
    public var qualityAlone: String
    public var repeats: [Labelled]
    public var repeating: String
    /// What the recorder answers when asked what the reservation would clash with.
    public var checking: Bool
    public var checkingLine: String
    public var conflictsLine: String
    public var clashes: Bool
    public var conflicts: [String]
    public var reserveHeld: Bool
    /// What went wrong with the recorder, at the sheet's foot.
    public var problem: String
    public var hasAsked: Bool
    public var asked: Asked
    /// The sheet is to close.
    public var done: Bool
}

/// The reservation's sheet (`ReservationSheet` on iOS).
public struct ReservationSheetScreen: Sendable {
    public var title: String
    public var station: String
    public var starts: String
    public var length: String
    public var waking: String
    public var onTelevision: Bool
    /// The mode and the repeat as values (`settled`, or a television's), or as choices.
    public var settled: Bool
    public var qualityValue: String
    public var repeatValue: String
    public var qualities: [Labelled]
    public var quality: String
    public var repeats: [Labelled]
    public var repeating: String
    public var disks: [Labelled]
    public var disk: String
    public var diskAlone: String
    public var follows: String
    public var madeBy: String
    public var size: String
    public var recording: Bool
    /// The recorder's 重複, with the reservations at the same hours.
    public var conflict: Bool
    public var clashLine: String
    public var overlappingHeading: String
    public var overlapping: [String]
    public var noneOverlapping: String
    /// Made by the recorder's keyword conditions, and what that means for a delete.
    public var madeByItself: String
    public var summary: String
    public var extended: String
    public var asking: String
    public var changed: Bool
    public var changeLabel: String
    public var changeFooter: String
    public var buttonsHeld: Bool
    public var problem: String
    public var hasAsked: Bool
    public var asked: Asked
    public var done: Bool
}

/// What a sheet's window keeps going while its sheet is open, ended as it closes: a task added after the end is
/// ended at once, whichever thread adds it.
final class Follows: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var ended = false

    func add(_ task: Task<Void, Never>) {
        let late = lock.withLock { () -> Bool in
            if !ended { tasks.append(task) }
            return ended
        }
        if late { task.cancel() }
    }

    func end() {
        let running = lock.withLock { () -> [Task<Void, Never>] in
            ended = true
            defer { tasks = [] }
            return tasks
        }
        running.forEach { $0.cancel() }
    }
}

/// Calls `changed` each time `value` comes to something other than it was, and not for what it starts at: SwiftUI's
/// `onChange`.
@MainActor
func onChange<T: Equatable & Sendable>(of value: @escaping @MainActor @Sendable () -> T,
                                       _ changed: @escaping @MainActor (T) -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        var last: T?
        var started = false
        for await now in Observations(value) {
            defer { (last, started) = (now, true) }
            if started, last != now { changed(now) }
        }
    }
}

private func labelled(_ codes: [String], _ labels: [String: String]) -> [Labelled] {
    codes.map { Labelled(code: $0, label: labels[$0] ?? $0) }
}

@MainActor
private func waking(_ model: AppModel) -> String {
    (model.waking || model.settlingTheSlot) ? model.busy ?? "" : ""
}

public final class ProgrammeSheetWindow: Sendable {
    let model: AppModel
    let sheet: ProgramSheetState
    private let shown: Watched<ProgrammeSheetScreen>
    private let follows = Follows()

    @MainActor
    init(_ sheet: ProgramSheetState, model: AppModel) {
        self.sheet = sheet
        self.model = model
        shown = Watched { ProgrammeSheetWindow.screen(sheet, model) }
        follows.add(Task { await sheet.opened() })
        // `task(id: checkKey)`: each time what the recorder is to be asked changes, the last ask is given up and the
        // recorder asked again.
        follows.add(Task { @MainActor in
            var asking: Task<Void, Never>?
            var last: String?
            for await key in Observations({ sheet.checkKey }) where key != last {
                last = key
                asking?.cancel()
                asking = Task { await sheet.check() }
            }
            asking?.cancel()
        })
        follows.add(onChange(of: { sheet.device }) { sheet.deviceChanged(to: $0) })
        follows.add(onChange(of: { model.timesForgotten }) { _ in sheet.recordersListsLetGo() })
        follows.add(onChange(of: { model.usbDisk }) { _ in sheet.usbDiskChanged() })
        follows.add(onChange(of: { model.tvTimesForgotten }) { _ in sheet.televisionsListsLetGo() })
        follows.add(onChange(of: { model.timesAttached }) { _ in sheet.recorderAttached() })
    }

    public func read() async -> ProgrammeSheetScreen { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    /// The sheet has closed: nothing more is followed for it.
    public func closed() async {
        follows.end()
    }

    // Each press does nothing while the model holds its button back, as the iOS sheet's disabled button does: what
    // Compose shows comes a turn after the model, and a second tap could otherwise send a write twice. The sheet is
    // held whole while a request of its own is out (`holdsTheSheet`, `.disabled(sheet.asking != nil)` on iOS).

    /// 予約先, `recorder` or `tv`.
    public func chooseDevice(_ code: String) async {
        await MainActor.run { if !sheet.holdsTheSheet { sheet.choose(DeviceSlot(rawValue: code)) } }
    }

    public func chooseDisk(_ destination: String) async {
        await MainActor.run { if !sheet.holdsTheSheet { sheet.chosenDisk = destination } }
    }

    public func chooseQuality(_ code: String) async {
        await MainActor.run { if !sheet.holdsTheSheet { sheet.quality = code } }
    }

    public func chooseRepeat(_ code: String) async {
        await MainActor.run { if !sheet.holdsTheSheet { sheet.repeating = code } }
    }

    /// 録画予約する, for the device it is offered for.
    public func reserve() async {
        await MainActor.run {
            guard !sheet.holdsTheSheet, sheet.ask == nil else { return }
            if sheet.offersAReservation(on: .recorder), !sheet.holdsReservingOnTheRecorder { sheet.reserveOnTheRecorder() }
            else if sheet.offersAReservation(on: .tv), !sheet.holdsReservingOnTheTelevision { sheet.reserveOnTheTelevision() }
        }
    }

    /// 予約を削除, for the reservation the device (`recorder` or `tv`) holds of the programme.
    public func delete(_ code: String) async {
        await MainActor.run {
            guard !sheet.holdsTheSheet, sheet.ask == nil else { return }
            if code == "tv", let reservation = sheet.televisions, !sheet.holdsDeletingTheTelevisions {
                sheet.delete(reservation)
            } else if code == "recorder", let reservation = sheet.reservation, !sheet.holdsTheRecordersButtons {
                sheet.delete(reservation)
            }
        }
    }

    /// 予約を変更する: the reservation's own sheet, for the reservation the device holds of the programme.
    public func change(_ code: String) async -> ReservationSheetWindow? {
        await MainActor.run {
            guard !sheet.holdsTheSheet,
                  let reservation = code == "tv" ? sheet.televisions : sheet.reservation,
                  sheet.offersChanging(reservation),
                  !(code == "tv" ? sheet.holdsChangingTheTelevisions : sheet.holdsTheRecordersButtons) else { return nil }
            sheet.change(reservation)
            return ReservationSheetWindow(ReservationSheetState(reservation: reservation, model: model), model: model)
        }
    }

    /// The reservation's own sheet, opened from here, has closed.
    public func changeClosed() async {
        await MainActor.run { sheet.editing = nil }
    }

    /// もう一度送る, for the row waiting for the device: offered only for a row the device refused.
    public func sendAgain(_ code: String) async {
        await MainActor.run {
            guard !sheet.holdsTheSheet, sheet.ask == nil, let waiting = sheet.waiting(on: DeviceSlot(rawValue: code)),
                  waiting.problem != nil, !sheet.holdsSendingAgain(waiting) else { return }
            sheet.sendAgain(waiting)
        }
    }

    /// 送信待ちの予約を削除, for the row waiting for the device.
    public func deleteWaiting(_ code: String) async {
        await MainActor.run {
            guard !sheet.holdsTheSheet, sheet.ask == nil, let waiting = sheet.waiting(on: DeviceSlot(rawValue: code)),
                  !sheet.holdsDeletingWaiting(waiting) else { return }
            sheet.deleteWaiting(waiting)
        }
    }

    /// The button of the question or answer shown with `key` that does something.
    public func act(_ key: String) async {
        await MainActor.run {
            guard let asked = sheet.ask, Self.key(asked) == key else { return }
            sheet.act(on: asked)
            sheet.askClosed()
        }
    }

    /// The button of the question or answer shown with `key` that closes it.
    public func closeAsked(_ key: String) async {
        await MainActor.run {
            guard let asked = sheet.ask, Self.key(asked) == key else { return }
            sheet.close(asked)
            sheet.askClosed()
        }
    }

    /// What tells one question or answer from another: all of it, as it is described.
    static func key(_ asked: ProgramSheetState.Ask) -> String { String(describing: asked) }

    @MainActor
    private static func screen(_ sheet: ProgramSheetState, _ model: AppModel) -> ProgrammeSheetScreen {
        let program = sheet.program
        let none = HeldReservation(heading: "", quality: "", repeating: "", disk: "", recording: false,
                                   offersChanging: false, changeHeld: false, deleteHeld: false, problem: "")
        let nothingWaits = WaitingReservation(heading: "", quality: "", repeating: "", disk: "", problem: "",
                                              notYet: "", sendAgainHeld: false, deleteHeld: false)
        func waiting(_ device: DeviceSlot) -> WaitingReservation {
            guard let row = sheet.waiting(on: device) else { return nothingWaits }
            return WaitingReservation(
                heading: sheet.waitingHeading(device),
                quality: Codes.quality(code: row.request.qualityCode).map { Codes.qualityLabel[$0] ?? $0 } ?? "-",
                repeating: Codes.repeatLabel[Codes.repeatName(code: row.request.repeatCode) ?? ""] ?? "しない",
                disk: model.diskShown(row) ?? "", problem: row.problem?.asABody ?? "",
                notYet: PendingQueue.notYetAt(device), sendAgainHeld: sheet.holdsSendingAgain(row),
                deleteHeld: sheet.holdsDeletingWaiting(row))
        }
        let recorders = sheet.reservation.map { held in
            HeldReservation(heading: sheet.recordersHeading, quality: held.qualityName ?? "-",
                            repeating: Codes.repeatLabel[held.repeatName ?? ""] ?? "しない",
                            disk: model.diskShown(held) ?? "", recording: held.recording,
                            offersChanging: sheet.offersChanging(held), changeHeld: sheet.holdsTheRecordersButtons,
                            deleteHeld: sheet.holdsTheRecordersButtons, problem: "")
        }
        let televisions = sheet.televisions.map { held in
            HeldReservation(heading: DeviceSlot.tv.label, quality: "",
                            repeating: Codes.repeatLabel[held.repeatName ?? ""] ?? "しない", disk: "",
                            recording: held.recording, offersChanging: sheet.offersChanging(held),
                            changeHeld: sheet.holdsChangingTheTelevisions, deleteHeld: sheet.holdsDeletingTheTelevisions,
                            problem: model.problem(for: .tv)?.asABody ?? "")
        }
        let offer: DeviceSlot? = sheet.offersAReservation(on: .recorder) ? .recorder
            : sheet.offersAReservation(on: .tv) ? .tv : nil
        let offered = model.diskChoices
        let conflicts = sheet.conflicts
        let asked = sheet.ask.map { asked in
            let action = sheet.actionLabel(for: asked)
            return Asked(key: Self.key(asked), title: sheet.askTitle, message: sheet.message(for: asked),
                         action: action?.label ?? "",
                         destructive: action?.destructive ?? false, closing: sheet.closingLabel(for: asked))
        }
        return ProgrammeSheetScreen(
            title: program.title, station: program.serviceName, starts: Format.dateTime.string(from: program.start),
            length: Format.duration(program.durationSec), genre: program.genre?.label ?? "", summary: program.summary,
            extended: program.extended, waking: waking(model),
            hasRecorders: recorders != nil, recorders: recorders ?? none,
            hasTelevisions: televisions != nil, televisions: televisions ?? none,
            hasWaitingForTheRecorder: sheet.waiting(on: .recorder) != nil, waitingForTheRecorder: waiting(.recorder),
            hasWaitingForTheTelevision: sheet.waiting(on: .tv) != nil, waitingForTheTelevision: waiting(.tv),
            asking: sheet.asking ?? "", held: sheet.holdsTheSheet,
            offer: offer?.rawValue ?? "",
            destinations: (sheet.destinationChoices ?? []).map { Labelled(code: $0.rawValue, label: $0.label) },
            destinationAlone: sheet.showsTheDestinationAlone ? offer?.label ?? "" : "",
            device: sheet.device?.rawValue ?? "",
            disks: offer == .recorder
                ? offered.map { Labelled(code: $0.destination, label: RecorderDisk.label($0.destination, named: $0.name)) } : [],
            disk: model.diskOffered(sheet.chosenDisk),
            diskAlone: offer == .recorder && offered.isEmpty ? sheet.chosenDisk.map(model.diskLabel) ?? "" : "",
            qualities: offer == .recorder ? labelled(RecorderDriver.recordsIn, Codes.qualityLabel) : [],
            quality: sheet.quality,
            qualityAlone: offer == .tv ? Codes.qualityLabel[TVDriver.recordsIn] ?? TVDriver.recordsIn : "",
            repeats: labelled(offer == .tv ? sheet.televisionRepeatOptions : sheet.repeatOptions, Codes.repeatLabel),
            repeating: sheet.repeating,
            // Under the recorder's 録画予約 only, as on iOS: the television is asked nothing of what it would clash with.
            checking: offer == .recorder && sheet.checking, checkingLine: ProgramSheetState.checkingLine,
            conflictsLine: offer == .recorder
                ? conflicts.map { $0.isEmpty ? RecorderDriver.noClashes : ProgramSheetState.clashes($0.count) } ?? "" : "",
            clashes: offer == .recorder && !(conflicts?.isEmpty ?? true),
            conflicts: offer == .recorder ? (conflicts ?? []).map { "\(Format.dateTime.string(from: $0.start)) \($0.title)" } : [],
            reserveHeld: offer == .tv ? sheet.holdsReservingOnTheTelevision : sheet.holdsReservingOnTheRecorder,
            problem: model.problem(for: .recorder)?.asABody ?? "",
            hasAsked: asked != nil,
            asked: asked ?? Asked(key: "", title: "", message: "", action: "", destructive: false, closing: ""),
            done: sheet.done)
    }
}

/// What a reservation's window keeps of its own: whether the device that holds the row let its lists go while the
/// sheet was up, which closes the sheet (`closesWithItsDevice` on iOS).
@MainActor @Observable
final class LetGo {
    var happened = false

    nonisolated init() {}
}

public final class ReservationSheetWindow: Sendable {
    let model: AppModel
    let sheet: ReservationSheetState
    private let letGo = LetGo()
    private let shown: Watched<ReservationSheetScreen>
    private let follows = Follows()

    @MainActor
    init(_ sheet: ReservationSheetState, model: AppModel) {
        self.sheet = sheet
        self.model = model
        let letGo = self.letGo
        shown = Watched { ReservationSheetWindow.screen(sheet, model, letGo) }
        follows.add(Task { await sheet.opened() })
        let onTelevision = sheet.onTelevision
        follows.add(onChange(of: { onTelevision ? model.tvTimesForgotten : model.timesForgotten }) { _ in
            letGo.happened = true
        })
    }

    public func read() async -> ReservationSheetScreen { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    public func closed() async {
        follows.end()
    }

    // As on the programme's sheet, each press does nothing while the model holds its button back.

    public func chooseQuality(_ code: String) async {
        await MainActor.run { if sheet.asking == nil { sheet.quality = code } }
    }

    public func chooseRepeat(_ code: String) async {
        await MainActor.run { if sheet.asking == nil { sheet.repeating = code } }
    }

    public func chooseDisk(_ destination: String) async {
        await MainActor.run { if sheet.asking == nil { sheet.pick(disk: destination) } }
    }

    /// 変更を〈機器〉に送る.
    public func sendTheChange() async {
        await MainActor.run {
            guard sheet.asking == nil, !sheet.isAsking, sheet.changed, !sheet.holdsItsButtons else { return }
            sheet.sendTheChange()
        }
    }

    /// 予約を削除: the question first.
    public func delete() async {
        await MainActor.run {
            guard sheet.asking == nil, !sheet.isAsking, !sheet.holdsItsButtons else { return }
            sheet.delete()
        }
    }

    /// 削除する, under the question shown with `key`.
    public func confirmDelete(_ key: String) async {
        await MainActor.run {
            guard sheet.confirming, sheet.asking == nil, Self.key(sheet) == key else { return }
            sheet.confirmDelete()
            sheet.askClosed()
        }
    }

    /// The question or the report shown with `key` closed, whichever button it was.
    public func closeAsked(_ key: String) async {
        await MainActor.run {
            guard sheet.isAsking, Self.key(sheet) == key else { return }
            sheet.askClosed()
        }
    }

    /// What tells the question or report up from the next.
    @MainActor
    static func key(_ sheet: ReservationSheetState) -> String {
        "\(sheet.confirming)|\(sheet.failure ?? "")|\(sheet.said ?? "")"
    }

    @MainActor
    private static func screen(_ sheet: ReservationSheetState, _ model: AppModel, _ letGo: LetGo) -> ReservationSheetScreen {
        let reservation = sheet.reservation
        let offered = sheet.diskChoices
        let televisions = sheet.televisionsRepeats
        return ReservationSheetScreen(
            title: reservation.title, station: model.channelName(for: reservation),
            starts: Format.dateTime.string(from: reservation.start), length: Format.duration(reservation.durationSec),
            waking: sheet.onTelevision ? "" : waking(model), onTelevision: sheet.onTelevision,
            settled: sheet.onTelevision ? televisions.isEmpty : sheet.settled,
            qualityValue: reservation.qualityName.map { Codes.qualityLabel[$0] ?? $0 } ?? (sheet.onTelevision ? "" : "-"),
            repeatValue: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない",
            qualities: sheet.onTelevision ? [] : labelled(RecorderDriver.recordsIn, Codes.qualityLabel),
            quality: sheet.quality,
            repeats: labelled(sheet.onTelevision ? televisions : sheet.repeatOptions, Codes.repeatLabel),
            repeating: sheet.repeating,
            disks: offered.map { Labelled(code: $0.destination, label: RecorderDisk.label($0.destination, named: $0.name)) },
            disk: sheet.disk, diskAlone: offered.isEmpty ? sheet.diskShown ?? "" : "",
            follows: sheet.onTelevision ? "" : reservation.followsItsProgramme ?? "",
            madeBy: sheet.onTelevision ? "" : reservation.madeBy,
            size: sheet.onTelevision ? "" : reservation.sizeMB.map { Format.gigabytes(megabytes: $0, on: reservation.device) } ?? "",
            recording: reservation.recording, conflict: reservation.conflict,
            clashLine: ReservationSheetState.clashLine, overlappingHeading: ReservationSheetState.overlappingHeading,
            overlapping: reservation.conflict ? sheet.overlapping.map(\.line) : [],
            noneOverlapping: ReservationSheetState.noneOverlapping,
            madeByItself: reservation.createdByRecorder ? RecorderDriver.madeByItself : "",
            summary: sheet.program?.summary ?? "", extended: sheet.program?.extended ?? "",
            asking: sheet.asking ?? "", changed: sheet.changed, changeLabel: sheet.changeLabel,
            changeFooter: sheet.changeFooter, buttonsHeld: sheet.holdsItsButtons,
            problem: model.problem(for: reservation.device)?.asABody ?? "",
            hasAsked: sheet.isAsking,
            asked: Asked(key: key(sheet), title: sheet.askTitle, message: sheet.askMessage,
                         action: sheet.asksBeforeDeleting ? "削除する" : "", destructive: sheet.asksBeforeDeleting,
                         closing: sheet.asksBeforeDeleting ? "キャンセル" : "OK"),
            done: sheet.done || letGo.happened)
    }
}

/// The recording's sheet (`TitleSheet` on iOS).
public struct TitleSheetScreen: Sendable {
    public var title: String
    public var station: String
    public var recorded: String
    /// Empty where the length, the size, the mode, the disk or the genre is not known or not said.
    public var length: String
    public var size: String
    public var quality: String
    public var disk: String
    public var viewing: String
    public var genre: String
    /// テレビで再生: 再生 (held where its own door turns it away, and while the playback's buttons are), the other
    /// buttons held together, レコーダーの電源を入れる where offered, and what is said under them.
    public var offersPlayback: Bool
    public var playLabel: String
    public var playHeld: Bool
    public var playbackHeld: Bool
    public var offersPower: Bool
    public var playbackNote: String
    public var protected: Bool
    public var protectLabel: String
    public var protectHeld: Bool
    public var deleteHeld: Bool
    /// Why the delete is held, where its own door would turn it away.
    public var whyNotDeleted: String
    public var summary: String
    public var details: [String]
    /// The recorder's line while it works -- turning it on to play takes as long as waking it -- or nothing.
    public var line: String
    public var problem: String
    public var asking: Bool
    public var hasAsked: Bool
    public var asked: Asked
    /// 削除する under the question is held while the device works or a run is under way.
    public var actionHeld: Bool
    public var done: Bool
}

public final class TitleSheetWindow: Sendable {
    let model: AppModel
    let sheet: TitleSheetState
    private let letGo = LetGo()
    private let shown: Watched<TitleSheetScreen>
    private let follows = Follows()

    @MainActor
    init(_ sheet: TitleSheetState, model: AppModel) {
        self.sheet = sheet
        self.model = model
        let letGo = self.letGo
        shown = Watched { TitleSheetWindow.screen(sheet, model, letGo) }
        follows.add(Task { await sheet.opened() })
        let onTelevision = sheet.title.device == .tv
        follows.add(onChange(of: { onTelevision ? model.tvTimesForgotten : model.timesForgotten }) { _ in
            letGo.happened = true
        })
    }

    public func read() async -> TitleSheetScreen { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    public func closed() async {
        follows.end()
    }

    // As on the other sheets, each press does nothing while the model holds its button back.

    /// 再生, 一時停止 / 再開 or 停止: `play`, `pause` or `stop`.
    public func play(_ operation: String) async {
        await MainActor.run {
            guard ["play", "pause", "stop"].contains(operation), sheet.offersPlayback, !sheet.holdsPlayback,
                  operation != "play" || sheet.whyNotPlayed == nil else { return }
            sheet.play(operation)
        }
    }

    public func powerOn() async {
        await MainActor.run {
            guard sheet.offersPower, !sheet.holdsPlayback else { return }
            sheet.powerOn()
        }
    }

    public func setProtected(_ on: Bool) async {
        await MainActor.run {
            guard !sheet.holdsProtect, on != sheet.current.protected else { return }
            sheet.setProtected(on)
        }
    }

    /// この録画を削除: the question first.
    public func delete() async {
        await MainActor.run {
            guard !sheet.holdsDelete, !sheet.isAsking else { return }
            sheet.delete()
        }
    }

    /// 削除する, under the question shown with `key`.
    public func confirmDelete(_ key: String) async {
        await MainActor.run {
            guard sheet.confirmingDelete, !sheet.asking, !sheet.holdsConfirmingDelete, Self.key(sheet) == key else { return }
            sheet.confirmDelete()
            sheet.askClosed()
        }
    }

    /// The question or the report shown with `key` closed, whichever button it was.
    public func closeAsked(_ key: String) async {
        await MainActor.run {
            guard sheet.isAsking, Self.key(sheet) == key else { return }
            sheet.askClosed()
        }
    }

    @MainActor
    static func key(_ sheet: TitleSheetState) -> String {
        "\(sheet.confirmingDelete)|\(sheet.failure ?? "")|\(sheet.told ?? "")"
    }

    @MainActor
    private static func screen(_ sheet: TitleSheetState, _ model: AppModel, _ letGo: LetGo) -> TitleSheetScreen {
        let current = sheet.current
        return TitleSheetScreen(
            title: current.title, station: model.channelName(for: current),
            recorded: Format.dateTime.string(from: current.start),
            length: current.lengthKnown ? Format.duration(current.durationSec) : "",
            size: current.sizeMB.map { Format.gigabytes(megabytes: $0, on: current.device) } ?? "",
            quality: current.qualityName.map { Codes.qualityLabel[$0] ?? $0 } ?? "",
            disk: model.diskShown(current) ?? "", viewing: sheet.viewing, genre: current.genre?.label ?? "",
            offersPlayback: sheet.offersPlayback, playLabel: sheet.playLabel,
            playHeld: sheet.whyNotPlayed != nil || sheet.holdsPlayback, playbackHeld: sheet.holdsPlayback,
            offersPower: sheet.offersPower, playbackNote: sheet.playbackNote.asABody,
            protected: current.protected, protectLabel: sheet.protectLabel, protectHeld: sheet.holdsProtect,
            deleteHeld: sheet.holdsDelete, whyNotDeleted: sheet.whyNotDeleted?.asABody ?? "",
            summary: sheet.detail?.summary ?? "", details: (sheet.detail?.details ?? []).filter { !$0.isEmpty },
            line: model.busy ?? "", problem: model.problem(for: current.device)?.asABody ?? "",
            asking: sheet.asking, hasAsked: sheet.isAsking,
            asked: Asked(key: key(sheet), title: sheet.askTitle, message: sheet.askMessage,
                         action: sheet.asksBeforeDeleting ? "削除する" : "", destructive: sheet.asksBeforeDeleting,
                         closing: sheet.asksBeforeDeleting ? "キャンセル" : "OK"),
            actionHeld: sheet.holdsConfirmingDelete, done: sheet.done || letGo.happened)
    }
}
