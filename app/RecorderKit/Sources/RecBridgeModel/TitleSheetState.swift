import Foundation
import Observation
import RecorderKit

/// One recording's sheet as the reader works it: what it says of the recording, playing it on the television,
/// protecting it, deleting it, and the one question or report up at a time. The screen lays it out and hands this the
/// reader's presses; what each press does, what is held back and what the sheet says are here, where a test can hold
/// them. A television's row is not played from here, and what it says of itself is all that is shown of it.
@MainActor
@Observable
public final class TitleSheetState {
    public let title: RecordedTitle
    @ObservationIgnored private let model: AppModel

    /// The programme's summary and details, read as the sheet opens.
    public private(set) var detail: (summary: String, details: [String])?
    /// The question before a delete is up.
    public private(set) var confirmingDelete = false
    /// What the sheet asked for and did not come to pass: the device's answer, or why nothing was sent.
    public private(set) var failure: String?
    /// What a delete that went through had to say -- that the recording was deleted already -- said in the report,
    /// whose closing closes the sheet.
    public private(set) var told: String?
    public private(set) var deleted = false
    /// Whether one of the sheet's own requests is out -- playback, the power, the protect, the delete -- which holds
    /// the sheet open until it is answered, so that what it came to is said here rather than lost with a closed sheet,
    /// and its controls from the press, before the recorder's line is up. Not its details, which are asked as it opens
    /// and may be left behind.
    public private(set) var asking = false

    public init(title: RecordedTitle, model: AppModel) {
        self.title = title
        self.model = model
    }

    /// The sheet has opened: the programme's details are read.
    public func opened() async {
        detail = await model.detail(of: title)
    }

    // MARK: - what the sheet shows

    /// The live copy, since protecting it changes the list underneath.
    public var current: RecordedTitle { model.row(like: title) ?? title }

    /// Whether the list still has the recording: a bulk delete, or the list read again, can take it away under the
    /// sheet, which then closes as after its own delete. By the whole list, not by what a filter shows.
    var listed: Bool { model.row(like: title) != nil }

    /// Whether the sheet is to close for a recording gone from the list: once nothing of its own is out or up -- a
    /// request, or the question or report, the delete's question among them, whose closing closes it then.
    var goneFromTheList: Bool {
        !listed && !asking && !deleted && failure == nil && told == nil && !confirmingDelete
    }

    /// Set once the sheet is to close: its own delete went through, or the recording went from the list under it.
    public var done: Bool { deleted || goneFromTheList }

    /// 視聴状態: recording now, or how far it was watched, with the minutes where it was watched partway.
    public var viewing: String {
        if current.recording { return "録画中" }
        guard current.watchState == .partway, let resume = current.resumeSec else { return current.watchState.label }
        return "\(current.watchState.label)（\(resume / 60)分）"
    }

    /// テレビで再生: a recorder's row only.
    public var offersPlayback: Bool { current.device == .recorder }

    /// The recorder cannot be told where to start: `play` begins at the beginning whatever position is sent
    /// (docs/xsrs-api.md). A recording watched partway says so on the button, rather than surprise a reader who
    /// expected to carry on where they left off.
    public var playLabel: String { current.watchState == .partway ? "最初から再生" : "再生" }

    /// Why 再生 is held, where its own door would turn it away: 一時停止 and 停止 are about what is on the television.
    public var whyNotPlayed: String? { model.whyNot(playing: current) }

    /// What is said under the playback's buttons: why 再生 is held, or where it plays.
    public var playbackNote: String { whyNotPlayed ?? "レコーダーに接続されたテレビで再生されます。" }

    /// The playback's buttons are held while the recorder works, and from the press until the sheet's own request is
    /// answered. 一時停止 is one toggle on the recorder, so a second tap while the first was still on its way resumed
    /// what the reader had meant to pause; and turning the recorder on to play takes long enough to invite a second
    /// tap too.
    public var holdsPlayback: Bool { model.isBusy(for: .recorder) || asking }

    /// レコーダーの電源を入れる, while the recorder is in a standby that playing cannot reach.
    public var offersPower: Bool { model.needsPower }

    public var protectLabel: String { current.device == .tv ? "保護" : "保護（自動削除の対象外にする）" }

    /// The protect is held while a run is under way as well as while the device works (`AppModel.canAlter`): a run
    /// walks the list it writes to. Not by an id about to go, nor one of a disk gone from the slot: the protect's
    /// door's rule, which the sentence under the delete says as well.
    public var holdsProtect: Bool { model.whyNot(altering: current) != nil || !model.canAlter(current) || asking }

    /// Why the delete is held, where its own door would turn it away: said under it.
    public var whyNotDeleted: String? { model.whyNot(deleting: current) }

    /// この録画を削除: offered only where the delete's own door would let it through.
    public var holdsDelete: Bool { whyNotDeleted != nil || !model.canAlter(current) || asking }

    // MARK: - the question or the report

    /// Whether the one question or report is up.
    public var isAsking: Bool { confirmingDelete || failure != nil || told != nil }

    public var askTitle: String { failure != nil ? "エラー" : told != nil ? "録画" : "この録画を削除しますか？" }

    public var askMessage: String {
        if let failure { return failure.asABody }
        if let told { return told.asABody }
        return "\(current.title)\n" + [current].deletedForGood.asABody
    }

    /// Whether it is the question before a delete, with 削除する and キャンセル, rather than a report with OK.
    public var asksBeforeDeleting: Bool { failure == nil && told == nil }

    /// 削除する under the question is held while the device works or a run is under way.
    public var holdsConfirmingDelete: Bool { !model.canAlter(current) }

    // MARK: - the reader's presses

    /// 再生, 一時停止 / 再開 or 停止 on the television: `play`, `pause` or `stop`.
    public func play(_ operation: String) {
        let current = current
        ask { await self.model.play(current, operation) }
    }

    /// レコーダーの電源を入れる.
    public func powerOn() {
        ask { await self.model.powerOn() }
    }

    /// 保護, turned on or off.
    public func setProtected(_ on: Bool) {
        let current = current
        ask { await self.model.setProtected(current, on) }
    }

    /// この録画を削除: the question first.
    public func delete() { confirmingDelete = true }

    /// 削除する, under the question.
    public func confirmDelete() {
        let title = current
        ask {
            let came = await self.model.delete(title)
            switch came {
            case .done(let more?): self.told = more
            case .done(nil): self.deleted = true
            case .notDone: break
            }
            return came
        }
    }

    /// The question or report has been closed, whichever it was: a delete that went through with something to say
    /// closes the sheet with it.
    public func askClosed() {
        if told != nil { deleted = true }
        confirmingDelete = false
        failure = nil
        told = nil
    }

    /// Asks `operation` with the sheet held until it is answered, and says what it came to.
    private func ask(_ operation: @escaping @MainActor () async -> Altered) {
        asking = true
        Task {
            let came = await operation()
            asking = false
            if case .notDone(let why) = came { failure = why }
        }
    }
}
