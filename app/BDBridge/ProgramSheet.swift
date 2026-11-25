import RecBridgeModel
import RecorderKit
import SwiftUI

/// One programme: what it is, whether the recorder is already set to record it -- or will be, once a
/// reservation waiting on this phone reaches it -- and the two choices that go with a new reservation. What the
/// sheet holds, offers, holds back and says, and what each press does, are the model's (`ProgramSheetState`):
/// this lays it out, in a sheet over the screen or, from the guide on an iPad, in a column beside it
/// (`ProgramColumn`), the same rows over the same state either way (`ProgramDetails`).
struct ProgramSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: ProgramSheetState

    /// The sheet of a state the screen that opened it made and keeps: the guide's and the search's. A presented
    /// sheet is made afresh for each state it is handed, so the one kept here is always the one handed in.
    init(sheet: ProgramSheetState) {
        _sheet = State(initialValue: sheet)
    }

    var body: some View {
        NavigationStack {
            ProgramDetails(sheet: sheet)
                .navigationTitle(ProgramSheetState.sheetTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetCloseButton().disabled(sheet.holdsTheSheet) }
                .onChange(of: sheet.done) { if $1 { dismiss() } }
        }
    }
}

/// The programme in the guide's inspector, the column beside the guide on a regular width, an iPad's. The column
/// has no bar of its own -- what is put in a toolbar here goes up into the window's -- so its title and its close
/// are a row at its top, which the rows scroll under. A request that is done leaves it open, where the sheet closes
/// itself: the column holds nothing of the guide up, and shows what became of the programme.
struct ProgramColumn: View {
    let sheet: ProgramSheetState
    /// What the close does: an inspector is closed by its binding, not by the system's dismiss.
    let close: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            // The system blurs what scrolls under a bar put here, as it does under a navigation bar.
            ProgramDetails(sheet: sheet).safeAreaBar(edge: .top, spacing: 0) { titleRow }
        } else {
            // Nothing of the system's is drawn behind an inset, and the rows scrolled under it would print over
            // the title.
            ProgramDetails(sheet: sheet).safeAreaInset(edge: .top, spacing: 0) { titleRow.background(.bar) }
        }
    }

    private var titleRow: some View {
        HStack {
            Text(ProgramSheetState.sheetTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            SheetCloseButton(close: close).disabled(sheet.holdsTheSheet)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// The programme's rows and what they do, in the sheet and in the column alike.
private struct ProgramDetails: View {
    @Environment(AppModel.self) private var model
    let sheet: ProgramSheetState

    private var program: GuideProgramRow { sheet.program }

    var body: some View {
        @Bindable var sheet = sheet
        List {
            WakingSection()
            Section {
                Text(program.title).font(.headline)
                LabeledContent(SheetWords.station, value: program.serviceName)
                LabeledContent(SheetWords.starts, value: Format.dateTime.string(from: program.start))
                LabeledContent(SheetWords.length, value: Format.duration(program.durationSec))
                if let genre = program.genre?.label {
                    LabeledContent(SheetWords.genre, value: genre)
                }
            }

            if let reservation = sheet.reservation {
                Section(sheet.recordersHeading) {
                    LabeledContent(SheetWords.quality, value: ProgramSheetState.qualityName(reservation))
                    LabeledContent(SheetWords.repeating, value: SheetWords.repeatShown(reservation))
                    if let shown = model.diskShown(reservation) { LabeledContent(SheetWords.disk, value: shown) }
                    if reservation.recording { Text(SheetWords.recordingLine).foregroundStyle(.red) }
                    if sheet.offersChanging(reservation) {
                        Button(ProgramSheetState.changeLabel) { sheet.change(reservation) }
                            .disabled(sheet.holdsTheRecordersButtons)
                    }
                    Button(SheetWords.deleteReservationLabel, role: .destructive) { sheet.delete(reservation) }
                        .disabled(sheet.holdsTheRecordersButtons)
                }
            }
            if let televisions = sheet.televisions {
                televisionSection(televisions)
            }
            if let waiting = sheet.waiting(on: .recorder) {
                pendingSection(waiting)
            }
            if let waiting = sheet.waiting(on: .tv) {
                pendingSection(waiting)
            }
            if let asking = sheet.asking {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(asking).font(.callout)
                    }
                }
            }
            if sheet.offersAReservation(on: .recorder) {
                Section(ProgramSheetState.reserveHeading) {
                    destinationRow(.recorder)
                    NewDiskRow(chosen: $sheet.chosenDisk)
                    Picker(SheetWords.quality, selection: $sheet.quality) {
                        ForEach(RecorderDriver.recordsIn, id: \.self) { code in
                            Text(SheetWords.qualityLabel(code)).tag(code)
                        }
                    }
                    Picker(SheetWords.repeating, selection: $sheet.repeating) {
                        ForEach(sheet.repeatOptions, id: \.self) { key in
                            Text(SheetWords.repeatLabel(key)).tag(key)
                        }
                    }
                    conflictRow
                    Button(ProgramSheetState.reserveLabel) { sheet.reserveOnTheRecorder() }
                        .disabled(sheet.holdsReservingOnTheRecorder)
                }
            } else if sheet.offersAReservation(on: .tv) {
                televisionOffer
            }

            if !program.summary.isEmpty {
                Section(SheetWords.summaryHeading) { Text(program.summary) }
            }
            if !program.extended.isEmpty {
                Section(SheetWords.detailsHeading) { Text(program.extended) }
            }
            if let problem = model.problem(for: .recorder) {
                Section { Text(problem.asABody).foregroundStyle(.red).font(.callout) }
            }
        }
        .disabled(sheet.asking != nil)
        .interactiveDismissDisabled(sheet.holdsTheSheet)
        .task(id: sheet.checkKey) { await sheet.check() }
        .task { await sheet.opened() }
        .onChange(of: sheet.device) { sheet.deviceChanged(to: $1) }
        .sheet(item: $sheet.editing) { ReservationSheet(reservation: $0, model: model) }
        .onChange(of: model.timesForgotten) { sheet.recordersListsLetGo() }
        .onChange(of: model.usbDisk) { sheet.usbDiskChanged() }
        .onChange(of: model.tvTimesForgotten) { sheet.televisionsListsLetGo() }
        .onChange(of: model.timesAttached) { sheet.recorderAttached() }
        .alert(sheet.askTitle, isPresented: Binding(get: { sheet.ask != nil },
                                                    set: { if !$0 { sheet.askClosed() } }),
               presenting: sheet.ask) { asked in
            if let action = sheet.actionLabel(for: asked) {
                Button(action.label, role: action.destructive ? .destructive : nil) { sheet.act(on: asked) }
            }
            Button(sheet.closingLabel(for: asked), role: .cancel) { sheet.close(asked) }
        } message: { asked in
            Text(sheet.message(for: asked))
        }
    }

    /// 録画予約 for the television: the one mode it records in and the repeats it is sent for this programme.
    private var televisionOffer: some View {
        @Bindable var sheet = sheet
        return Section(ProgramSheetState.reserveHeading) {
            destinationRow(.tv)
            LabeledContent(SheetWords.quality, value: ProgramSheetState.televisionsQuality)
            Picker(SheetWords.repeating, selection: $sheet.repeating) {
                ForEach(sheet.televisionRepeatOptions, id: \.self) { key in
                    Text(SheetWords.repeatLabel(key)).tag(key)
                }
            }
            Button(ProgramSheetState.reserveLabel) { sheet.reserveOnTheTelevision() }
                .disabled(sheet.holdsReservingOnTheTelevision)
        }
    }

    /// 予約先: a choice with both devices free, one fixed line where the other holds the programme or has it
    /// waiting, and nothing in a home with one device.
    @ViewBuilder
    private func destinationRow(_ device: DeviceSlot) -> some View {
        if let free = sheet.destinationChoices {
            Picker(ProgramSheetState.destination, selection: Binding(get: { device }, set: { sheet.choose($0) })) {
                ForEach(free, id: \.self) { Text($0.label).tag($0) }
            }
        } else if sheet.showsTheDestinationAlone {
            LabeledContent(ProgramSheetState.destination, value: device.label)
        }
    }

    /// The television's reservation of this programme, under the television's name. What went wrong with the
    /// television is said under the button that ran into it, and not at the sheet's foot, which is the recorder's.
    private func televisionSection(_ reservation: Reservation) -> some View {
        Section(DeviceSlot.tv.label) {
            LabeledContent(SheetWords.repeating, value: SheetWords.repeatShown(reservation))
            if reservation.recording { Text(SheetWords.recordingLine).foregroundStyle(.red) }
            if sheet.offersChanging(reservation) {
                Button(ProgramSheetState.changeLabel) { sheet.change(reservation) }
                    .disabled(sheet.holdsChangingTheTelevisions)
            }
            Button(SheetWords.deleteReservationLabel, role: .destructive) { sheet.delete(reservation) }
                .disabled(sheet.holdsDeletingTheTelevisions)
            if let problem = model.problem(for: .tv) {
                Text(problem.asABody).foregroundStyle(.red).font(.callout)
            }
        }
    }

    /// A reservation made while its device could not be reached: what was asked for, since the device has not
    /// made anything of it yet, and what the device said if it refused.
    private func pendingSection(_ waiting: PendingReservation) -> some View {
        Section(sheet.waitingHeading(waiting.target)) {
            LabeledContent(SheetWords.quality, value: ProgramSheetState.qualityShown(waiting))
            LabeledContent(SheetWords.repeating, value: ProgramSheetState.repeatShown(waiting))
            if let shown = model.diskShown(waiting) { LabeledContent(SheetWords.disk, value: shown) }
            if let problem = waiting.problem {
                Text(problem.asABody).foregroundStyle(.red).font(.callout)
                Button(ProgramSheetState.sendAgainLabel) { sheet.sendAgain(waiting) }
                    .disabled(sheet.holdsSendingAgain(waiting))
            } else {
                Text(PendingQueue.notYetAt(waiting.target))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Button(ProgramSheetState.deleteWaitingLabel, role: .destructive) { sheet.deleteWaiting(waiting) }
                .disabled(sheet.holdsDeletingWaiting(waiting))
        }
    }

    /// What the recorder answers when asked what a new reservation would clash with.
    @ViewBuilder
    private var conflictRow: some View {
        if sheet.checking {
            HStack {
                ProgressView().controlSize(.small)
                Text(ProgramSheetState.checkingLine).foregroundStyle(.secondary)
            }
        } else if let conflicts = sheet.conflicts {
            if conflicts.isEmpty {
                Label(ProgramSheetState.conflictsLine(conflicts), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(ProgramSheetState.conflictsLine(conflicts), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.legibleOrange)
                        .font(.callout)
                    ForEach(conflicts) { conflict in
                        Text("\(Format.dateTime.string(from: conflict.start)) \(conflict.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
