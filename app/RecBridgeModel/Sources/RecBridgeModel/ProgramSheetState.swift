import Foundation
import Observation
import RecorderKit

/// One programme's sheet as the reader works it: what it holds of the reservation to be made -- where it goes
/// (予約先), the recorder's disk (録画先), the mode and the repeat -- what the recorder says it would clash with,
/// the one question or answer up at a time (`Ask`), and the requests of its own that are out. The screen lays the
/// sheet out and hands this the reader's presses; what each press does, what is offered and what is held back,
/// and what the sheet says, are here, where a test can hold them.
///
/// The programme says whether the recorder is already set to record it -- or will be, once a reservation
/// waiting on this phone reaches it. With a television saved the same is said of the television beside that,
/// each device under its own name, and a new reservation says where it goes: to a device that neither holds the
/// programme nor has it waiting (`AppModel.destinations(for:)`), so what one device holds neither stands in for
/// a reservation on the other nor is in the way of one. What is offered under it is the chosen device's: the
/// recorder's modes, repeats and what it would clash with (`RecorderDriver`), or the one mode and the repeats a
/// television is sent (`TVDriver`); and what the question before reserving says of the device is its driver's
/// too. The television is asked nothing until the reader reserves, and what that came to is said in the one
/// question or answer, a case of the result to a case of it (`say`).
///
/// With the recorder alone none of that is offered, and the sheet is the one it has always been. So with the
/// recorder's disk: a new reservation on the recorder says which disk it records to only while a USB disk that
/// takes recordings is known, and a reservation or a row that waits names its disk only off the internal one.
@MainActor
@Observable
public final class ProgramSheetState {
    public let program: GuideProgramRow
    @ObservationIgnored private let model: AppModel

    /// Starts at the mode chosen in the settings, and choosing another here is for this reservation only.
    public var quality: String
    public var repeating = "none"
    public private(set) var conflicts: [Reservation]?
    public private(set) var checking = false

    /// What the one question or answer is for: the screen honours one at a time, and asking and reporting never
    /// happen at once. Reporting is here because the red line at the sheet's foot is below the fold.
    public enum Ask {
        /// A reservation on the device 録画予約 was for as its button was pressed. The question keeps that
        /// device, and its words and its button use no other: the lists can be read again while it is up. It
        /// keeps the recorder's disk the same way, as the reader picked it, and names it: nil, and no disk
        /// named, where no disk was there to pick.
        case reserve(DeviceSlot, disk: String?)
        case cancel(Reservation)
        case cancelPending(PendingReservation)
        case failed(String)
        /// The reservation is waiting instead of made, and the sentence for why. `stays`: the sheet is left
        /// open on the row, which waited before or does not go by itself.
        case kept(String, stays: Bool)
        /// Made, and what its device had to say of it; or made by a sending while the reader was deleting
        /// the row it waited in, said as such a sending says it. The device names the answer.
        case said(String, DeviceSlot)
        /// Making it would stop others from recording, which the row's reason names: whether to make it
        /// all the same. `fresh`: it was asked for just now, so a no takes the row off again.
        case wouldStop(PendingReservation, fresh: Bool)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public private(set) var ask: Ask?
    /// Set once the sheet is to close: the screen closes it.
    public private(set) var done = false
    /// The reservation whose own sheet is open for changing it.
    public var editing: Reservation?
    /// Set when the recorder's lists were let go of under this sheet, until another recorder is attached and
    /// asked what the reservation would clash with there; `checks` is what has it asked.
    @ObservationIgnored private var lastRecorderGone = false
    private var checks = 0
    /// The device the reader picked under 予約先, for as long as it is free for the programme.
    private var chosen: DeviceSlot?
    /// The recorder's disk the reader picked under 録画先, kept as picked though it is no longer offered: a
    /// reservation to it is then refused when it is sent rather than sent to the internal disk in its place.
    /// Nil until a disk is picked, and every sheet starts on the internal disk. A disk refused for being no
    /// longer offered puts it on the internal disk, named, so that the next press does not ask for it again.
    public var chosenDisk: String?
    /// The device a reservation asked for here is for, from 録画予約する until what it came to has been said
    /// and closed: see `device`.
    private var turn: DeviceSlot?
    /// The line of a request of this sheet's own, while it is out: a reservation on either device, a waiting
    /// row sent again, the yes to making one all the same, and a delete of either device's reservation, each
    /// under its device's line for it. Nothing on the sheet can be pressed under it and the sheet cannot be
    /// closed (`holdsTheSheet`): what the request came to is said here, and a sheet that had gone would say it
    /// nowhere. A recorder's can be out for as long as a waking and the wait for its disk take.
    public private(set) var asking: String?
    /// How many requests of this sheet's own are out and not under `asking`: a delete of a waiting row, which
    /// waits for the queue's turn and puts up no line. A request to the television does not begin while there
    /// is one, nor one to the recorder. As it ends, such a request closes the sheet, or puts up its own answer
    /// and takes `asking` down, and one begun first would do that under the other's: the sheet gone while that
    /// answer is still out, or left open to be pressed and closed while its round runs -- a reservation on the
    /// recorder waits for the same queue's turn as the delete. Read by the television's three buttons --
    /// 録画予約する, もう一度送る and the way to change its reservation, whose sheet would send a request of its own
    /// -- by the recorder's 録画予約する, もう一度送る, 予約を変更する and 予約を削除 for the same reason, and by the
    /// sheet's close, as `asking` is: the sheet is held for such a delete as for its other requests.
    private var others = 0

