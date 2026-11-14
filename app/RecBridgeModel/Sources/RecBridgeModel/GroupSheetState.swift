import Foundation
import Observation
import RecorderKit

/// One programme's recordings as the reader works them: the selection that bulk work needs, the runs it starts, a
/// row's own delete and 保護解除, and what the one alert says. The sheet lays it out and hands this what is tapped,
/// swiped and pressed.
///
/// The programme's recordings (`members`) and the ones ticked (`chosen`) are read once by the sheet each time it is
/// drawn and handed to what needs them: each read sorts every recording and picks this programme's out of them, and
/// every tick in the selection draws the sheet again.
@MainActor
@Observable
public final class GroupSheetState {
    @ObservationIgnored private let model: AppModel
    public let group: TitleGroup

    public private(set) var selecting = false
    /// The rows ticked, by key (`RecordedTitle.listKey`).
    public private(set) var selected: Set<String> = []
    private var confirmingDelete = false
    /// The row swiped, by key, read back out of the model when the question asks.
    private var removing: String?
    private var failure: String?
    /// What a single delete that went through had to say: that the recording was deleted already.
    private var told: String?
    /// Whether the sheet's own single delete, or a swipe's 保護解除, is out: the sheet is held open until it is
    /// answered, so that what it came to is said here rather than lost with a closed sheet, and the swipes and the
    /// delete's confirm are held, so that a second is not sent meanwhile.
    public private(set) var asking = false

    public init(group: TitleGroup, model: AppModel) {
        self.group = group
        self.model = model
    }

    /// The programme's recordings, through the screen's filters and in its order.
    public var members: [RecordedTitle] { model.members(of: group) }

    /// The recordings ticked, of those listed.
    public func chosen(among members: [RecordedTitle]) -> [RecordedTitle] {
        AppModel.chosenTitles(among: members, selected)
    }

    // MARK: - the question or the answer

    /// One alert for all three jobs. Two on a view is not something SwiftUI promises to honour, and this one has a
    /// bulk delete, a single delete and a failure to report.
    public enum Ask {
        case bulk
        case one(RecordedTitle)
        case failed(String)
        case told(String)
    }

    public func ask(among members: [RecordedTitle]) -> Ask? {
        if let failure { return .failed(failure) }
        if let told { return .told(told) }
        if let key = removing, let title = members.first(where: { $0.listKey == key }) { return .one(title) }
        return confirmingDelete ? .bulk : nil
    }

    public func askTitle(_ asked: Ask?, chosen: [RecordedTitle]) -> String {
        switch asked {
        case .bulk: "選択した \(chosen.count) 件を削除しますか？"
        case .failed: "エラー"
        case .told: "録画"
        case .one, nil: "この録画を削除しますか？"
        }
    }

    public func message(for asked: Ask, chosen: [RecordedTitle]) -> String {
        switch asked {
        case .bulk:
            "合計 \(Self.gigabytes(chosen))。保護された録画と録画中のものは削除されません。\n"
                + chosen.deletedForGood.asABody
        case .one(let title): AppModel.deleteMessage(title)
        case .failed(let reason), .told(let reason): reason.asABody
        }
    }

    /// The button that does something, beside the one that closes: nil where there is none.
    public func actionLabel(for asked: Ask, chosen: [RecordedTitle]) -> (label: String, destructive: Bool)? {
        switch asked {
        case .bulk: ("\(Format.count(chosen.count)) 件を削除する", true)
        case .one: ("削除する", true)
        case .failed, .told: nil
        }
    }

    public func closingLabel(for asked: Ask) -> String {
        switch asked {
        case .bulk, .one: "キャンセル"
        case .failed, .told: "OK"
        }
    }

    /// What starts a run is held while one is under way, and while the recorder works or connects, where a
    /// recorder's row is among them (`AppModel.canStartARun(over:)`); a single delete, while its device works or a
    /// request of this sheet's own is out.
    public func holdsTheAction(for asked: Ask, chosen: [RecordedTitle]) -> Bool {
        switch asked {
        case .bulk: !model.canStartARun(over: chosen)
        case .one(let title): !model.canAlter(title) || asking
        case .failed, .told: false
        }
    }

    /// The button that does something. The bulk delete sends what the delete's own door would let through, and the
    /// selection stays when the press was held off: nothing was started.
    public func act(on asked: Ask, chosen: [RecordedTitle]) {
        switch asked {
        case .bulk:
            let deletable = chosen.filter { model.whyNot(deleting: $0) == nil }.map(\.id)
            if model.startBulk(.delete, ids: deletable) { endSelecting() }
        case .one(let title):
            ask { await self.model.delete(title) }
        case .failed, .told:
            break
        }
    }

    /// Lets go of whatever the alert was up for, as it closes.
    public func askClosed() {
        confirmingDelete = false
        (removing, failure, told) = (nil, nil, nil)
    }

    /// Asks `operation` with the sheet held until it is answered, and says what it came to in the alert.
    private func ask(_ operation: @escaping @MainActor () async -> Altered) {
        asking = true
        Task {
            let came = await operation()
            asking = false
            switch came {
            case .notDone(let why): failure = why
            case .done(let more): told = more
            }
        }
    }

    // MARK: - the selection

    /// 選択, and 完了 while picking.
    public var selectLabel: String { selecting ? "完了" : "選択" }

