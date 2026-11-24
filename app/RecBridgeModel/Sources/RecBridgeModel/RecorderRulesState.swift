import Foundation
import Observation
import RecorderKit

/// The recorder's own keyword conditions (おまかせ・まる録) as the reader works them: what is said over the list, the
/// delete a row's swipe asks for and its question, and what the one alert says. Made and removed from here, never
/// edited: a condition read over the LAN is missing the channel narrowing the recorder's own screen can set, and
/// writing it back would erase that. The screen lays it out and hands this what is swiped and pressed; the list is
/// the model's (`recorderRules`).
@MainActor
@Observable
public final class RecorderRulesState {
    @ObservationIgnored private let model: AppModel

    private var removing: RecorderRule?
    private var failure: String?

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: - what the screen says

    public static let title = "おまかせ・まる録"

    /// The + button's name for a screen reader: the title of the form it opens (`RecorderRuleSheetState.title`).
    public static let addLabel = RecorderRuleSheetState.title

    /// A row's swipe: the lists' word (`ListWords.deleteLabel`).
    public static let deleteLabel = ListWords.deleteLabel

    /// The title of the alert that says why a delete, or a registration from the form, was turned down.
    public static let failureTitle = "エラー"

    /// Under the conditions.
    public static let footer = "レコーダー本体が番組を自動で探して録画する条件です。アプリを閉じていても動作します。"
        + "対象チャンネルの指定はレコーダー本体でのみ設定でき、ここには表示されません。"

    /// Above the conditions, what the list is.
    public enum ListSays: Equatable, Sendable {
        /// The list could not be read: said even over a list read before, which is then what the recorder said last
        /// time rather than now.
        case failed(String)
        /// Read, and empty: only once the recorder has said so.
        case empty
        /// Not read yet, and nothing to show.
        case loading
        /// The conditions alone.
        case nothing
    }

    public var listSays: ListSays {
        if let failure = model.recorderRulesFailure { return .failed(failure.asABody) }
        guard model.recorderRules.isEmpty else { return .nothing }
        return model.recorderRulesLoaded ? .empty : .loading
    }

    public static let couldNotRead = "条件を読み込めませんでした"
    public static let noConditions = "条件が登録されていません"
    public static let loading = "読み込み中"

    /// What a condition's row says under its name, with the disk it records to where one is said.
    public func details(of rule: RecorderRule) -> String {
        rule.details(disk: model.diskShown(rule))
    }

    /// 条件を追加 is held while the app is not connected, or the recorder works.
    public var holdsAdding: Bool { !model.connected || model.isBusy(for: .recorder) }

    // MARK: - the question or the answer

    /// One alert for both, as elsewhere: two on one view is not something SwiftUI promises to honour.
    public enum Ask {
        case confirm(RecorderRule)
        case failed(String)
    }

    /// A failure wins: it is the answer to what was just asked.
    public var ask: Ask? {
        if let failure { return .failed(failure) }
        if let removing { return .confirm(removing) }
        return nil
    }

    public var askTitle: String {
        if case .failed = ask { return Self.failureTitle }
        return "この条件を削除しますか？"
    }

    public func message(for asked: Ask) -> String {
        switch asked {
        case .confirm(let rule): "「\(rule.name)」をレコーダーから削除します。本体で設定した対象チャンネルの指定も削除されます。"
        case .failed(let text): text.asABody
        }
    }

    public func actionLabel(for asked: Ask) -> (label: String, destructive: Bool)? {
        switch asked {
        case .confirm: (SheetWords.confirmDeleteLabel, true)
        case .failed: nil
        }
    }

    public func closingLabel(for asked: Ask) -> String {
        switch asked {
        case .confirm: SheetWords.cancelLabel
        case .failed: SheetWords.okLabel
        }
    }

    /// 削除する is held while the recorder works.
    public func holdsTheAction(for asked: Ask) -> Bool {
        switch asked {
        case .confirm: model.isBusy(for: .recorder)
        case .failed: false
        }
    }

    /// 削除する, under the question: of the condition it was asked about. Why it was not deleted is said in the same
    /// alert, once the question has closed; a delete that went through says nothing.
    public func act(on asked: Ask) {
        guard case .confirm(let rule) = asked else { return }
        Task { if case .notDone(let why) = await model.removeRecorderRule(rule) { failure = why } }
    }

    /// Lets go of whatever the alert was up for, as it closes.
    public func askClosed() {
        (removing, failure) = (nil, nil)
    }