    /// A sheet for `program`, starting at the mode the settings hold (`DefaultQuality`).
    public init(program: GuideProgramRow, model: AppModel) {
        self.program = program
        self.model = model
        quality = DefaultQuality.current(in: model.defaults)
    }

    // MARK: - what the sheet shows

    /// The recorder's reservation of this programme, and the television's, held apart.
    public var reservation: Reservation? { model.reservations(for: program).first { $0.device == .recorder } }
    public var televisions: Reservation? { model.reservations(for: program).first { $0.device == .tv } }
    /// The rows waiting on this phone for the programme, the recorder's and the television's.
    public func waiting(on device: DeviceSlot) -> PendingReservation? { model.pending(for: program, on: device) }
    public var past: Bool { program.end <= Date() }

    /// The device 録画予約 is for, or nil when no device is free for the programme: the one the reader
    /// picked while it is free, and otherwise the first that is, the recorder before the television.
    ///
    /// In a home with two it is not read afresh in the middle of a reservation (`turn`). A television's
    /// leaves the television no longer free -- the row waits, or was made -- and falling back to the
    /// recorder there would change the section under the question or the answer, and have the recorder
    /// asked what a reservation would clash with (`check`) on account of one that was the television's.
    public var device: DeviceSlot? {
        if let turn, model.destinations.count > 1 { return turn }
        let free = model.destinations(for: program)
        return chosen.flatMap { free.contains($0) ? $0 : nil } ?? free.first
    }

    /// Whether 録画予約 is offered for `device`: it is the device a new reservation goes to, and the programme
    /// is not over. Not for a programme already waiting there: a second reservation would only replace it in the
    /// queue.
    public func offersAReservation(on device: DeviceSlot) -> Bool { self.device == device && !past }

    /// 予約先: where a new reservation goes, among the devices free for the programme. A choice with both free
    /// (`destinationChoices`); one fixed line where a home's other device holds the programme or has it waiting
    /// (`showsTheDestinationAlone`); and nothing in a home with one device, where there is nothing to say.
    public var destinationChoices: [DeviceSlot]? {
        let free = model.destinations(for: program)
        return free.count > 1 ? free : nil
    }

    public var showsTheDestinationAlone: Bool {
        model.destinations(for: program).count <= 1 && model.destinations.count > 1
    }

    /// The reader picked another device under 予約先.
    public func choose(_ device: DeviceSlot) { chosen = device }

    /// The disk the reader picked while it is no longer offered: let go of since, still shown as a value under
    /// 録画先, and refused when it is sent. Nil while what was picked is offered, and while nothing was picked.
    var pickedAndGone: String? {
        chosenDisk.flatMap { RecorderDisk.offers($0, with: model.usbDisk) ? nil : $0 }
    }

    /// The disk the clashes are asked for: the one the row under 録画先 shows. Nil while that is a disk no longer
    /// offered, which is asked nothing: the clashes on another disk would not be the ones of the disk shown, and
    /// a reservation to it is refused before anything is sent.
    var checkedDisk: String? {
        pickedAndGone == nil ? model.diskOffered(chosenDisk) : nil
    }

    /// The disk the question before reserving names and the reservation is sent to: the one picked, or the
    /// internal disk where a picker was there and nothing was picked; nil where there was nothing to pick.
    var askedDisk: String? {
        chosenDisk ?? (model.diskChoices.isEmpty ? nil : RecorderDisk.internalID)
    }

