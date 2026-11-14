import Foundation
import RecorderKit

/// What a screen says when it has nothing to list, and why, chosen here where a test can hold it: the screens draw
/// what is chosen, with their own icons, and the platform's own words where there are some (the way to the local
/// network switch).
extension AppModel {
    /// A title and, where there is one, what is said under it.
    public struct ScreenSays: Equatable, Sendable {
        public let title: String
        public let detail: String?

        public init(_ title: String, _ detail: String? = nil) {
            self.title = title
            self.detail = detail
        }
    }

    // MARK: - no recorder to talk to

    /// What to say when there is no recorder to talk to, in the situations that need different words: nothing has
    /// been set up yet, the app working on one, local network privacy in the way, or a recorder set up and not
    /// answering -- asleep, or the phone away from home. Sending someone to correct an address that is already
    /// right is worse than saying nothing, which is why looking for the recorder again is offered below 再接続 and
    /// not instead of it.
    public enum NoRecorderSays: Equatable, Sendable {
        /// Nothing has been set up yet: what to do is to look for one.
        case notAdded
        /// The app is working on it, under the recorder's line: not a failure, and not to read as one. The
        /// recorder's lines only: the television's work is no waking of the recorder.
        case working(String)
        /// Local network privacy is in the way: checking the power and the Wi-Fi would change nothing here.
        case blocked
        /// A recorder set up and not answering, with what went wrong when the app knows, since this is where the
        /// guide says it now: an address that is not one, or a device there that is not a recorder, is not put
        /// right by checking the power. `phones`: what went wrong is the phone's own cache, which is no failure to
        /// reach the recorder, and is titled as the guide tab titles it.
        case notReached(why: String?, phones: Bool)
    }

    public var noRecorderSays: NoRecorderSays {
        if host.isEmpty { return .notAdded }
        if let busy = recorderBusy { return .working(busy) }
        if connectBlocked { return .blocked }
        let why = whyNothingToShow
        return .notReached(why: why, phones: why != nil && why == phoneProblem)
    }

    /// The words of each case but the blocked one, whose are the platform's.
    public static let notAdded = ScreenSays("レコーダーが追加されていません", "同じ Wi-Fi 上のレコーダーを探して追加してください")
    public static let wakingDetail = "レコーダーが起きるまで数秒かかります"
    public static func notReached(why: String?, phones: Bool) -> ScreenSays {
        ScreenSays(phones ? "エラー" : "レコーダーに接続できません",
                   why ?? "レコーダーの電源と、同じネットワークに接続されているかを確かめてください")
    }

    // MARK: - the guide

    /// What the guide's screen shows in place of its programmes, if anything.
    public enum GuideShows: Equatable, Sendable {
        /// Nothing for the day on screen, and no recorder to fetch it from: what is wrong, and 再接続 and
        /// レコーダーを探す (`noRecorderSays`).
        case noRecorder
        /// The guide is on its way. The first run lands here as soon as the recorder answers: saying there is
        /// nothing for the day would read as though the download had come to nothing.
        case fetching
        /// Nothing to show for the day, and why (`guideEmpty(narrowed:)`).
        case empty
        /// The day's programmes.
        case programmes
    }

    /// What the guide's screen shows, in the list (`grid` false) or the grid. The grid shows every channel whatever
    /// the list is narrowed to, so it is judged by all of the day's programmes.
    public func guideShows(grid: Bool) -> GuideShows {
        let nothing = (grid ? programs : filteredPrograms).isEmpty
        guard nothing else { return .programmes }
        let byChoice = guideIsEmptyByChoice(narrowed: !grid && serviceFilter != nil)
        if guideSource == .recorder, !connected, !byChoice { return .noRecorder }
        if !byChoice, guideOnItsWay { return .fetching }
        return .empty
    }

    public static let fetchingTheGuide = ScreenSays("番組表を取得しています", "初回は少し時間がかかります")

    /// Nothing on screen because of what the reader chose rather than what the cache holds: every channel hidden,
    /// or the list narrowed to a channel with nothing that day. Said ahead of anything about the recorder, which is
    /// not the reason and could not put it right.
    func guideIsEmptyByChoice(narrowed: Bool) -> Bool {
        everyChannelHidden || (narrowed && !programs.isEmpty)
    }

