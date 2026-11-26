import RecBridgeModel
import RecorderKit
import SwiftUI

/// One box that searches the three lists the app holds: programmes still to come, what is set to record,
/// and what is already recorded. The guide half reads the on-device cache, so it works away from home; the
/// other two read what the recorder has said, which needs it to be reachable -- and, of what is set to record,
/// what the television has said as well.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var search: SearchState
    /// The programme, the reservation or the recording open, made here as its row is tapped and handed to its sheet
    /// or to the one column (`OpenRow`).
    @State private var row = OpenRow<Opened>()

    /// What a result opens: the state of a programme's, a reservation's or a recording's sheet.
    enum Opened: RowSheetState {
        case program(ProgramSheetState)
        case reservation(ReservationSheetState)
        case title(TitleSheetState)

        /// The state's own, each being one opening of one row. Nonisolated, as `Identifiable` asks of it: it reads
        /// nothing that changes.
        nonisolated var id: ObjectIdentifier {
            switch self {
            case .program(let sheet): sheet.id
            case .reservation(let sheet): sheet.id
            case .title(let sheet): sheet.id
            }
        }

        var requestOut: Bool {
            switch self {
            case .program(let sheet): sheet.requestOut
            case .reservation(let sheet): sheet.requestOut
            case .title(let sheet): sheet.requestOut
            }
        }

        var hasSomethingToSay: Bool {
            switch self {
            case .program(let sheet): sheet.hasSomethingToSay
            case .reservation(let sheet): sheet.hasSomethingToSay
            case .title(let sheet): sheet.hasSomethingToSay
            }
        }
    }

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
            // On a regular width a result opens beside the results, under the bar, rather than over them: in the
            // one column, whichever kind it is.
            .inspectorColumn(row, inColumn: inColumn) { opened in
                switch opened {
                case .program(let sheet): ProgramColumn(sheet: sheet, close: row.close)
                case .reservation(let sheet): ReservationColumn(sheet: sheet, close: row.close)
                case .title(let sheet): TitleColumn(sheet: sheet, close: row.close)
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
            .sheet(item: row.sheetShown(inColumn: inColumn)) { opened in
                switch opened {
                case .program(let sheet): ProgramSheet(sheet: sheet)
                case .reservation(let sheet): ReservationSheet(sheet: sheet)
                case .title(let sheet): TitleSheet(sheet: sheet)
                }
            }
            .onChange(of: search.query) { closeOffTheResults() }
            .onChange(of: search.scope) { closeOffTheResults() }
        }
    }

    /// Whether a result opens beside the results, in the system's inspector, rather than in a sheet over them: on a
    /// regular width, an iPad's. Never on an iPhone, which keeps the sheets it has always had.
    private var inColumn: Bool { sizeClass == .regular }

    /// The result each list marks as the one in the column, by what tells that list's rows apart. None in a sheet,
    /// which covers the results.
    private var markedProgram: GuideProgramRow.ID? {
        guard inColumn, case .program(let sheet)? = row.opened else { return nil }
        return sheet.program.id
    }

    private var markedReservation: String? {
        guard inColumn, case .reservation(let sheet)? = row.opened else { return nil }
        return sheet.reservation.listKey
    }

    private var markedTitle: String? {
        guard inColumn, case .title(let sheet)? = row.opened else { return nil }
        return sheet.title.listKey
    }

    /// Other words or another scope take what the column shows off the results beside it, and the column goes too,
    /// unless a request of its own is out. A sheet covers the results and stays.
    private func closeOffTheResults() {
        if inColumn { row.closeUnlessAsking() }
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
                    Button { row.open { .program(ProgramSheetState(program: program, model: model)) } } label: {
                        ProgramRowView(program: program, logo: model.logo(for: program),
                                       reservation: model.reservation(for: program),
                                       pending: model.pending(for: program), snippet: hit.snippet)
                            .rowHitArea()
                    }
                    .buttonStyle(.plain)
                    .markedOpen(markedProgram == program.id)
                }
            }
            .listStyle(.plain)
        case .reservations:
            List(search.reservations, id: \.listKey) { reservation in
                Button {
                    row.open { .reservation(ReservationSheetState(reservation: reservation, model: model)) }
                } label: {
                    ReservationRowView(reservation: reservation,
                                       channel: model.channelName(for: reservation),
                                       logo: model.logo(for: reservation),
                                       device: model.tv != nil ? reservation.device.label : nil,
                                       disk: model.diskShown(reservation))
                        .rowHitArea()
                }
                .buttonStyle(.plain)
                .markedOpen(markedReservation == reservation.listKey)
            }
            .listStyle(.plain)
        case .recordings:
            List(search.recordings) { title in
                Button { row.open { .title(TitleSheetState(title: title, model: model)) } } label: {
                    TitleRowView(title: title, channel: model.channelName(for: title),
                                 logo: model.logo(for: title), disk: model.diskShown(title))
                        .rowHitArea()
                }
                .buttonStyle(.plain)
                .markedOpen(markedTitle == title.listKey)
            }
            .listStyle(.plain)
        }
    }
}