    /// What a reservation on the recorder can be given, as its driver offers them: the weekly one only on the
    /// programme's own weekday (`RecorderDriver.repeats(startingAt:)`).
    public var repeatOptions: [String] { RecorderDriver.repeats(startingAt: program.start) }

    /// What a reservation on the television can be given: the one mode it records in, and the repeats it is sent
    /// for this programme. Nothing is said of what it would stop, which the television is asked when the reader
    /// reserves and not before.
    public var televisionRepeatOptions: [String] { TVDriver.repeats(for: program) }

    /// The heading of the section about the recorder's reservation. With a television registered the sections
    /// are named for the device each is about -- レコーダー here, テレビ over the television's -- and what is in a
    /// section says the rest. With the recorder alone there is nothing to tell apart, and the heading says what it
    /// said before there was a television.
    public var recordersHeading: String { model.tv != nil ? DeviceSlot.recorder.label : "この番組は予約済みです" }

    /// The heading of the section of a row that waits for `device`, named for the device once a television is
    /// saved.
    public func waitingHeading(_ device: DeviceSlot) -> String {
        model.tv != nil ? "\(device.label)・送信待ち" : "この番組は送信待ちです"
    }

    /// Whether the way to the recorder's reservation's own sheet is offered: changing it happens there rather than
    /// here, so there is one place that does it and one set of pickers to keep right. Not where that sheet's change
    /// would be turned away: being recorded, or over.
    public func offersChanging(_ reservation: Reservation) -> Bool {
        reservation.device == .tv ? !TVDriver.repeats(changing: reservation).isEmpty
            : RecorderDriver.whyNot(changing: reservation) == nil
    }

    /// Whether a button of the recorder's reservation -- its change and its delete -- is held back: while the
    /// recorder works, and while a request of this sheet's own is out (`others`).
    public var holdsTheRecordersButtons: Bool { model.isBusy(for: .recorder) || others > 0 }

    /// The television's reservation: the way to change it is held back while a request of this sheet's own is out
    /// (its sheet would send one of its own), and its delete while the television works.
    public var holdsChangingTheTelevisions: Bool { others > 0 }
    public var holdsDeletingTheTelevisions: Bool { model.isBusy(for: .tv) }

    /// A row that waits for its device is neither sent again nor deleted while that device works, since a sending
    /// that is out may have it in hand; nor sent again while another request of this sheet's is out (`others`).
    public func holdsSendingAgain(_ waiting: PendingReservation) -> Bool { model.isBusy(for: waiting.target) || others > 0 }
    public func holdsDeletingWaiting(_ waiting: PendingReservation) -> Bool { model.isBusy(for: waiting.target) }

    /// 録画予約する for the recorder: alive even while the recorder is being woken or cannot be reached at all, a
    /// reservation made now going to the queue and sent when the recorder next answers. Held while the recorder
    /// works and while a delete of this sheet's own is out (`others`), as the television's is.
    public var holdsReservingOnTheRecorder: Bool { model.working || others > 0 }

    /// 録画予約する for the television: held back by the television's work, and by a request of this sheet's own
    /// that is still out (`others`), never by the recorder's work as such.
    public var holdsReservingOnTheTelevision: Bool { model.isBusy(for: .tv) || others > 0 }

    /// Whether the sheet is held open, and nothing on it pressed: a request of its own is out (`asking`, `others`).
    public var holdsTheSheet: Bool { asking != nil || others > 0 }

    /// What the recorder answers when asked what a new reservation would clash with: the reservations whose hours
    /// it shares (`docs/xsrs-api.md`). Said as that rather than as 重複, the recorder's own mark: it has more than
    /// one tuner, so hours in common do not by themselves mean anything will be missed.
    public static let checkingLine = "時間が重なる予約を確認中"
    public static func clashes(_ count: Int) -> String { "時間が重なる予約が \(count) 件あります" }

    // MARK: - the question or the answer

    /// 削除 throughout, as in the rest of the app, and not 取り消す beside the question's own キャンセル.
    public var askTitle: String {
        switch ask {
        case .cancel: "この予約を削除しますか？"
        case .cancelPending: "送信待ちの予約を削除しますか？"
        case .failed: "エラー"
        case .kept(_, let stays): stays ? "送信待ちのままです" : "送信待ちにしました"
        case .said(_, let device): "\(device.label)の予約"
        case .wouldStop: "それでも予約しますか？"
        case .reserve(.recorder, _) where model.offline: RecorderDriver.keepingTitle
        case .reserve, nil: "この番組を録画予約しますか？"
        }
    }