    // MARK: - a row swiped

    /// 削除 on a row: asked first.
    public func delete(_ rule: RecorderRule) {
        removing = rule
    }

    /// A row's 削除 is held while the recorder works.
    public var holdsDeleting: Bool { model.isBusy(for: .recorder) }

    /// The condition picked for deletion is the last recorder's when its lists are let go of (`timesForgotten`).
    /// One being typed is nobody's yet, and stays.
    public func recordersListsLetGo() {
        removing = nil
    }
}

/// The form for a new condition, over what the recorder takes (`RecorderRuleDraft`), as the reader works it: the
/// words, the narrowing, the disk, and the registration with what it came to. The sheet lays it out.
@MainActor
@Observable
public final class RecorderRuleSheetState {
    @ObservationIgnored private let model: AppModel

    /// The condition as typed, starting at the mode the settings hold, which it does not write back (see
    /// `ProgramSheetState.quality`).
    public var draft: RecorderRuleDraft
    /// The disk the reader picked under 録画先, kept as picked, as on the programme's sheet
    /// (`ProgramSheetState.chosenDisk`): nil until a disk is picked, and the internal disk after one was refused for
    /// being no longer offered.
    public var chosenDisk: String?
    public private(set) var failure: String?
    /// Whether the registration is out: the sheet is held open until it is answered -- the wait for the recorder
    /// and for the USB slot among it -- so that what it came to is said here rather than lost with a closed sheet;
    /// and レコーダーに登録 is held from the press, before the recorder's line is up, so that a second press makes no
    /// second condition.
    public private(set) var asking = false
    /// The condition was registered: the sheet closes.
    public private(set) var done = false

    public init(model: AppModel) {
        self.model = model
        draft = RecorderRuleDraft(quality: DefaultQuality.current(in: model.defaults))
    }

    // MARK: - the words

    /// The form's title, and the name of the button that opens it (`RecorderRulesState.addLabel`).
    public static let title = "条件を追加"

    public func addKeyword() {
        if draft.mayAddKeyword { draft.keywords.append(.init()) }
    }

    /// A keyword row taken away by its button: there is none on the only one left.
    public func removeKeyword(_ id: RecorderRuleDraft.Word.ID) {
        guard draft.mayRemoveKeyword else { return }
        draft.keywords.removeAll { $0.id == id }
    }

    public func addExclusion() {
        if draft.mayAddExclusion { draft.excluded.append(.init()) }
    }

    public func removeExclusion(_ id: RecorderRuleDraft.Word.ID) {
        draft.excluded.removeAll { $0.id == id }
    }

    /// Under the keywords: why the condition cannot be sent yet, in place of the hint while there is a reason.
    public var keywordFooter: String {
        draft.problem?.asABody
            ?? "番組名や番組内容に含まれる言葉です。\(RecorderRuleDraft.keywordLimit) つまで登録できます。"
    }

    public static let excludedFooter =
        "この言葉を含む番組は録画しません。\(RecorderRuleDraft.excludedLimit) つまで登録できます。"

    // MARK: - the narrowing

    public var subGenres: [Int] { RecorderRuleDraft.subGenres(of: draft.genre) }

    public var broadcastingScopes: [RecorderRuleDraft.Choice] {
        RecorderRuleDraft.broadcastingScopes(guide: model.counts)
    }

    public static let narrowingFooter = "対象チャンネルの指定はレコーダー本体でのみ設定できます。条件の名前はレコーダーが自動で付けます。"

    // MARK: - the registration

    /// レコーダーに登録 is held while the condition cannot be sent, the recorder works, or the registration is out.
    public var holdsRegistering: Bool { draft.problem != nil || model.isBusy(for: .recorder) || asking }

    /// レコーダーに登録. Refused for a disk that cannot be had -- no longer offered, or not answered by the slot while
    /// it was waited for -- the sheet goes back to the internal disk, named, for the reader to send again or leave.
    public func register() {
        asking = true
        Task {
            defer { asking = false }
            let request = draft.request(to: chosenDisk)
            switch await model.addRecorderRule(request) {
            case .done:
                done = true
            case .notDone(let why):
                failure = why
                if model.diskCannotBeHad(request.destination) {
                    chosenDisk = RecorderDisk.internalID
                }
            }
        }
    }

    /// What a registration turned down is said as.
    public var failureMessage: String? { failure?.asABody }

    public func failureClosed() {
        failure = nil
    }
}
