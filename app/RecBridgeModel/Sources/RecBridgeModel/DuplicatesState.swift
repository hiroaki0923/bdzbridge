import Foundation
import Observation
import RecorderKit

/// The recordings that look like copies of one broadcast, as the reader works them: the scan and what is said
/// before and after it, the ticks, and the delete of what is ticked with its question. A tick deletes, and whatever
/// is left unticked is marked as kept: the mark follows the ticks rather than the suggestion, so that it can never
/// name a copy that is about to go. The view lays it out; the sets and the ticks themselves are the model's
/// (`duplicates`, `duplicatePicks`).
@MainActor
@Observable
public final class DuplicatesState {
    @ObservationIgnored private let model: AppModel

    /// Whether the delete's question is up.
    public var confirming = false

    public init(model: AppModel) {
        self.model = model
    }

    /// What a delete would take: the ticked copies the recorder will part with.
    public var chosen: [RecordedTitle] {
        model.duplicates.flatMap(\.items).filter { Duplicates.deletable($0) && model.duplicatePicks.contains($0.id) }
    }

    /// Sets with every copy ticked. Nothing is deleted while there are any: see `Duplicates.emptied`.
    public var emptied: [DuplicateSet] {
        Duplicates.emptied(model.duplicates, picked: model.duplicatePicks)
    }

    // MARK: - with no sets to show

    /// Whether a scan has looked: not one the recorder stopped (`AppModel.scannedForDuplicates`).
    private var scanned: Bool { model.scannedForDuplicates }

    public var promptTitle: String {
        !scanned ? "重複した録画を探す"
            : model.unreadDuplicates > 0 ? "調べた範囲に重複はありませんでした" : "重複はありませんでした"
    }

    public var promptDetail: String {
        if scanned, model.unreadDuplicates > 0 { return unread }
        return "タイトルと長さが同じ録画について、番組内容をレコーダーから取得して照合します。"
            + "1 件ずつ取得するため、初回は時間がかかります。"
    }

    public var scanLabel: String { scanned ? "もう一度調べる" : "検出を開始" }

    /// What starts a run is held while one is under way, and while the recorder works or connects
    /// (`AppModel.canStartARun`): the scan here and in the list, the delete at the foot and its confirm. The first
    /// scan, with nothing to look through as well.
    public var holdsTheScan: Bool { !model.canStartARun || model.titles.isEmpty }

    public func scan() {
        model.startDuplicateScan()
    }

    // MARK: - the sets

    /// Over the sets: what a tick does, and which ticks the scan put there.
    public static let explanation = "チェックを付けたものを削除し、チェックの無いものは残します。番組内容も同じ組では、"
        + "先に放送されたもの（保護中や視聴途中のものがあればそちら）を残して、ほかにチェックを付けています。"
        + "説明文が毎回同じ番組の組と、内容を確かめられない組にはチェックを付けていません。"

    /// Candidates left out because their text has not been read yet: the scan was stopped, or the recorder could
    /// not give it. Scanning again reads only those. Nil with none.
    public var unreadLine: String? { model.unreadDuplicates > 0 ? unread : nil }

    private var unread: String {
        "番組内容をまだ取得できていない録画が \(model.unreadDuplicates) 件あり、比べていません。"
    }

    /// もう一度調べる, among the sets.
    public var holdsScanningAgain: Bool { !model.canStartARun }

    /// Under a set's title: how many copies, how big, and how sure the match is.
    public func details(of set: DuplicateSet) -> String {
        "\(set.items.count) 本 · \(Format.gigabytes(set.sizeGB)) · \(set.confidence.label)"
    }

    // MARK: - a copy

    /// Whether the recorder would part with the copy at all: its tick is grey where it would not.
    public func deletable(_ title: RecordedTitle) -> Bool { Duplicates.deletable(title) }

    /// Whether the copy stays: unticked, or one the recorder would refuse to delete.
    public func keeps(_ title: RecordedTitle) -> Bool {
        !(Duplicates.deletable(title) && model.duplicatePicks.contains(title.id))
    }