    /// What the question or the answer says under its title.
    public func message(for asked: Ask) -> String {
        switch asked {
        case .reserve(let device, let named):
            let mode = device == .tv ? TVDriver.recordsIn : quality
            let disk = named.map { " · " + model.diskLabel($0) } ?? ""
            let confirming = device == .tv ? TVDriver.confirming : RecorderDriver.confirming(away: model.offline)
            return "\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n"
                + "\(Codes.qualityLabel[mode] ?? mode) · \(Codes.repeatLabel[repeating] ?? repeating)" + disk + "\n"
                + confirming
        case .cancel(let reservation):
            return "\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                + reservation.whatDeletingDoes(fromTheList: false)
        case .cancelPending(let waiting):
            return "\(Format.dateTime.string(from: waiting.request.start)) \(waiting.request.title)\n"
                + waiting.whatDeletingDoes
        case .failed(let said), .said(let said, _):
            return said.asABody
        case .kept(let why, _):
            return "\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n" + why
        case .wouldStop(let held, _):
            // The reason without the sentence about a button this question does not have. The consent is to
            // the reason whole, as it stands on the row.
            return TVDriver.asks(of: held) ?? held.problem ?? ""
        }
    }

    /// The button that does something, beside the one that closes: nil where there is none.
    public func actionLabel(for asked: Ask) -> (label: String, destructive: Bool)? {
        switch asked {
        case .reserve: ("予約する", false)
        case .cancel, .cancelPending: ("削除する", true)
        case .wouldStop: ("それでも予約", false)
        case .failed, .kept, .said: nil
        }
    }

    /// The button that closes: OK for what only says, キャンセル for a question.
    public func closingLabel(for asked: Ask) -> String {
        switch asked {
        case .kept, .said, .failed: "OK"
        case .reserve, .cancel, .cancelPending, .wouldStop: "キャンセル"
        }
    }

    /// The reader pressed the button that does something (`actionLabel(for:)`).
    public func act(on asked: Ask) {
        switch asked {
        case .reserve(let device, let named):
            reserve(on: device, disk: named)
        case .cancel(let reservation):
            // Held under its device's line, as this sheet's other requests to either device are.
            asking = line(TVDriver.deletingLine, or: RecorderDriver.deletingLine, on: reservation.device)
            Task {
                let deleted = await model.cancel(reservation)
                asking = nil
                switch deleted {
                case .done: done = true
                case .notDone(let why): ask = .failed(why)
                }
            }
        case .cancelPending(let waiting):
            others += 1
            Task {
                // A row is not deleted while the device it waits for works, and stays on the sheet then: a
                // sending begun under the question may have it in hand. One a sending made first is said as
                // made, and the sheet closes once that is read.
                let instead = await model.deleteWaiting(waiting)
                others -= 1
                if let instead {
                    ask = .said(instead, waiting.target)
                } else {
                    done = model.pending(for: program, on: waiting.target) == nil
                }
            }
        case .wouldStop(let held, let fresh):
            request(under: TVDriver.sendingLine, on: .tv, fresh: fresh) {
                await self.model.consent(to: held, askedForJustNow: fresh)
            }
        case .failed, .kept, .said:
            break
        }
    }

    /// The reader pressed the button that closes (`closingLabel(for:)`).
    public func close(_ asked: Ask) {
        switch asked {
        case .kept(_, let stays):
            if stays { turn = nil } else { done = true }
        case .said:
            done = true
        case .wouldStop(let held, let fresh):
            Task {
                await model.decline(held, askedForJustNow: fresh)
                turn = nil
            }
        case .reserve, .cancel, .cancelPending, .failed:
            turn = nil
        }
    }

    /// The question or the answer has gone from the screen, after whichever button was pressed.
    public func askClosed() { ask = nil }

    // MARK: - the reader's presses

    /// 録画予約する for the recorder. With a disk picked and let go of since, what 予約する would do is done at once:
    /// the question would promise a registration the recorder's driver is about to refuse.
    public func reserveOnTheRecorder() {
        turn = .recorder
        if let gone = pickedAndGone {
            reserve(on: .recorder, disk: gone)
        } else {
            ask = .reserve(.recorder, disk: askedDisk)
        }
    }

    /// 録画予約する for the television.
    public func reserveOnTheTelevision() { (turn, ask) = (.tv, .reserve(.tv, disk: nil)) }

    /// 予約を削除, for either device's reservation.
    public func delete(_ reservation: Reservation) { ask = .cancel(reservation) }

