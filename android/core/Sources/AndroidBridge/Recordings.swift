import Foundation
import Observation
import RecBridgeModel
import RecorderKit

// What the recordings' screen has beyond its list: the bulk job's bar, a programme's page with the selection that
// bulk work needs, and the recordings that look like copies of one broadcast. Each lays out the model's state of it
// (`BulkJob`, `GroupSheetState`, `DuplicatesState`), as the iOS views do.

/// Which view of the recordings is on, kept where the iOS screen keeps it, under its key in the model's settings
/// (`DefaultsKey.recordingsMode`), which are touched on the main actor alone; and here for the screen to be told
/// when it changes.
@MainActor @Observable
final class ShownMode {
    @ObservationIgnored let defaults: WrittenDefaults
    private(set) var mode: RecordingsState.Mode

    init(_ defaults: WrittenDefaults) {
        self.defaults = defaults
        mode = RecordingsState.Mode(kept: defaults.string(forKey: DefaultsKey.recordingsMode))
    }

    func choose(_ mode: RecordingsState.Mode) {
        defaults.set(mode.rawValue, forKey: DefaultsKey.recordingsMode)
        self.mode = mode
    }
}

// MARK: - the bulk job

/// The bulk job's bar (`JobBarView`): nothing while there is no job (`hasJob`).
public struct JobBar: Sendable {
    public var hasJob: Bool
    public var finished: Bool
    /// `削除中 3 / 12` while it runs, and what it came to once it has stopped.
    public var line: String
    /// 中止します…, once 中止 was pressed and the recording in hand is being finished; empty otherwise.
    public var stopping: String
    /// How far it is, in hundredths.
    public var progress: Int64
    /// Said under a job under way: what becomes of it when the reader leaves the app.
    public var note: String
    /// Why the device stopped the run, and the first few recordings it passed over with why, once it is over.
    public var why: String
    public var passedOver: [String]
}

public final class JobWindow: Sendable {
    let model: AppModel
    private let shown: Watched<JobBar>

    init(_ model: AppModel) {
        self.model = model
        shown = Watched { JobWindow.bar(model) }
    }

    public func read() async -> JobBar { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// 中止: stops before the next recording.
    public func cancel() async {
        await MainActor.run { model.cancelBulk() }
    }

    /// The finished job's bar closed.
    public func clear() async {
        await MainActor.run { model.clearJob() }
    }

    @MainActor
    private static func bar(_ model: AppModel) -> JobBar {
        guard let job = model.job else {
            return JobBar(hasJob: false, finished: false, line: "", stopping: "", progress: 0, note: "", why: "",
                          passedOver: [])
        }
        return JobBar(hasJob: true, finished: job.finished, line: job.finished ? job.outcome : job.progressLine,
                      stopping: !job.finished && job.cancelled ? BulkJob.stopping : "",
                      progress: Int64((job.progress * 100).rounded()), note: job.finished ? "" : BulkJob.pausesAway,
                      why: job.whyItStopped ?? "", passedOver: job.passedOver.map(\.said))
    }
}

// MARK: - a programme's recordings

/// One programme's recordings (`GroupSheet`), with the selection that bulk work needs.
public struct GroupScreen: Sendable {
    public var name: String
    /// 選択, or 完了 while picking; held with nothing listed.
    public var selecting: Bool
    public var selectLabel: String
    public var selectHeld: Bool
    /// この番組をすべて保護 and この番組の保護をすべて解除 are held while a run may not be started over these.
    public var protectAllHeld: Bool
    public var rows: [GroupMember]
    /// `3 件`, of the rows ticked.
    public var count: String
    /// The bar of what to do with the ticked rows: there while picking with something ticked, held while a run
    /// may not be started over them. `選択した 3 件を削除（12.3 GB）` is its delete.
    public var offersActions: Bool
    public var deleteLabel: String
    public var actionsHeld: Bool
    /// The question of a bulk delete or of one row's, or what a delete or 保護解除 came to: one at a time.
    public var hasAsked: Bool
    public var asked: Asked
    public var actionHeld: Bool
    /// A request of the page's own is out: it is not left until that is answered.
    public var asking: Bool
    /// The recorder whose recordings these were has been let go of: the page closes.
    public var done: Bool
}

/// A recording of the programme: its row, whether it is ticked, and whether a bulk delete would take it (the tick
/// is grey where it would pass it over).
public struct GroupMember: Sendable {
    public var row: RecordingRow
    public var selected: Bool
    public var wouldBeDeleted: Bool
}

public final class GroupWindow: Sendable {
    let model: AppModel
    let sheet: GroupSheetState
    private let gone = LetGo()
    private let shown: Watched<GroupScreen>
    private let follows = Follows()