    /// 残す or 削除, beside the copy.
    public func mark(_ title: RecordedTitle) -> String { keeps(title) ? "残す" : "削除" }

    /// The tick tapped.
    public func toggle(_ title: RecordedTitle) {
        if model.duplicatePicks.contains(title.id) {
            model.duplicatePicks.remove(title.id)
        } else {
            model.duplicatePicks.insert(title.id)
        }
    }

    /// The tick is held where the recorder would refuse to delete the copy. And while a job runs the ticks stay as
    /// they are: a delete is working from them, and a scan builds the sets again when it ends. Not held by the
    /// recorder's other work, as what starts a run is: a tick sends nothing.
    public func holdsTheTick(_ title: RecordedTitle) -> Bool { !Duplicates.deletable(title) || model.jobRunning }

    /// What the tick is read out as: what it does, rather than the name of a circle. Worded as a choice: a double
    /// tap only marks the recording for the delete at the foot of the screen.
    public func tickLabel(_ title: RecordedTitle) -> String {
        "\(Format.dateTime.string(from: title.start))の録画を削除する対象に選ぶ"
    }

    /// Why this copy is kept or not, as the scan gave it.
    public func reason(_ title: RecordedTitle, in set: DuplicateSet) -> String { set.reasons[title.id] ?? "" }

    /// The disk off the internal one, the channel, the length, the size, the mode and whether it has been watched:
    /// the parts of one line.
    public func details(of title: RecordedTitle) -> [String] {
        let channel = model.channelName(for: title)
        var parts = [model.diskShown(title), channel.isEmpty ? nil : channel].compactMap { $0 }
        parts.append(Format.duration(title.durationSec))
        if let size = Format.size(of: title) { parts.append(size) }
        if let quality = title.qualityName { parts.append(quality) }
        parts.append(title.watchState.label)
        return parts
    }

    // MARK: - the delete

    /// 選択した N 件を削除（X GB）, at the foot while anything is ticked; nil with nothing ticked.
    public var deleteLabel: String? {
        let chosen = chosen
        return chosen.isEmpty ? nil
            : "選択した \(Format.count(chosen.count)) 件を削除（\(Format.gigabytes(Gigabytes.of(chosen)))）"
    }

    public var holdsDeleting: Bool { !model.canStartARun }

    /// The delete at the foot: asked first.
    public func delete() {
        confirming = true
    }

    /// One alert for both, since two on the same view is not something SwiftUI promises to honour: the question,
    /// or, while a set would lose every copy, that it would.
    public var askTitle: String {
        emptied.isEmpty ? "重複した \(Format.count(chosen.count)) 件を削除しますか？" : "1 本も残らない組があります"
    }

    public var askMessage: String {
        guard emptied.isEmpty else { return emptiedMessage }
        let chosen = chosen
        return "合計 \(Format.gigabytes(Gigabytes.of(chosen)))。チェックの無いものは残ります。\n"
            + chosen.deletedForGood + "。"
    }

    /// Which sets would go entirely, by name, since the reader has to find them in the list to put it right.
    private var emptiedMessage: String {
        let emptied = emptied
        var names = emptied.prefix(3).map { "・\($0.title)" }
        if emptied.count > 3 { names.append("ほか \(emptied.count - 3) 組") }
        return "次の組はすべてにチェックが付いていて、削除すると 1 本も残りません。"
            + "残すものを選んで、チェックを外してください。\n\n" + names.joined(separator: "\n")
    }

    /// The button that deletes: none while a set would lose every copy.
    public var actionLabel: String? { emptied.isEmpty ? "\(Format.count(chosen.count)) 件を削除する" : nil }

    public var closingLabel: String { emptied.isEmpty ? "キャンセル" : "OK" }

    public var holdsTheAction: Bool { !model.canStartARun }

    /// N 件を削除する: the run over what is ticked now.
    public func act() {
        model.startBulk(.delete, ids: chosen.map(\.id))
    }
}
