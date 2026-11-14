import Foundation
import RecBridgeModel
import RecorderKit

// The recorder's own keyword conditions (おまかせ・まる録) as the iOS screen and its form lay them out, over the
// model's states of them (`RecorderRulesState`, `RecorderRuleSheetState`).

/// The conditions' page (`RecorderRulesScreen`).
public struct ConditionsScreen: Sendable {
    public var title: String
    /// Above the conditions: `failed` with why, `empty`, `loading`, or nothing; and what is said.
    public var listSays: String
    public var said: Said
    public var rows: [ConditionRow]
    /// Under them.
    public var footer: String
    /// 条件を追加 is held while the app is not connected or the recorder works, and a row's 削除 while it works.
    public var addHeld: Bool
    public var deleteHeld: Bool
    /// The question a row's delete asks, or why a delete was not done: one at a time (`hasAsked`).
    public var hasAsked: Bool
    public var asked: Asked
    public var actionHeld: Bool
    /// What the list is read again by: each time the app connects, as on iOS.
    public var loadKey: String
}

public struct ConditionRow: Sendable {
    public var id: String
    public var name: String
    /// The keywords, what is left out, the broadcasts, the times, the genre, the mode and the disk.
    public var details: String
}

public final class ConditionsWindow: Sendable {
    let model: AppModel
    let state: RecorderRulesState
    private let shown: Watched<ConditionsScreen>
    private let follows = Follows()

    @MainActor
    init(_ model: AppModel) {
        self.model = model
        let state = RecorderRulesState(model: model)
        self.state = state
        shown = Watched { ConditionsWindow.screen(state, model) }
        // As the iOS screen follows it with `onChange`, for as long as the page is open.
        follows.add(onChange(of: { model.timesForgotten }) { _ in state.recordersListsLetGo() })
    }