    @MainActor
    init(_ sheet: GroupSheetState, model: AppModel) {
        self.sheet = sheet
        self.model = model
        let gone = gone
        shown = Watched { GroupWindow.screen(sheet, gone, model) }
        // `closesWithItsRecorder`: the rows are the last recorder's once its lists are let go of.
        follows.add(onChange(of: { model.timesForgotten }) { _ in gone.happened = true })
    }

    public func read() async -> GroupScreen { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    /// The page has closed: nothing more is followed for it.
    public func closed() async {
        follows.end()
    }

    // Each press does nothing while the model holds its button back, as the iOS control's disabled state does.

    /// 選択 or 完了.
    public func toggleSelecting() async {
        await MainActor.run { if !sheet.members.isEmpty { sheet.toggleSelecting() } }
    }

    /// A row tapped while picking.
    public func toggle(_ id: String) async {
        await MainActor.run {
            guard sheet.selecting, let title = member(id) else { return }
            sheet.toggle(title)
        }
    }

    /// 削除できるものをすべて選択.
    public func selectWhatCanBeDeleted() async {
        await MainActor.run { if sheet.selecting { sheet.selectWhatCanBeDeleted(among: sheet.members) } }
    }

    /// 選択解除.
    public func selectNothing() async {
        await MainActor.run { sheet.selectNothing() }
    }

    /// 選択した N 件を削除: asked first.
    public func deleteChosen() async {
        await MainActor.run {
            let chosen = sheet.chosen(among: sheet.members)
            guard sheet.offersActions(on: chosen), !sheet.holdsActions(on: chosen) else { return }
            sheet.deleteChosen()
        }
    }

    /// 保護する or 保護を解除, over the ticked rows.
    public func protect(_ on: Bool) async {
        await MainActor.run {
            let chosen = sheet.chosen(among: sheet.members)
            guard sheet.offersActions(on: chosen), !sheet.holdsActions(on: chosen) else { return }
            sheet.protect(on, chosen)
        }
    }

    /// この番組をすべて保護, or この番組の保護をすべて解除.
    public func protectAll(_ on: Bool) async {
        await MainActor.run {
            let members = sheet.members
            guard !sheet.holdsProtectingAll(members) else { return }
            sheet.protectAll(on, members)
        }
    }

    /// 削除 on a row's swipe: asked first.
    public func delete(_ id: String) async {
        await MainActor.run {
            guard let title = member(id), sheet.swipe(for: title) == .delete, !sheet.holds(title) else { return }
            sheet.delete(title)
        }
    }

    /// 保護解除 on a protected row's swipe.
    public func unprotect(_ id: String) async {
        await MainActor.run {
            guard let title = member(id), sheet.swipe(for: title) == .unprotect, !sheet.holds(title) else { return }
            sheet.unprotect(title)
        }
    }

    /// The button of the question shown with `key` that does something, and the question closed with it.
    public func act(_ key: String) async {
        await MainActor.run {
            let members = sheet.members, chosen = sheet.chosen(among: members)
            guard let asked = sheet.ask(among: members), Self.key(asked, chosen) == key,
                  !sheet.holdsTheAction(for: asked, chosen: chosen) else { return }
            sheet.act(on: asked, chosen: chosen)
            sheet.askClosed()
        }
    }

    /// The question or the answer shown with `key` closed.
    public func closeAsked(_ key: String) async {
        await MainActor.run {
            let members = sheet.members
            guard let asked = sheet.ask(among: members), Self.key(asked, sheet.chosen(among: members)) == key else { return }
            sheet.askClosed()
        }
    }

    /// The sheet of one of the programme's recordings, over the page, while the programme has it.
    public func open(_ id: String) async -> TitleSheetWindow? {
        await MainActor.run {
            member(id).map { TitleSheetWindow(TitleSheetState(title: $0, model: model), model: model) }
        }
    }

    @MainActor
    private func member(_ id: String) -> RecordedTitle? {
        sheet.members.first { $0.listKey == id }
    }

    /// What tells one question or answer from another: for the bulk delete, the rows it would take as well, so that
    /// a press is for the selection it was shown with.
    static func key(_ asked: GroupSheetState.Ask, _ chosen: [RecordedTitle]) -> String {
        switch asked {
        case .bulk: "bulk-" + chosen.map(\.listKey).joined(separator: ",")
        case .one(let title): "one-\(title.listKey)"
        case .failed(let said): "failed-\(said)"
        case .told(let said): "told-\(said)"
        }
    }

    @MainActor
    private static func screen(_ sheet: GroupSheetState, _ gone: LetGo, _ model: AppModel) -> GroupScreen {
        let members = sheet.members, chosen = sheet.chosen(among: members)
        let ask = sheet.ask(among: members)
        let asked = ask.map { asked in
            let action = sheet.actionLabel(for: asked, chosen: chosen)
            return Asked(key: key(asked, chosen), title: sheet.askTitle(asked, chosen: chosen),
                         message: sheet.message(for: asked, chosen: chosen), action: action?.label ?? "",
                         destructive: action?.destructive ?? false, closing: sheet.closingLabel(for: asked))
        }
        return GroupScreen(
            name: sheet.group.name, selecting: sheet.selecting, selectLabel: sheet.selectLabel,
            selectHeld: members.isEmpty, protectAllHeld: sheet.holdsProtectingAll(members),
            rows: members.map { title in
                GroupMember(row: RecordingsWindow.row(title, model, swipe: .some(sheet.swipe(for: title)),
                                                      held: sheet.holds(title)),
                            selected: sheet.isSelected(title), wouldBeDeleted: sheet.wouldBeDeleted(title))
            },
            count: GroupSheetState.countLine(chosen), offersActions: sheet.offersActions(on: chosen),
            deleteLabel: GroupSheetState.deleteLabel(chosen), actionsHeld: sheet.holdsActions(on: chosen),
            hasAsked: asked != nil,
            asked: asked ?? Asked(key: "", title: "", message: "", action: "", destructive: false, closing: ""),
            actionHeld: ask.map { sheet.holdsTheAction(for: $0, chosen: chosen) } ?? false,
            asking: sheet.asking, done: gone.happened)
    }
}

// MARK: - the duplicates

/// The recordings that look like copies of one broadcast (`DuplicatesView`).
public struct DuplicatesScreen: Sendable {
    /// With no sets to show (`hasSets` false): what is said in their place, and the scan it offers.
    public var hasSets: Bool
    public var prompt: Said
    public var scanLabel: String
    public var scanHeld: Bool
    /// Over the sets: what a tick does. Then, where some candidates could not be compared, that they were not, with
    /// もう一度調べる under it.
    public var explanation: String
    public var unread: String
    public var scanAgainHeld: Bool
    public var sets: [CopySet]
    /// `選択した 2 件を削除（3.4 GB）` at the foot while anything is ticked; empty with nothing ticked.
    public var deleteLabel: String
    public var deleteHeld: Bool
    /// The delete's question, or the answer that names a set that would lose every copy.
    public var hasAsked: Bool
    public var asked: Asked
    public var actionHeld: Bool
}

public struct CopySet: Sendable {
    public var id: String
    public var title: String
    /// `2 本 · 3.4 GB · 番組内容も一致`.
    public var details: String
    public var copies: [Copy]
}

/// One copy: whether it stays (`keeping`, and 残す or 削除 beside it), its tick -- grey where the recorder would not
/// part with it, held then and while a job runs -- why it is kept or not, and what it is.
public struct Copy: Sendable {
    public var id: String
    public var keeping: Bool
    public var mark: String
    public var deletable: Bool
    public var tickHeld: Bool
    public var tickLabel: String
    public var reason: String
    public var protected: Bool
    public var recorded: String
    public var details: String
}

public final class DuplicatesWindow: Sendable {
    let model: AppModel
    let state: DuplicatesState
    private let shown: Watched<DuplicatesScreen>