    /// What the guide says when there is nothing to show for the day, in the list and in the grid alike. It says
    /// why, since most of the reasons are not put right by a refresh: every channel hidden, the list narrowed to a
    /// channel with nothing that day, a recorder with no guide to give. Not for a recorder that cannot be reached,
    /// nor for a guide on its way, which the screen says before this (`guideShows(grid:)`).
    public enum GuideEmpty: Equatable, Sendable {
        /// Every channel of the type hidden: the way to the channel settings.
        case everyChannelHidden
        /// The list narrowed to a channel with nothing that day: the way back to every channel.
        case narrowedToNothing
        /// The demo's guide is what the line-up invented, and a refresh would fetch the same again.
        case demo
        /// A recorder that gives no guide.
        case notCapable
        /// What went wrong, in the words of whoever knows.
        case cannotShow(String)
        /// The other types came in and this one did not: the recorder had no file for it, which is what a model
        /// without that kind of tuner answers.
        case typeNotAnswered
        /// Nothing fetched yet.
        case notFetched
        /// A guide, with nothing on this day.
        case nothingThatDay
    }

    /// Why the guide has nothing for the day: `narrowed` is the list narrowed to one channel, which the grid never is.
    public func guideEmpty(narrowed: Bool) -> GuideEmpty {
        let cached = counts[broadcasting]?.programs ?? 0
        if everyChannelHidden { return .everyChannelHidden }
        if narrowed, !programs.isEmpty { return .narrowedToNothing }
        if demo { return .demo }
        if info?.epgCapable == false { return .notCapable }
        if let problem = whyNothingToShow { return .cannotShow(problem) }
        if cached == 0, counts.values.contains(where: { $0.programs > 0 }) { return .typeNotAnswered }
        if cached == 0 { return .notFetched }
        return .nothingThatDay
    }

    /// The words of each, for the broadcasting type on screen.
    public func says(_ empty: GuideEmpty) -> ScreenSays {
        let type = Codes.broadcastingInSentence(broadcasting)
        let refresh = "右上の更新ボタンでレコーダーから取得できます"
        switch empty {
        case .everyChannelHidden:
            return ScreenSays("\(type)の局をすべて非表示にしています", "表示する局を選ぶと、番組表に出てきます")
        case .narrowedToNothing:
            return ScreenSays("この日の\(channelName)の番組はありません")
        case .demo:
            let cached = counts[broadcasting]?.programs ?? 0
            return ScreenSays(cached == 0 ? "\(type)の番組表はありません" : "この日の番組表はありません",
                              DemoLineUp.guideCoverage)
        case .notCapable:
            return ScreenSays("このレコーダーは番組表に対応していません", "この機種からは番組表を取得できません")
        case .cannotShow(let problem):
            return ScreenSays("番組表を表示できません", problem)
        case .typeNotAnswered:
            return ScreenSays("\(type)の番組表はありません", "レコーダーが対応していない放送は空のままです。右上の更新ボタンで取得し直せます")
        case .notFetched:
            return ScreenSays("番組表をまだ取得していません", refresh)
        case .nothingThatDay:
            return ScreenSays("この日の番組表はありません", refresh)
        }
    }

    // MARK: - the reservations and the recordings

    /// The reservations tab shows what is wrong in place of its list only with nothing at all to show: away from
    /// home there is still what the recorder said last time, the television, and above all the queue, which is in
    /// use exactly then.
    public var reservationsHaveNoRecorder: Bool { !connected && allReservations.isEmpty && pending.isEmpty }

    /// The list is empty, with nothing waiting either: said on top of the list rather than in its place, so that
    /// pulling down still reloads.
    public var reservationsAreEmpty: Bool { shownReservations.isEmpty && pending.isEmpty }
    public static let noReservations = ScreenSays("予約はありません", "番組表から番組を選んで予約できます")

    /// The recordings tab shows what is wrong in place of its list with no recorder connected and nothing of the
    /// television's to show; and that the list is being read while the recorder is at it with none read yet.
    public var recordingsHaveNoRecorder: Bool { !connected && !tvHasSomethingToShow }
    public var recordingsAreLoading: Bool { recorderBusy != nil && allTitles.isEmpty }
    public static let loadingRecordings = ScreenSays("読み込み中", "レコーダーから録画一覧を取得しています")

    /// What an empty list of recordings says: that there is nothing, or, while a television's list may still be
    /// coming, that it is on its way.
    public var noRecordingsSays: ScreenSays {
        tvTitlesStillComing ? ScreenSays("読み込み中", TVDriver.titlesComingLine.asABody)
            : ScreenSays("録画された番組はありません")
    }
}
