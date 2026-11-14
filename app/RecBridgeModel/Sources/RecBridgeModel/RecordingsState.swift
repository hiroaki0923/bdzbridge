import Foundation
import Observation
import RecorderKit

/// The recordings' screen as the reader works it: which of its three views is on, what it says under its title, the
/// delete a row's swipe asks for and its question, a protected row's 保護解除, and what the one alert says. The
/// screen lays it out and hands this what is swiped and pressed; the list, its filters and its sort are the
/// model's (`shownTitles`, `titleGroups`).
@MainActor
@Observable
public final class RecordingsState {
    @ObservationIgnored private let model: AppModel

    /// The row swiped, by key rather than by value (`RecordedTitle.listKey`): the recording is read back out of
    /// the model when the question asks, so a delete can only ever be sent for a row the list still holds.
    private var removing: String?
    private var failure: String?
    /// What a delete that went through had to say: that the recording was deleted already.
    private var told: String?

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: - which view

    /// The screen's three views of the same recordings, as the screen keeps the reader's pick
    /// (`DefaultsKey.recordingsMode`): every recording, the recordings gathered into programmes, and the ones
    /// recorded more than once. Anything else kept there is the list.
    public enum Mode: String, CaseIterable, Sendable {
        case list, groups, dups

        public init(kept: String?) {
            self = kept.flatMap(Mode.init(rawValue:)) ?? .list
        }

        public var label: String {
            switch self {
            case .list: "一覧"
            case .groups: "まとめ"
            case .dups: "重複"
            }
        }
    }

    // MARK: - what the screen says

    /// The screen's title: the free space of the disk shown, which is worth a permanent place, or 録画 while it is
    /// not known.
    public var heading: String {
        model.shownFreeBytes.map { "残り \(Format.gigabytes($0, on: model.shownFreeDevice))" } ?? "録画"
    }

    /// Under the title: what the app is doing with a device, or what is being shown, since the filters live behind
    /// a menu.
    public func subtitle(in mode: Mode) -> String {
        if let busy = model.busy { return busy }
        if mode == .dups { return "\(model.duplicates.count) 組の重複" }
        let what = mode == .groups ? "\(model.titleGroups.count) 番組" : "\(model.shownTitles.count) 件"
        let disk = model.shownDestination.map(model.titleDestinationLabel)
        let genre = model.titleGenre.flatMap { Codes.genreLabel[$0] }
        return ([disk, genre].compactMap { $0 } + [what]).joined(separator: " · ")
    }

    /// Whether the list is narrowed or sorted otherwise than newest first, which the menu's icon marks.
    public var filtering: Bool {
        model.shownDestination != nil || model.titleGenre != nil || model.titleState != nil
            || model.titleSort != .newest
    }

    // MARK: - the question or the answer

    /// One alert does both jobs, because two on the same view is not something SwiftUI promises to honour.
    public enum Ask {
        case confirm(RecordedTitle)
        case failed(String)
        case told(String)
    }

    public var ask: Ask? {
        if let failure { return .failed(failure) }
        if let told { return .told(told) }
        if let key = removing, let title = model.allTitles.first(where: { $0.listKey == key }) {
            return .confirm(title)
        }
        return nil
    }

    public var askTitle: String {
        switch ask {
        case .failed: "エラー"
        case .told: "録画"
        case .confirm, nil: "この録画を削除しますか？"
        }
    }

    /// What the question or the answer says under its title.
    public func message(for asked: Ask) -> String {
        switch asked {
        case .confirm(let title): AppModel.deleteMessage(title)
        case .failed(let reason), .told(let reason): reason.asABody
        }
    }

    /// The button that does something, beside the one that closes: nil where there is none.
    public func actionLabel(for asked: Ask) -> (label: String, destructive: Bool)? {
        switch asked {
        case .confirm: ("削除する", true)
        case .failed, .told: nil
        }
    }

    /// The button that closes: OK for what only says, キャンセル for the question.
    public func closingLabel(for asked: Ask) -> String {
        switch asked {
        case .confirm: "キャンセル"
        case .failed, .told: "OK"
        }
    }

    /// 削除する is held while the device that holds the recording works, or a run walks its list.
    public func holdsTheAction(for asked: Ask) -> Bool {
        switch asked {
        case .confirm(let title): !model.canAlter(title)
        case .failed, .told: false
        }
    }

    /// 削除する, under the question: of the recording the question was asked about, as it was handed to the button.
    /// What it came to is said in the same alert, once the question has closed.
    public func act(on asked: Ask) {
        guard case .confirm(let title) = asked else { return }
        Task {
            switch await model.delete(title) {
            case .notDone(let why): failure = why
            case .done(let more): told = more
            }
        }
    }

    /// Lets go of whatever the alert was up for, as it closes.
    public func askClosed() {
        (removing, failure, told) = (nil, nil, nil)
    }

    // MARK: - a row swiped

    /// 削除 on a row: asked first -- this is the device's disk and there is no undo.
    public func delete(_ title: RecordedTitle) {
        removing = title.listKey
    }

    /// 保護解除 on a protected row, which has to happen before it can be deleted. Why it could not be done is said in
    /// the alert.
    public func unprotect(_ title: RecordedTitle) {
        Task {
            if case .notDone(let why) = await model.setProtected(title, false) { failure = why }
        }
    }

    /// A row's swipe is held while the device that holds the row works or a run is under way.
    public func holds(_ title: RecordedTitle) -> Bool { !model.canAlter(title) }

    /// The recording picked for deletion is the last recorder's when its lists are let go of (`timesForgotten`).
    public func recordersListsLetGo() {
        removing = nil
    }

    /// A television's rows go with its host (`tvTimesForgotten`), and a row of the other device's stays picked.
    public func televisionsListsLetGo() {
        if !model.allTitles.contains(where: { $0.listKey == removing }) { removing = nil }
    }
}

extension AppModel {
    /// What a recording's row offers under a swipe.
    public enum TitleSwipe: Sendable {
        /// 削除, asked first.
        case delete
        /// 保護解除: the device refuses to delete a protected recording, so that has to happen first.
        case unprotect
    }

    /// What `title`'s row offers under a swipe, by the delete's own door (`whyNot(deleting:)`): the delete where it
    /// would be let through, 保護解除 for a protected one, and nothing otherwise -- the device is writing to this
    /// one and refuses to delete it, and the row says 録画中, which is the answer to why there is no button; or its
    /// disk has left the slot, and the list is about to be read again.
    public func swipe(for title: RecordedTitle) -> TitleSwipe? {
        switch whyNot(deleting: title) {
        case nil: .delete
        case RecorderDriver.protectedCannotBeDeleted?: .unprotect
        default: nil
        }
    }
}
