import RecorderKit
import SwiftUI

/// One box that searches the three lists the app holds: programmes still to come, what is set to record,
/// and what is already recorded. The guide half reads the on-device cache, so it works away from home; the
/// other two read what the recorder has said, which needs it to be reachable -- and, of what is set to record,
/// what the television has said as well.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    // `-searchFor ニュース` fills the box at launch, which is how the results are checked without typing.
    @State private var query = UserDefaults.standard.string(forKey: DefaultsKey.searchFor) ?? ""
    // `-searchScope recordings` picks which of the three to search, the same way `-startTab` picks a tab.
    @State private var scope = Scope(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.searchScope) ?? "")
        ?? .guide
    @State private var guide = GuideSearchResults()
    /// The words `guide` is the answer to. While they differ from what is in the box the answer is on its
    /// way, and the old one is left up so that the list does not blink at every character typed.
    @State private var answered = ""
    @State private var openedProgram: GuideProgramRow?
    @State private var openedReservation: Reservation?
    @State private var openedTitle: RecordedTitle?

    enum Scope: String, CaseIterable, Identifiable {
        case guide, reservations, recordings
        var id: Self { self }

        var label: String {
            switch self {
            case .guide: "番組表"
            case .reservations: "予約"
            case .recordings: "録画"
            }
        }

        var prompt: String {
            switch self {
            case .guide: "番組名・出演者・番組内容"
            case .reservations: "予約した番組名"
            case .recordings: "録画した番組名"
            }
        }

        /// What the scope looks through. The reservations' names the television too where one is registered,
        /// since its reservations are among what is found.
        func explanation(withTelevision: Bool) -> String {
            switch self {
            case .guide:
                "番組名、番組内容、出演者などの詳細に含まれる言葉で、今後 8 日分の番組を検索します。"
                    + "番組名に含まれるものから順に並びます。"
            case .reservations:
                (withTelevision ? "レコーダーとテレビ" : "レコーダー")
                    + "に登録されている予約を番組名で検索します。おまかせ・まる録による予約も含みます。"
            case .recordings:
                "レコーダーに録画されている番組を番組名で検索します。"
            }
        }
    }

    /// The same normalisation and the same words the cache search uses in SQL, so that what matches in one
    /// place matches in the others: full width and half width, upper and lower case, all the same, and every
    /// word separated by a space has to be there.
    private func matches(_ text: String) -> Bool {
        Search.matches(query, in: text)
    }

    /// Of both devices, as the reservations' own tab lists them.
    private var reservations: [Reservation] {
        model.allReservations.filter { matches($0.title) }
    }

    private var recordings: [RecordedTitle] {
        model.titles.filter { matches($0.title) }
    }

    /// Nothing to look for: an empty box, or spaces alone, which would otherwise match every reservation.
    private var blank: Bool { Search.terms(query).isEmpty }

    private var count: Int {
        guard !blank else { return 0 }
        switch scope {
        case .guide: return guide.hits.count
        case .reservations: return reservations.count
        case .recordings: return recordings.count
        }
    }

    /// The guide's answer is still on its way and there is nothing from before to show meanwhile.
    private var waiting: Bool {
        scope == .guide && answered != query && guide.hits.isEmpty
    }

    /// What the guide search is run again for: new words, or coming back to the guide from the other two.
    private struct GuideRequest: Equatable {
        var query: String
        var scope: Scope
    }

    /// What has the reservations and the recordings read: the scope turned to, and the app becoming connected.
    private struct ListsWanted: Equatable {
        var scope: Scope
        var connected: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if blank {
                    ContentUnavailableView {
                        Label("\(scope.label)を検索", systemImage: "magnifyingglass")
                    } description: {
                        Text(scope.explanation(withTelevision: model.tv != nil)
                             + "\nスペースで区切ると、すべての語を含むものに絞り込みます。"
                             + "全角と半角、大文字と小文字は区別しません。")
                    }
                } else if waiting {
                    ProgressView().controlSize(.large)
                } else if count == 0 {
                    ContentUnavailableView.search(text: query)
                } else {
                    results
                }
            }
            .recorderActivity()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("検索").font(.subheadline.weight(.semibold))
                        if count > 0 {
                            Text("\(scope.label) \(count) 件\(scope == .guide && guide.more ? "以上" : "")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: scope.prompt)
            .searchScopes($scope) {
                ForEach(Scope.allCases) { Text($0.label).tag($0) }
            }
            // The task is cancelled whenever the text or the scope changes, so the wait is the debounce. The
            // guide is searched only while it is the scope.
            .task(id: GuideRequest(query: query, scope: scope)) {
                guard scope == .guide else { return }
                guard !blank else {
                    guide = GuideSearchResults()
                    answered = ""
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let found = await model.search(query)
                guard !Task.isCancelled else { return }
                guide = found
                answered = query
            }
            // Coming back with other words than the list on screen answers: that list is not left up while
            // the new one comes, as it is while typing, since nothing on screen would say it is the old one.
            .onChange(of: scope) { _, scope in
                if scope == .guide, answered != query { guide = GuideSearchResults() }
            }
            // The other two lists are searched where they already are, in memory, so they have to be there.
            // Whichever screen fetched them first pays for it; this one only asks, and asks again when the app
            // becomes connected, as their own screens do, since the lists go when another recorder answers.
            .task(id: ListsWanted(scope: scope, connected: model.connected && !model.offline)) {
                switch scope {
                case .guide: break
                case .reservations: await model.loadReservations()
                case .recordings: await model.loadTitles()
                }
            }
            // The television's reservations in a task of its own, as on the reservations' tab: the one above
            // asks the recorder, and is not to run again for anything that becomes of the television.
            .task(id: scope) {
                if scope == .reservations { await model.tvHost?.loadReservations() }
            }
            .sheet(item: $openedProgram) { ProgramSheet(program: $0) }
            .sheet(item: $openedReservation) { ReservationSheet(reservation: $0) }
            .sheet(item: $openedTitle) { TitleSheet(title: $0) }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch scope {
        case .guide:
            List {
                // At the top, where it is read before the list is taken for everything there is. The best
                // matches are what the list holds, so narrowing is the way to the rest.
                if guide.more {
                    Text("\(guide.hits.count) 件以上あります。語を足して絞り込んでください")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(guide.hits) { hit in
                    let program = hit.program
                    Button { openedProgram = program } label: {
                        ProgramRowView(program: program, logo: model.logo(for: program),
                                       reservation: model.reservation(for: program),
                                       pending: model.pending(for: program), snippet: hit.snippet)
                            .rowHitArea()
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        case .reservations:
            List(reservations, id: \.listKey) { reservation in
                Button { openedReservation = reservation } label: {
                    ReservationRowView(reservation: reservation,
                                       channel: model.channelName(for: reservation),
                                       logo: model.logo(for: reservation),
                                       device: model.tv != nil ? reservation.device.label : nil)
                        .rowHitArea()
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        case .recordings:
            List(recordings) { title in
                Button { openedTitle = title } label: {
                    TitleRowView(title: title, channel: model.channelName(for: title),
                                 logo: model.logo(for: title))
                        .rowHitArea()
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}