    /// 送信待ちの予約を削除.
    public func deleteWaiting(_ waiting: PendingReservation) { ask = .cancelPending(waiting) }

    /// 予約を変更する: the reservation's own sheet.
    public func change(_ reservation: Reservation) { editing = reservation }

    /// もう一度送る, for a row that waits with a refusal: asking again gets the same answer until whatever it names
    /// has changed, which only the reader can know.
    public func sendAgain(_ waiting: PendingReservation) {
        let device = waiting.target
        request(under: line(TVDriver.sendingLine, or: RecorderDriver.sendingLine, on: device), on: device,
                fresh: false) {
            await self.model.sendAgain(waiting)
        }
    }

    // MARK: - what the model does under the sheet

    /// The sheet has opened. The queue on screen is otherwise read when the reservations tab has been opened or a
    /// device was connected to, and a programme that waits for the television unread would be offered here as
    /// one it can still be reserved on. With the recorder alone the sheet reads what it always has.
    public func opened() async {
        if model.tv != nil { await model.loadPending() }
    }

    /// 録画予約 changed devices. A repeat picked under the recorder is not carried to the television, which is not
    /// sent all of them: whenever 録画予約 becomes the television's, by the reader's choice or by the recorder
    /// turning out to hold the programme, it starts from none.
    public func deviceChanged(to device: DeviceSlot?) {
        if device == .tv { repeating = "none" }
    }

    /// The recorder's lists were let go of (`AppModel.timesForgotten`). The programme is the broadcast's, and the
    /// sheet stays. What it holds of that recorder goes: the reservation picked for deletion, whose number would
    /// go to the next recorder, and the clashes that recorder named, which the next one attached is asked for. A
    /// reservation's sheet open over this one closes itself. What the reader picked of the recorder goes too: a
    /// disk picked, and the question that names one off the internal disk, a disk of the recorder let go of. One
    /// naming none, as in a home with no USB disk, stays.
    public func recordersListsLetGo() {
        if case .cancel(let picked) = ask, picked.device == .recorder { ask = nil }
        if case .reserve(.recorder, let named?) = ask, named != RecorderDisk.internalID {
            (ask, turn) = (nil, nil)
        }
        chosenDisk = nil
        conflicts = nil
        lastRecorderGone = true
    }

    /// The USB disk known changed. A disk let go of while the question that names it is up: the question would
    /// promise a registration the recorder's driver is about to refuse. It goes, as above, and 録画予約する says why.
    public func usbDiskChanged() {
        if case .reserve(.recorder, let named?) = ask, !RecorderDisk.offers(named, with: model.usbDisk) {
            (ask, turn) = (nil, nil)
        }
    }

    /// The television's lists were let go of (`AppModel.tvTimesForgotten`). A television's reservation picked for
    /// deletion is not the recorder's to take, and goes with them. So does the question whether to make a
    /// reservation that would stop others there: the names in it are that television's.
    public func televisionsListsLetGo() {
        if case .cancel(let picked) = ask, picked.device == .tv { ask = nil }
        if case .wouldStop = ask { (ask, turn) = (nil, nil) }
    }

    /// A recorder was attached (`AppModel.timesAttached`): after the lists of the last were let go of, it is asked
    /// what the reservation would clash with.
    public func recorderAttached() {
        guard lastRecorderGone else { return }
        lastRecorderGone = false
        checks += 1
    }

    /// What has the recorder asked again what a reservation would clash with (`check`), for the screen to run it
    /// whenever this changes. It says whether 録画予約 is the television's, so that the recorder is asked when the
    /// section becomes its own again, and only that of the device: with the recorder alone it is what it was. The
    /// disk is in it, so that the clashes asked are the ones on the disk the row under 録画先 shows, and none while
    /// that is a disk let go of.
    public var checkKey: String {
        "\(program.id)-\(quality)-\(repeating)-\(checkedDisk ?? "")-\(checks)" + (device == .tv ? "-tv" : "")
    }