    public func read() async -> ConditionsScreen { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    /// The page has closed: nothing more is followed for it.
    public func closed() async {
        follows.end()
    }

    public func load() async {
        await model.loadRecorderRules()
    }

    /// Pulled down: the list read again, or a connect.
    public func pullDown() async {
        await model.refreshRecorderRules()
    }

    /// 削除 on the condition whose row has `id`, asked first; nothing while the recorder works, as the iOS swipe's
    /// button is held.
    public func delete(_ id: String) async {
        await MainActor.run {
            guard !state.holdsDeleting, let rule = model.recorderRules.first(where: { $0.id == id }) else { return }
            state.delete(rule)
        }
    }

    /// The button of the question shown with `key` that does something, and the question closed with it.
    public func act(_ key: String) async {
        await MainActor.run {
            guard let asked = state.ask, Self.key(asked) == key, !state.holdsTheAction(for: asked) else { return }
            state.act(on: asked)
            state.askClosed()
        }
    }

    /// The question or the answer shown with `key` closed.
    public func closeAsked(_ key: String) async {
        await MainActor.run {
            guard let asked = state.ask, Self.key(asked) == key else { return }
            state.askClosed()
        }
    }

    static func key(_ asked: RecorderRulesState.Ask) -> String {
        switch asked {
        case .confirm(let rule): "confirm-\(rule.id)"
        case .failed(let said): "failed-\(said)"
        }
    }

    /// The form for a new condition: a window of its own, ended as the form closes.
    public func newCondition() async -> ConditionFormWindow {
        await MainActor.run { ConditionFormWindow(RecorderRuleSheetState(model: model), model: model) }
    }

    @MainActor
    private static func screen(_ state: RecorderRulesState, _ model: AppModel) -> ConditionsScreen {
        var said = Said("")
        let says: String
        switch state.listSays {
        case .failed(let why):
            says = "failed"
            said = Said(RecorderRulesState.couldNotRead, why)
        case .empty:
            says = "empty"
            said = Said(RecorderRulesState.noConditions)
        case .loading:
            says = "loading"
            said = Said(RecorderRulesState.loading)
        case .nothing:
            says = ""
        }
        let asked = state.ask.map { asked in
            let action = state.actionLabel(for: asked)
            return Asked(key: key(asked), title: state.askTitle, message: state.message(for: asked),
                         action: action?.label ?? "", destructive: action?.destructive ?? false,
                         closing: state.closingLabel(for: asked))
        }
        return ConditionsScreen(
            title: RecorderRulesState.title, listSays: says, said: said,
            rows: model.recorderRules.map { ConditionRow(id: $0.id, name: $0.name, details: state.details(of: $0)) },
            footer: RecorderRulesState.footer, addHeld: state.holdsAdding, deleteHeld: state.holdsDeleting,
            hasAsked: asked != nil,
            asked: asked ?? Asked(key: "", title: "", message: "", action: "", destructive: false, closing: ""),
            actionHeld: state.ask.map(state.holdsTheAction) ?? false,
            loadKey: "\(model.connected && !model.offline)")
    }
}

/// The form for a new condition (`RecorderRuleSheet`).
public struct ConditionForm: Sendable {
    /// The rows, each by an id the form keeps for it, with the text as the model has it: what a field starts with.
    public var keywords: [WordRow]
    public var mayAddKeyword: Bool
    /// The only keyword row left has no button to take it away.
    public var mayRemoveKeyword: Bool
    /// Why the condition cannot be sent yet, in place of the hint while there is one.
    public var keywordFooter: String
    public var excluded: [WordRow]
    public var mayAddExclusion: Bool
    public var excludedFooter: String
    /// 検索方法, asked once there is more than one keyword.
    public var asksHowToCombine: Bool
    public var logics: [Labelled]
    public var logic: String
    /// ジャンル, `""` for 指定しない; サブジャンル, `""` for すべて, offered only for a genre that has them.
    public var genres: [Labelled]
    public var genre: String
    public var subGenres: [Labelled]
    public var subGenre: String
    public var scopes: [Labelled]
    public var scope: String
    public var times: [Labelled]
    public var time: String
    public var qualities: [Labelled]
    public var quality: String
    /// 録画先: a choice while a USB disk that takes recordings is known; the disk picked as a value once it has gone;
    /// nothing in a home with no USB disk.
    public var disks: [Labelled]
    public var disk: String
    public var diskAlone: String
    public var narrowingFooter: String
    /// レコーダーに登録 is held while the condition cannot be sent, the recorder works, or the registration is out;
    /// the form is held whole while it is out (`asking`).
    public var registerHeld: Bool
    public var asking: Bool
    /// What a registration turned down is said as, or nothing.
    public var failure: String
    /// The condition was registered: the form closes.
    public var done: Bool
}

public struct WordRow: Sendable {
    public var id: String
    public var text: String
}

public final class ConditionFormWindow: Sendable {
    let model: AppModel
    let sheet: RecorderRuleSheetState
    private let shown: Watched<ConditionForm>
    private let follows = Follows()

    @MainActor
    init(_ sheet: RecorderRuleSheetState, model: AppModel) {
        self.sheet = sheet
        self.model = model
        shown = Watched { ConditionFormWindow.form(sheet, model) }
    }