    @MainActor
    init(_ state: DuplicatesState, model: AppModel) {
        self.state = state
        self.model = model
        shown = Watched { DuplicatesWindow.screen(state, model) }
    }

    public func read() async -> DuplicatesScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// 検出を開始, or もう一度調べる.
    public func scan() async {
        await MainActor.run {
            guard model.duplicates.isEmpty ? !state.holdsTheScan : !state.holdsScanningAgain else { return }
            state.scan()
        }
    }

    /// The tick of the copy with `id` (`RecordedTitle.id`).
    public func toggle(_ id: String) async {
        await MainActor.run {
            guard let copy = copy(id), !state.holdsTheTick(copy) else { return }
            state.toggle(copy)
        }
    }

    /// The delete at the foot: asked first.
    public func delete() async {
        await MainActor.run {
            guard state.deleteLabel != nil, !state.holdsDeleting else { return }
            state.delete()
        }
    }

    /// N 件を削除する, under the question shown with `key`, and the question closed with it.
    public func act(_ key: String) async {
        await MainActor.run {
            guard state.confirming, Self.key(state) == key, state.actionLabel != nil, !state.holdsTheAction else { return }
            state.act()
            state.confirming = false
        }
    }

    /// The question or the answer shown with `key` closed.
    public func closeAsked(_ key: String) async {
        await MainActor.run {
            guard state.confirming, Self.key(state) == key else { return }
            state.confirming = false
        }
    }