    /// 選択 or 完了: either way the ticks go.
    public func toggleSelecting() {
        selecting.toggle()
        selected = []
    }

    private func endSelecting() {
        selecting = false
        selected = []
    }

    public func isSelected(_ title: RecordedTitle) -> Bool { selected.contains(title.listKey) }

    /// A row tapped while picking.
    public func toggle(_ title: RecordedTitle) {
        if selected.contains(title.listKey) {
            selected.remove(title.listKey)
        } else {
            selected.insert(title.listKey)
        }
    }

    /// Whether a bulk delete would take the recording, by the delete's own door: the tick is grey where it would
    /// pass it over -- a protected one, and one still being recorded.
    public func wouldBeDeleted(_ title: RecordedTitle) -> Bool { model.whyNot(deleting: title) == nil }

    /// 削除できるものをすべて選択.
    public func selectWhatCanBeDeleted(among members: [RecordedTitle]) {
        selected = Set(members.filter { model.whyNot(deleting: $0) == nil }.map(\.listKey))
    }

    /// 選択解除.
    public func selectNothing() {
        selected = []
    }

    public static func countLine(_ chosen: [RecordedTitle]) -> String { "\(Format.count(chosen.count)) 件" }

    // MARK: - what the selection is asked

    /// The bar of what to do with the ticked rows is there while picking with something ticked.
    public func offersActions(on chosen: [RecordedTitle]) -> Bool { selecting && !chosen.isEmpty }

    public static func deleteLabel(_ chosen: [RecordedTitle]) -> String {
        "選択した \(Format.count(chosen.count)) 件を削除（\(gigabytes(chosen))）"
    }

    /// 選択した N 件を削除: asked first.
    public func deleteChosen() {
        confirmingDelete = true
    }

    /// 保護する or 保護を解除 over the ticked rows. The selection ends once the run has begun.
    public func protect(_ on: Bool, _ chosen: [RecordedTitle]) {
        guard model.startBulk(.protecting(on), ids: chosen.map(\.id)) else { return }
        endSelecting()
    }

    public func holdsActions(on chosen: [RecordedTitle]) -> Bool { !model.canStartARun(over: chosen) }

    /// この番組をすべて保護, or この番組の保護をすべて解除.
    public func protectAll(_ on: Bool, _ members: [RecordedTitle]) {
        model.startBulk(.protecting(on), ids: members.map(\.id))
    }

    public func holdsProtectingAll(_ members: [RecordedTitle]) -> Bool {
        !model.canStartARun(over: members) || members.isEmpty
    }

    // MARK: - a row swiped

    /// What a row offers under a swipe. Nothing while picking: a swipe there is how the reader scrolls a list of
    /// tick boxes.
    public func swipe(for title: RecordedTitle) -> AppModel.TitleSwipe? {
        selecting ? nil : model.swipe(for: title)
    }

    public func holds(_ title: RecordedTitle) -> Bool { !model.canAlter(title) || asking }

    /// 削除 on a row: asked first.
    public func delete(_ title: RecordedTitle) {
        removing = title.listKey
    }

    /// 保護解除 on a protected row, with the sheet held until it is answered.
    public func unprotect(_ title: RecordedTitle) {
        ask { await self.model.setProtected(title, false) }
    }

    private static func gigabytes(_ titles: [RecordedTitle]) -> String {
        Format.gigabytes(Gigabytes.of(titles))
    }
}

public extension TitleGroup {
    /// From the start of the first recording to the end of the last, which for one recording is when it was on. An
    /// end on the day the span starts is said by its time alone.
    var span: String {
        let sameDay = Format.day.string(from: earliest) == Format.day.string(from: lastEnd)
        let end = (sameDay ? Format.time : Format.dateTime).string(from: lastEnd)
        return "\(Format.dateTime.string(from: earliest)) 〜 \(end)"
    }

    /// How many and how big, and how many are new or protected where any are: the parts of one line.
    var countSaid: String { "\(Format.count(count)) 件" }
    var sizeSaid: String { Format.gigabytes(sizeGB) }
    var newSaid: String? { newCount > 0 ? "未視聴 \(Format.count(newCount))" : nil }
    var protectedSaid: String? { protectedCount > 0 ? "🔒 \(Format.count(protectedCount))" : nil }
}

public extension BulkJob {
    /// What the bar says of a job under way: `削除中 3 / 12`.
    var progressLine: String { "\(verb)中 \(Format.count(done)) / \(Format.count(total))" }
    /// Beside it, once 中止 was pressed and the recording in hand is being finished.
    static let stopping = "中止します…"
    /// Under a job under way, since nothing can say it once the reader has gone: the job finishes the recording it
    /// is on and waits there.
    static let pausesAway = "アプリを離れると一時停止し、戻ると再開します"

    /// Why the device stopped the run, or kept it from beginning, in the sentence the driver handed back with the
    /// stop, once the job is over. Silence has none: what the job's outcome says says it.
    var whyItStopped: String? { finished ? stopped?.said?.asABody : nil }

    /// The first few recordings a finished job passed over, each with why (`Skip.said`).
    var passedOver: [Skip] { finished ? Array(skipped.prefix(3)) : [] }
}

public extension BulkJob.Skip {
    /// Why the job passed the recording over, as a line of the bar.
    var said: String { "・" + reason.asABody }
}