    public func read() async -> ConditionForm { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    public func closed() async {
        follows.end()
    }

    // Nothing is changed while the registration is out, as the iOS form is held whole then.

    /// What is typed into the keyword row with `id`.
    public func typeKeyword(_ id: String, _ text: String) async {
        await edit { sheet in
            if let index = sheet.draft.keywords.firstIndex(where: { $0.id.uuidString == id }) {
                sheet.draft.keywords[index].text = text
            }
        }
    }

    public func typeExclusion(_ id: String, _ text: String) async {
        await edit { sheet in
            if let index = sheet.draft.excluded.firstIndex(where: { $0.id.uuidString == id }) {
                sheet.draft.excluded[index].text = text
            }
        }
    }

    public func addKeyword() async { await edit { $0.addKeyword() } }
    public func addExclusion() async { await edit { $0.addExclusion() } }

    public func removeKeyword(_ id: String) async {
        await edit { sheet in sheet.draft.keywords.first { $0.id.uuidString == id }.map { sheet.removeKeyword($0.id) } }
    }

    public func removeExclusion(_ id: String) async {
        await edit { sheet in sheet.draft.excluded.first { $0.id.uuidString == id }.map { sheet.removeExclusion($0.id) } }
    }

    public func chooseLogic(_ code: String) async { await edit { $0.draft.logic = code } }
    public func chooseGenre(_ code: String) async { await edit { $0.draft.genre = Int(code) } }
    public func chooseSubGenre(_ code: String) async { await edit { $0.draft.subGenre = Int(code) } }
    public func chooseScope(_ code: String) async { await edit { $0.draft.broadcastingScope = code } }
    public func chooseTime(_ code: String) async { await edit { $0.draft.timeScope = code } }
    public func chooseQuality(_ code: String) async { await edit { $0.draft.quality = code } }
    public func chooseDisk(_ code: String) async { await edit { $0.chosenDisk = code } }

    /// レコーダーに登録, while it is not held.
    public func register() async {
        await MainActor.run { if !sheet.holdsRegistering { sheet.register() } }
    }

    /// The answer of a registration turned down closed.
    public func failureClosed() async {
        await MainActor.run { sheet.failureClosed() }
    }

    private func edit(_ change: @escaping @MainActor @Sendable (RecorderRuleSheetState) -> Void) async {
        let sheet = sheet
        await MainActor.run { if !sheet.asking { change(sheet) } }
    }

    @MainActor
    private static func form(_ sheet: RecorderRuleSheetState, _ model: AppModel) -> ConditionForm {
        let draft = sheet.draft
        let offered = model.diskChoices
        return ConditionForm(
            keywords: draft.keywords.map { WordRow(id: $0.id.uuidString, text: $0.text) },
            mayAddKeyword: draft.mayAddKeyword, mayRemoveKeyword: draft.mayRemoveKeyword,
            keywordFooter: sheet.keywordFooter,
            excluded: draft.excluded.map { WordRow(id: $0.id.uuidString, text: $0.text) },
            mayAddExclusion: draft.mayAddExclusion, excludedFooter: RecorderRuleSheetState.excludedFooter,
            asksHowToCombine: draft.asksHowToCombine,
            logics: RecorderRuleDraft.logics.map { Labelled(code: $0.code, label: $0.label) }, logic: draft.logic,
            genres: [Labelled(code: "", label: "指定しない")]
                + RecorderRuleDraft.genres.map { Labelled(code: "\($0)", label: Codes.genreLabel[$0] ?? "") },
            genre: draft.genre.map { "\($0)" } ?? "",
            subGenres: sheet.subGenres.isEmpty ? []
                : [Labelled(code: "", label: "すべて")] + sheet.subGenres.map {
                    Labelled(code: "\($0)", label: Codes.subGenre(level1: draft.genre, level2: $0) ?? "")
                },
            subGenre: draft.subGenre.map { "\($0)" } ?? "",
            scopes: sheet.broadcastingScopes.map { Labelled(code: $0.code, label: $0.label) },
            scope: draft.broadcastingScope,
            times: RecorderRuleDraft.timeScopes.map { Labelled(code: $0.code, label: $0.label) }, time: draft.timeScope,
            qualities: RecorderDriver.recordsIn.map { Labelled(code: $0, label: Codes.qualityLabel[$0] ?? $0) },
            quality: draft.quality,
            disks: offered.map { Labelled(code: $0.destination, label: RecorderDisk.label($0.destination, named: $0.name)) },
            disk: model.diskOffered(sheet.chosenDisk),
            diskAlone: offered.isEmpty ? sheet.chosenDisk.map(model.diskLabel) ?? "" : "",
            narrowingFooter: RecorderRuleSheetState.narrowingFooter,
            registerHeld: sheet.holdsRegistering, asking: sheet.asking, failure: sheet.failureMessage ?? "",
            done: sheet.done)
    }
}