    /// The sheet of the copy with `id`, while a set has it.
    public func open(_ id: String) async -> TitleSheetWindow? {
        await MainActor.run {
            copy(id).map { TitleSheetWindow(TitleSheetState(title: $0, model: model), model: model) }
        }
    }

    @MainActor
    private func copy(_ id: String) -> RecordedTitle? {
        model.duplicates.flatMap(\.items).first { $0.id == id }
    }

    /// What tells the question from the next: what it would delete, or the sets it names.
    @MainActor
    static func key(_ state: DuplicatesState) -> String {
        state.emptied.isEmpty ? "delete-" + state.chosen.map(\.id).joined(separator: ",")
            : "emptied-" + state.emptied.map(\.id).joined(separator: ",")
    }

    @MainActor
    private static func screen(_ state: DuplicatesState, _ model: AppModel) -> DuplicatesScreen {
        let none = Asked(key: "", title: "", message: "", action: "", destructive: false, closing: "")
        return DuplicatesScreen(
            hasSets: !model.duplicates.isEmpty, prompt: Said(state.promptTitle, state.promptDetail),
            scanLabel: state.scanLabel, scanHeld: state.holdsTheScan, explanation: DuplicatesState.explanation,
            unread: state.unreadLine ?? "", scanAgainHeld: state.holdsScanningAgain,
            sets: model.duplicates.map { set in
                CopySet(id: set.id, title: set.title, details: state.details(of: set), copies: set.items.map { copy in
                    Copy(id: copy.id, keeping: state.keeps(copy), mark: state.mark(copy), deletable: state.deletable(copy),
                         tickHeld: state.holdsTheTick(copy), tickLabel: state.tickLabel(copy),
                         reason: state.reason(copy, in: set), protected: copy.protected,
                         recorded: Format.dateTime.string(from: copy.start),
                         details: state.details(of: copy).joined(separator: " · "))
                })
            },
            deleteLabel: state.deleteLabel ?? "", deleteHeld: state.holdsDeleting,
            hasAsked: state.confirming,
            asked: !state.confirming ? none
                : Asked(key: key(state), title: state.askTitle, message: state.askMessage,
                        action: state.actionLabel ?? "", destructive: true, closing: state.closingLabel),
            actionHeld: state.holdsTheAction)
    }
}
