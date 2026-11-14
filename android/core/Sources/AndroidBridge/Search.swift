import Foundation
import RecBridgeModel
import RecorderKit

/// The search (`SearchScreen` on iOS): one box over the programmes still to come, what is set to record and what is
/// recorded, as the model's `SearchState` works it.
public struct SearchScreen: Sendable {
    /// What is shown (`SearchState.Shows`): `scopeExplained`, `waiting`, `nothingFound` or `results`. The scopes are
    /// on this screen at all times, so it never says to tap the field for them (`invitation`).
    public var shows: String
    /// What is said in place of the results: what the chosen scope searches and how, or that nothing was found.
    public var said: Said
    /// 番組表, 予約 and 録画, and the one searched.
    public var scopes: [Labelled]
    public var scope: String
    /// What the field says while it is empty.
    public var prompt: String
    /// What is in the box, as the model has it: what the field starts with.
    public var query: String
    /// `番組表 12 件以上`, while something is found.
    public var countLine: String
    /// At the top of the guide's results when there are more than the list holds.
    public var moreLine: String
    public var programmes: [FoundProgramme]
    /// The logos of the stations the programmes found are on, each once.
    public var logos: [StationLogo]
    public var reservations: [ReservationRow]
    public var recordings: [RecordingRow]
}

/// A programme the guide's search found: its row as the guide's list words it, the day it is on, since what is found
/// is of every day of the guide, and, for one found only in its details, the words found with a little on either side.
public struct FoundProgramme: Sendable {
    public var row: GuideRow
    /// `11/8(日)`.
    public var day: String
    /// The key of its station's logo among `SearchScreen.logos`.
    public var logo: String
    public var hasSnippet: Bool
    public var before: String
    public var match: String
    public var after: String
}

public struct StationLogo: Sendable {
    public var key: String
    /// As an image file.
    public var image: [UInt8]
}

public final class SearchWindow: Sendable {
    let model: AppModel
    let search: SearchState
    private let shown: Watched<SearchScreen>
    private let tasks = SearchTasks()

    @MainActor
    init(_ model: AppModel) {
        self.model = model
        let search = SearchState(model: model)
        // The scopes are offered beside the field all the time here, not only once the field is tapped, so the
        // screen says what the chosen one searches from the start.
        search.searching = true
        self.search = search
        shown = Watched { SearchWindow.screen(search, model) }
    }

    public func read() async -> SearchScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// The screen has come on, or gone: told in the order it happened. While it is on, the window searches and reads
    /// as the iOS screen's three tasks do, each begun again when what it is keyed by moves.
    public func shown(_ on: Bool) async {
        await MainActor.run { on ? tasks.begin(search) : tasks.end() }
    }

    public func type(_ text: String) async {
        await MainActor.run { search.query = text }
    }

    public func chooseScope(_ code: String) async {
        await MainActor.run { if let scope = SearchState.Scope(rawValue: code) { search.scope = scope } }
    }

    /// The sheet of a programme found, while the results have it.
    public func openProgramme(_ id: String) async -> ProgrammeSheetWindow? {
        await MainActor.run {
            search.guide.hits.first { $0.id == id }.map {
                ProgrammeSheetWindow(ProgramSheetState(program: $0.program, model: model), model: model)
            }
        }
    }

    /// The sheet of a reservation found, while a device's list has it.
    public func openReservation(_ id: String) async -> ReservationSheetWindow? {
        await MainActor.run {
            model.reservation(listKey: id).map {
                ReservationSheetWindow(ReservationSheetState(reservation: $0, model: model), model: model)
            }
        }
    }

    /// The sheet of a recording found, while a device's list has it.
    public func openRecording(_ id: String) async -> TitleSheetWindow? {
        await MainActor.run {
            model.allTitles.first { $0.listKey == id }.map {
                TitleSheetWindow(TitleSheetState(title: $0, model: model), model: model)
            }
        }
    }

    @MainActor
    private static func screen(_ search: SearchState, _ model: AppModel) -> SearchScreen {
        let shows = search.shows
        var said = Said("")
        switch shows {
        case .invitation: said = Said(SearchState.invitation)
        case .scopeExplained: said = Said(search.scopeExplained)
        case .nothingFound: said = Said("見つかりませんでした", "「\(search.query)」に当てはまるものは、\(search.scope.label)にありません。")
        case .waiting, .results: break
        }
        let hits = shows == .results && search.scope == .guide ? search.guide.hits : []
        var logos: [StationLogo] = [], listed: Set<String> = []
        let programmes = hits.map { hit -> FoundProgramme in
            let program = hit.program
            let key = "\(program.broadcasting)-\(program.serviceID)"
            if listed.insert(key).inserted, let logo = model.logo(for: program) {
                logos.append(StationLogo(key: key, image: [UInt8](logo)))
            }
            return FoundProgramme(row: GuideWindow.row(program, model), day: Format.day.string(from: program.start),
                                  logo: key, hasSnippet: hit.snippet != nil, before: hit.snippet?.before ?? "",
                                  match: hit.snippet?.match ?? "", after: hit.snippet?.after ?? "")
        }
        return SearchScreen(
            shows: "\(shows)", said: said,
            scopes: SearchState.Scope.allCases.map { Labelled(code: $0.rawValue, label: $0.label) },
            scope: search.scope.rawValue, prompt: search.scope.prompt, query: search.query,
            countLine: search.countLine ?? "", moreLine: search.moreLine ?? "", programmes: programmes, logos: logos,
            // A reservation found says its day before its time: the list it is found in is not under the days'
            // headings, as the reservations' own is.
            reservations: shows == .results && search.scope == .reservations
                ? search.reservations.map { reservation in
                    var row = ReservationsWindow.row(reservation, model)
                    row.time = Format.dateTime.string(from: reservation.start)
                    return row
                } : [],
            recordings: shows == .results && search.scope == .recordings
                ? search.recordings.map { RecordingsWindow.row($0, model) } : [])
    }
}

/// The search screen's three tasks, as the iOS screen keys them (`task(id:)`): the guide searched again a moment
/// after the words or the scope change, the recorder's lists read as a scope is turned to and as the app connects,
/// and the television's as a scope is turned to.
@MainActor
final class SearchTasks {
    private let guide = TaskByID(), lists = TaskByID(), televisions = TaskByID()

    nonisolated init() {}

    func begin(_ search: SearchState) {
        guide.begin(id: { search.guideRequest }) { await search.searchTheGuide() }
        lists.begin(id: { search.listsWanted }) { await search.readTheRecordersList() }
        televisions.begin(id: { search.scope }) { await search.readTheTelevisionsList() }
    }

    func end() {
        guide.end()
        lists.end()
        televisions.end()
    }
}
