import RecorderKit
import SwiftUI

/// One box that searches the three lists the app holds: programmes still to come, what is set to record,
/// and what is already recorded. The guide half reads the on-device cache, so it works away from home; the
/// other two read what the recorder has said, which needs it to be reachable.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    // `-searchFor ニュース` fills the box at launch, which is how the results are checked without typing.
    @State private var query = UserDefaults.standard.string(forKey: "searchFor") ?? ""
    // `-searchScope recordings` picks which of the three to search, the same way `-startTab` picks a tab.
    @State private var scope = Scope(rawValue: UserDefaults.standard.string(forKey: "searchScope") ?? "")
        ?? .guide
    @State private var programs: [GuideProgramRow] = []
    @State private var searching = false
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
            case .guide: "番組名・番組内容"
            case .reservations: "予約した番組名"
            case .recordings: "録画した番組名"
            }
        }

        var explanation: String {
            switch self {
            case .guide:
                "番組名か番組内容に含まれる言葉で、これから放送される 8 日分を探します。"
            case .reservations:
                "レコーダーに入っている予約を番組名で探します。おまかせ録画が入れたものも含みます。"
            case .recordings:
                "レコーダーに録れている番組を名前で探します。"
            }
        }
    }

    /// The same normalisation the cache search uses in SQL, so that what matches in one place matches in
    /// the others: full width and half width, upper and lower case, all the same.
    private func matches(_ text: String) -> Bool {
        Search.normalise(text).contains(Search.normalise(query))
    }

    private var reservations: [Reservation] {
        model.reservations.filter { matches($0.title) }
    }

    private var recordings: [RecordedTitle] {
        model.titles.filter { matches($0.title) }
    }

    private var count: Int {
        switch scope {
        case .guide: programs.count
        case .reservations: reservations.count
        case .recordings: recordings.count
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("\(scope.label)を探す", systemImage: "magnifyingglass")
                    } description: {
                        Text(scope.explanation + "\n全角と半角、大文字と小文字は区別しません。")
                    }
                } else if searching {
                    ProgressView().controlSize(.large)
                } else if count == 0 {
                    ContentUnavailableView.search(text: query)
                } else {
                    results
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("検索").font(.subheadline.weight(.semibold))
                        if count > 0 {
                            Text("\(scope.label) \(count) 件").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: scope.prompt)
            .searchScopes($scope) {
                ForEach(Scope.allCases) { Text($0.label).tag($0) }
            }
            // the task is cancelled whenever the text changes, so the wait is the debounce
            .task(id: query) {
                guard !query.isEmpty else {
                    programs = []
                    return
                }
                searching = programs.isEmpty
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                programs = await model.search(query)
                searching = false
            }
            // The other two lists are searched where they already are, in memory, so they have to be there.
            // Whichever screen fetched them first pays for it; this one only asks.
            .task(id: scope) {
                switch scope {
                case .guide: break
                case .reservations: await model.loadReservations()
                case .recordings: await model.loadTitles()
                }
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
            List(programs) { program in
                Button { openedProgram = program } label: {
                    ProgramRowView(program: program, logo: model.logo(for: program),
                                   reservation: model.reservation(for: program))
                        .rowHitArea()
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        case .reservations:
            List(reservations) { reservation in
                Button { openedReservation = reservation } label: {
                    ReservationRowView(reservation: reservation,
                                       channel: model.channelName(for: reservation),
                                       logo: model.logo(for: reservation))
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
