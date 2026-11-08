import Foundation
import Observation
import RecorderKit

/// One box that searches the three lists the app holds: programmes still to come, what is set to record, and what
/// is already recorded. The guide half reads the on-device cache, so it works away from home; the other two read
/// what the recorder has said, which needs it to be reachable -- and, of what is set to record, what the television
/// has said as well. The screen lays it out and hands this what is typed and picked.
@MainActor
@Observable
public final class SearchState {
    @ObservationIgnored private let model: AppModel

    public enum Scope: String, CaseIterable, Identifiable, Sendable {
        case guide, reservations, recordings
        public var id: Self { self }

        public var label: String {
            switch self {
            case .guide: "番組表"
            case .reservations: "予約"
            case .recordings: "録画"
            }
        }

        public var prompt: String {
            switch self {
            case .guide: "番組名・出演者・番組内容"
            case .reservations: "予約した番組名"
            case .recordings: "録画した番組名"
            }
        }

        /// What the scope looks through. The reservations' names the television too where one is registered,
        /// since its reservations are among what is found.
        public func explanation(withTelevision: Bool) -> String {
            switch self {
            case .guide:
                "番組名、番組内容、出演者などの詳細に含まれる言葉で、今後 8 日分の番組を検索します。"
                    + "番組名に含まれるものから順に並びます。"
            case .reservations:
                (withTelevision ? "レコーダーとテレビ" : "レコーダー")
                    + "にある予約を番組名で検索します。おまかせ・まる録による予約も含みます。"
            case .recordings:
                (withTelevision ? "レコーダーとテレビ" : "レコーダー") + "に録画されている番組を番組名で検索します。"
            }
        }
    }

    public var query: String
    /// Coming back to the guide with other words than the list on screen answers: that list is not left up while
    /// the new one comes, as it is while typing, since nothing on screen would say it is the old one.
    public var scope: Scope {
        didSet { if scope != oldValue, scope == .guide, answered != query { guide = GuideSearchResults() } }
    }
    /// Whether the search field is in use. The scopes show only while it is, so before that the screen says what
    /// can be searched rather than what the chosen scope searches.
    public var searching = false
    public private(set) var guide = GuideSearchResults()
    /// The words `guide` is the answer to. While they differ from what is in the box the answer is on its way, and
    /// the old one is left up so that the list does not blink at every character typed.
    private var answered = ""

    /// A search, with `-searchFor ニュース` in the model's defaults filling the box at launch, which is how the
    /// results are checked without typing, and `-searchScope recordings` picking which of the three to search, the
    /// same way `-startTab` picks a tab.
    public init(model: AppModel) {
        self.model = model
        query = model.defaults.string(forKey: DefaultsKey.searchFor) ?? ""
        scope = Scope(rawValue: model.defaults.string(forKey: DefaultsKey.searchScope) ?? "") ?? .guide
    }

    // MARK: - what is found

    /// The same normalisation and the same words the cache search uses in SQL, so that what matches in one place
    /// matches in the others: full width and half width, upper and lower case, all the same, and every word
    /// separated by a space has to be there.
    private func matches(_ text: String) -> Bool { Search.matches(query, in: text) }

    /// Of both devices, as the reservations' own tab lists them.
    public var reservations: [Reservation] { model.allReservations.filter { matches($0.title) } }
    public var recordings: [RecordedTitle] { model.allTitles.filter { matches($0.title) } }

    /// Nothing to look for: an empty box, or spaces alone, which would otherwise match every reservation.
    public var blank: Bool { Search.terms(query).isEmpty }

    public var count: Int {
        guard !blank else { return 0 }
        switch scope {
        case .guide: return guide.hits.count
        case .reservations: return reservations.count
        case .recordings: return recordings.count
        }
    }

    /// What the screen shows.
    public enum Shows: Equatable, Sendable {
        /// Nothing typed and the field not in use: what can be searched.
        case invitation
        /// Nothing typed, the field in use: what the chosen scope searches, and how.
        case scopeExplained
        /// The guide's answer is still on its way and there is nothing from before to show meanwhile.
        case waiting
        /// Nothing found.
        case nothingFound
        case results
    }

    public var shows: Shows {
        if blank { return searching ? .scopeExplained : .invitation }
        if scope == .guide, answered != query, guide.hits.isEmpty { return .waiting }
        return count == 0 ? .nothingFound : .results
    }

    public static let invitation = AppModel.ScreenSays("検索", "番組表・予約・録画を検索できます。検索欄をタップすると、どれを検索するか選べます。")

    public var scopeExplained: AppModel.ScreenSays {
        AppModel.ScreenSays("\(scope.label)を検索", scope.explanation(withTelevision: model.tv != nil)
                                + "\nスペースで区切ると、すべての語を含むものに絞り込みます。"
                                + "全角と半角、大文字と小文字は区別しません。")
    }

    /// Under the screen's title, while something is found: the scope and how many, the guide's best matches being
    /// what it holds.
    public var countLine: String? {
        count > 0 ? "\(scope.label) \(count) 件\(scope == .guide && guide.more ? "以上" : "")" : nil
    }

    /// At the top of the guide's results, where it is read before the list is taken for everything there is: the
    /// best matches are what the list holds, so narrowing is the way to the rest.
    public var moreLine: String? {
        guide.more ? "\(guide.hits.count) 件以上あります。語を足して絞り込んでください" : nil
    }

    // MARK: - asking

    /// What the guide search is run again for: new words, or coming back to the guide from the other two.
    public struct GuideRequest: Equatable, Sendable {
        var query: String
        var scope: Scope
    }

    public var guideRequest: GuideRequest { GuideRequest(query: query, scope: scope) }

    /// Searches the guide for what is in the box, a moment after the last change: the screen cancels the one under
    /// way whenever the request changes, so the wait is the debounce. The guide is searched only while it is the
    /// scope.
    public func searchTheGuide() async {
        guard scope == .guide else { return }
        guard !blank else {
            guide = GuideSearchResults()
            answered = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let words = query
        let found = await model.search(words)
        guard !Task.isCancelled else { return }
        guide = found
        answered = words
    }

    /// What has the reservations and the recordings read: the scope turned to, and the app becoming connected.
    public struct ListsWanted: Equatable, Sendable {
        var scope: Scope
        var connected: Bool
    }

    public var listsWanted: ListsWanted { ListsWanted(scope: scope, connected: model.connected && !model.offline) }

    /// The other two lists are searched where they already are, in memory, so they have to be there. Whichever
    /// screen fetched them first pays for it; this one only asks, and asks again when the app becomes connected, as
    /// their own screens do, since the lists go when another recorder answers.
    public func readTheRecordersList() async {
        switch scope {
        case .guide: break
        case .reservations: await model.loadReservations()
        case .recordings: await model.loadTitles()
        }
    }

    /// The television's, apart from the recorder's, as on their own tabs: that one asks the recorder, and is not to
    /// run again for anything that becomes of the television.
    public func readTheTelevisionsList() async {
        if scope == .reservations { await model.loadReservations(of: .tv) }
        if scope == .recordings { await model.loadTVTitles() }
    }
}