    /// Asks the recorder what the reservation would clash with. Only where 録画予約 is the recorder's: nothing is
    /// asked of the recorder on account of a reservation that goes to the television. Nor for a disk let go of
    /// (`checkedDisk`), whose row then shows nothing: the clashes said before were for a disk that is no longer the
    /// one shown. A USB disk the slot did not answer while it was waited for is said by the model, and the sheet
    /// goes back to the internal disk, asked afresh.
    public func check() async {
        guard device == .recorder, !past else { return }
        guard let disk = checkedDisk else {
            (conflicts, checking) = (nil, false)
            return
        }
        guard model.connected else { return }
        checking = true
        let found = await model.conflicts(for: program, quality: quality, repeating: repeating, disk: disk)
        // A check that set out before the row changed comes back all the same (the recorder's requests are not
        // given up halfway), and what it found is for what the row showed then.
        guard !Task.isCancelled else { return }
        conflicts = found
        checking = false
        if found == nil, model.diskCannotBeHad(disk) { chosenDisk = RecorderDisk.internalID }
    }

    // MARK: - requests

    /// 予約する: a reservation on `device`, sent with the disk the question named, or the internal disk where it
    /// named none. The mode and the repeat are read now, as the question showed them, and not when the request
    /// sets out. A disk that cannot be had -- no longer offered, or not answered by the slot while it was waited
    /// for -- is refused by the recorder's driver before anything is queued or sent, and the sheet goes back to
    /// the internal disk, named, with the television beside it under 予約先 where it is free.
    private func reserve(on device: DeviceSlot, disk named: String?) {
        let (quality, repeating) = (quality, repeating)
        let sent = named ?? RecorderDisk.internalID
        request(under: line(TVDriver.reservingLine, or: RecorderDriver.reservingLine, on: device), on: device,
                fresh: true) {
            let came = await self.model.reserve(self.program, on: device, quality: quality, repeating: repeating,
                                                disk: sent)
            if self.model.diskCannotBeHad(sent) { self.chosenDisk = RecorderDisk.internalID }
            return came
        }
    }

    /// The line a request of this sheet's is held under, as the device's driver puts it up: the recorder's names
    /// the recorder once a television is saved beside it (`RecorderDriver.line(_:withATelevisionSaved:)`).
    private func line(_ television: String, or recorder: String, on device: DeviceSlot) -> String {
        device == .tv ? television : RecorderDriver.line(recorder, withATelevisionSaved: model.tv != nil)
    }

    /// What this sheet asks for a reservation: one on a device, a waiting row sent again, or the yes to making
    /// one all the same. What it came to is said (`say`), and with nothing put up and the sheet staying, 録画予約
    /// is read afresh. `line` is the line of `device`, the one the request is for, and is up for as long as that
    /// is out (`asking`).
    private func request(under line: String, on device: DeviceSlot, fresh: Bool,
                         _ work: @escaping @MainActor () async -> Reserved?) {
        asking = line
        Task {
            let came = await work()
            asking = nil
            say(came, on: device, fresh: fresh)
            if ask == nil, !done { turn = nil }
        }
    }

    /// What a reservation, or a waiting row sent again, came to on `device`, as this sheet says it and what it
    /// does then: a case of the result to a case of the question or answer. `fresh` is a reservation asked for
    /// just now, on this sheet, and not a row that was waiting before: it travels with the question whether to
    /// make it all the same, however often that is asked again.
    ///
    /// Made closes the sheet, after what there is to say of it. Kept closes it too, the row then being on the
    /// reservations tab -- but not over a row that was waiting before, nor over one that carries a reason which
    /// is not what is being said (`Reserved.leftForTheReader`): that row was not sent at all, and waits for the
    /// reader whatever its device does next, so the sheet is left open on its section. Nil is nothing to say: the
    /// sections say what became of the row.
    private func say(_ came: Reserved?, on device: DeviceSlot, fresh: Bool) {
        guard let came else { return }
        switch came {
        case .made(nil): done = true
        case .made(let more?): ask = .said(more, device)
        case .wouldStop(let held): ask = .wouldStop(held, fresh: fresh)
        case .waiting(_, let why): ask = .kept(why, stays: !fresh || came.leftForTheReader)
        case .notDone(let why): ask = .failed(why)
        }
    }
}

/// The recording mode a new reservation and a new keyword condition start at: the one chosen in the settings, while
/// the recorder records in it, and LSR otherwise. Chosen there and only there: the sheets start their own picker
/// from it and leave it alone, where they used to be bound to it, so that trying a mode on one programme quietly
/// changed the next one's.
public enum DefaultQuality {
    public static let fallback = "LSR"

    /// The mode saved in `defaults`, the model's (`Surroundings.defaults`).
    public static func current(in defaults: UserDefaults) -> String {
        let saved = defaults.string(forKey: DefaultsKey.defaultQuality) ?? fallback
        return RecorderDriver.recordsIn.contains(saved) ? saved : fallback
    }
}
