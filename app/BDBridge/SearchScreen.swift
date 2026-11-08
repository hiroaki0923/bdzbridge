import RecBridgeModel
import RecorderKit
import SwiftUI

/// One box that searches the three lists the app holds: programmes still to come, what is set to record,
/// and what is already recorded. The guide half reads the on-device cache, so it works away from home; the
/// other two read what the recorder has said, which needs it to be reachable -- and, of what is set to record,
/// what the television has said as well.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search: SearchState
    @State private var openedProgram: GuideProgramRow?
    @State private var openedReservation: Reservation?
    @State private var openedTitle: RecordedTitle?

    init(model: AppModel) {
        _search = State(initialValue: SearchState(model: model))
    }

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            Group {
                switch search.shows {
                case .invitation:
                    ContentUnavailableView {
                        Label(SearchState.invitation.title, systemImage: "magnifyingglass")
                    } description: {
                        Text(SearchState.invitation.detail ?? "")
                    }
                case .scopeExplained:
                    ContentUnavailableView {
                        Label(search.scopeExplained.title, systemImage: "magnifyingglass")
                    } description: {
                        Text(search.scopeExplained.detail ?? "")
                    }
                case .waiting:
                    ProgressView().controlSize(.large)
                case .nothingFound:
                    ContentUnavailableView.search(text: search.query)
                case .results:
                    results
                }
            }
            .recorderActivity()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("検索").font(.subheadline.weight(.semibold))
                        if let line = search.countLine {
                            Text(line).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search.query, isPresented: $search.searching, prompt: search.scope.prompt)
            // Offered as soon as the field is tapped, before anything is typed, which is what the screen says
            // until then; left to the system, they would wait for the first letter.
            .searchScopes($search.scope, activation: .onSearchPresentation) {
                ForEach(SearchState.Scope.allCases) { Text($0.label).tag($0) }
            }
            // Cancelled whenever the words or the scope change, so the model's wait is the debounce.
            .task(id: search.guideRequest) { await search.searchTheGuide() }
            .task(id: search.listsWanted) { await search.readTheRecordersList() }
            .task(id: search.scope) { await search.readTheTelevisionsList() }
            .sheet(item: $openedProgram) { ProgramSheet(program: $0, model: model) }
            .sheet(item: $openedReservation) { ReservationSheet(reservation: $0, model: model) }
            .sheet(item: $openedTitle) { TitleSheet(title: $0) }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch search.scope {
        case .guide:
            List {
                if let more = search.moreLine {
                    Text(more).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(search.guide.hits) { hit in
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
            List(search.reservations, id: \.listKey) { reservation in
                Button { openedReservation = reservation } label: {
                    ReservationRowView(reservation: reservation,
                                       channel: model.channelName(for: reservation),
                                       logo: model.logo(for: reservation),
                                       device: model.tv != nil ? reservation.device.label : nil,
                                       disk: model.diskShown(reservation))
                        .rowHitArea()
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        case .recordings:
            List(search.recordings) { title in
                Button { openedTitle = title } label: {
                    TitleRowView(title: title, channel: model.channelName(for: title),
                                 logo: model.logo(for: title), disk: model.diskShown(title))
                        .rowHitArea()
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}
